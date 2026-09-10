# Vault → OpenBao Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the unRAID HashiCorp Vault with OpenBao 2.6.2 on talos-cloud-01 (same Postgres storage, OCI KMS seal, caddy fronting `vault.mcb-homelab.com`) with staged validation, parity checks, and an AKV purge after soak.

**Architecture:** OpenBao (Arcane "OpenBao", unpublished) + Caddy (Arcane "Proxy", 80/443) on talos-cloud-01, both on the existing `proxy` docker network; OpenBao reads the SAME PostgreSQL (`vault-data` @ `10.99.0.1:5432`, tables `vault_kv_store`/`vault_ha_locks`). Seal migrates Azure Key Vault → OCI KMS (instance principal) via OpenBao's seal-migration (`azurekeyvault` + `disabled="true"`, `ocikms` new; `bao operator unseal -migrate` with the old recovery keys). Stage phase validates on a DB copy; cutover is a short downtime window; old Vault stays untouched until checks pass; AKV purged after 24-48h soak.

**Tech Stack:** OpenBao 2.6.2 (`ghcr.io/openbao/openbao:2.6.2`), Caddy 2.x, OCI KMS + Dynamic Group + policy (`oci` CLI 3.90.3), Postgres/pgbouncer (`10.99.0.1`), Arcane API (projects on talos-cloud-01), `bao`/`vault` CLIs, shell + git (branch `develop`).

## Global Constraints

- Do NOT touch the unRAID Vault container until Task 7; it stays running until all stage checks pass.
- Storage tables MUST remain `vault_kv_store` / `vault_ha_locks` (set `table`/`ha_table` explicitly — never let OpenBao use `openbao_*` defaults against the live DB).
- PG/azure credentials are NEVER committed; fetched at deploy time from the tower `.env` (`/mnt/user/appdata/arcane/projects/Hashicorp-Vault/.env`) and rendered by `deploy_bao.sh`.
- Human gates (STOP and hand off, do not proceed):
  - **G3**: entering the 3 recovery shares (user runs `bao operator unseal -migrate` themselves)
  - **G4**: Cloudflare DNS/TLS changes (grey-cloud → A record → re-proxy, SSL Full(strict))
  - **G5**: `az login` + final AKV purge confirmation
- All commits on `develop`; never `git add -A` (unrelated working-tree changes exist).
- Version pins: OpenBao `2.6.2` (ocikms stays built-in), Caddy `caddy:2.9.x` or latest 2.x tag.

---

### Task 0: Environment & Prerequisites Check

**Files:** none (verification only)

- [ ] **Step 1: Verify host health**

```bash
ping -c2 -W2 14.225.220.145 && ssh -i /root/ssh-keys/oracle -o ConnectTimeout=10 -o BatchMode=yes root@14.225.220.145 'docker ps --format "{{.Names}}" | grep -E "pgbouncer|postgres"'
ssh -i /root/ssh-keys/oracle -o ConnectTimeout=8 -o BatchMode=yes opc@140.245.100.82 'docker network ls --format "{{.Name}}" | grep -E "^proxy$"'
ssh -i /root/ssh-keys/homelab-linux root@192.168.1.40 'docker ps --format "{{.Names}} {{.Status}}" | grep hashicorp'
```
Expected: pgbouncer + postgres containers on talos-cloud-00; `proxy` network on talos-cloud-01; `hashicorp-vault Up`.

- [ ] **Step 2: Verify live-Vault read access + CLIs**

```bash
vault status | grep -E "Sealed|Version"
command -v oci bao az
```
Expected: `Sealed false`; `oci`, `az` present; if `bao` missing, install:
```bash
curl -fsSL -o /tmp/bao.zip https://github.com/openbao/openbao/releases/download/v2.6.2/bao_2.6.2_linux_amd64.zip
unzip -o -q /tmp/bao.zip -d /usr/local/bin/ && bao version
```

- [ ] **Step 3: Record pre-cutover baseline (for parity later)**

