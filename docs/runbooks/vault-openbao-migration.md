# Runbook: Vault → OpenBao Migration (Cutover, Seal Migration, Rollback)

**Date:** 2026-09-10
**Branch:** develop
**Scope:** Replace unRAID HashiCorp Vault (`http://unraid.internal:9200`, azurekeyvault seal)
with OpenBao 2.6.2 on talos-cloud-01 (OCI KMS seal) fronted by Caddy
(`https://vault.mcb-homelab.com`). Same PostgreSQL storage (`vault-data`
@ `10.99.0.1:5432`, tables `vault_kv_store` / `vault_ha_locks`).

> **Human gates:** G3 (recovery shares — user only), G4 (Cloudflare console — user only),
> G5 (`az login` + AKV purge — user only, after soak).

---

## 0. Pre-flight checklist (ALL must be true before cutover)

- [ ] Stage parity GREEN: `mounts equal: True`, `auth equal: True`, `POLICIES-MATCH`
      (Task 4 evidence).
- [ ] Pre-cutover dump exists on talos-cloud-01: `/docker-volume/backup-vault/vault-data-pre-cutover.dump`
      (size > 0).
- [ ] talos-cloud-00 healthy: `docker ps` shows `pgbouncer` + `postgres18`; `10.99.0.1:5432`
      reachable from talos-cloud-01.
- [ ] Old Vault healthy: `docker ps` on unRAID shows `hashicorp-vault Up`;
      `vault status` shows `Sealed false`.
- [ ] `/tmp/openbao-oci.env` exists on the controller (KEY_ID, CRYPTO_ENDPOINT,
      MANAGEMENT_ENDPOINT, INSTANCE_OCID) — consumed by `deploy_bao.sh prod`.
- [ ] `bao` CLI installed on the controller (v2.6.2).
- [ ] User holds the 3 recovery shares (threshold of 5).

---

## 1. Stop the old Vault (downtime starts ≈10–15 min)

```bash
ssh -i /root/ssh-keys/homelab-linux root@192.168.1.40 'docker stop hashicorp-vault'
```

The old container is NOT removed. Its PostgreSQL data stays untouched until
`unseal -migrate`; a snapshot dump exists for rollback.

---

## 2. Cloudflare: grey-cloud + A record (G4 — USER, console)

1. Cloudflare console → `vault.mcb-homelab.com` → **grey-cloud** (DNS only) the record.
2. Set/create an **A record** → talos-cloud-01 public IP (`140.245.100.82`).
3. Wait for propagation:

```bash
dig +short vault.mcb-homelab.com | grep -v '^2606:4700' | head -1
# must print a public A (140.245.100.82), NOT a 2606:4700 (Cloudflare) address
```

---

## 3. Deploy the prod OpenBao config

```bash
./docker/talos-cloud-01/openbao/deploy_bao.sh prod
# renders bao-config.hcl: azure seal disabled="true" + ocikms, storage = vault-data
# uploads to talos-cloud-01:/docker-volume/arcane/projects/OpenBao and `compose up -d`
```

Verify the container and the expected sealed state:

```bash
ssh -i /root/ssh-keys/oracle opc@140.245.100.82 'sudo docker ps --format "{{.Names}} {{.Status}}" | grep openbao'
BAO_ADDR=https://vault.mcb-homelab.com bao status | grep -E "Seal Type|Sealed|Initialized"
```

**Expected before G3:** `Seal Type azurekeyvault`, `Initialized true`, **`Sealed true`**
(sealed — it needs the seal migration).

