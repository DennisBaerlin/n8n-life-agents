# /etc/n8n/n8n.env — rendered by provisioning (chmod 640 root:n8n). DO NOT hand-edit
# secrets: the provisioning core generates them ONCE and preserves them on re-run.
# systemd EnvironmentFile syntax: plain KEY=value, no quoting, no shell expansion.

# --- secret (generated once; changing it makes ALL stored credentials undecryptable) ---
N8N_ENCRYPTION_KEY=@@N8N_ENCRYPTION_KEY@@

# --- database (PostgreSQL on the same host) ---
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=127.0.0.1
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=@@N8N_DB_NAME@@
DB_POSTGRESDB_USER=@@N8N_DB_USER@@
DB_POSTGRESDB_PASSWORD=@@N8N_DB_PASSWORD@@

# --- listener (your reverse proxy is the public face) ---
# Derived from TRUSTED_PROXIES (core.env): proxy on this host -> 127.0.0.1; proxy on another host -> 0.0.0.0,
# but ONLY together with the lifeagents firewall table that admits just that proxy (lib/firewall.sh, fail-closed).
N8N_LISTEN_ADDRESS=@@N8N_LISTEN_ADDRESS@@
N8N_PORT=@@N8N_PORT@@
# The reverse proxy must forward ONLY /webhook* — the n8n UI/REST is never served over public HTTPS,
# only over localhost/LAN http (UI access + the internal owner-setup/API-key mint). A Secure-flagged
# auth cookie is NOT sent by clients over http -> every login (incl. the headless mint) would 401.
# So the cookie must be non-Secure for this architecture.
N8N_SECURE_COOKIE=false
N8N_PROTOCOL=@@N8N_PROTOCOL@@
N8N_HOST=@@N8N_HOST@@
N8N_USER_FOLDER=@@N8N_USER_FOLDER@@

# --- external URLs (set once a domain exists; WEBHOOK_URL drives Telegram webhook paths) ---
N8N_EDITOR_BASE_URL=@@N8N_EDITOR_BASE_URL@@
WEBHOOK_URL=@@WEBHOOK_URL@@
# Behind ONE reverse proxy — trust a single X-Forwarded hop. A proxy CHAIN (e.g. a cloud LB in front
# of the proxy) would need a higher value; a bare NAT port-forward adds no hop, so 1 stays correct.
N8N_PROXY_HOPS=1

# --- operational ---
GENERIC_TIMEZONE=@@TIMEZONE@@
N8N_DIAGNOSTICS_ENABLED=false
N8N_RUNNERS_ENABLED=true
# Code/expression nodes must never read the process environment (it carries the host secrets from core.env).
# This is the n8n 2.x default; pinned so a changed default can never open it silently.
N8N_BLOCK_ENV_ACCESS_IN_NODE=true
