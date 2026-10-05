---
name: setup-litellm
description: >-
  Installs LiteLLM proxy on the infra Docker daemon with its own Postgres,
  Langfuse tracing, Telegram alerts, virtual-key budget defaults, and dual
  bind on localhost plus WireGuard. Use when the user asks to set up
  LiteLLM, the LLM gateway, litellm-infra, /ui dashboard, or DeepSeek via UI.
---

# Setup LiteLLM (infra)

Requires Langfuse web reachable at `http://langfuse-web:3000` on network
`infra`, with matching `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY`.
Public URL needs WireGuard + VPS `4000 → 4000`.

Own Postgres under `$INFRA_ROOT/litellm/data/postgres`. Do not share
Langfuse's database.

## Layout

```
$INFRA_ROOT/litellm/
  docker-compose.yml
  litellm_config.yaml
  alerting.yaml          # documentation twin of the alerting block
  .env                   # mode 600
  data/postgres/
```

Image: `ghcr.io/berriai/litellm:main-stable`.
`STORE_MODEL_IN_DB=True`. `model_list` in yaml is **empty** — admin adds
models in `/ui` (this fleet: DeepSeek). Do not put provider keys in git.

Dashboard:

- env `UI_USERNAME=admin` + `LITELLM_UI_PASSWORD`
- `PROXY_BASE_URL=http://${PUBLIC_HOST}:${LITELLM_PUBLIC_PORT}` (invite links + cookies)

`LITELLM_SALT_KEY` encrypts provider keys in Postgres. **Never change**
after models exist in the DB.

`LITELLM_MASTER_KEY` is break-glass admin. Apps use virtual keys created
in the UI, not the master key.

## Alerting

LiteLLM POSTs Slack-shaped `{"text":"..."}`. Telegram accepts that on
`sendMessage?chat_id=`. Compose builds:

```
TELEGRAM_WEBHOOK_<NAME>=https://api.telegram.org/bot${TOKEN}/sendMessage?chat_id=${CHAT}
```

`alerting: ["slack"]` in yaml is required for that transport. Do not log
prompt bodies (`redact_messages_in_exceptions`, `store_prompts_in_spend_logs: false`).

## Workflow

```
- [ ] 1. Copy compose + yaml + unit
- [ ] 2. Write .env mode 600; copy Langfuse keys
- [ ] 3. mkdir data/postgres
- [ ] 4. systemctl enable --now litellm-infra
- [ ] 5. Hit /health/liveliness and /ui
```

```bash
install -d -m 755 -o "$ADMIN_USER" -g "$ADMIN_GROUP" "$INFRA_ROOT/litellm/data/postgres"
install -m 644 "<SKILL>/templates/docker-compose.yml" "$INFRA_ROOT/litellm/docker-compose.yml"
install -m 644 "<SKILL>/templates/litellm_config.yaml" "$INFRA_ROOT/litellm/litellm_config.yaml"
install -m 644 "<SKILL>/templates/alerting.yaml" "$INFRA_ROOT/litellm/alerting.yaml"
```

Copy [templates/env.example](templates/env.example) → `.env`, `chmod 600`.

```bash
openssl rand -hex 16
printf 'sk-%s\n' "$(openssl rand -hex 24)"   # MASTER_KEY and SALT_KEY
```

Telegram: one bot token, one chat id per destination. Empty token =
container will get a broken webhook URL; omit the env vars and the yaml
block if alerting is not wanted yet.

### Verify

```bash
sudo systemctl enable --now litellm-infra
docker-infra ps
curl -sS http://127.0.0.1:4000/health/liveliness
```

Local UI: `http://127.0.0.1:4000/ui`. Public: `http://${PUBLIC_HOST}:4000/ui`.

Add models in UI after login. Create a virtual key per app; do not hand
out `LITELLM_MASTER_KEY`.

`litellm-infra.service` `Requires=langfuse-infra.service`.

## Pitfalls

- Changing `LITELLM_SALT_KEY` makes stored provider keys unreadable.
- `PROXY_BASE_URL` must be the public URL or invite cookies break.
- Healthcheck needs `start_period` (~60s) — first migrate is slow.
- Do not put Anthropic/OpenAI keys in compose unless the user asks;
  current fleet keeps DeepSeek in the DB only.
