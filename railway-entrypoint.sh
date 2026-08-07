#!/bin/sh
# agentmemory boot for Railway.
#
#   1. Refuse to boot without AGENTMEMORY_SECRET. agentmemory's auth check is
#      `if (!secret) return null` — with the variable empty, every REST and MCP
#      endpoint answers anonymously, so an empty value is not a weaker
#      deployment, it is a public memory store.
#   2. Repair ownership of the Railway volume (mounted uid 0) and drop to the
#      unprivileged `node` user for the app itself.
#   3. Write the engine config with absolute /data paths and LOOPBACK binds —
#      nothing but the in-container gateway may reach the API socket.
#   4. Front both surfaces with nginx on Railway's injected $PORT: the API is
#      gated by the app's bearer token, the viewer by basic auth here, because
#      a loopback-bound viewer proxies to the REST API with the secret injected
#      and therefore authenticates nobody by itself.
set -eu

DATA_DIR="${AGENTMEMORY_DATA_DIR:-/data}"
REST_PORT=3111
STREAM_PORT=3112
VIEWER_PORT=$((REST_PORT + 2))
PORT="${PORT:-8080}"
RUN_AS="node:node"
VIEWER_USER="${AGENTMEMORY_VIEWER_USER:-admin}"
III_CONFIG="/opt/agentmemory/node_modules/@agentmemory/agentmemory/dist/iii-config.yaml"

if [ -z "${AGENTMEMORY_SECRET:-}" ]; then
  echo "[railway] FATAL: AGENTMEMORY_SECRET is empty." >&2
  echo "[railway] agentmemory disables authentication entirely when the secret is unset:" >&2
  echo "[railway] every /agentmemory/* REST and MCP endpoint would answer without credentials." >&2
  echo "[railway] Set AGENTMEMORY_SECRET (the template generates one) and redeploy." >&2
  exit 1
fi

echo "[railway] agentmemory ${AGENTMEMORY_VERSION:-?} / iii ${AGENTMEMORY_III_VERSION:-?} (sdk $(node -p "require('/opt/agentmemory/node_modules/iii-sdk/package.json').version"))"

mkdir -p "$DATA_DIR"
chown -R "$RUN_AS" "$DATA_DIR"
echo "[railway] volume $DATA_DIR owner=$(stat -c %u:%g "$DATA_DIR")"

# The npm-bundled config binds 127.0.0.1 but stores state under a RELATIVE
# ./data path, which on Railway lands on the ephemeral overlay instead of the
# volume. Absolute paths, same loopback binds.
cat > "$III_CONFIG" <<EOF
workers:
  - name: iii-http
    config:
      port: ${REST_PORT}
      host: 127.0.0.1
      default_timeout: 180000
      cors:
        allowed_origins: ["http://127.0.0.1:${REST_PORT}", "http://127.0.0.1:${VIEWER_PORT}"]
        allowed_methods: [GET, POST, PUT, DELETE, OPTIONS]
  - name: iii-state
    config:
      adapter:
        name: kv
        config:
          store_method: file_based
          file_path: ${DATA_DIR}/state_store.db
  - name: iii-queue
    config:
      adapter:
        name: builtin
  - name: iii-pubsub
    config:
      adapter:
        name: local
  - name: iii-cron
    config:
      adapter:
        name: kv
  - name: iii-stream
    config:
      port: ${STREAM_PORT}
      host: 127.0.0.1
      adapter:
        name: kv
        config:
          store_method: file_based
          file_path: ${DATA_DIR}/stream_store
  - name: iii-observability
    config:
      enabled: true
      service_name: agentmemory
      exporter: memory
      sampling_ratio: 0.1
      metrics_enabled: true
      logs_enabled: true
      logs_console_output: true
EOF
chown "$RUN_AS" "$III_CONFIG"

# The CLI's first-run flow is interactive; there is no TTY here.
HOME_DIR="$(getent passwd node | cut -d: -f6)"
mkdir -p "$HOME_DIR/.agentmemory"
cat > "$HOME_DIR/.agentmemory/preferences.json" <<'EOF'
{
  "schemaVersion": 1,
  "lastAgent": null,
  "lastAgents": [],
  "lastProvider": null,
  "skipSplash": true,
  "skipNpxHint": true,
  "skipGlobalInstall": true,
  "skipConsoleInstall": true,
  "firstRunAt": "2026-01-01T00:00:00.000Z"
}
EOF
chown -R "$RUN_AS" "$HOME_DIR/.agentmemory"

# Basic-auth credentials for the viewer. Written into the image layer, never
# onto the volume: /tmp is not reliably writable on Railway and the volume is
# readable by the app itself.
printf '%s:%s\n' "$VIEWER_USER" "$(openssl passwd -apr1 "$AGENTMEMORY_SECRET")" \
  > /etc/nginx/viewer.htpasswd
chmod 0644 /etc/nginx/viewer.htpasswd

cat > /etc/nginx/nginx.conf <<EOF
worker_processes auto;
pid /run/nginx.pid;
error_log /dev/stderr warn;
events { worker_connections 1024; }
http {
  access_log off;
  server_tokens off;
  sendfile on;
  client_max_body_size 64m;
  proxy_http_version 1.1;
  proxy_set_header Host \$host;
  proxy_set_header X-Forwarded-Proto \$http_x_forwarded_proto;
  proxy_read_timeout 300s;
  proxy_send_timeout 300s;

  map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
  }

  server {
    listen ${PORT} default_server;

    # Railway's healthcheck dials the INJECTED port with no credentials, and
    # /agentmemory/livez is the one endpoint upstream leaves unauthenticated.
    location = /agentmemory/livez {
      proxy_pass http://127.0.0.1:${REST_PORT};
    }

    # REST + MCP. Authentication is the app's bearer check, so clients present
    # AGENTMEMORY_SECRET exactly as they would against a local instance.
    location /agentmemory/ {
      proxy_pass http://127.0.0.1:${REST_PORT};
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection \$connection_upgrade;
    }

    # Viewer. Loopback-bound it injects the bearer token on every upstream call,
    # i.e. it authenticates nobody — basic auth here is what stands in front.
    location / {
      auth_basic "agentmemory viewer";
      auth_basic_user_file /etc/nginx/viewer.htpasswd;
      proxy_pass http://127.0.0.1:${VIEWER_PORT};
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection \$connection_upgrade;
    }
  }
}
EOF

nginx -t
nginx
echo "[railway] gateway listening on ${PORT} (api -> ${REST_PORT}, viewer -> ${VIEWER_PORT}, viewer user '${VIEWER_USER}')"

exec gosu "$RUN_AS" agentmemory "$@"