```bash
vault secrets list -format=json > /tmp/pre-migration-secrets.json
vault auth list -format=json      > /tmp/pre-migration-auth.json
vault policy list                 > /tmp/pre-migration-policies.txt
vault kv list -format=json kubernetes/ | head -50
```
Expected: files created; kv path lists non-empty (e.g. `docker-secrets`, `openbao…` etc. as present).

---

### Task 1: Provision OCI KMS (vault, key, dynamic group, policy)

**Files:** none (OCI resources; outputs recorded in Task-1 commit note)

**Interfaces:**
- Produces: `KEY_ID_OCID`, `CRYPTO_ENDPOINT`, `MANAGEMENT_ENDPOINT`, `INSTANCE_OCID` used by Tasks 3/6 configs and `deploy_bao.sh`.

- [ ] **Step 1: Create the KMS vault (root compartment = tenancy)**

```bash
TEN=ocid1.tenancy.oc1..aaaaaaaafr5xg6lbfol6oznns4oyhlxpj4go55p6aslnpupqlq22ub7jexua
oci kms management vault create --compartment-id "$TEN" --display-name homelab-kms --vault-type DEFAULT --wait-for-state ACTIVE
```
Expected: vault OCID in output. If a vault already exists (list first: `oci kms management vault list -c "$TEN" --all`), reuse it.

- [ ] **Step 2: Create the AES-256 key + capture endpoints**

```bash
VAULT_ID=<vault-ocid>
oci kms management key create --compartment-id "$TEN" --display-name openbao-seal --vault-id "$VAULT_ID" --key-shape-algorithm-id AES --key-shape-length 32 --wait-for-state ENABLED
oci kms management vault get --vault-id "$VAULT_ID"
```
Expected: key OCID; vault shows `cryptoEndpoint` and `managementEndpoint` with `…-crypto.kms.ap-singapore-1.oraclecloud.com` / `…-management.kms.ap-singapore-1.oraclecloud.com`.

- [ ] **Step 3: Instance OCID + Dynamic Group + policy**

```bash
oci compute instance list -c "$TEN" --all | python3 -c "import json,sys; [print(i['id'], i['display-name']) for i in json.load(sys.stdin)['data']]"
```
Identify talos-cloud-01's instance OCID, then (console + CLI where possible):
- Create Dynamic Group `talos-cloud-01-openbao` with rule `instance.id = '<INSTANCE_OCID>'`.
- Create policy (root) `openbao-kms-policy`:
`allow dynamic-group talos-cloud-01-openbao to use keys in compartment <root-compartment-name>`
(Dynamic Group + policy creation are console/API actions; use `oci iam dynamic-group create` and `oci iam policy create` with `--statements` if the API key user has IAM rights; otherwise record as a human-gate note with exact values).

- [ ] **Step 4: Persist the references for later tasks**

Write OCIDs + endpoints into a local scratch file `/tmp/openbao-oci.env` (chmod 600; never commit):
```bash
cat > /tmp/openbao-oci.env <<'EOF'
KEY_ID=<key-ocid>
CRYPTO_ENDPOINT=<crypto-endpoint>
MANAGEMENT_ENDPOINT=<management-endpoint>
INSTANCE_OCID=<instance-ocid>
EOF
chmod 600 /tmp/openbao-oci.env
```

---

### Task 2: Stage Database Copy (`vault-data-stage`)

**Files:** none (DB ops on talos-cloud-00)

**Interfaces:**
- Consumes: PG credentials from tower `.env` (`PG_CONNECTION_STRING`).
- Produces: `vault-data-stage` DB (same tables+rows as live, point-in-time) and a **pre-cutover `pg_dump` backup** kept until soak completes.

- [ ] **Step 1: Fetch PG conn string (masked in logs) and test connectivity**

```bash
ssh -i /root/ssh-keys/homelab-linux root@192.168.1.40 'grep PG_CONNECTION_STRING /mnt/user/appdata/arcane/projects/Hashicorp-Vault/.env' > /tmp/pg.env
# NOTE: no .env content in tool output; use only into scripts
ssh -i /root/ssh-keys/oracle root@14.225.220.145 'docker ps --format "{{.Names}}" | grep -iE "pgbouncer|postgres"'
```
Expected: connection string available; identify the pgbouncer container (db `vault-data` in its pool).

