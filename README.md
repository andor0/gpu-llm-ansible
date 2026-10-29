# gpu-llm-ansible

**English** · [Русский](README.ru.md)

Ansible playbooks that set up a GPU server (Ubuntu + NVIDIA) and run an LLM behind an OpenAI-compatible API.

## Requirements

- **Server:** Ubuntu 26.04 LTS (24.04 is also supported), NVIDIA GPU, SSH access with sudo.
- **Control node:** ansible-core ≥ 2.20 (Ubuntu 26.04 ships Python 3.14, which older Ansible versions do not support):
  ```bash
  pip install -r requirements-dev.txt
  ansible-galaxy collection install -r requirements.yml
  ```

## Playbooks

| Playbook | Hosts | What it does |
|---|---|---|
| `playbooks/ollama.yml` | `gpu_servers` | Driver, Docker, NVIDIA Container Toolkit, **Ollama**, nginx, monitoring agent, verification. Also works without a GPU (CPU mode) |
| `playbooks/vllm.yml` | `gpu_servers` | Same, but with **vLLM** (requires an NVIDIA GPU) |
| `playbooks/monitoring.yml` | `monitoring` | VictoriaMetrics, vmalert, Grafana (+ Alertmanager) |

## Roles

| Role | Purpose |
|---|---|
| `common` | Pre-flight checks, base packages, UFW, GPU detection (`gpu_enabled`) |
| `nvidia_driver` | NVIDIA driver (`-server-open`), hold, reboot, persistenced |
| `docker` | Docker CE, `daemon.json` (log rotation, CDI) |
| `nvidia_container_toolkit` | NVIDIA Container Toolkit, CDI, `nvidia-smi` smoke test in a container |
| `ollama` | Ollama in Docker Compose, model pull |
| `vllm` | vLLM in Docker Compose |
| `llm_proxy` | nginx: TLS, bearer tokens, rate limit, path allowlist |
| `monitoring_agent` | node_exporter, dcgm-exporter, vmagent → VictoriaMetrics |
| `monitoring_stack` | VictoriaMetrics, vmalert, Grafana with dashboards |
| `llm_verify` | Health check, test inference, auth check |

`ollama` and `vllm` plug into the shared roles through variables set in the playbook:
`llm_backend`, `llm_upstream_port`, `llm_health_path`, `llm_served_model`.

## Architecture

### Current

```
                         GPU server (playbooks/ollama.yml | vllm.yml)
 Client ──HTTPS──▶ nginx :443  TLS · Bearer tokens · rate limit per token · path allowlist
                     │ 127.0.0.1
                     ▼
                   Ollama :11434  or  vLLM :8000      Docker Compose, one backend per server
                     │
                   NVIDIA GPU   driver 580-server-open (signed modules) · Container Toolkit · CDI
                   container-autoheal (systemd timer): restarts unhealthy containers, exports health

 node_exporter · dcgm-exporter · vLLM /metrics ──▶ vmagent ──HTTPS + basic auth──┐
                                                                                 ▼
                         Monitoring server (playbooks/monitoring.yml)   VictoriaMetrics :8428
                                                    Grafana ◀──────────────────┤
                                     Telegram ◀── Alertmanager ◀── vmalert ◀───┘
```

### Design decisions

| Decision | Why |
|---|---|
| Docker Compose, not Swarm | One GPU node per backend; GPUs in Swarm work only via generic resources and `deploy.resources.reservations.devices` is ignored there |
| Driver from the Ubuntu archive, signed modules, no DKMS | Works with Secure Boot, no module builds on kernel updates; driver and kernel are held and upgraded together |
| One backend per GPU server, Ollama or vLLM | Both reserve VRAM; Ollama is simple and runs on CPU (dev, CI), vLLM gives throughput under concurrent load (production) |
| Model on `127.0.0.1`, only nginx exposed | Ollama has no auth and exposes `/api/pull`, `/api/delete`; one place for TLS, tokens and limits |
| OpenAI-compatible API | Clients do not change when switching backends or adding a gateway |
| Separate monitoring server, push via vmagent | GPU servers need no inbound ports for monitoring; works across providers (OVH, DigitalOcean, Cherry) |
| Autoheal as a systemd timer | Docker restart policies ignore `unhealthy`; no third-party image needed |

