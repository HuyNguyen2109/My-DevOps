#!/usr/bin/env bash
# Deploys the OpenBao project to talos-cloud-01.
# Usage: deploy_bao.sh <stage|prod>
#   stage - azure seal only, storage = vault-data-stage (copy of live DB)
#   prod  - azure seal disabled + ocikms seal, storage = vault-data (live DB)
# Renders bao-config.hcl from the templates with credentials fetched at runtime
# from the unRAID tower (.env of the old hashicorp-vault Arcane project).
# NEVER commit bao-config.hcl or any *.env (see .gitignore).
set -euo pipefail
MODE="${1:?usage: deploy_bao.sh stage|prod}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TGT="opc@140.245.100.82"; KEY="/root/ssh-keys/oracle"; REM="/docker-volume/arcane/projects/OpenBao"
ENV_SRC="/mnt/user/appdata/arcane/projects/Hashicorp-Vault/.env"
HTTP() { ssh -i /root/ssh-keys/homelab-linux root@192.168.1.40 "$1"; }

# Escape sed replacement metacharacters (& | \) in credential values
esc() { printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'; }

PG_LIVE="$(HTTP "grep -E '^PG_CONNECTION_STRING=' $ENV_SRC | cut -d= -f2-")"
PG_LIVE="${PG_LIVE%%\?*}"   # strip any existing query; template supplies ?sslmode=disable
# The .env password uses backslash escapes that the Go/pgx driver unescapes but libpq
# does NOT (verified: only the backslash-stripped form authenticates via libpq).
PG_LIVE="${PG_LIVE//\\/}"
AZURE_TENANT_ID="$(HTTP "grep -E '^AZURE_TENANT_ID=' $ENV_SRC | cut -d= -f2-")"
AZURE_CLIENT_ID="$(HTTP "grep -E '^AZURE_CLIENT_ID=' $ENV_SRC | cut -d= -f2-")"
AZURE_CLIENT_SECRET="$(HTTP "grep -E '^AZURE_CLIENT_SECRET=' $ENV_SRC | cut -d= -f2-")"
AZURE_VAULT_NAME="$(HTTP "grep -E '^AZURE_VAULT_NAME=' $ENV_SRC | cut -d= -f2-")"

if [ "$MODE" = "stage" ]; then
  SOURCE=bao-config.hcl.stage; TARGET_URL="${PG_LIVE//vault-data/vault-data-stage}"
  KEY_ID=""; CRYPTO_ENDPOINT=""; MANAGEMENT_ENDPOINT=""
else
  SOURCE=bao-config.hcl.prod; TARGET_URL="$PG_LIVE"
  . /tmp/openbao-oci.env
fi

# Guard: the stage DB differs from the live DB only in the suffix swap
[ "$MODE" = "stage" ] && [ "$TARGET_URL" = "$PG_LIVE" ] && { echo "ERROR: stage TARGET_URL == PG_LIVE (no DB swap!)" >&2; exit 1; }

sed \
  -e "s|postgres://USER:PASS@10.99.0.1:5432/vault-data-stage|$(esc "$TARGET_URL")|g" \
  -e "s|postgres://USER:PASS@10.99.0.1:5432/vault-data|$(esc "$TARGET_URL")|g" \
  -e "s|AZURE_TENANT_ID|$(esc "$AZURE_TENANT_ID")|g" \
  -e "s|AZURE_CLIENT_ID|$(esc "$AZURE_CLIENT_ID")|g" \
  -e "s|AZURE_CLIENT_SECRET|$(esc "$AZURE_CLIENT_SECRET")|g" \
  -e "s|AZURE_VAULT_NAME|$(esc "$AZURE_VAULT_NAME")|g" \
  -e "s|KEY_ID_OCID|$(esc "$KEY_ID")|g" \
  -e "s|CRYPTO_ENDPOINT|$(esc "$CRYPTO_ENDPOINT")|g" \
  -e "s|MANAGEMENT_ENDPOINT|$(esc "$MANAGEMENT_ENDPOINT")|g" \
  "$DIR/$SOURCE" > "$DIR/bao-config.hcl"
chmod 600 "$DIR/bao-config.hcl"

echo "== verifying rendered config (masked) =="
sed -E 's#(postgres://[^:]+:)[^@]+@#\1***@#; s#(client_secret *= *")[^"]+(")#\1***\2#; s#(KEY_ID_OCID|CRYPTO_ENDPOINT|MANAGEMENT_ENDPOINT)#__OCI__#g' "$DIR/bao-config.hcl"

echo "== uploading to $TGT:$REM (mode=$MODE) =="
UP="/tmp/bao-update-$(date +%s)"
ssh -i "$KEY" "$TGT" "sudo rm -rf /tmp/bao-update /tmp/bao-update-*; mkdir -p $UP; sudo mkdir -p $REM"
scp -i "$KEY" -r "$DIR/compose.yaml" "$DIR/bao-config.hcl" "$TGT":"$UP/"
ssh -i "$KEY" "$TGT" "sudo cp -r $UP/* $REM/ && cd $REM && sudo docker compose up -d"