- [ ] **Step 2: Create consistent dump + stage DB**

From the controller, using `pg_dump` against pgbouncer (`10.99.0.1:5432`):
```bash
export $(grep PG_CONNECTION_STRING /tmp/pg.env | sed 's/^export //')
PG_URL="${PG_CONNECTION_STRING/vault-data/vault-data}"   # unchanged; live db
pg_dump "$PG_URL" -Fc -f /tmp/vault-data.dump -Z 9 -n public
# create stage DB (via postgres18 directly or pgbouncer with the new db registered)
ssh -i /root/ssh-keys/oracle root@14.225.220.145 'docker exec -i <postgres18-container> psql -U <pguser> -c "CREATE DATABASE vault-data-stage;"'
# restore into stage db
pg_restore -d "${PG_CONNECTION_STRING/vault-data/vault-data-stage}" --no-owner /tmp/vault-data.dump
```
Expected: dump size >0; `vault-data-stage` contains `vault_kv_store` with same row count as live (verify: `select count(*) from vault_kv_store;` on both).
Note: if pgbouncer rejects the stage db, register `vault-data-stage` in the pgbouncer config (`pgbouncer.ini` `[databases]`) + reload — or restore directly against postgres18 and point the stage config at postgres18 (same host).
If `pg_dump`/`pg_restore` are absent on the controller, run them inside the postgres18 container via `docker exec`.

- [ ] **Step 3: Keep the dump as the rollback/soak artifact**

```bash
ssh -i /root/ssh-keys/oracle opc@140.245.100.82 'sudo mkdir -p /docker-volume/backup-vault && cat > /tmp/x' ; scp -i /root/ssh-keys/oracle /tmp/vault-data.dump opc@140.245.100.82:/tmp/ && ssh -i /root/ssh-keys/oracle opc@140.245.100.82 'sudo mv /tmp/vault-data.dump /docker-volume/backup-vault/vault-data-pre-cutover.dump && sudo ls -la /docker-volume/backup-vault/'
```
Expected: file `vault-data-pre-cutover.dump` present (this and one external copy are kept until AKV purge).

---

### Task 3: Arcane "OpenBao" Project (stage) + start + unseal

**Files:**
- Create: `docker/talos-cloud-01/openbao/compose.yaml`
- Create: `docker/talos-cloud-01/openbao/bao-config.hcl.stage`
- Create: `docker/talos-cloud-01/openbao/bao-config.hcl.prod`
- Create: `docker/talos-cloud-01/openbao/deploy_bao.sh`
- Create: `docker/talos-cloud-01/openbao/.gitignore`

**Interfaces:**
- Consumes: `/tmp/openbao-oci.env` (Task 1), `/tmp/pg.env` (Task 2).
- Produces: live OpenBao container (stage config) reachable on the `proxy` network as `openbao:8200`; deploy script reused at cutover.

- [ ] **Step 1: Create project files**

