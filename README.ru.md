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

## Архитектура

### Сейчас

```
                         GPU-сервер (playbooks/ollama.yml | vllm.yml)
 Клиент ──HTTPS──▶ nginx :443  TLS · Bearer-токены · rate limit на токен · allowlist путей
                     │ 127.0.0.1
                     ▼
                   Ollama :11434  или  vLLM :8000     Docker Compose, один бэкенд на сервер
                     │
                   NVIDIA GPU   драйвер 580-server-open (подписанные модули) · Container Toolkit · CDI
                   container-autoheal (systemd-таймер): перезапуск unhealthy-контейнеров, метрики

 node_exporter · dcgm-exporter · vLLM /metrics ──▶ vmagent ──HTTPS + basic auth──┐
                                                                                 ▼
                       Сервер мониторинга (playbooks/monitoring.yml)    VictoriaMetrics :8428
                                                    Grafana ◀──────────────────┤
                                     Telegram ◀── Alertmanager ◀── vmalert ◀───┘
```

### Ключевые решения

| Решение | Почему |
|---|---|
| Docker Compose, а не Swarm | Одна GPU-нода на бэкенд; GPU в Swarm работают только через generic resources, `deploy.resources.reservations.devices` там игнорируется |
| Драйвер из репозитория Ubuntu, подписанные модули, без DKMS | Работает с Secure Boot, нет сборки модулей при обновлении ядра; драйвер и ядро на hold и обновляются вместе |
| Один бэкенд на GPU-сервер: Ollama или vLLM | Оба резервируют видеопамять; Ollama простая и работает на CPU (dev, CI), vLLM даёт throughput под параллельной нагрузкой (прод) |
| Модель на `127.0.0.1`, наружу только nginx | У Ollama нет авторизации и открыты `/api/pull`, `/api/delete`; TLS, токены и лимиты в одном месте |
| OpenAI-совместимый API | Клиенты не меняются при смене бэкенда или появлении gateway |
| Отдельный сервер мониторинга, push через vmagent | GPU-серверам не нужны входящие порты для мониторинга; работает между провайдерами (OVH, DigitalOcean, Cherry) |
| Autoheal как systemd-таймер | Политики перезапуска Docker игнорируют `unhealthy`; не нужен сторонний образ |

## Быстрый старт

```bash
# inventory и секреты
cp -r inventories/example inventories/prod   # указать IP хостов
cp inventories/prod/group_vars/all/vault.yml.example inventories/prod/group_vars/all/vault.yml
ansible-vault encrypt inventories/prod/group_vars/all/vault.yml

ansible-playbook -i inventories/prod playbooks/monitoring.yml --ask-vault-pass   # необязательно, запускать первым
ansible-playbook -i inventories/prod playbooks/ollama.yml --ask-vault-pass       # или vllm.yml

# только проверка
ansible-playbook -i inventories/prod playbooks/ollama.yml --tags llm_verify --ask-vault-pass
```

Мониторинг необязателен: без группы `monitoring` в inventory `ollama.yml`/`vllm.yml` пропускают агента
мониторинга. Если группа есть, сначала запускается `monitoring.yml` (GPU-серверы забирают его TLS-сертификат).

Любую роль можно запустить отдельно через `--tags <роль>`: определение GPU в `common` помечено тегом `always`.

## Основные переменные

Переменные, которые чаще всего меняют. Все переменные со значениями по умолчанию и комментариями —
в `roles/*/defaults/main.yml`; переопределять в `inventories/<env>/group_vars/`.

