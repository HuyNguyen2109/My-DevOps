#!/bin/bash
# Define stack name (change this as needed)
STACK_NAME="postgres-cluster"
POSTGRES_EXTENDED_CONF="postgres-extended-conf"
POSTGRES_CERT_PEM="postgres-cert-pem"
POSTGRES_KEY_PEM="postgres-key-pem"
POSTGRES_CA_PEM="postgres-ca-pem"
POSTGRES_HBA_FILE="pg-hba-conf"
# === Remove existing Docker services if it exists ===
docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true

docker secret rm $POSTGRES_CERT_PEM >/dev/null 2>&1 || true
docker secret rm $POSTGRES_KEY_PEM >/dev/null 2>&1 || true
docker secret rm $POSTGRES_CA_PEM >/dev/null 2>&1 || true
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
# Load environment variables from .env file
export IMAGE_TAG="17-debian-12"

CLOUDFLARE_PEM=$(vault kv get -field=cloudflare-cert-pem-b64 kubernetes/terraform)
echo "$CLOUDFLARE_PEM" | base64 --decode | docker secret create $POSTGRES_CERT_PEM -

CLOUDFLARE_KEY=$(vault kv get -field=cloudflare-key-pem-b64 kubernetes/terraform)
echo "$CLOUDFLARE_KEY" | base64 --decode | docker secret create $POSTGRES_KEY_PEM -

CLOUDFLARE_CA=$(vault kv get -field=cloudflare-origin-ca-pem-b64 kubernetes/terraform)
echo "$CLOUDFLARE_CA" | base64 --decode | docker secret create $POSTGRES_CA_PEM -
# === Create Docker Config via STDIN ===
echo "Parsing all necessary variables into config..."
docker config rm $POSTGRES_EXTENDED_CONF >/dev/null 2>&1 || true
docker config rm $POSTGRES_HBA_FILE >/dev/null 2>&1 || true
cat <<EOF | docker config create $POSTGRES_EXTENDED_CONF -
# Memory Settings
shared_buffers = 768MB               # ~25% of RAM, main PostgreSQL cache
work_mem = 16MB                      # Memory per sort/hash operation
maintenance_work_mem = 192MB         # Used for VACUUM, CREATE INDEX, etc.
effective_cache_size = 2GB           # Estimated OS-level file system cache
wal_buffers = 16MB                   # Usually 16MB is enough
temp_buffers = 8MB                   # Per-session temporary table buffers

# Checkpoint Settings
checkpoint_completion_target = 0.9   # Spread checkpoints to avoid spikes
checkpoint_timeout = 15min
max_wal_size = 1GB
min_wal_size = 80MB

# Parallelism (low, since we have 1 CPU)
max_parallel_workers = 2
max_parallel_workers_per_gather = 1
parallel_setup_cost = 1000
parallel_tuple_cost = 0.1

# Connections
max_connections = 50                 # Reduce if each connection uses lots of RAM
superuser_reserved_connections = 3

# WAL & Durability
wal_level = replica                  # Use 'minimal' if no replication needed
synchronous_commit = on               # Set to 'off' for speed at risk of data loss
full_page_writes = on
archive_mode = off                    # Enable if you need PITR

# Query Planning
random_page_cost = 1.1                # SSD tuning (lower than HDD default)
effective_io_concurrency = 200        # For SSD/NVMe; lower for HDD

# Logging
log_min_duration_statement = 500ms    # Log queries slower than 0.5s
log_checkpoints = on
log_connections = off
log_disconnections = off

# Autovacuum
autovacuum = on
autovacuum_naptime = 15s
autovacuum_vacuum_scale_factor = 0.05
autovacuum_analyze_scale_factor = 0.02

# SSL enforcement
ssl = on
ssl_cert_file = '/opt/bitnami/postgresql/certs/server.crt'
ssl_key_file  = '/opt/bitnami/postgresql/certs/server.key'
ssl_ca_file   = '/opt/bitnami/postgresql/certs/ca.crt'
EOF

cat <<EOF | docker config create $POSTGRES_HBA_FILE -
# ============================================================================
# PostgreSQL Client Authentication Configuration
# ============================================================================
# TYPE   DATABASE        USER           ADDRESS               METHOD    OPTIONS
# ----------------------------------------------------------------------------
# 1. Allow local Unix socket connections (no SSL)
local   all             all                                  trust

# 2. Allow internal Docker Swarm network (no SSL)
# Replace 10.0.0.0/8 with your Swarm network CIDRs if more restrictive
hostnossl all           all           10.0.0.0/8             md5
hostnossl all           all           172.16.0.0/12          md5
hostnossl all           all           192.168.0.0/16         md5
# Allow Netbird network (no SSL)
hostnossl all           all           100.64.0.0/10          md5

# 3. Require SSL for any other (public) connections
hostssl   all           all           0.0.0.0/0              md5
hostssl   all           all           ::/0                   md5

# 4. Reject non-SSL connections from outside internal networks
hostnossl all           all           0.0.0.0/0              reject
hostnossl all           all           ::/0                   reject

EOF
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME"
echo "✅ Docker stack '$STACK_NAME' deployed successfully!"
