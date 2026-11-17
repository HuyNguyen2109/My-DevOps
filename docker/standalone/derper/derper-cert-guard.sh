#!/usr/bin/env bash
# Restart derper when Caddy renews the TLS certificate it serves.
#
# derper's manual cert mode loads the certificate once at startup and never
# reloads it (cmd/derper/cert.go). Caddy renews the cert in place, so without
# a restart derper would keep serving the old cert until it expires.
#
# Intended to run from derper-cert-guard.timer.
set -euo pipefail

CONTAINER="talos-cloud-00-derper"
CERT_DIR="/mnt/docker-data/arcane/projects/Derper/certs"

shopt -s nullglob
certs=("$CERT_DIR"/*.crt)
if (( ${#certs[@]} != 1 )); then
    echo "error: expected exactly one .crt in $CERT_DIR, found ${#certs[@]}" >&2
    exit 1
fi
cert=${certs[0]}

cert_mtime=$(stat -c %Y -- "$cert")

started_at=$(docker inspect --format '{{.State.StartedAt}}' "$CONTAINER")
container_start=$(date -d "$started_at" +%s)

if (( cert_mtime > container_start )); then
    echo "certificate renewed after container start; restarting $CONTAINER"
    docker restart "$CONTAINER"
else
    echo "certificate is not newer than container start; no restart needed"
fi
