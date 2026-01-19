#!/bin/bash
log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }

STACK_NAME="postgres-cluster-ha"
POSTGRES_PRIMARY_CONF="postgres-ha-primary-conf"
POSTGRES_STANDBY_CONF="postgres-ha-standby-conf"
POSTGRES_INIT_REPLICATOR="postgres-ha-init-replicator"
PG_HBA_PRIMARY_CONF="pg-hba-ha-primary-conf"
PG_HBA_STANDBY_CONF="pg-hba-ha-standby-conf"
PGCAT_TRANSACTION_CONFIG="pgcat-transaction-ha-config"
PGCAT_SESSION_CONFIG="pgcat-session-ha-config"

PRIMARY_NODE_CODENAME=""
STANDBY_NODE_CODENAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --primary|-p)
      PRIMARY_NODE_CODENAME="$2"
      shift 2
      ;;
    --standby|-s)
      STANDBY_NODE_CODENAME="$2"
      shift 2
      ;;
    -h|--help)
      log "Usage: $0 --primary <CODENAME> --standby <CODENAME>"
      log "Options:"
      log "  --primary, -p    Node codename for primary (alpha, beta, gamma)"
      log "  --standby, -s    Node codename for standby (alpha, beta, gamma)"
      log "  -h, --help       Show this help message"
      log ""
      log "Example: $0 --primary alpha --standby beta"
      exit 0
      ;;
    *)
      err "Unknown option: $1"
      err "Use --help for usage information"
      exit 1
      ;;
  esac
done

if [ -z "$PRIMARY_NODE_CODENAME" ] || [ -z "$STANDBY_NODE_CODENAME" ]; then
  err "Both --primary and --standby are required."
  err "Usage: $0 --primary <CODENAME> --standby <CODENAME>"
  exit 1
fi

if [ "$PRIMARY_NODE_CODENAME" == "$STANDBY_NODE_CODENAME" ]; then
  err "Primary and standby must be on different nodes."
  exit 1
fi

log "Deploying PostgreSQL HA Cluster"
log "  Primary node: $PRIMARY_NODE_CODENAME"
log "  Standby node: $STANDBY_NODE_CODENAME"

get_node_config() {
  local codename=$1
  case "$codename" in
    alpha)
      SSH_KEY="$HOME/ssh-keys/oracle.key"
      NODE_USER="root"
      NODE_HOST=$SWARM_MANAGER_HOSTNAME
      DATA_FOLDER="/mnt/docker/data"
      ;;
    beta)
      SSH_KEY="$HOME/ssh-keys/oracle.key"
      NODE_USER="root"
      NODE_HOST=$SWARM_WORKER_VN_HOSTNAME
      DATA_FOLDER="/mnt/docker/data"
      ;;
    gamma)
      SSH_KEY="$HOME/ssh-keys/oracle.key"
      NODE_USER="ubuntu"
      NODE_HOST=$SWARM_WORKER_SG_HOSTNAME
      DATA_FOLDER="/mnt/docker/data"
      ;;
    *)
      err "Unknown codename: $codename (valid: alpha, beta, gamma)"
      exit 1
      ;;
  esac
}

get_node_config "$PRIMARY_NODE_CODENAME"
PRIMARY_SSH_KEY="$SSH_KEY"
PRIMARY_NODE_USER="$NODE_USER"
PRIMARY_NODE_HOST="$NODE_HOST"
PRIMARY_DATA_FOLDER="$DATA_FOLDER"

get_node_config "$STANDBY_NODE_CODENAME"
STANDBY_SSH_KEY="$SSH_KEY"
STANDBY_NODE_USER="$NODE_USER"
STANDBY_NODE_HOST="$NODE_HOST"
STANDBY_DATA_FOLDER="$DATA_FOLDER"

if [ -z "$PRIMARY_NODE_HOST" ] || [ -z "$STANDBY_NODE_HOST" ]; then
  err "Node hostname environment variables are not set."
  exit 1
