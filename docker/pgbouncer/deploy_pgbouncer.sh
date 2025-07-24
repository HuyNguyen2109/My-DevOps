#!/bin/bash
# Define stack name (change this as needed)
STACK_NAME="pgbouncer"
PGBOUNCER_CONFIG_FILE="pgbouncer_ini"
PGBOUNCER_USERLIST_FILE="pgbouncer_userlist"
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
POSTGRES_HOST=$(vault kv get -field=azure-postgresql-host kubernetes/docker-secrets)
POSTGRES_USER=$(vault kv get -field=azure-postgresql-user kubernetes/docker-secrets)
POSTGRESQL_PLAINTEXT_PASSWORD=$(vault kv get -field=azure-postgresql-plaintext-password kubernetes/docker-secrets)
MD5_HASHED_PASSWORD=$(echo -n "$POSTGRESQL_PLAINTEXT_PASSWORD$POSTGRES_USER" | md5sum | awk '{print $1}')
# === Create Docker Config via STDIN ===
echo "Parsing all necessary variables into config..."
docker config rm $PGBOUNCER_CONFIG_FILE
docker config rm $PGBOUNCER_USERLIST_FILE
cat <<EOF | docker config create $PGBOUNCER_CONFIG_FILE -
[databases]
postgres = host=$POSTGRES_HOST port=5432 auth_user=$POSTGRES_USER dbname=postgres
k3s-datastore = host=$POSTGRES_HOST port=5432 auth_user=$POSTGRES_USER dbname=k3s-datastore

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = md5
auth_file = /opt/bitnami/pgbouncer/conf/userlist.txt
pool_mode = transaction

; Connection limits
max_client_conn = 500 
default_pool_size = 10
reserve_pool_size = 20
reserve_pool_timeout = 3.0

; Timeouts
server_login_retry = 5
server_lifetime = 3600
server_idle_timeout = 600
server_connect_timeout = 15
query_timeout = 600

admin_users = $POSTGRES_USER

; TLS settings for client → PgBouncer
client_tls_sslmode = require
client_tls_cert_file = /opt/bitnami/pgbouncer/certs/cloudflare-cert.pem
client_tls_key_file = /opt/bitnami/pgbouncer/certs/cloudflare-key.pem
client_tls_ca_file = /opt/bitnami/pgbouncer/certs/cloudflare-origin-ca.pem

; TLS settings for PgBouncer → Azure PostgreSQL
server_tls_sslmode = verify-full
server_tls_ca_file = /opt/bitnami/pgbouncer/certs/azure-root-ca.pem
EOF
cat <<EOF | docker config create $PGBOUNCER_USERLIST_FILE -
"$POSTGRES_USER" "md5$MD5_HASHED_PASSWORD"
EOF
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME"
echo "✅ Docker stack '$STACK_NAME' deployed successfully!"
