#!/bin/bash
# Define stack name (change this as needed)
STACK_NAME="monitoring-agents"
GRAFANA_CONFIG_FILE="grafana-conf"
PROMETHEUS_RULES="prometheus-rules"
PROMETHEUS_CONFIG_FILE="prometheus-conf"
# === Remove existing Docker services if it exists ===
docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true
# === Check if Vault CLI is installed ===
echo "Checking vault cli is installed..."
if ! command -v vault >/dev/null 2>&1; then
    echo "❌ Vault CLI is not installed!"
    exit 1
fi
echo "Checking Vault credentials for Vault..."
REQUIRED_VARS=(
  VAULT_ADDR
  VAULT_TOKEN
)
for VAR in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!VAR}" ]; then
    echo "❌ Environment variable '$VAR' is not set or is empty."
    exit 1
  fi
done
# === Get secrets from Vault ===
echo "🔐 Fetching secrets from Vault..."
GRAFANA_ADMIN_PASSWORD=$(vault kv get -field=grafana-admin-password kubernetes/docker-secrets)
GRAFANA_DB_ADMIN_PASSWORD=$(vault kv get -field=grafana-db-admin-password kubernetes/docker-secrets)
GRAFANA_AUTHENTIK_CLIENT_ID=$(vault kv get -field=grafana-authentik-client-id kubernetes/docker-secrets)
GRAFANA_AUTHENTIK_CLIENT_SECRET=$(vault kv get -field=grafana-authentik-client-secret kubernetes/docker-secrets)
VALKEY_AUTH_PASSWORD=$(vault kv get -field=valkey-auth-password kubernetes/docker-secrets)
export DOMAIN_NAME="mcb-svc.work"
# === Create Docker Config via STDIN ===
echo "Parsing all necessary variables into config..."

docker config rm "$PROMETHEUS_CONFIG_FILE" >/dev/null 2>&1 || true
cat <<'EOF' | docker config create "$PROMETHEUS_CONFIG_FILE" -
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - 'alertmanager:9093'

rule_files:
  - './rules.yml'

scrape_configs:
  # Scrape cAdvisor
  - job_name: 'cadvisor'
    static_configs:
      - targets:
          - 100.74.212.20:9080
          - 100.76.78.71:9080
        labels:
          role: cadvisor
    relabel_configs:
      - source_labels: [__address__]
        regex: '([^:]+):\d+'
        target_label: instance
        replacement: '${1}'

  # Scrape Node Exporter
  - job_name: 'node-exporter'
    static_configs:
      - targets:
          - 100.74.212.20:9100
          - 100.76.78.71:9100
        labels:
          role: node
    relabel_configs:
      - action: labeldrop
        regex: instance
      - source_labels: [__address__]
        regex: '([^:]+):\d+'
        target_label: instance
        replacement: '${1}'

  # Scrape all Docker Swarm services (optional generic job)
  - job_name: 'swarm-tasks'
    dockerswarm_sd_configs:
      - host: unix:///var/run/docker.sock
        role: tasks
    relabel_configs:
      - source_labels: [__meta_dockerswarm_task_service_name]
        target_label: swarm_service

    #   - source_labels: [__meta_dockerswarm_task_container_label_prometheus_scrape]
    #     regex: 'true'
    #     action: keep

      - source_labels: [__meta_dockerswarm_task_container_label_prometheus_port]
        regex: (.+)
        target_label: __address__
        replacement: '${1}'

      - source_labels: [__meta_dockerswarm_task_container_label_prometheus_path]
        regex: (.+)
        target_label: __metrics_path__
        replacement: '${1}'

EOF

docker config rm "$PROMETHEUS_RULES" >/dev/null 2>&1 || true
cat <<'EOF' | docker config create "$PROMETHEUS_RULES" -
groups:
  - name: system_resources
    rules:
      - alert: HighMemoryUsage
        expr: (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes * 100 > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High memory usage (instance {{ $labels.instance }})"
          description: "Memory usage is above 80%\n  VALUE = {{ $value }}%\n  LABELS: {{ $labels }}"

      - alert: HighCPUUsage
        expr: 100 - (avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 50
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High CPU usage (instance {{ $labels.instance }})"
          description: "CPU usage is above 50%\n  VALUE = {{ $value }}%\n  LABELS: {{ $labels }}"

  - name: docker_swarm
    rules:
      - alert: HighDockerServiceMemoryUsage
        expr: |
          (
            sum by (container_label_com_docker_swarm_service_name, instance) (
            container_memory_usage_bytes{container_label_com_docker_swarm_service_name!=""}
          )
          /
          ignoring(container_label_com_docker_swarm_service_name)
          group_left
          sum by (instance) (
            node_memory_MemTotal_bytes
          )
          ) * 100 > 20
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High memory usage in Docker service (service {{ $labels.container_label_com_docker_swarm_service_name }})"
          description: "Service is using more than 20% of system memory\n  VALUE = {{ $value }}%\n  LABELS: {{ $labels.container_label_com_docker_swarm_service_name }}"

      - alert: HighDockerServiceCPUUsage
        expr: |
          rate(
            container_cpu_usage_seconds_total{container_label_com_docker_swarm_service_name!=""}[5m]
          ) * on(instance) group_left count(node_cpu_seconds_total{mode="system"}) by (instance) * 100 > 50
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High CPU usage in Docker service (service {{ $labels.container_label_com_docker_swarm_service_name }})"
          description: "Service is using more than 50% of system CPU\n  VALUE = {{ $value }}%\n  LABELS: {{ $labels.container_label_com_docker_swarm_service_name }}"
EOF

docker config rm "$GRAFANA_CONFIG_FILE" >/dev/null 2>&1 || true
cat <<EOF | docker config create "$GRAFANA_CONFIG_FILE" -
[log]
mode = "console"
level = "info"

[log.console]
level = "warn"
format = "json"

[security]
admin_user = "admin"
admin_password = "$GRAFANA_ADMIN_PASSWORD"

[server]
domain = "grafana.mcb-svc.work"
root_url = "https://grafana.mcb-svc.work"

[auth]
disable_login_form = false

[auth.anonymous]
enabled = false

[database]
type = "postgres"
host = "postgresql-master:5432"
name = "grafana"
user = "grafana_admin"
password = "$GRAFANA_DB_ADMIN_PASSWORD"
migration_locking = false

[remote_cache]
type = "redis"
connstr = "addr=valkey-server:6379,password=$VALKEY_AUTH_PASSWORD,db=0"

[plugins]
disable_plugins = ""

[auth.generic_oauth]
enabled = true
client_id = "$GRAFANA_AUTHENTIK_CLIENT_ID"
client_secret = "$GRAFANA_AUTHENTIK_CLIENT_SECRET"
auth_url = "https://auth.mcb-svc.work/application/o/authorize/"
token_url = "https://auth.mcb-svc.work/application/o/token/"
api_url = "https://auth.mcb-svc.work/application/o/userinfo/"
scopes = openid email profile
auto_login = true
# Optionally map user groups to Grafana roles
role_attribute_path = contains(groups, 'Grafana Admins') && 'Admin' || contains(groups, 'Grafana Editors') && 'Editor' || 'Viewer'
allow_assign_grafana_admin = true
use_refresh_token = true

[users]
auto_assign_org = true
auto_assign_org_id = 1
EOF
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME"
echo "✅ Docker stack '$STACK_NAME' deployed successfully!"