fi

source "$(dirname "$0")/../../swarm_initialization/create_directories.sh" 2>/dev/null || {
  log "Creating directories via SSH..."
  ssh -i "$PRIMARY_SSH_KEY" "$PRIMARY_NODE_USER@$PRIMARY_NODE_HOST" \
    "sudo mkdir -p $PRIMARY_DATA_FOLDER/postgres-primary $PRIMARY_DATA_FOLDER/postgres-primary-archive && sudo chown -R 999:999 $PRIMARY_DATA_FOLDER/postgres-primary $PRIMARY_DATA_FOLDER/postgres-primary-archive" || true
  ssh -i "$STANDBY_SSH_KEY" "$STANDBY_NODE_USER@$STANDBY_NODE_HOST" \
    "sudo mkdir -p $STANDBY_DATA_FOLDER/postgres-standby && sudo chown -R 999:999 $STANDBY_DATA_FOLDER/postgres-standby" || true
}

docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true
sleep 5

log "Checking vault cli is installed..."
if ! command -v vault >/dev/null 2>&1; then
    err "Vault CLI is not installed!"
    exit 1
fi

log "Checking Vault credentials..."
REQUIRED_VARS=(VAULT_ADDR VAULT_TOKEN)
for VAR in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!VAR}" ]; then
    err "Environment variable '$VAR' is not set or is empty."
    exit 1
  fi
done

log "Fetching secrets from Vault..."
POSTGRES_PASSWORD=$(vault kv get -field=postgres-root-password kubernetes/docker-secrets 2>/dev/null)

if [ -z "$POSTGRES_PASSWORD" ]; then
  err "Failed to fetch password from Vault. Ensure Vault is accessible."
  exit 1
fi

log "Creating Docker secrets..."
docker secret rm postgres-root-password >/dev/null 2>&1 || true
echo -n "$POSTGRES_PASSWORD" | docker secret create postgres-root-password - >/dev/null 2>&1 || true

export IMAGE_TAG="16-alpine"
export PGCAT_TAG="v1.2.0"
export PRIMARY_DATA_FOLDER="$PRIMARY_DATA_FOLDER"
export STANDBY_DATA_FOLDER="$STANDBY_DATA_FOLDER"

log "Creating Docker configs..."
docker config rm $POSTGRES_PRIMARY_CONF >/dev/null 2>&1 || true
docker config rm $POSTGRES_STANDBY_CONF >/dev/null 2>&1 || true
docker config rm $POSTGRES_INIT_REPLICATOR >/dev/null 2>&1 || true
docker config rm $PG_HBA_PRIMARY_CONF >/dev/null 2>&1 || true
docker config rm $PG_HBA_STANDBY_CONF >/dev/null 2>&1 || true
docker config rm $PGCAT_TRANSACTION_CONFIG >/dev/null 2>&1 || true
docker config rm $PGCAT_SESSION_CONFIG >/dev/null 2>&1 || true

cat <<EOF | docker config create $POSTGRES_PRIMARY_CONF - >/dev/null 2>&1 || true
listen_addresses = '*'
port = 5432
max_connections = 200
wal_level = replica
max_wal_senders = 5
max_replication_slots = 5
hot_standby = on
synchronous_commit = on
synchronous_standby_names = 'FIRST 1 (*)'
wal_keep_size = 1GB
shared_buffers = 2GB
effective_cache_size = 6GB
work_mem = 32MB
maintenance_work_mem = 512MB
wal_compression = on
max_wal_size = 4GB
min_wal_size = 1GB
checkpoint_timeout = 10min
checkpoint_completion_target = 0.9
wal_buffers = 64MB
archive_mode = on
archive_command = 'test ! -f /var/lib/postgresql/archive/%f && cp %p /var/lib/postgresql/archive/%f'
autovacuum = on
autovacuum_naptime = 30s
autovacuum_max_workers = 2
autovacuum_vacuum_scale_factor = 0.1
autovacuum_analyze_scale_factor = 0.05
max_parallel_workers_per_gather = 1
max_parallel_workers = 2
max_worker_processes = 4
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
EOF