`compose.yaml`:
```yaml
services:
  openbao:
    image: ghcr.io/openbao/openbao:2.6.2
    container_name: openbao
    hostname: openbao
    cap_add: [IPC_LOCK]
    networks: [proxy]
    volumes:
      - ./bao-config.hcl:/etc/bao/bao-config.hcl:ro
    command: ["server", "-config=/etc/bao/bao-config.hcl"]
networks:
  proxy:
    external: true
```
`.gitignore`:
```
bao-config.hcl
*.env
```
`bao-config.hcl.stage` (rendered live by `deploy_bao.sh`; azure-only, stage DB):
```hcl
ui = true
storage "postgresql" {
  connection_url = "postgres://USER:PASS@10.99.0.1:5432/vault-data-stage?sslmode=disable"
  table           = "vault_kv_store"
  ha_table        = "vault_ha_locks"
}
listener "tcp" {
  address = "0.0.0.0:8200"
  tls_disable = 1
}
seal "azurekeyvault" {
  tenant_id     = "AZURE_TENANT_ID"
  client_id     = "AZURE_CLIENT_ID"
  client_secret = "AZURE_CLIENT_SECRET"
  vault_name    = "AZURE_VAULT_NAME"
  key_name      = "unseal-key-hcl"
}
```
`bao-config.hcl.prod` (cutover variant; azure disabled + ocikms):
```hcl
ui = true
storage "postgresql" {
  connection_url = "postgres://USER:PASS@10.99.0.1:5432/vault-data?sslmode=disable"
  table           = "vault_kv_store"
  ha_table        = "vault_ha_locks"
}
listener "tcp" {
  address = "0.0.0.0:8200"
  tls_disable = 1
}
seal "azurekeyvault" {
  tenant_id     = "AZURE_TENANT_ID"
  client_id     = "AZURE_CLIENT_ID"
  client_secret = "AZURE_CLIENT_SECRET"
  vault_name    = "AZURE_VAULT_NAME"
  key_name      = "unseal-key-hcl"
  disabled = "true"
}
seal "ocikms" {
  key_id              = "KEY_ID_OCID"
  crypto_endpoint     = "CRYPTO_ENDPOINT"
  management_endpoint = "MANAGEMENT_ENDPOINT"
}
```
`deploy_bao.sh` (renders config from env, uploads via Arcane or SSH, starts container):
```bash
#!/usr/bin/env bash
# Usage: deploy_bao.sh <stage|prod>
set -euo pipefail
MODE="${1:?usage: deploy_bao.sh stage|prod}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TGT="opc@140.245.100.82"; KEY="/root/ssh-keys/oracle"; REM="/docker-volume/arcane/projects/OpenBao"
ENV_SRC="/mnt/user/appdata/arcane/projects/Hashicorp-Vault/.env"
HTTP() { ssh -i /root/ssh-keys/homelab-linux root@192.168.1.40 "$1"; }

PG_LIVE="$(HTTP "grep -E '^PG_CONNECTION_STRING=' $ENV_SRC | cut -d= -f2-")"
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

sed \
  -e "s|postgres://USER:PASS@10.99.0.1:5432/vault-data-stage|${TARGET_URL}|g" \
  -e "s|postgres://USER:PASS@10.99.0.1:5432/vault-data|${TARGET_URL}|g" \
  -e "s|AZURE_TENANT_ID|${AZURE_TENANT_ID}|g" \
  -e "s|AZURE_CLIENT_ID|${AZURE_CLIENT_ID}|g" \
  -e "s|AZURE_CLIENT_SECRET|${AZURE_CLIENT_SECRET}|g" \
  -e "s|AZURE_VAULT_NAME|${AZURE_VAULT_NAME}|g" \
  -e "s|KEY_ID_OCID|${KEY_ID:-}|g" \
  -e "s|CRYPTO_ENDPOINT|${CRYPTO_ENDPOINT:-}|g" \
  -e "s|MANAGEMENT_ENDPOINT|${MANAGEMENT_ENDPOINT:-}|g" \
  "$DIR/$SOURCE" > "$DIR/bao-config.hcl"
chmod 600 "$DIR/bao-config.hcl"
ssh -i "$KEY" "$TGT" "sudo mkdir -p $REM"
scp -i "$KEY" -r "$DIR/compose.yaml" "$DIR/bao-config.hcl" "$TGT":/tmp/bao-update/
ssh -i "$KEY" "$TGT" "sudo cp -r /tmp/bao-update/* $REM/ && cd $REM && sudo docker compose up -d"
```
(Actual credentials come from the tower `.env` at runtime; the placeholder URL in the templates is replaced wholesale.)

- [ ] **Step 2: Create the Arcane project "OpenBao"** (talos-cloud-01 env `1b592877-91b9-4d7e-8e45-8712ba91d25d`) with the compose + current rendered config files (multipart manifest flow used previously), then start:
```bash
./docker/talos-cloud-01/openbao/deploy_bao.sh stage
```
Expected: `openbao` container Up on talos-cloud-01; no published ports; `ss -tlnp` shows nothing new on host ports.

- [ ] **Step 3: Unseal/status checks (auto-unseal via Azure)**

