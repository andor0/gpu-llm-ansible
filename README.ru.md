# gpu-llm-ansible

[English](README.md) · **Русский**

Ansible-плейбуки для настройки GPU-сервера (Ubuntu + NVIDIA) и запуска LLM с доступом через OpenAI-совместимый API.

## Требования

- **Сервер:** Ubuntu 26.04 LTS (поддерживается и 24.04), NVIDIA GPU, SSH-доступ с sudo.
- **Управляющая машина:** ansible-core ≥ 2.20 (на Ubuntu 26.04 Python 3.14, старые версии Ansible его не поддерживают):
  ```bash
  pip install -r requirements-dev.txt
  ansible-galaxy collection install -r requirements.yml
  ```

## Плейбуки

| Плейбук | Хосты | Что делает |
|---|---|---|
| `playbooks/ollama.yml` | `gpu_servers` | Драйвер, Docker, NVIDIA Container Toolkit, **Ollama**, nginx, агент мониторинга, проверка. Работает и без GPU (CPU-режим) |
| `playbooks/vllm.yml` | `gpu_servers` | То же, но с **vLLM** (требует NVIDIA GPU) |
| `playbooks/monitoring.yml` | `monitoring` | VictoriaMetrics, vmalert, Grafana (+ Alertmanager) |

## Роли

| Роль | Назначение |
|---|---|
| `common` | Pre-flight проверки, базовые пакеты, UFW, определение GPU (`gpu_enabled`) |
| `nvidia_driver` | Драйвер NVIDIA (`-server-open`), hold, reboot, persistenced |
| `docker` | Docker CE, `daemon.json` (ротация логов, CDI) |
| `nvidia_container_toolkit` | NVIDIA Container Toolkit, CDI, smoke test `nvidia-smi` в контейнере |
| `ollama` | Ollama в Docker Compose, загрузка модели |
| `vllm` | vLLM в Docker Compose |
| `llm_proxy` | nginx: TLS, Bearer-токены, rate limit, allowlist путей |
| `monitoring_agent` | node_exporter, dcgm-exporter, vmagent → VictoriaMetrics |
| `monitoring_stack` | VictoriaMetrics, vmalert, Grafana с дашбордами |
| `llm_verify` | Health check, тестовый inference, проверка авторизации |

`ollama` и `vllm` подключаются к общим ролям через переменные, заданные в плейбуке:
`llm_backend`, `llm_upstream_port`, `llm_health_path`, `llm_served_model`.

## Быстрый старт

```bash
# inventory и секреты
cp -r inventories/example inventories/prod   # указать IP хостов
cp inventories/prod/group_vars/all/vault.yml.example inventories/prod/group_vars/all/vault.yml
ansible-vault encrypt inventories/prod/group_vars/all/vault.yml

ansible-playbook -i inventories/prod playbooks/monitoring.yml --ask-vault-pass
ansible-playbook -i inventories/prod playbooks/ollama.yml --ask-vault-pass   # или vllm.yml

# только проверка
ansible-playbook -i inventories/prod playbooks/ollama.yml --tags llm_verify --ask-vault-pass
```

## Доступ к API

Модель слушает только `127.0.0.1`, наружу её отдаёт nginx (роль `llm_proxy`):

- HTTPS (по умолчанию self-signed; `llm_proxy_tls_mode: provided` — свой сертификат, например Cloudflare Origin CA), HTTP → 301 на HTTPS;
- авторизация по Bearer-токену из `llm_proxy_api_keys` (несколько ключей, без токена — `401`);
- rate limit на токен (`10r/s`, burst `20`, сверх — `429`);
- открыты только `/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`, `/v1/models`
  (+ `/api/chat`, `/api/generate` для Ollama); всё остальное, включая `/api/pull` и `/api/delete`, — `404`.

Новый ключ: добавить в `vault_llm_api_keys` и перезапустить с `--tags llm_proxy`. Отзыв — удалить и так же перезапустить.

## Проверка работоспособности

Роль `llm_verify` выполняется в конце каждого плейбука (отдельно — `--tags llm_verify`):