cat <<EOF | docker config create $POSTGRES_STANDBY_CONF - >/dev/null 2>&1 || true
listen_addresses = '*'
port = 5432
max_connections = 200
wal_level = replica
hot_standby = on
hot_standby_feedback = on
max_standby_streaming_delay = 30s
max_standby_archive_delay = 60s
shared_buffers = 512MB
effective_cache_size = 1536MB
work_mem = 16MB
maintenance_work_mem = 128MB
wal_compression = on
max_wal_size = 2GB
min_wal_size = 512MB
checkpoint_timeout = 10min
checkpoint_completion_target = 0.9
autovacuum = on
autovacuum_naptime = 60s
autovacuum_max_workers = 1
max_parallel_workers_per_gather = 1
max_parallel_workers = 1
max_worker_processes = 4
log_destination = 'stderr'
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-standby-%Y-%m-%d.log'
log_rotation_age = 1d
log_rotation_size = 100MB
log_min_duration_statement = 2000
log_checkpoints = on
log_connections = on
log_disconnections = on
EOF

cat <<'INITSCRIPT' | docker config create $POSTGRES_INIT_REPLICATOR - >/dev/null 2>&1 || true
#!/bin/bash
set -e
REPLICATOR_PASSWORD=$(cat /run/secrets/postgres-root-password)
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'replicator') THEN
            CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '$REPLICATOR_PASSWORD';
        END IF;
    END
    \$\$;
EOSQL
INITSCRIPT

cat <<EOF | docker config create $PG_HBA_PRIMARY_CONF - >/dev/null 2>&1 || true
local   all             all                                     md5
host    all             all             127.0.0.1/32            md5
host    all             all             ::1/128                 md5
host    replication     replicator      10.0.0.0/8              md5
host    replication     replicator      172.16.0.0/12           md5
host    replication     replicator      192.168.0.0/16          md5
host    replication     replicator      11.0.0.0/8              md5
host    all             all             10.0.0.0/8              md5
host    all             all             172.16.0.0/12           md5
host    all             all             192.168.0.0/16          md5
host    all             all             11.0.0.0/8              md5
EOF

cat <<EOF | docker config create $PG_HBA_STANDBY_CONF - >/dev/null 2>&1 || true
local   all             all                                     md5
host    all             all             127.0.0.1/32            md5
host    all             all             ::1/128                 md5
host    all             all             10.0.0.0/8              md5
host    all             all             172.16.0.0/12           md5
host    all             all             192.168.0.0/16          md5
host    all             all             11.0.0.0/8              md5
EOF

# PgCat configuration - single config for pooling + R/W splitting + load balancing
cat <<EOF | docker config create $PGCAT_TRANSACTION_CONFIG - >/dev/null 2>&1 || true
#
# PgCat Configuration for PostgreSQL HA Cluster
#

[general]
host = "0.0.0.0"
port = 6432

# Prometheus metrics endpoint
enable_prometheus_exporter = true
prometheus_exporter_port = 9930

# Connection settings
connect_timeout = 5000
idle_timeout = 30000
server_lifetime = 86400000

# Health check
healthcheck_timeout = 1000
healthcheck_delay = 30000
shutdown_timeout = 60000
ban_time = 60

# Logging
log_client_connections = true
log_client_disconnections = true

# Workers (adjust based on CPU)
worker_threads = 4

# TCP keepalive
tcp_keepalives_idle = 5
tcp_keepalives_count = 5
tcp_keepalives_interval = 5

# Admin database
admin_username = "pgcat_admin"
admin_password = "${POSTGRES_PASSWORD}"