> **Operator notes (learned during stage):**
> 1. After a prod deploy, re-upload the rendered `bao-config.hcl` to the Arcane
>    workspace of project `openbao` (PUT `/environments/<env>/projects/<id>/workspace`,
>    `fileChanges: [{"operation":"create_file","relativePath":"bao-config.hcl","uploadIndex":0}]`
>    + the file part), otherwise a future dashboard redeploy would start OpenBao from the
>    stale stage config. `compose.yaml` must NOT be sent through the workspace (protected;
>    it lives in the project's `composeContent`).
> 2. `chmod 600 /docker-volume/arcane/projects/OpenBao/bao-config.hcl` after deploy —
>    Arcane writes workspace files as 0644 and the file contains PG + Azure credentials.
> 3. OpenBao auto-creates a `control-group` policy on first start (built-in CE behavior)
>    and may log a transient `agent-registry` mount error; both are cosmetic — mounts,
>    auth, secret values and policy contents match the old Vault.

---

## 4. G3 — SEAL MIGRATION (USER — recovery shares, do NOT skip)

> **The user must run these commands. Recovery shares are never shown to or entered by agents.**

```bash
BAO_ADDR=https://vault.mcb-homelab.com bao operator unseal -migrate
# then enter the 3 recovery shares when prompted (user only)
```

Then verify:

```bash
BAO_ADDR=https://vault.mcb-homelab.com bao status
```

**Expected:** `Seal Type ociKms`, `Sealed false`, `Initialized true`.
The master key has been re-wrapped from Azure Key Vault to OCI KMS.

---

## 5. Post-migration verification

```bash
# Secret readability through the new endpoint
BAO_ADDR=https://vault.mcb-homelab.com bao kv get kubernetes/docker-secrets

# Health endpoint (init=1, sealed=0, active=1 -> 200)
curl -sk https://vault.mcb-homelab.com/v1/sys/health -o /dev/null -w "HTTP:%{http_code}\n"

# Parity sweep (mounts + auth + policies vs the Task 0 baseline)
BAO_ADDR=https://vault.mcb-homelab.com bao secrets list -format=json  > /tmp/cutover-secrets.json
BAO_ADDR=https://vault.mcb-homelab.com bao auth list -format=json    > /tmp/cutover-auth.json
python3 - <<'PY'
import json
live=json.load(open('/tmp/pre-migration-secrets.json')); now=json.load(open('/tmp/cutover-secrets.json'))
lm={k: v['type'] for k,v in live.items() if k not in ('secret/','identity/','cubbyhole/','sys/')}
nm={k: v['type'] for k,v in now.items() if k not in ('secret/','identity/','cubbyhole/','sys/')}
print('mounts equal:', lm==nm)
PY
```

If any check fails → **rollback** (section 7).

---

## 6. Cloudflare: re-enable proxy + SSL Full(strict) (G4 — USER, console)

1. Cloudflare console → `vault.mcb-homelab.com` → re-enable the orange **proxy** cloud.
2. TLS/SSL mode → **Full (strict)** (origin serves a valid Let's Encrypt cert from Caddy).
3. Verify through Cloudflare:

```bash
dig +short vault.mcb-homelab.com          # should show 2606:4700 (Cloudflare) again
curl -skI https://vault.mcb-homelab.com | head -1   # HTTP/2 200
```

---

## 7. Rollback (only if cutover checks fail, or after soak as decommission note)

### 7a. Restart the old Vault (any time before `unseal -migrate` completes are final)

```bash
ssh -i /root/ssh-keys/homelab-linux root@192.168.1.40 'docker start hashicorp-vault'
vault status   # VAULT_ADDR=http://unraid.internal:9200 -> Sealed false
```

Stop/remove the OpenBao + Caddy projects on talos-cloud-01:

```bash
ssh -i /root/ssh-keys/oracle opc@140.245.100.82 'cd /docker-volume/arcane/projects/OpenBao && sudo docker compose down'
ssh -i /root/ssh-keys/oracle opc@140.245.100.82 'cd /docker-volume/arcane/projects/Proxy && sudo docker compose down'
```

Point Cloudflare back to the old origin (unRAID) and re-enable proxy (G4, user).

### 7b. If the seal migration already re-wrapped the master key

Restore the pre-cutover dump into `vault-data` (requires dropping the migrated tables):

```bash
# On talos-cloud-00 (postgres18 reachable), after stopping BOTH Vault and OpenBao:
#   psql -c 'DROP TABLE vault_kv_store; DROP TABLE vault_ha_locks;'
# Then restore the dump (kept at /docker-volume/backup-vault/vault-data-pre-cutover.dump):
#   pg_restore -d postgres://<user>:***@10.99.0.1:5432/vault-data --no-owner /docker-volume/backup-vault/vault-data-pre-cutover.dump
# Then restart the unRAID Vault (7a). The AKV seal still works until AKV is purged.
```

The old Vault remains unsealable via Azure Key Vault for as long as AKV exists
(G5 purge only happens after the 24–48h soak).

---

## 8. Post-soak decommission (Task 10 — later dispatch)

- Soak: OpenBao up ≥24–48h with ≥1 clean restart + OCI-KMS auto-unseal
  (`bao status` → `Seal Type ociKms`).
- G5 (user): `az login`; `az keyvault list`; `az keyvault delete` + `az keyvault purge`.
- Old unRAID Vault is then permanently sealed (frozen backup); removing the container
  is a user decision.