1. ждёт health-эндпоинт бэкенда (`/api/tags` у Ollama, `/health` у vLLM);
2. делает тестовый запрос к `/v1/chat/completions` и проверяет, что модель сгенерировала токены;
3. на GPU-сервере проверяет, что модель действительно в видеопамяти (`nvidia-smi`);
4. через nginx: без токена → `401`, `/api/pull` → `404`, с токеном → успешный ответ модели;
5. печатает сводку: бэкенд, модель, GPU, latency, ответ.

Ручная проверка:

```bash
nvidia-smi                                  # GPU и занятая память
docker ps                                   # контейнер healthy
docker logs -f ollama                       # или vllm
curl -s http://127.0.0.1:11434/api/tags     # Ollama (8000/health — vLLM), только на сервере
```

## vLLM

- Требует NVIDIA GPU; плейбук падает на pre-flight, если GPU нет.
- Первый запуск долгий: скачивание весов (Qwen3-8B ≈ 16 ГБ) и компиляция CUDA graphs; ожидание до `vllm_start_timeout` (30 мин).
- Модель по умолчанию `Qwen/Qwen3-8B` (≈ 24 ГБ VRAM с KV-кешем). Для GPU меньше — квантизованная модель
  (`vllm_model: Qwen/Qwen3-8B-AWQ`) или меньше `vllm_max_model_len`.
- Qwen3 — reasoning-модель: с `vllm_reasoning_parser: qwen3` (по умолчанию) «размышления» приходят в
  `reasoning_content`, а в `content` — только ответ. Для другой модели — свой парсер или пустая строка.
- `vllm_hf_token` нужен только для gated-моделей (Llama, Gemma): принять лицензию на huggingface.co и указать токен в `vault_hf_token`.
- Имя модели в API — `vllm_served_model_name` (по умолчанию `qwen3-8b`).

## Переключение бэкенда

На одном GPU-сервере работает один бэкенд: роль `ollama` останавливает vLLM, роль `vllm` — Ollama
(контейнер останавливается, модели и кэш остаются на диске). Переключиться — просто запустить другой плейбук;
nginx перенастраивается на новый upstream.

## Мониторинг

```
GPU-сервер                                         Сервер мониторинга (playbooks/monitoring.yml)
 node_exporter :9100 ┐                              ┌ VictoriaMetrics :8428 (basic auth)
 dcgm-exporter :9400 ├─▶ vmagent ── remote write ──▶├ vmalert → Alertmanager (опционально)
 vLLM /metrics :8000 ┘   (все на 127.0.0.1)          └ Grafana 127.0.0.1:3000
```

- **Агент** (`monitoring_agent`, входит в `ollama.yml`/`vllm.yml`): экспортеры слушают только localhost,
  vmagent добавляет метку `host=<inventory_hostname>` и отправляет метрики с basic auth. В конце роль
  ждёт, пока метрики хоста появятся в VictoriaMetrics.
- **Стек** (`monitoring_stack`): VictoriaMetrics (хранение `90d`), vmalert с правилами
  `roles/monitoring_stack/files/rules/gpu-llm.yml`, Grafana с datasource и дашбордами
  NVIDIA DCGM, Node Exporter Full, vLLM.
- **Доступ.** Docker публикует порты в обход UFW, поэтому:
  - VictoriaMetrics закрыта basic auth (`monitoring_write_password`); в проде задайте
    `monitoring_stack_victoriametrics_listen` с IP приватной сети (VPC/vRack);
  - Grafana слушает только localhost: `ssh -L 3000:127.0.0.1:3000 root@<monitoring-host>` → http://localhost:3000
    (логин `admin`, пароль `vault_grafana_admin_password`; применяется только при первом запуске Grafana).
- **Алерты:** температура GPU, XID-ошибки, сбой remap строк памяти и некорректируемые ошибки HBM,
  заполнение видеопамяти, недоступность цели сбора, заполнение диска, очередь vLLM. Отправка — после
  `monitoring_stack_alertmanager_enabled: true` и настройки `monitoring_stack_alertmanager_config`
  (receivers: Telegram/Slack/…).