## Quick start

```bash
# inventory and secrets
cp -r inventories/example inventories/prod   # set host IPs
cp inventories/prod/group_vars/all/vault.yml.example inventories/prod/group_vars/all/vault.yml
ansible-vault encrypt inventories/prod/group_vars/all/vault.yml

ansible-playbook -i inventories/prod playbooks/monitoring.yml --ask-vault-pass   # optional, run first
ansible-playbook -i inventories/prod playbooks/ollama.yml --ask-vault-pass       # or vllm.yml

# verification only
ansible-playbook -i inventories/prod playbooks/ollama.yml --tags llm_verify --ask-vault-pass
```

Monitoring is optional: without a `monitoring` group in the inventory, `ollama.yml`/`vllm.yml` skip
the monitoring agent. With it, run `monitoring.yml` first (GPU servers fetch its TLS certificate).

Any role can be run on its own with `--tags <role>`: GPU detection in `common` is tagged `always`.

## Main variables

The variables you most likely want to change. All variables with defaults and comments are in
`roles/*/defaults/main.yml`; set overrides in `inventories/<env>/group_vars/`.

| Variable | Default | Description |
|---|---|---|
| **Common** | | |
| `common_gpu_mode` | `auto` | `auto` (detect via `lspci`), `present`, `absent` (CPU mode) |
| `common_disk_check_path` / `common_min_free_disk_gb` | `/srv/llm` / `50` | Pre-flight disk check; space already used by models counts as available |
| `common_ufw_enabled` | `true` | Enable UFW (deny incoming, allow SSH) |
| **NVIDIA driver** | | |
| `nvidia_driver_branch` | `"580"` | Ubuntu driver branch (`580`, `595`, …) |
| `nvidia_driver_open` | `true` | Open kernel modules (required for Blackwell) |
| `nvidia_driver_hold` / `nvidia_driver_upgrade` | `true` / `false` | Hold driver + kernel; `upgrade=true` upgrades them together and reboots |
| `nvidia_driver_fabricmanager` | `false` | Fabric manager for HGX/NVSwitch systems |
| **Ollama** | | |
| `ollama_version` | `"0.40.12"` | Image tag |
| `ollama_model` | `qwen3:8b` | Model from the Ollama library |
| `ollama_num_parallel` / `ollama_context_length` | `4` / `8192` | Parallel requests per model, context window |
| `ollama_kv_cache_type` | `q8_0` | KV cache quantization (`f16`, `q8_0`, `q4_0`) |
| **vLLM** | | |
| `vllm_version` | `v0.32.0` | Image tag |
| `vllm_model` | `Qwen/Qwen3-8B` | Hugging Face model id |
| `vllm_served_model_name` | `qwen3-8b` | Model name in the API |
| `vllm_gpu_memory_utilization` | `0.90` | Share of VRAM vLLM reserves (weights + KV cache) |
| `vllm_max_model_len` | `8192` | Max context length |
| `vllm_tensor_parallel_size` | `1` | Number of GPUs for one model |
| `vllm_reasoning_parser` | `qwen3` | Reasoning parser; empty for non-reasoning models |
| `vllm_hf_token` | `""` | Hugging Face token, only for gated models |
| `vllm_extra_args` | `[]` | Any extra `vllm serve` flags |
| **API proxy (nginx)** | | |
| `llm_proxy_api_keys` | `[]` | Client bearer tokens (required, 16–200 chars) |
| `llm_proxy_server_name` | `_` | Domain name |
| `llm_proxy_tls_mode` | `selfsigned` | `selfsigned` or `provided` (`llm_proxy_tls_cert` / `llm_proxy_tls_key`) |
| `llm_proxy_rate_limit` / `llm_proxy_rate_burst` | `10r/s` / `20` | Rate limit per token |
| `llm_proxy_read_timeout` | `600s` | Upstream read timeout (long generations) |
| **Monitoring** | | |
| `monitoring_remote_write_url` | — | `https://<monitoring-host>:8428/api/v1/write` |
| `monitoring_write_password` | — | VictoriaMetrics basic auth password (vault) |
| `monitoring_stack_victoriametrics_listen` | `0.0.0.0:8428` | Prefer a private network IP |
| `monitoring_stack_remote_write_sources` | `ansible_host` of `gpu_servers` | IPs allowed to port 8428 in UFW |
| `monitoring_stack_tls_extra_names` | `[]` | Extra DNS names/IPs for the VictoriaMetrics certificate |
| `monitoring_stack_grafana_admin_password` | — | Grafana `admin` password (vault) |
| `monitoring_stack_telegram_bot_token` / `_chat_id` | `""` | Telegram notifications (enables Alertmanager) |
| `monitoring_stack_retention` | `90d` | Metrics retention |

