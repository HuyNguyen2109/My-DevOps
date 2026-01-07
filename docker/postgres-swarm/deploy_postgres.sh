#!/bin/bash
# ----------------------
log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
# ----------------------
STACK_NAME="postgres-cluster"
POSTGRES_EXTENDED_CONF="postgres-extended-conf"
POSTGRES_HBA_FILE="pg-hba-conf"
PGBOUNCER_INI="pgbouncer-ini"
PGBOUNCER_USERLIST="pgbouncer-userlist"
MASTER_DATA_FOLDER="/mnt/docker/data"
REQUIRED_DIRECTORY="postgres"

# === Parse command-line arguments ===
SWARM_NODE_CODENAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node|--codename|-n)
      SWARM_NODE_CODENAME="$2"
      shift 2
      ;;
    -h|--help)
      log "Usage: $0 --node <SWARM_NODE_CODENAME>"
      log "Options:"
      log "  --node, --codename, -n    Specify the node codename (alpha, beta, gamma)"
      log "  -h, --help                Show this help message"
      log ""
      log "Example: $0 --node alpha"
      exit 0
      ;;
    *)
      err "❌ Unknown option: $1"
      err "Use --help for usage information"
      exit 1
      ;;
  esac
done

if [ -z "$SWARM_NODE_CODENAME" ]; then
  err "❌ SWARM_NODE_CODENAME is required."
  err "Usage: $0 --node <SWARM_NODE_CODENAME>"
  err "Example: $0 --node alpha"
  exit 1
fi

log "🎯 Deploying to node codename: $SWARM_NODE_CODENAME"

# === Set node-specific configuration based on codename ===
case "$SWARM_NODE_CODENAME" in
  alpha)
    SSH_KEY="$HOME/ssh-keys/oracle.key"
    NODE_USER="root"
    NODES=($SWARM_MANAGER_HOSTNAME)
    ;;
  beta)
    SSH_KEY="$HOME/ssh-keys/oracle.key"
    NODE_USER="root"
    NODES=($SWARM_WORKER_VN_HOSTNAME)
    ;;
  gamma)
    SSH_KEY="$HOME/ssh-keys/oracle.key"
    NODE_USER="ubuntu"
    NODES=($SWARM_WORKER_SG_HOSTNAME)
    ;;
  *)
    err "❌ Unknown SWARM_NODE_CODENAME: $SWARM_NODE_CODENAME"
    err "Valid options: alpha, beta, gamma"
    exit 1
    ;;
esac