- У Ollama нет Prometheus-метрик: для неё доступны метрики GPU и хоста, а доступность API проверяет `llm_verify`.

Если мониторинг ставится на тот же хост, что и LLM, хост добавляется в обе группы inventory, а
`common_gpu_mode: absent` из `group_vars/monitoring` нужно убрать (иначе GPU не будет обнаружен).

## Драйвер NVIDIA и обновления

Драйвер ставится из репозитория Ubuntu (`nvidia-headless-no-dkms-<branch>-server-open` + подписанные
модули `linux-modules-nvidia-<branch>-server-open-<flavour>`), без DKMS — работает с Secure Boot.

Пакет модулей выбирается по ядру: HWE — `generic-hwe-<версия>`, иначе суффикс ядра (`-generic`;
облачное `linux-virtual` — то же ядро `-generic`).

Пакеты драйвера **и мета-пакеты ядра** ставятся на hold: модули NVIDIA собраны под конкретное ядро,
и автоматическое обновление одного без другого оставит сервер без GPU. Обновлять осознанно:

```bash
ansible-playbook -i inventories/prod playbooks/ollama.yml --tags nvidia_driver -e nvidia_driver_upgrade=true
```

## Проверено на

DigitalOcean GPU Droplet: NVIDIA H100 SXM5 80GB, Ubuntu 26.04.1 LTS (ядро 7.0.0, `linux-virtual`), 2026-10-28.

| Плейбук | Результат |
|---|---|
| `ollama.yml` | драйвер 580.178.04 + перезагрузка, toolkit 1.20.1 (CDI), `qwen3:8b` 100% на GPU (~200 ток/с), повторный прогон `changed=0` |
| `vllm.yml` | vLLM v0.32.0, `Qwen/Qwen3-8B`, ~1 с на 200 токенов, повторный прогон `changed=0` |
| `monitoring.yml` | VictoriaMetrics, vmalert (8 правил), Grafana с 3 дашбордами; метрики GPU и vLLM (TTFT, токены, KV cache) доходят; повторный прогон `changed=0` |
| Снаружи | 401 без токена, 404 вне allowlist, стриминг через nginx; VictoriaMetrics — 401 без пароля; Grafana и экспортеры недоступны |

## CI

`.github/workflows/ci.yml`, раннер `ubuntu-26.04`:

| Job | Что проверяет |
|---|---|
| Lint | `yamllint --strict`, `ansible-lint` (profile `production`), `--syntax-check` всех плейбуков |
| E2E (monitoring + Ollama on CPU) | `monitoring.yml` и `ollama.yml` на раннере без GPU (`tests/ci/inventory.yml`, модель `qwen2.5:0.5b`), включая nginx, `llm_verify` и доставку метрик; повторные прогоны без изменений; `curl` через nginx, запросы к VictoriaMetrics и Grafana |

Роли с GPU (`nvidia_driver`, `nvidia_container_toolkit`) в CI пропускаются: на раннерах GitHub нет NVIDIA GPU.

Локально:

```bash
yamllint --strict . && ansible-lint
```

## Пример API-запроса

`model`: `qwen3:8b` для Ollama, `qwen3-8b` для vLLM (список — `GET /v1/models`).
С self-signed сертификатом добавьте `-k`.

```bash
curl https://llm.example.com/v1/chat/completions \
  -H "Authorization: Bearer $LLM_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
        "model": "qwen3:8b",
        "messages": [{"role": "user", "content": "Привет! Кто ты?"}],
        "max_tokens": 200
      }'
```

Python (OpenAI SDK), со стримингом:

```python
from openai import OpenAI

client = OpenAI(base_url="https://llm.example.com/v1", api_key="<LLM_API_KEY>")
stream = client.chat.completions.create(
    model="qwen3:8b",
    messages=[{"role": "user", "content": "Расскажи про Ansible в двух предложениях"}],
    stream=True,
)
for chunk in stream:
    print(chunk.choices[0].delta.content or "", end="", flush=True)
```

## TODO

- [ ] Секреты из Infisical
- [ ] README: таблица переменных, troubleshooting