```bash
ssh -i /root/ssh-keys/oracle opc@140.245.100.82 'sudo docker logs openbao --tail 20 2>&1 | grep -iE "error|unseal|seal" | tail -5'
ssh -i /root/ssh-keys/oracle opc@140.245.100.82 'sudo docker exec -e BAO_ADDR=http://127.0.0.1:8200 openbao bao status' 2>&1 | grep -E "Seal Type|Initialized|Sealed|Recovery Seal"
```
Expected: `Seal Type azurekeyvault`, `Initialized true`, `Sealed false` (auto-unsealed via Azure — proves OpenBao reads the copied storage with the existing seal).

- [ ] **Step 4: Commit**

```bash
git add docker/talos-cloud-01/openbao
git commit -m "feat(openbao): stage project files for vault->openbao migration (azure seal, postgres vault-data tables)"
```

---

### Task 4: Parity Checks (stage vs live)

**Interfaces:**
- Consumes: Task 0 baseline files; Task 3 stage instance.
- Produces: evidence that OpenBao reads the storage identically; any mismatch ABORTS the migration.

- [ ] **Step 1: Compare mounts & auth**

```bash
ssh -i /root/ssh-keys/oracle opc@140.245.100.82 'sudo docker exec -e BAO_ADDR=http://127.0.0.1:8200 openbao bao secrets list -format=json' > /tmp/stage-secrets.json
ssh -i /root/ssh-keys/oracle opc@140.245.100.82 'sudo docker exec -e BAO_ADDR=http://127.0.0.1:8200 openbao bao auth list -format=json'  > /tmp/stage-auth.json
python3 - <<'PY'
import json
live=json.load(open('/tmp/pre-migration-secrets.json')); stage=json.load(open('/tmp/stage-secrets.json'))
lm={k: v['type'] for k,v in live.items() if k not in ('secret/','identity/','cubbyhole/','sys/')}
sm={k: v['type'] for k,v in stage.items() if k not in ('secret/','identity/','cubbyhole/','sys/')}
print('mounts equal:', lm==sm)
if lm!=sm: print('only-live:', set(lm)-set(sm), 'only-stage:', set(sm)-set(lm))
la=json.load(open('/tmp/pre-migration-auth.json')); sa=json.load(open('/tmp/stage-auth.json'))
print('auth equal:', {k:v['type'] for k,v in la.items()}=={k:v['type'] for k,v in sa.items()})
PY
```
Expected: `mounts equal: True`, `auth equal: True`.

- [ ] **Step 2: Compare representative secrets**

```bash
for p in kubernetes/docker-secrets kubernetes/terraform; do
  live=$(vault kv get -format=json "$p" | sha256sum | cut -d' ' -f1)
  stage=$(ssh -i /root/ssh-keys/oracle opc@140.245.100.82 "sudo docker exec -e BAO_ADDR=http://127.0.0.1:8200 openbao bao kv get -format=json $p" 2>/dev/null | sha256sum | cut -d' ' -f1)
  echo "$p: $([ "$live" = "$stage" ] && echo MATCH || echo MISMATCH)"
done
```
(Adjust the path list to the actual mount paths from Task 0 step 3 — include at least `kubernetes/*`, plus any non-kubernetes mounts present.)

- [ ] **Step 3: Compare policies + identity sanity**

```bash
diff <(vault policy list | sort) <(ssh -i /root/ssh-keys/oracle opc@140.245.100.82 'sudo docker exec -e BAO_ADDR=http://127.0.0.1:8200 openbao bao policy list' | sort) && echo POLICIES-MATCH
```
Expected: `POLICIES-MATCH`. Any mismatch ⇒ STOP, report, do not proceed.

---

### Task 5: Arcane "Proxy" Project (caddy) + routing test

**Files:**
- Create: `docker/talos-cloud-01/proxy/compose.yaml`
- Create: `docker/talos-cloud-01/proxy/Caddyfile`
- Create: `docker/talos-cloud-01/proxy/deploy_proxy.sh`

**Interfaces:**
- Consumes: Talos-cloud-01 `proxy` network; OpenBao service name `openbao`.
- Produces: public-facing `vault.mcb-homelab.com` reverse proxy (both plain and TLS modes supported).

- [ ] **Step 1: Create files**

