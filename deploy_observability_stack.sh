#!/bin/bash
# Observability Stack: Grafana, Prometheus, Loki, Mimir, Promtail
# AWS Well-Architected | Ubuntu 22.04/24.04
# Usage: sudo ./deploy_observability_stack.sh

set -euo pipefail

PROM_VER="2.51.2"
LOKI_VER="3.0.0"
MIMIR_VER="2.12.0"
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
LOG="/var/log/observability-deploy.log"
exec > >(tee -a "$LOG") 2>&1

[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

# ── Dependencies ──────────────────────────────────────────────────────────────
apt-get update -qq
apt-get install -y -qq curl wget tar unzip gpg ufw

# ── Firewall (Security) ───────────────────────────────────────────────────────
for port in 22 3000 9090 3100 9009; do ufw allow "$port/tcp" || true; done
ufw --force enable || true

# ── Helper: create service user ───────────────────────────────────────────────
mkuser() { id "$1" &>/dev/null || useradd --no-create-home --shell /bin/false "$1"; }

# ── Helper: write systemd service ─────────────────────────────────────────────
mksvc() {
  local name=$1 cmd=$2 wdir=$3 user=${4:-$1}
  cat > "/etc/systemd/system/${name}.service" <<EOF
[Unit]
Description=$name
After=network.target
[Service]
User=$user
Group=$user
WorkingDirectory=$wdir
ExecStart=$cmd
Restart=on-failure
RestartSec=10s
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$wdir
MemoryLimit=512M
CPUQuota=50%
[Install]
WantedBy=multi-user.target
EOF
}

# ── Prometheus ────────────────────────────────────────────────────────────────
echo "==> Prometheus..."
mkuser prometheus
mkdir -p /etc/prometheus /var/lib/prometheus
cd /tmp
wget -q "https://github.com/prometheus/prometheus/releases/download/v${PROM_VER}/prometheus-${PROM_VER}.linux-${ARCH}.tar.gz"
tar -xzf "prometheus-${PROM_VER}.linux-${ARCH}.tar.gz"
cp "prometheus-${PROM_VER}.linux-${ARCH}/"{prometheus,promtool} /usr/local/bin/
chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus

cat > /etc/prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]
  - job_name: loki
    static_configs:
      - targets: ["localhost:3100"]
  - job_name: mimir
    static_configs:
      - targets: ["localhost:9009"]
remote_write:
  - url: http://localhost:9009/api/v1/push
EOF

mksvc prometheus "/usr/local/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus --storage.tsdb.retention.time=7d" /var/lib/prometheus

# ── Loki ──────────────────────────────────────────────────────────────────────
echo "==> Loki..."
mkuser loki
mkdir -p /etc/loki /var/lib/loki/chunks /var/lib/loki/rules
cd /tmp
wget -q "https://github.com/grafana/loki/releases/download/v${LOKI_VER}/loki-linux-${ARCH}.zip"
unzip -q -o "loki-linux-${ARCH}.zip"
chmod +x "loki-linux-${ARCH}" && mv "loki-linux-${ARCH}" /usr/local/bin/loki
chown -R loki:loki /etc/loki /var/lib/loki

cat > /etc/loki/loki-config.yaml <<'EOF'
auth_enabled: false
server:
  http_listen_port: 3100
  grpc_listen_port: 9096
common:
  path_prefix: /var/lib/loki
  storage:
    filesystem:
      chunks_directory: /var/lib/loki/chunks
      rules_directory:  /var/lib/loki/rules
  replication_factor: 1
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: inmemory
schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h
limits_config:
  retention_period: 720h
EOF

mksvc loki "/usr/local/bin/loki -config.file=/etc/loki/loki-config.yaml" /var/lib/loki

# ── Promtail ──────────────────────────────────────────────────────────────────
echo "==> Promtail..."
cd /tmp
wget -q "https://github.com/grafana/loki/releases/download/v${LOKI_VER}/promtail-linux-${ARCH}.zip"
unzip -q -o "promtail-linux-${ARCH}.zip"
chmod +x "promtail-linux-${ARCH}" && mv "promtail-linux-${ARCH}" /usr/local/bin/promtail

cat > /etc/loki/promtail-config.yaml <<'EOF'
server:
  http_listen_port: 9080
  grpc_listen_port: 0
positions:
  filename: /var/lib/loki/positions.yaml
clients:
  - url: http://localhost:3100/loki/api/v1/push