## API access

The model listens on `127.0.0.1` only; nginx exposes it (role `llm_proxy`):

- HTTPS (self-signed by default; `llm_proxy_tls_mode: provided` for your own certificate, e.g. Cloudflare Origin CA), HTTP → 301 to HTTPS;
- bearer token auth with keys from `llm_proxy_api_keys` (multiple keys; no token → `401`);
- rate limit per token (`10r/s`, burst `20`, over the limit → `429`);
- only `/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`, `/v1/models` are exposed
  (+ `/api/chat`, `/api/generate` for Ollama); everything else, including `/api/pull` and `/api/delete`, returns `404`.

New key: add it to `vault_llm_api_keys` and rerun with `--tags llm_proxy`. To revoke, remove it and rerun the same way.

## Health checks

The `llm_verify` role runs at the end of each playbook (on its own: `--tags llm_verify`):

1. waits for the backend health endpoint (`/api/tags` for Ollama, `/health` for vLLM);
2. sends a test request to `/v1/chat/completions` and checks that the model generated tokens;
3. on a GPU server, checks that the model is actually in VRAM (`nvidia-smi`);
4. through nginx: no token → `401`, `/api/pull` → `404`, with a token → a successful model response;
5. prints a summary: backend, model, GPU, latency, answer.

After deployment:

- the LLM container restarts if the process exits (`restart: unless-stopped`) and starts with Docker on boot;
- the `container-autoheal` systemd timer (role `docker`) restarts containers labelled `autoheal=true`
  (Ollama, vLLM) when their healthcheck reports `unhealthy`, which Docker restart policies do not do.
  Restarts are logged (`journalctl -t container-autoheal`) and exported as metrics with an alert (see Monitoring).

Manual check:

```bash
nvidia-smi                                  # GPU and used memory
docker ps                                   # container is healthy
docker logs -f ollama                       # or vllm
curl -s http://127.0.0.1:11434/api/tags     # Ollama (8000/health for vLLM), on the server only
```

## vLLM

- Requires an NVIDIA GPU; the playbook fails at pre-flight if there is none.
- The first start is slow: downloading weights (Qwen3-8B ≈ 16 GB) and compiling CUDA graphs; waits up to `vllm_start_timeout` (30 min).
- Default model is `Qwen/Qwen3-8B` (≈ 24 GB VRAM with KV cache). For smaller GPUs use a quantized model
  (`vllm_model: Qwen/Qwen3-8B-AWQ`) or a lower `vllm_max_model_len`.
- Qwen3 is a reasoning model: with `vllm_reasoning_parser: qwen3` (default) the "thinking" goes to
  `reasoning_content` and `content` holds only the answer. For another model, set its parser or an empty string.
- `vllm_hf_token` is only needed for gated models (Llama, Gemma): accept the license on huggingface.co and put the token in `vault_hf_token`.
- The model name in the API is `vllm_served_model_name` (default `qwen3-8b`).

## Switching backends

One backend runs per GPU server: the `ollama` role stops vLLM, the `vllm` role stops Ollama
(the container is stopped; models and caches stay on disk). To switch, just run the other playbook;
nginx is repointed to the new upstream.

## Monitoring