`compose.yaml`:
```yaml
services:
  caddy:
    image: caddy:2.9.2
    container_name: caddy-proxy
    restart: unless-stopped
    networks: [proxy]
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
volumes:
  caddy-data:
  caddy-config:
networks:
  proxy:
    external: true
```
`Caddyfile`:
```
vault.mcb-homelab.com {
    reverse_proxy openbao:8200
}
```
`deploy_proxy.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TGT="opc@140.245.100.82"; KEY="/root/ssh-keys/oracle"; REM="/docker-volume/arcane/projects/Proxy"
ssh -i "$KEY" "$TGT" "sudo mkdir -p $REM"
scp -i "$KEY" -r "$DIR/compose.yaml" "$DIR/Caddyfile" "$TGT":/tmp/proxy-update/
ssh -i "$KEY" "$TGT" "sudo cp -r /tmp/proxy-update/* $REM/ && cd $REM && sudo docker compose up -d"
```

- [ ] **Step 2: Deploy via Arcane project "Proxy"** (or the script fallback), then route test from talos-cloud-01 itself:
```bash
ssh -i /root/ssh-keys/oracle opc@140.245.100.82 'curl -sk -H "Host: vault.mcb-homelab.com" https://localhost/api/v1/sys/health --resolve vault.mcb-homelab.com:443:127.0.0.1 -o /dev/null -w "HTTP:%{http_code}\n"'
```
Expected: local request through caddy reaches OpenBao → 200 (note: caddy serves a self-signed/staging cert during pre-DNS window; HTTP code is what matters; also test `http://vault.mcb-homelab.com` over plain 80 with the Host header).
Test the L7 path: `curl -sk -H "Host: vault.mcb-homelab.com" http://127.0.0.1/v1/sys/health`.

- [ ] **Step 3: Commit**

```bash
git add docker/talos-cloud-01/proxy
git commit -m "feat(openbao): caddy proxy project for vault.mcb-homelab.com -> openbao"
```

---

### Task 6: Cutover Package (files only — NO destructive actions)

**Files:**
- Create: `docs/runbooks/vault-openbao-migration.md` (cutover + unseal -migrate + rollback runbook)
- Modify: `docker/talos-cloud-01/openbao/deploy_bao.sh` (already supports `prod` mode — verify)

**Interfaces:**
- Consumes: all prior tasks.
- Produces: executed-verbatim runbook for the human-gated steps.

- [ ] **Step 1: Write the runbook**

`docs/runbooks/vault-openbao-migration.md` — contains, verbatim:
1. Pre-flight checklist (stage parity GREEN, dump exists, talos-cloud-00 healthy).
2. `ssh -i /root/ssh-keys/homelab-linux root@192.168.1.40 'docker stop hashicorp-vault'`
3. CF console: grey-cloud `vault.mcb-homelab.com`; A record → talos-cloud-01 public IP; wait for propagation (`dig +short vault.mcb-homelab.com` shows A; not 2606:4700).
4. `./docker/talos-cloud-01/openbao/deploy_bao.sh prod`
5. `bao status` — expect sealed.
6. **G3**: `bao operator unseal -migrate` — enter 3 recovery shares; then `bao status` → `Seal Type ociKms`, `Sealed false`.
7. Verify `bao kv get kubernetes/docker-secrets` + `/v1/sys/health`.
8. CF console: re-enable proxy; SSL Full(strict).
9. Rollback section: restart unRAID Vault (`docker start hashicorp-vault`); restore dump if seal migration completed (`pg_restore` into `vault-data` after clearing tables); CF back to old origin.

- [ ] **Step 2: Commit**

```bash
git add docs/runbooks/vault-openbao-migration.md
git commit -m "docs(runbook): vault->openbao cutover, sealed unseal -migrate, rollback"
```

---

### Task 7: CUTOVER (HUMAN-GATED)

**Gate G3 is a hard stop: the recovery shares are entered by the user only.**

- [ ] **Step 1: Execute through the gate**