# Validate that NODES array is populated
if [ ${#NODES[@]} -eq 0 ]; then
  err "❌ NODES array is empty. Please ensure the environment variable for the selected node is set."
  exit 1
fi

log "SSH to node to create required sub-directories"
for NODE in "${NODES[@]}"; do
  log "🔧 Preparing data folder on $NODE..."
  if ssh -i $SSH_KEY $NODE_USER@$NODE "[ -d $MASTER_DATA_FOLDER/$REQUIRED_DIRECTORY ]"; then
    log "  ✓ Directory $REQUIRED_DIRECTORY already exists, skipping..."
  else
    log "  📁 Creating directory $REQUIRED_DIRECTORY..."
    ssh -i $SSH_KEY $NODE_USER@$NODE "sudo mkdir -p $MASTER_DATA_FOLDER/$REQUIRED_DIRECTORY && sudo chown docker:docker $MASTER_DATA_FOLDER/$REQUIRED_DIRECTORY"
  fi
done

# === Remove existing Docker stack ===
docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true
sleep 5

# === Check if Vault CLI is installed ===
log "Checking vault cli is installed..."
if ! command -v vault >/dev/null 2>&1; then
    err "❌ Vault CLI is not installed!"
    exit 1
fi

log "Checking Vault credentials..."
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

# === Get secrets from Vault ===
log "🔐 Fetching secrets from Vault..."
POSTGRES_PASSWORD=$(vault kv get -field=postgres-root-password kubernetes/docker-secrets)

# === Create Docker Secret ===
log "Creating Docker secrets..."
docker secret rm postgres-root-password >/dev/null 2>&1 || true
echo -n "$POSTGRES_PASSWORD" | docker secret create postgres-root-password - >/dev/null 2>&1 || true

# === Export environment variables ===
export IMAGE_TAG="17-alpine3.23"
export PGBOUNCER_TAG="latest"
export MASTER_DATA_FOLDER=$MASTER_DATA_FOLDER
export SWARM_NODE_CODENAME=$SWARM_NODE_CODENAME
export PGADMIN_DEFAULT_EMAIL="JohnasHuy21091996@gmail.com"

# === Create Docker Configs ===
log "Creating Docker configs..."
docker config rm $POSTGRES_EXTENDED_CONF >/dev/null 2>&1 || true
docker config rm $POSTGRES_HBA_FILE >/dev/null 2>&1 || true
docker config rm $PGBOUNCER_INI >/dev/null 2>&1 || true
docker config rm $PGBOUNCER_USERLIST >/dev/null 2>&1 || true

# PostgreSQL extended configuration
cat <<EOF | docker config create $POSTGRES_EXTENDED_CONF - >/dev/null 2>&1 || true
############################################
# CONNECTIONS AND AUTHENTICATION
############################################
listen_addresses = '*'
port = 5432
max_connections = 200

############################################
# Memory & Cache
############################################
shared_buffers = 6GB
effective_cache_size = 18GB
work_mem = 64MB
maintenance_work_mem = 1GB

############################################
# WAL & Checkpoints
############################################
wal_level = replica
wal_compression = on
max_wal_size = 8GB
min_wal_size = 2GB
checkpoint_timeout = 10min
checkpoint_completion_target = 0.9
archive_mode = off
synchronous_commit = on
wal_buffers = 64MB

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
# Logging
############################################
log_destination = 'stderr'
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d.log'
log_rotation_age = 1d
log_rotation_size = 100MB
log_min_duration_statement = 1000
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
log_temp_files = 0
EOF

# PostgreSQL pg_hba.conf
cat <<EOF | docker config create $POSTGRES_HBA_FILE - >/dev/null 2>&1 || true
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     md5
host    all             all             127.0.0.1/32            md5
host    all             all             ::1/128                 md5
host    all             all             0.0.0.0/0               md5
host    all             all             ::/0                    md5
host    replication     all             0.0.0.0/0               md5
EOF

# PgBouncer configuration (edoburu/pgbouncer image)
cat <<EOF | docker config create $PGBOUNCER_INI - >/dev/null 2>&1 || true
[databases]
* = host=postgres port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 5432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
admin_users = postgres
stats_users = postgres
pool_mode = transaction
max_client_conn = 2000
default_pool_size = 50
min_pool_size = 10
reserve_pool_size = 10
reserve_pool_timeout = 5
server_lifetime = 3600
server_idle_timeout = 600
server_connect_timeout = 15
server_login_retry = 5
query_timeout = 300
query_wait_timeout = 120
client_idle_timeout = 0
ignore_startup_parameters = extra_float_digits
log_connections = 1
log_disconnections = 1
log_pooler_errors = 1
EOF

# PgBouncer userlist (MD5 hash format: "user" "md5<hash>")
# Generate MD5 hash: echo -n "password<username>" | md5sum
POSTGRES_MD5=$(echo -n "${POSTGRES_PASSWORD}postgres" | md5sum | awk '{print $1}')
cat <<EOF | docker config create $PGBOUNCER_USERLIST - >/dev/null 2>&1 || true
"postgres" "md5${POSTGRES_MD5}"
EOF

# Deploy the stack
log "🚀 Deploying stack..."
docker stack deploy -c docker-compose.yml "$STACK_NAME" --detach > /dev/null 2>&1 || true
log "✅ Docker stack '$STACK_NAME' deployed successfully!"