#
# Pool configuration
#
[pools.postgres]
pool_mode = "transaction"
load_balancing_mode = "random"

# Route to primary by default for writes, query parser handles reads
default_role = "any"

# Enable query parsing for automatic read/write splitting
query_parser_enabled = true
query_parser_read_write_splitting = true

# Include primary in read load balancing
primary_reads_enabled = true

# Prepared statements cache
prepared_statements_cache_size = 500

# Pool-level timeouts
idle_timeout = 40000
connect_timeout = 3000

# User configuration
[pools.postgres.users.0]
username = "postgres"
password = "${POSTGRES_PASSWORD}"
pool_size = 50
min_pool_size = 5
statement_timeout = 0

[pools.postgres.users.1]
username = "replicator"
password = "${POSTGRES_PASSWORD}"
pool_size = 10
min_pool_size = 1
statement_timeout = 0

# Shard 0 (single shard for non-sharded setup)
[pools.postgres.shards.0]
servers = [
    ["postgres-primary", 5432, "primary"],
    ["postgres-standby", 5432, "replica"]
]
database = "postgres"
EOF

cat <<EOF | docker config create $PGCAT_SESSION_CONFIG - >/dev/null 2>&1 || true
#
# PgCat Configuration for PostgreSQL HA Cluster
#

[general]
host = "0.0.0.0"
port = 6432

# Prometheus metrics endpoint
enable_prometheus_exporter = true
prometheus_exporter_port = 9930

# Connection settings
connect_timeout = 5000
idle_timeout = 30000
server_lifetime = 86400000

# Health check
healthcheck_timeout = 1000
healthcheck_delay = 30000
shutdown_timeout = 60000
ban_time = 60

# Logging
log_client_connections = true
log_client_disconnections = true

# Workers (adjust based on CPU)
worker_threads = 4

# TCP keepalive
tcp_keepalives_idle = 5
tcp_keepalives_count = 5
tcp_keepalives_interval = 5

# Admin database
admin_username = "pgcat_admin"
admin_password = "${POSTGRES_PASSWORD}"

#
# Pool configuration
#
[pools.postgres]
pool_mode = "session"
load_balancing_mode = "random"

# Route to primary by default for writes, query parser handles reads
default_role = "any"

# Enable query parsing for automatic read/write splitting
query_parser_enabled = true
query_parser_read_write_splitting = true

# Include primary in read load balancing
primary_reads_enabled = true

# Prepared statements cache
prepared_statements_cache_size = 500

# Pool-level timeouts
idle_timeout = 40000
connect_timeout = 3000

# User configuration
[pools.postgres.users.0]
username = "postgres"
password = "${POSTGRES_PASSWORD}"
pool_size = 50
min_pool_size = 5
statement_timeout = 0

[pools.postgres.users.1]
username = "replicator"
password = "${POSTGRES_PASSWORD}"
pool_size = 10
min_pool_size = 1
statement_timeout = 0

# Shard 0 (single shard for non-sharded setup)
[pools.postgres.shards.0]
servers = [
    ["postgres-primary", 5432, "primary"],
    ["postgres-standby", 5432, "replica"]
]
database = "postgres"
EOF

log "Deploying stack..."
docker stack deploy -c docker-compose.yml "$STACK_NAME" --detach
log "Docker stack '$STACK_NAME' deployed successfully!"
log ""
log "Architecture: App → PgCat (pooling + R/W split) → PostgreSQL"
log ""
log "Connection endpoints:"
log "  Single endpoint (recommended): pgcat:6432 or postgres-ha:6432"
log "  Direct primary (write):        postgres-primary:5432"
log "  Direct standby (read):         postgres-standby:5432"
log ""
log "Query routing (automatic via PgCat query parser):"
log "  - SELECT queries → load balanced to replica"
log "  - INSERT/UPDATE/DELETE → primary"
log ""
log "Prometheus metrics: http://<any-manager>:9930/metrics"
