#!/usr/bin/env bash
# Deploys the Caddy reverse proxy project to talos-cloud-01.
# Fallback path if the Arcane API is unavailable (see migration plan Task 5).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TGT="opc@140.245.100.82"; KEY="/root/ssh-keys/oracle"; REM="/docker-volume/arcane/projects/Proxy"

echo "== uploading proxy project =="
UP="/tmp/proxy-update-$(date +%s)"
ssh -i "$KEY" "$TGT" "sudo rm -rf /tmp/proxy-update /tmp/proxy-update-*; mkdir -p $UP; sudo mkdir -p $REM"
scp -i "$KEY" -r "$DIR/compose.yaml" "$DIR/Caddyfile" "$TGT":"$UP/"
ssh -i "$KEY" "$TGT" "sudo cp -r $UP/* $REM/ && cd $REM && sudo docker compose up -d"

echo "== containers =="
ssh -i "$KEY" "$TGT" "cd $REM && sudo docker compose ps"