scrape_configs:
  - job_name: system
    static_configs:
      - targets: [localhost]
        labels:
          job: varlogs
          __path__: /var/log/*.log
  - job_name: services
    static_configs:
      - targets: [localhost]
        labels:
          job: services
          __path__: /var/log/syslog
EOF

chown loki:loki /etc/loki/promtail-config.yaml
mksvc promtail "/usr/local/bin/promtail -config.file=/etc/loki/promtail-config.yaml" /var/lib/loki loki

# ── Mimir ─────────────────────────────────────────────────────────────────────
echo "==> Mimir..."
mkuser mimir
mkdir -p /etc/mimir /var/lib/mimir/data/{blocks,tsdb,compactor}
cd /tmp
wget -q "https://github.com/grafana/mimir/releases/download/mimir-${MIMIR_VER}/mimir-linux-${ARCH}"
chmod +x "mimir-linux-${ARCH}" && mv "mimir-linux-${ARCH}" /usr/local/bin/mimir
chown -R mimir:mimir /etc/mimir /var/lib/mimir

cat > /etc/mimir/mimir-config.yaml <<'EOF'
target: all
multitenancy_enabled: false
server:
  http_listen_port: 9009
  grpc_listen_port: 9095
  log_level: warn
common:
  storage:
    backend: filesystem
    filesystem:
      dir: /var/lib/mimir/data
blocks_storage:
  backend: filesystem
  filesystem:
    dir: /var/lib/mimir/data/blocks
  tsdb:
    dir: /var/lib/mimir/data/tsdb
compactor:
  data_dir: /var/lib/mimir/data/compactor
limits:
  compactor_blocks_retention_period: 90d
ingester:
  ring:
    replication_factor: 1
store_gateway:
  sharding_ring:
    replication_factor: 1
EOF

mksvc mimir "/usr/local/bin/mimir -config.file=/etc/mimir/mimir-config.yaml" /var/lib/mimir

# ── Grafana ───────────────────────────────────────────────────────────────────
echo "==> Grafana..."
rm -f /etc/apt/keyrings/grafana.gpg /etc/apt/sources.list.d/grafana.list
mkdir -p /etc/apt/keyrings
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | tee /etc/apt/keyrings/grafana.gpg > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
apt-get update -qq && apt-get install -y -qq grafana

cat >> /etc/grafana/grafana.ini <<'EOF'
[auth.anonymous]
enabled = false
[users]
allow_sign_up = false
EOF

mkdir -p /etc/grafana/provisioning/datasources
cat > /etc/grafana/provisioning/datasources/observability.yaml <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    url: http://localhost:9090
    isDefault: true
  - name: Loki
    type: loki
    url: http://localhost:3100
  - name: Mimir
    type: prometheus
    url: http://localhost:9009/prometheus
EOF
chown -R grafana:grafana /etc/grafana/provisioning/

# ── Start services ────────────────────────────────────────────────────────────
echo "==> Starting services..."
systemctl daemon-reload
for svc in mimir loki promtail prometheus grafana-server; do
  systemctl reset-failed "$svc" 2>/dev/null || true
  systemctl enable --now "$svc"
done

# ── Cleanup (Sustainability) ──────────────────────────────────────────────────
rm -rf /tmp/prometheus-* /tmp/loki-* /tmp/mimir-* /tmp/promtail-* 2>/dev/null || true

# ── Validate ──────────────────────────────────────────────────────────────────
echo "==> Validating..."; sleep 10
for s in "grafana-server:3000" "prometheus:9090" "loki:3100" "mimir:9009" "promtail:9080"; do
  n="${s%%:*}"; p="${s##*:}"
  systemctl is-active --quiet "$n" && echo "  [OK] $n :$p" || echo "  [WARN] $n not running"
done

PUBLIC_IP=$(curl -sf --max-time 3 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "<EC2-IP>")
echo ""
echo "  Grafana    -> http://${PUBLIC_IP}:3000 (admin/admin)"
echo "  Prometheus -> http://${PUBLIC_IP}:9090"
echo "  Loki       -> http://${PUBLIC_IP}:3100/ready"
echo "  Mimir      -> http://${PUBLIC_IP}:9009/ready"
echo "  Log        -> $LOG"
echo ""
echo "  Verify in Grafana Explore:"
echo "    Mimir  -> query: up"
echo "    Loki   -> query: {job=\"varlogs\"}"
