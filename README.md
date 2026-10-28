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

## Possible improvements

- Secrets from Infisical instead of Ansible Vault; logs (Docker, nginx) to VictoriaLogs.
- Cloudflare Tunnel/Access in front of nginx (no open inbound ports), Let's Encrypt or Origin CA certificates.
- LiteLLM as a gateway: per-key quotas, usage accounting, routing across several GPU servers.
- Docker Swarm or Kubernetes (GPU Operator) for multi-node scheduling.

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

## TODO

- [ ] README: variables table, troubleshooting
