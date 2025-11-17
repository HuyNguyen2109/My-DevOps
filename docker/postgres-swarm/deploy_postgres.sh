#!/bin/bash
# ----------------------
log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
# ----------------------
# Define stack name (change this as needed)
STACK_NAME="postgres-cluster"
POSTGRES_EXTENDED_CONF="postgres-extended-conf"
POSTGRES_EXTENDED_CONF_SLAVE="postgres-extended-conf-slave"
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
log "Checking vault cli is installed..."
if ! command -v vault >/dev/null 2>&1; then
    err "❌ Vault CLI is not installed!"
    exit 1
fi
log "Checking Vault credentials for Vault..."
REQUIRED_VARS=(
  VAULT_ADDR
  VAULT_TOKEN
)
for VAR in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!VAR}" ]; then
    err "❌ Environment variable '$VAR' is not set or is empty."
    exit 1
  fi
done
# Load environment variables from .env file
export IMAGE_TAG="latest"
export MASTER_DATA_FOLDER=$MASTER_DATA_FOLDER
export REPLICATION_USER="repl-admin"

CLOUDFLARE_PEM=$(vault kv get -field=cloudflare-cert-pem-b64 kubernetes/terraform)
echo "$CLOUDFLARE_PEM" | base64 --decode | docker secret create $POSTGRES_CERT_PEM -

CLOUDFLARE_KEY=$(vault kv get -field=cloudflare-key-pem-b64 kubernetes/terraform)
echo "$CLOUDFLARE_KEY" | base64 --decode | docker secret create $POSTGRES_KEY_PEM -

CLOUDFLARE_CA=$(vault kv get -field=cloudflare-origin-ca-pem-b64 kubernetes/terraform)
echo "$CLOUDFLARE_CA" | base64 --decode | docker secret create $POSTGRES_CA_PEM -
# === Create Docker Config via STDIN ===
log "Parsing all necessary variables into config..."
docker config rm $POSTGRES_EXTENDED_CONF >/dev/null 2>&1 || true
docker config rm $POSTGRES_HBA_FILE >/dev/null 2>&1 || true
docker config rm $POSTGRES_EXTENDED_CONF_SLAVE >/dev/null 2>&1 || true
cat <<EOF | docker config create $POSTGRES_EXTENDED_CONF - >/dev/null 2>&1 || true
############################################
# Memory & Cache
############################################
shared_buffers = 5GB                  # ~25% of total RAM
effective_cache_size = 13GB           # ~75% of total RAM
work_mem = 16MB                       # per operation; safe for 4 cores
maintenance_work_mem = 512MB          # for VACUUM/CREATE INDEX

############################################
# WAL & Checkpoints
############################################
wal_level = replica
wal_compression = on
max_wal_size = 4GB
min_wal_size = 1GB
checkpoint_timeout = 5min
checkpoint_completion_target = 0.7
archive_mode = off                    # unless using WAL archiving
synchronous_commit = on               # use 'off' for latency-sensitive apps

############################################
# Autovacuum & Analyze
############################################
autovacuum = on
autovacuum_naptime = 30s
autovacuum_max_workers = 3
autovacuum_vacuum_scale_factor = 0.1
autovacuum_analyze_scale_factor = 0.05
autovacuum_vacuum_cost_limit = 200
autovacuum_vacuum_cost_delay = 20ms

############################################
# Parallel Query
############################################
max_parallel_workers_per_gather = 2
max_parallel_workers = 4
max_worker_processes = 8
parallel_leader_participation = on

############################################
# Connections & Pooling
############################################
max_connections = 200                 # use PgBouncer for more
superuser_reserved_connections = 3
shared_preload_libraries = 'pg_stat_statements'
track_activity_query_size = 4096
pg_stat_statements.max = 10000

############################################
# Performance & Planner
############################################
random_page_cost = 1.1
seq_page_cost = 1.0
effective_io_concurrency = 200        # good for fast OCI block storage
default_statistics_target = 100

############################################
# Logging
############################################
log_min_duration_statement = 500ms
log_checkpoints = on
log_autovacuum_min_duration = 1000
log_line_prefix = '%t [%p] %q%u@%d '
log_error_verbosity = default

############################################
# Background Writer
############################################
bgwriter_lru_maxpages = 1000
bgwriter_lru_multiplier = 4.0
bgwriter_delay = 10ms

############################################
# SSL enforcement
############################################
ssl = on
ssl_cert_file = '/opt/bitnami/postgresql/certs/server.crt'
ssl_key_file  = '/opt/bitnami/postgresql/certs/server.key'
ssl_ca_file   = '/opt/bitnami/postgresql/certs/ca.crt'
EOF

cat <<EOF | docker config create $POSTGRES_EXTENDED_CONF_SLAVE - >/dev/null 2>&1 || true
############################################
# CONNECTIONS AND AUTHENTICATION
############################################
listen_addresses = '*'                   # Listen on all interfaces
port = 5432
max_connections = 200
superuser_reserved_connections = 3
############################################
# SSL enforcement
############################################
ssl = on
ssl_cert_file = '/opt/bitnami/postgresql/certs/server.crt'
ssl_key_file  = '/opt/bitnami/postgresql/certs/server.key'
ssl_ca_file   = '/opt/bitnami/postgresql/certs/ca.crt'
EOF

cat <<EOF | docker config create $POSTGRES_HBA_FILE - >/dev/null 2>&1 || true
# ============================================================================
# PostgreSQL Client Authentication Configuration
# ============================================================================
# TYPE   DATABASE        USER           ADDRESS               METHOD    OPTIONS
# ----------------------------------------------------------------------------
# 1. Allow local Unix socket connections (no SSL)
local   all             all                                  trust

# 2. Allow internal Docker Swarm network (no SSL)
# Replace 10.0.0.0/8 with your Swarm network CIDRs if more restrictive
hostnossl all           all           11.0.3.0/24            md5
hostnossl all           all           10.128.0.0/24          md5
hostnossl all           all           172.16.0.0/12          md5
hostnossl all           all           192.168.0.0/16         md5
hostssl   replication   repl-admin    11.0.3.0/24            md5
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
docker stack deploy -c docker-compose.yml "$STACK_NAME" --detach
log "✅ Docker stack '$STACK_NAME' deployed successfully!"