| Переменная | По умолчанию | Описание |
|---|---|---|
| **Общее** | | |
| `common_gpu_mode` | `auto` | `auto` (определить через `lspci`), `present`, `absent` (CPU-режим) |
| `common_disk_check_path` / `common_min_free_disk_gb` | `/srv/llm` / `50` | Pre-flight проверка диска; место, уже занятое моделями, считается доступным |
| `common_ufw_enabled` | `true` | Включить UFW (входящие запрещены, SSH разрешён) |
| **Драйвер NVIDIA** | | |
| `nvidia_driver_branch` | `"580"` | Ветка драйвера Ubuntu (`580`, `595`, …) |
| `nvidia_driver_open` | `true` | Open kernel modules (обязательны для Blackwell) |
| `nvidia_driver_hold` / `nvidia_driver_upgrade` | `true` / `false` | Hold драйвера и ядра; `upgrade=true` обновляет их вместе и перезагружает |
| `nvidia_driver_fabricmanager` | `false` | Fabric manager для HGX/NVSwitch |
| **Ollama** | | |
| `ollama_version` | `"0.40.12"` | Тег образа |
| `ollama_model` | `qwen3:8b` | Модель из библиотеки Ollama |
| `ollama_num_parallel` / `ollama_context_length` | `4` / `8192` | Параллельные запросы на модель, контекстное окно |
| `ollama_kv_cache_type` | `q8_0` | Квантизация KV-кеша (`f16`, `q8_0`, `q4_0`) |
| **vLLM** | | |
| `vllm_version` | `v0.32.0` | Тег образа |
| `vllm_model` | `Qwen/Qwen3-8B` | Id модели на Hugging Face |
| `vllm_served_model_name` | `qwen3-8b` | Имя модели в API |
| `vllm_gpu_memory_utilization` | `0.90` | Доля видеопамяти, которую резервирует vLLM (веса + KV-кеш) |
| `vllm_max_model_len` | `8192` | Максимальная длина контекста |
| `vllm_tensor_parallel_size` | `1` | Число GPU на одну модель |
| `vllm_reasoning_parser` | `qwen3` | Парсер «размышлений»; пустая строка для обычных моделей |
| `vllm_hf_token` | `""` | Токен Hugging Face, только для gated-моделей |
| `vllm_extra_args` | `[]` | Любые дополнительные флаги `vllm serve` |
| **API-прокси (nginx)** | | |
| `llm_proxy_api_keys` | `[]` | Bearer-токены клиентов (обязательно, 16–200 символов) |
| `llm_proxy_server_name` | `_` | Доменное имя |
| `llm_proxy_tls_mode` | `selfsigned` | `selfsigned` или `provided` (`llm_proxy_tls_cert` / `llm_proxy_tls_key`) |
| `llm_proxy_rate_limit` / `llm_proxy_rate_burst` | `10r/s` / `20` | Rate limit на токен |
| `llm_proxy_read_timeout` | `600s` | Таймаут чтения от бэкенда (долгие генерации) |
| **Мониторинг** | | |
| `monitoring_remote_write_url` | — | `https://<monitoring-host>:8428/api/v1/write` |
| `monitoring_write_password` | — | Пароль basic auth VictoriaMetrics (vault) |
| `monitoring_stack_victoriametrics_listen` | `0.0.0.0:8428` | Лучше IP приватной сети |
| `monitoring_stack_remote_write_sources` | `ansible_host` из `gpu_servers` | IP, которым UFW открывает порт 8428 |
| `monitoring_stack_tls_extra_names` | `[]` | Доп. DNS-имена/IP для сертификата VictoriaMetrics |
| `monitoring_stack_grafana_admin_password` | — | Пароль `admin` в Grafana (vault) |
| `monitoring_stack_telegram_bot_token` / `_chat_id` | `""` | Уведомления в Telegram (включают Alertmanager) |
| `monitoring_stack_retention` | `90d` | Срок хранения метрик |

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

После развёртывания:

- контейнер с LLM перезапускается, если процесс завершился (`restart: unless-stopped`), и стартует вместе с Docker при загрузке;
- systemd-таймер `container-autoheal` (роль `docker`) перезапускает контейнеры с меткой `autoheal=true`
  (Ollama, vLLM), если healthcheck вернул `unhealthy`: политики перезапуска Docker этого не делают.
  Перезапуски пишутся в журнал (`journalctl -t container-autoheal`) и отдаются метриками с алертом (см. «Мониторинг»).

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
 node_exporter :9100 ┐                              ┌ VictoriaMetrics :8428 (HTTPS + basic auth)
 dcgm-exporter :9400 ├─▶ vmagent ── remote write ──▶├ vmalert → Alertmanager → Telegram (опционально)
 vLLM /metrics :8000 ┘   (все на 127.0.0.1)  HTTPS   └ Grafana 127.0.0.1:3000
 состояние контейнеров (textfile)
```

- **Агент** (`monitoring_agent`, входит в `ollama.yml`/`vllm.yml`): экспортеры слушают только localhost,
  vmagent добавляет метку `host=<inventory_hostname>` и отправляет метрики с basic auth. В конце роль
  ждёт, пока метрики хоста появятся в VictoriaMetrics.
- **Стек** (`monitoring_stack`): VictoriaMetrics (хранение `90d`), vmalert с правилами
  `roles/monitoring_stack/files/rules/gpu-llm.yml`, Grafana с datasource и дашбордами
  NVIDIA DCGM, Node Exporter Full, vLLM.
- **Доступ.** Контейнеры мониторинга работают в host-сети, через Docker ничего не публикуется (это обходило бы UFW):
  - VictoriaMetrics отдаёт **HTTPS** с самоподписанным сертификатом (SAN: все IP хоста, `ansible_host`,
    `monitoring_stack_tls_extra_names`) и требует **basic auth** (`monitoring_write_password`). vmagent доверяет
    именно этому сертификату (забирает его с сервера мониторинга), поэтому пароль не идёт по сети открытым текстом;
  - UFW открывает порт 8428 только для `monitoring_stack_remote_write_sources` (по умолчанию `ansible_host` всех `gpu_servers`).
    В проде лучше указать IP приватной сети (VPC/vRack) в `monitoring_stack_victoriametrics_listen`;
  - Grafana, vmalert и Alertmanager слушают только localhost:
    `ssh -L 3000:127.0.0.1:3000 root@<monitoring-host>` → http://localhost:3000
    (логин `admin`, пароль `vault_grafana_admin_password`; применяется только при первом запуске Grafana).
- **Алерты:** температура GPU, XID-ошибки, сбой remap строк памяти и некорректируемые ошибки HBM,
  заполнение видеопамяти, недоступность цели сбора, заполнение диска, очередь vLLM, **LLM-контейнер unhealthy /
  перезапущен autoheal** (это покрывает и Ollama, у которой нет своих Prometheus-метрик).
- **Уведомления:** задайте `vault_telegram_bot_token` → `monitoring_stack_telegram_bot_token` и
  `monitoring_stack_telegram_chat_id` — Alertmanager включится, его конфиг проверяется через `amtool`.
  Другой получатель: полный `alertmanager.yml` в `monitoring_stack_alertmanager_config`.
  Без этого алерты видны в vmalert/Grafana, но никуда не отправляются.

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

## Проверка без GPU

Всё, кроме ролей для NVIDIA, проверяется на любой машине или VM с Ubuntu 24.04/26.04:

```bash
yamllint --strict . && ansible-lint                     # статические проверки
ansible-playbook -i inventories/example/hosts.yml --syntax-check playbooks/ollama.yml

