#!/bin/bash
# Define stack name (change this as needed)
STACK_NAME="logging-agents"
LOKI_CONFIG_FILE="loki-config"
PROMTAIL_CONFIG_FILE="promtail-config"
# === Check if Azure CLI is installed ===
echo "Checking az cli is installed..."
if ! command -v az >/dev/null 2>&1; then
    echo "❌ Azure CLI (az) is not installed. Please install it first: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi
echo "Checking Azure credentials for Azure Key Vault..."
REQUIRED_VARS=(
  AZURE_CLIENT_ID
  AZURE_CLIENT_SECRET
  AZURE_TENANT_ID
  AZURE_SUBSCRIPTION_ID
  AZURE_VAULT_NAME
)

for VAR in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!VAR}" ]; then
    echo "❌ Environment variable '$VAR' is not set or is empty."
    exit 1
  fi
done
# === Get secrets from Azure Key Vault ===
echo "🔐 Fetching secrets from Azure Key Vault..."
S3_LOKI_BUCKET_URL=$(az keyvault secret show --vault-name "$AZURE_VAULT_NAME" --name "s3-loki-bucket" --query "value" -o tsv)
# === Create Docker Config via STDIN ===
echo "Parsing all necessary variables into config..."
docker config rm $LOKI_CONFIG_FILE
docker config rm $PROMTAIL_CONFIG_FILE
cat <<EOF | docker config create $LOKI_CONFIG_FILE -
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096
  http_listen_address: 0.0.0.0

compactor:
  working_directory: /loki/compactor
  compactor_ring:
    kvstore:
      store: inmemory

ingester:
  wal:
    enabled: true
    dir: /loki/wal
  lifecycler:
    ring:
      kvstore:
        store: inmemory
      replication_factor: 1
  chunk_idle_period: 5m
  max_chunk_age: 1h

schema_config:
  configs:
    - from: 2025-01-01
      store: tsdb
      object_store: aws
      schema: v13
      index:
        prefix: index_
        period: 24h

storage_config:
  tsdb_shipper:
    active_index_directory: /loki/index
    cache_location: /loki/index_cache
  
  aws:
    s3: $S3_LOKI_BUCKET_URL
    endpoint: https://32e21cb26175efbbdbd48a4ce2d76d39.r2.cloudflarestorage.com
    region: auto
    s3forcepathstyle: false

limits_config:
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  allow_structured_metadata: false

table_manager:
  retention_deletes_enabled: true
  retention_period: 168h
EOF
cat <<EOF | docker config create $PROMTAIL_CONFIG_FILE -
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://tasks.loki:3100/loki/api/v1/push

scrape_configs:
  - job_name: docker
    docker_sd_configs:
      - host: unix:///var/run/docker.sock
        refresh_interval: 5s

    relabel_configs:
      - source_labels: [__meta_docker_container_label_com_docker_swarm_service_name]
        target_label: swarm_service
      - source_labels: [__meta_docker_container_name]
        target_label: container
      - source_labels: [__meta_docker_container_image]
        target_label: image
      - source_labels: [__address__]
        target_label: instance
EOF
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME"
echo "✅ Docker stack '$STACK_NAME' deployed successfully!"