```bash
ssh -i /root/ssh-keys/homelab-linux root@192.168.1.40 'docker stop hashicorp-vault'
# Cloudflare grey-cloud + A record (G4, user console) — verify:
dig +short vault.mcb-homelab.com | grep -v '^2606:4700' | head -1   # must show a public A (talos-cloud-01)
./docker/talos-cloud-01/openbao/deploy_bao.sh prod
BAO_ADDR=https://vault.mcb-homelab.com bao status | grep -E "Seal Type|Sealed"
```
Expected after deploy: `Seal Type azurekeyvault` (still) and `Sealed true` (needs migration unseal).

- [ ] **Step 2: STOP — hand over G3 to the user**

The user runs (exact text provided to them):
```bash
BAO_ADDR=https://vault.mcb-homelab.com bao operator unseal -migrate    # then enter 3 recovery shares when prompted
BAO_ADDR=https://vault.mcb-homelab.com bao status
```
Expected: `Seal Type ociKms`, `Sealed false`. **Do not proceed past this point in this dispatch.** Report completion of all pre-gate steps and the exact remaining commands.

---

### Task 8: Post-Cutover Verification (second dispatch, after G3 done)

**Files:** none

- [ ] **Step 1: End-to-end checks**

```bash
vault status 2>/dev/null | head -6   # via VAULT_ADDR=https://vault.mcb-homelab.com
bao kv get -format=json kubernetes/docker-secrets | sha256sum
diff <(vault secrets list -format=json | python3 -c "import json,sys; print(sorted(json.load(sys.stdin).keys()))") <(bao secrets list -format=json | python3 -c "import json,sys; print(sorted(json.load(sys.stdin).keys()))") | head
```
- [ ] **Step 2: Client probes** — ESO ClusterSecretStore re-sync (k8s), Terraform provider (`terraform providers` / `terraform init -reconfigure` dry), one deploy script (`deploy_observability.sh` reads `kubernetes/docker-secrets`) — all must succeed against the new endpoint.
- [ ] **Step 3: CF re-proxy + SSL mode Full(strict)** (G4, user console) — confirm `curl -skI https://vault.mcb-homelab.com` HTTP 200 via Cloudflare IPs.

---

### Task 9: Finalize (second dispatch)

**Files:**
- Modify: `terraform/proxmox-provision-ubuntu-k8s/main.tf` (`vault.mcb-svc.work` → `https://vault.mcb-homelab.com`)
- Modify: `AGENTS.md` (Secrets Architecture: Vault → OpenBao, endpoint, seal)
- Modify: repo scripts + controller env (`VAULT_ADDR`/`BAO_ADDR`), runbooks README table
- Delete: stage DB `vault-data-stage`

- [ ] **Step 1: Repoint clients & docs; commit**
- [ ] **Step 2: Remove azure seal block from `bao-config.hcl.prod` and restart clean; confirm `bao status` shows only ocikms and auto-unseal after restart**
- [ ] **Step 3: Drop `vault-data-stage`; confirm live count of `vault_kv_store` unchanged**
- [ ] **Step 4: Final verification sweep (parity diff, client probes) + commit docs updates**

---

### Task 10: Soak & Azure Decommission (later, after 24-48h)

- [ ] **Step 1: Soak criteria**: OpenBao up ≥24-48h, ≥1 clean restart + auto-unseal via OCI KMS (log evidence `bao status` after restart shows `Seal Type ociKms`, no azure errors).
- [ ] **Step 2 (G5)**: `az login` (user); retrieve AKV names (`az keyvault list`), `az keyvault delete --name … --resource-group …`, then verify + `az keyvault purge --name … --resource-group …`.
- [ ] **Step 3**: Post-purge note in AGENTS.md; old unRAID Vault now permanently sealed (frozen backup); optionally stop/remove the unRAID container (user decision, not automatic).

---

## Human Gates Summary

| Gate | Who | Trigger |
|---|---|---|
| G1 | user | confirmed recovery shares held (done during design) |
| G2 | user | Cloudflare grey-cloud + A record before cutover |
| G3 | user | run `bao operator unseal -migrate` with 3 shares (Task 7 stop-point) |
| G4 | user | CF re-proxy + SSL Full(strict) after cutover |
| G5 | user | `az login` + confirm AKV purge after soak |
| G6 | user | (optional) stop/remove frozen unRAID Vault container |