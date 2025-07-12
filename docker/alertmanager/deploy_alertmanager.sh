#!/bin/bash
# Define stack name (change this as needed)
STACK_NAME="alert-system"
ALERTMANAGER_CONFIG_FILE="alertmanager-conf"
# === Remove existing Docker services if it exists ===
docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true
# Load environment variables from .env file
if [ -f .env ]; then
    set -a  # Automatically export all variables
    source .env
    set +a
else
    echo "⚠️  .env file not found! Make sure it exists in the current directory."
    exit 1
fi
# === Create Docker Config via STDIN ===
echo "Parsing all necessary variables into config..."
docker config rm "$ALERTMANAGER_CONFIG_FILE" >/dev/null 2>&1 || true
cat <<EOF | docker config create "$ALERTMANAGER_CONFIG_FILE" -
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname', 'instance', 'severity']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 5m
  receiver: 'ntfy-notifications'

receivers:
  - name: 'ntfy-notifications'
    webhook_configs:
      - url: 'http://ntfy-alert-bridge:5001'
        send_resolved: true

inhibit_rules:
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['alertname', 'instance']

EOF
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME"
echo "✅ Docker stack '$STACK_NAME' deployed successfully!"
