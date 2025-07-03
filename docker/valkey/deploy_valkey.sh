#!/bin/bash
# Define stack name (change this as needed)
STACK_NAME="valkey"
VALKEY_CONFIG="valkey-config"
# === Remove existing Docker services if it exists ===
docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true
# === Create Docker Config via STDIN ===
echo "Parsing all necessary variables into config..."
docker config rm $VALKEY_CONFIG >/dev/null 2>&1 || true
cat <<EOF | docker config create $VALKEY_CONFIG -
# valkey.conf - minimal config for production-like use

bind 0.0.0.0
protected-mode no

port 6379
daemonize no
supervised no

# Persistence
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec

# Optional: snapshotting (RDB)
save 900 1
save 300 10
save 60 10000

dir /data

# Memory limit
maxmemory 1500mb
maxmemory-policy allkeys-lru

# Logging
logfile ""
loglevel notice

EOF
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME"
echo "✅ Docker stack '$STACK_NAME' deployed successfully!"