# полный прогон в CPU-режиме: GPU-роли пропускаются, Ollama запускает маленькую модель на CPU
ansible-playbook -i tests/ci/inventory.yml playbooks/monitoring.yml   # localhost, см. inventory
ansible-playbook -i tests/ci/inventory.yml playbooks/ollama.yml
```

`tests/ci/inventory.yml` задаёт `common_gpu_mode: absent` и `ollama_model: qwen2.5:0.5b`; для удалённой VM
скопируйте его и замените `ansible_connection: local` на адрес VM. То же самое выполняется в CI (ниже),
включая идемпотентность, проверки API через nginx, доставку метрик по HTTPS и autoheal контейнеров.

## Известные ограничения

- **GPU-контейнеры после `systemctl daemon-reload`.** С systemd cgroup driver daemon-reload может отнять у
  работающих GPU-контейнеров доступ к устройству (`Failed to initialize NVML: Unknown Error`) — известная проблема
  NVIDIA Container Toolkit. Плейбуки не делают лишних reload; если это случится, autoheal перезапустит
  unhealthy-контейнер. На тестовом сервере не воспроизводилось.
- **Перезагрузка сервера** покрыта конфигурацией (Docker, nvidia-persistenced, таймер autoheal включены; контейнеры
  `unless-stopped`), но end-to-end на GPU не проверялась. После перезагрузки Ollama загружает модель при первом
  запросе (~7 с на H100).
- **Security-обновления ядра** держатся вместе с драйвером; применять через `nvidia_driver_upgrade=true`.
- **Самоподписанные сертификаты** (nginx, VictoriaMetrics) действуют 825 дней и не перевыпускаются автоматически;
  в проде — `llm_proxy_tls_mode: provided` с управляемым сертификатом.
- Лимиты на параллельные запросы и `max_tokens` на токен nginx не ограничивает (только частоту запросов).

## Проверено на

DigitalOcean GPU Droplet: NVIDIA H100 SXM5 80GB, Ubuntu 26.04.1 LTS (ядро 7.0.0, `linux-virtual`), 2026-10-28.

| Плейбук | Результат |
|---|---|
| `ollama.yml` | драйвер 580.178.04 + перезагрузка, toolkit 1.20.1 (CDI), `qwen3:8b` 100% на GPU (~200 ток/с), повторный прогон `changed=0` |
| `vllm.yml` | vLLM v0.32.0, `Qwen/Qwen3-8B`, ~1 с на 200 токенов, повторный прогон `changed=0` |
| `monitoring.yml` | VictoriaMetrics, vmalert (8 правил), Grafana с 3 дашбордами; метрики GPU и vLLM (TTFT, токены, KV cache) доходят; повторный прогон `changed=0` |
| Снаружи | 401 без токена, 404 вне allowlist, стриминг через nginx; VictoriaMetrics — 401 без пароля; Grafana и экспортеры недоступны |

Изменения после теста на GPU (VictoriaMetrics по HTTPS, autoheal контейнеров, hold всех пакетов NVIDIA,
определение GPU с тегом `always`) проверены в CI и локальными тестами в контейнерах, но ещё не на GPU.

## CI

`.github/workflows/ci.yml`, раннер `ubuntu-26.04`:

| Job | Что проверяет |
|---|---|
| Lint | `yamllint --strict`, `ansible-lint` (profile `production`), `--syntax-check` всех плейбуков |
| E2E (monitoring + Ollama on CPU) | `monitoring.yml` и `ollama.yml` на раннере без GPU (`tests/ci/inventory.yml`, модель `qwen2.5:0.5b`), включая nginx, `llm_verify` и доставку метрик; повторные прогоны без изменений; прогон `--tags llm_verify`; `curl` через nginx; VictoriaMetrics по HTTPS с проверкой сертификата; Grafana; autoheal перезапускает контейнер с падающим healthcheck |

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