```
GPU server                                         Monitoring server (playbooks/monitoring.yml)
 node_exporter :9100 ┐                              ┌ VictoriaMetrics :8428 (HTTPS + basic auth)
 dcgm-exporter :9400 ├─▶ vmagent ── remote write ──▶├ vmalert → Alertmanager → Telegram (optional)
 vLLM /metrics :8000 ┘   (all on 127.0.0.1)  HTTPS   └ Grafana 127.0.0.1:3000
 container health (textfile)
```

- **Agent** (`monitoring_agent`, part of `ollama.yml`/`vllm.yml`): exporters listen on localhost only,
  vmagent adds the `host=<inventory_hostname>` label and ships metrics with basic auth. At the end the role
  waits until the host's metrics show up in VictoriaMetrics.
- **Stack** (`monitoring_stack`): VictoriaMetrics (`90d` retention), vmalert with rules from
  `roles/monitoring_stack/files/rules/gpu-llm.yml`, Grafana with a datasource and the
  NVIDIA DCGM, Node Exporter Full and vLLM dashboards.
- **Access.** Monitoring containers use host networking, so nothing is published through Docker (which would bypass UFW):
  - VictoriaMetrics serves **HTTPS** with a self-signed certificate (SANs: all host IPs, `ansible_host`,
    `monitoring_stack_tls_extra_names`) and **basic auth** (`monitoring_write_password`). vmagent trusts exactly
    this certificate (fetched from the monitoring host), so the password never crosses the network in plaintext;
  - UFW opens port 8428 only to `monitoring_stack_remote_write_sources` (default: `ansible_host` of all `gpu_servers`).
    In production, prefer a private network IP (VPC/vRack) in `monitoring_stack_victoriametrics_listen`;
  - Grafana, vmalert and Alertmanager listen on localhost only:
    `ssh -L 3000:127.0.0.1:3000 root@<monitoring-host>` → http://localhost:3000
    (login `admin`, password `vault_grafana_admin_password`; applied only on Grafana's first start).
- **Alerts:** GPU temperature, XID errors, memory row remap failure and uncorrectable HBM errors,
  VRAM almost full, scrape target down, disk almost full, vLLM queue, **LLM container unhealthy / restarted
  by autoheal** (this also covers Ollama, which has no Prometheus metrics of its own).
- **Notifications:** set `vault_telegram_bot_token` → `monitoring_stack_telegram_bot_token` and
  `monitoring_stack_telegram_chat_id`; Alertmanager is then enabled and its config is checked with `amtool`.
  Any other receiver: put a full `alertmanager.yml` into `monitoring_stack_alertmanager_config`.
  Without either, alerts are visible in vmalert/Grafana but not sent anywhere.

If monitoring runs on the same host as the LLM, add the host to both inventory groups and remove
`common_gpu_mode: absent` from `group_vars/monitoring` (otherwise the GPU will not be detected).

## NVIDIA driver and upgrades

The driver is installed from the Ubuntu archive (`nvidia-headless-no-dkms-<branch>-server-open` + signed
modules `linux-modules-nvidia-<branch>-server-open-<flavour>`), without DKMS, so it works with Secure Boot.

The modules package is chosen by kernel: HWE uses `generic-hwe-<version>`, otherwise the kernel suffix (`-generic`;
the cloud `linux-virtual` kernel is the same `-generic` kernel).

Driver packages **and kernel metapackages** are put on hold: NVIDIA modules are built for a specific kernel,
and upgrading one without the other leaves the server without a GPU. Upgrade deliberately:

```bash
ansible-playbook -i inventories/prod playbooks/ollama.yml --tags nvidia_driver -e nvidia_driver_upgrade=true
```

## Verification without a GPU

Everything except the NVIDIA-specific roles can be checked on any Ubuntu 24.04/26.04 machine or VM:

```bash
yamllint --strict . && ansible-lint                     # static checks
ansible-playbook -i inventories/example/hosts.yml --syntax-check playbooks/ollama.yml

# full run in CPU mode: GPU roles are skipped, Ollama runs a small model on CPU
ansible-playbook -i tests/ci/inventory.yml playbooks/monitoring.yml   # localhost, see the inventory
ansible-playbook -i tests/ci/inventory.yml playbooks/ollama.yml
```

`tests/ci/inventory.yml` sets `common_gpu_mode: absent` and `ollama_model: qwen2.5:0.5b`; for a remote VM
copy it and replace `ansible_connection: local` with the VM address. The same runs happen in CI (below),
including idempotency, API checks through nginx, metrics delivery over HTTPS and container autoheal.

## Known limitations

- **GPU containers after `systemctl daemon-reload`.** With the systemd cgroup driver, a daemon-reload can make
  running GPU containers lose access to the device (`Failed to initialize NVML: Unknown Error`), a known NVIDIA
  Container Toolkit issue. The playbooks avoid needless reloads; if it happens, autoheal restarts the unhealthy
  container. Not reproduced on the test server.
- **Server reboot** is covered by configuration (Docker, nvidia-persistenced, autoheal timer enabled; containers
  `unless-stopped`) but was not tested end to end on GPU hardware. After a reboot Ollama loads the model on the
  first request (~7 s on an H100).
- **Kernel security updates** are held together with the driver; apply them with `nvidia_driver_upgrade=true`.
- **Self-signed certificates** (nginx, VictoriaMetrics) are valid for 825 days and are not renewed automatically;
  use `llm_proxy_tls_mode: provided` with a managed certificate in production.
- Per-token concurrency and `max_tokens` limits are not enforced by nginx (only the request rate).

## Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| `NVIDIA GPU not found, but this playbook requires it` | No NVIDIA device on PCI (e.g. an AMD Instinct droplet), or the GPU is not passed through to the VM | `lspci -nn \| grep -i -e nvidia -e 10de`. Only NVIDIA (vendor `10de`) is supported; recreate the server with an NVIDIA GPU |
| `nvidia-smi`: *couldn't communicate with the NVIDIA driver* | Booted into a kernel without NVIDIA modules (e.g. kernel upgraded outside the playbook), or reboot pending | `uname -r` vs `dpkg -l 'linux-modules-nvidia-*'`; rerun `--tags nvidia_driver` (installs modules for the kernel flavour and reboots) |
| `Failed to initialize NVML: Driver/library version mismatch` | Userspace driver upgraded, old kernel module still loaded | Reboot; upgrade only with `nvidia_driver_upgrade=true` |
| `could not select device driver "nvidia" with capabilities: [[gpu]]` | Container toolkit missing or Docker not restarted | `--tags nvidia_container_toolkit`; check `docker info \| grep -i runtimes` |
| `Failed to initialize NVML: Unknown Error` inside a running container | Container lost GPU access after `systemctl daemon-reload` (see Known limitations) | `docker restart ollama` (or `vllm`); autoheal does it once the healthcheck fails |
| vLLM: *CUDA out of memory* / *free memory … less than desired GPU memory utilization* | VRAM taken by another process (e.g. Ollama) or the model + KV cache does not fit | `nvidia-smi`; lower `vllm_max_model_len` or `vllm_gpu_memory_utilization`, use a quantized model (`Qwen/Qwen3-8B-AWQ`/`-FP8`) |
| vLLM stays `health: starting` for a long time | Downloading weights, CUDA graph compilation | `docker logs -f vllm`; the playbook waits up to `vllm_start_timeout` |
| First request after deploying a new GPU takes ~40 s (Ollama) | CUDA kernel JIT compilation | Done by the playbook warm-up; the cache persists in `/srv/llm/ollama-cuda-cache` |
| API `401` | Missing or wrong token, missing `Bearer ` prefix | `Authorization: Bearer <key>`; key must be in `llm_proxy_api_keys` |
| API `404` | Path is not in the allowlist (e.g. `/api/tags`, `/api/pull`) | Use `/v1/*` endpoints; extend `llm_proxy_allowed_paths` only if really needed |
| API `429` | Rate limit per token | Raise `llm_proxy_rate_limit` / `llm_proxy_rate_burst` or use separate keys |
| API `502` | Backend is down or restarting | `docker ps`, `docker logs ollama\|vllm`, `journalctl -t container-autoheal` |
| API `504` / cut-off answers | Long non-streaming generation exceeds the timeout (Cloudflare: ~100 s) | Use `"stream": true`; raise `llm_proxy_read_timeout` |
| *Wait for this host's metrics in VictoriaMetrics* fails | UFW on the monitoring host blocks the GPU server, wrong password, or the URL host is not in the certificate | `docker logs vmagent` (`x509` → add the name/IP to `monitoring_stack_tls_extra_names`; `401` → password; timeout → `monitoring_stack_remote_write_sources`) |
| No alerts in Telegram | Alertmanager disabled, wrong chat id, or the bot cannot write to the chat | Check `monitoring_stack_telegram_*`; start a chat with the bot / add it to the group; `docker logs alertmanager` |
| New Grafana password from vault does not work | Applied only on Grafana's first start | `docker exec grafana grafana cli admin reset-admin-password <password>` |
| Pre-flight *Check free disk space* fails | Not enough space for images and models | Free space or set `common_disk_check_path` / `common_min_free_disk_gb` |

## Tested on

DigitalOcean GPU Droplet: NVIDIA H100 SXM5 80GB, Ubuntu 26.04.1 LTS (kernel 7.0.0, `linux-virtual`), 2026-10-28.

| Playbook | Result |
|---|---|
| `ollama.yml` | driver 580.178.04 + reboot, toolkit 1.20.1 (CDI), `qwen3:8b` 100% on GPU (~200 tok/s), second run `changed=0` |
| `vllm.yml` | vLLM v0.32.0, `Qwen/Qwen3-8B`, ~1 s per 200 tokens, second run `changed=0` |
| `monitoring.yml` | VictoriaMetrics, vmalert (8 rules), Grafana with 3 dashboards; GPU and vLLM metrics (TTFT, tokens, KV cache) arrive; second run `changed=0` |
| From outside | 401 without a token, 404 outside the allowlist, streaming through nginx; VictoriaMetrics returns 401 without a password; Grafana and exporters are unreachable |

Changes made after the GPU test (VictoriaMetrics over HTTPS, container autoheal, holding all NVIDIA packages,
`always`-tagged GPU detection) are covered by CI and local container tests, not yet by a GPU run.

## CI

`.github/workflows/ci.yml`, runner `ubuntu-26.04`:

| Job | What it checks |
|---|---|
| Lint | `yamllint --strict`, `ansible-lint` (profile `production`), `--syntax-check` of all playbooks |
| E2E (monitoring + Ollama on CPU) | `monitoring.yml` and `ollama.yml` on a runner without a GPU (`tests/ci/inventory.yml`, model `qwen2.5:0.5b`), including nginx, `llm_verify` and metrics delivery; second runs with no changes; a `--tags llm_verify` run; `curl` through nginx; VictoriaMetrics over HTTPS with certificate verification; Grafana; autoheal restarting a container with a failing healthcheck |

GPU roles (`nvidia_driver`, `nvidia_container_toolkit`) are skipped in CI: GitHub runners have no NVIDIA GPU.

Locally:

```bash
yamllint --strict . && ansible-lint
```

## API request example

`model`: `qwen3:8b` for Ollama, `qwen3-8b` for vLLM (list: `GET /v1/models`).
With a self-signed certificate add `-k`.

```bash
curl https://llm.example.com/v1/chat/completions \
  -H "Authorization: Bearer $LLM_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
        "model": "qwen3:8b",
        "messages": [{"role": "user", "content": "Hi! Who are you?"}],
        "max_tokens": 200
      }'
```

Python (OpenAI SDK), with streaming:

```python
from openai import OpenAI

client = OpenAI(base_url="https://llm.example.com/v1", api_key="<LLM_API_KEY>")
stream = client.chat.completions.create(
    model="qwen3:8b",
    messages=[{"role": "user", "content": "Explain Ansible in two sentences"}],
    stream=True,
)
for chunk in stream:
    print(chunk.choices[0].delta.content or "", end="", flush=True)
```
