# Vault → OpenBao Migration (unRAID → talos-cloud-01, OCI KMS seal)

**Date:** 2026-09-10
**Status:** Approved design (pending implementation plan)
**Branch:** develop

---

## 1. Overview & Goals

Migrate the HashiCorp Vault instance running on **unraid.internal** (tower.local,
unRAID 7.x, Docker via Arcane) to **OpenBao 2.6.x** running on **talos-cloud-01**
(OCI cloud VM, Docker via Arcane), without losing or duplicating any secret data.

Goals:

1. OpenBao becomes the drop-in replacement at **`vault.mcb-homelab.com`**,
   fronted by a new **Caddy** reverse-proxy (Arcane project "Proxy") on
   talos-cloud-01; Cloudflare proxy mode restored so ESO/k8s works again.
2. Reuse the **same PostgreSQL storage** (`vault-data` @ `10.99.0.1:5432`,
   talos-cloud-00 pgbouncer → postgres18) and the **same tables**
   (`vault_kv_store`, `vault_ha_locks`) — perfect data consistency.
3. Migrate the seal from **Azure Key Vault** to **OCI KMS** (instance-principal
   auth, $0/month standard vault + software AES key), using OpenBao's official
   seal-migration procedure (old seal `disabled=true` + new seal; `unseal -migrate`
   with the old recovery keys).
4. Keep the unRAID Vault **running untouched until all checks pass**; afterwards
   it becomes a frozen corpse (Azure Key Vault **purged** via `az` CLI after a
   24-48h soak).
5. Repoint all internal clients (scripts/`VAULT_ADDR`, Terraform) to
   `https://vault.mcb-homelab.com`.

## 2. Current State (verified 2026-09-10)

| Fact | Value |
|---|---|
| Container | `hashicorp/vault:2.0.3` on unRAID, Arcane project `hashicorp-vault`, port `9200→8200` |
| Client access today | `http://unraid.internal:9200` (local scripts, `vault` CLI on controller) |
| Storage | PostgreSQL `postgres://…@10.99.0.1:5432/vault-data` (talos-cloud-00 wg0/pgbouncer → postgres18), tables `vault_kv_store` / `vault_ha_locks` |
| Seal | `azurekeyvault` (key `unseal-key-hcl`), recovery shares **5 / threshold 3** (user holds shares) |
| Config | `ui = true`, `disable_mlock = true`, listener `tcp 0.0.0.0:8200` (TLS off, terminated upstream), templated via sed from Arcane `vault-config.hcl` |
| Public endpoint | `vault.mcb-homelab.com` → Cloudflare proxy → origin **down (521)** — public path currently broken |
| Other client | Terraform uses `vault.mcb-svc.work` |

## 3. Target Architecture

```
             ┌──────────── Cloudflare (proxy) ────────────┐
             │  vault.mcb-homelab.com  (A → talos-cloud-01)│
             └──────────────────────┬─────────────────────┘
                                    │ TLS (caddy ACME; CF Full(strict))
             ┌──────────────────────▼─────────────────────┐
             │ talos-cloud-01 · Arcane project "Proxy"    │
             │ caddy:2.x · net "proxy" · ports 80/443     │
             │ vault.mcb-homelab.com → openbao:8200       │
             └──────────────────────┬─────────────────────┘
             ┌──────────────────────▼─────────────────────┐
             │ talos-cloud-01 · Arcane project "OpenBao"  │
             │ openbao:2.6.2 · listener :8200 · ui        │
             │ seal "ocikms" (instance principal)         │
             │ storage postgresql → 10.99.0.1:5432 vault-data │
             └──────────────────────┬─────────────────────┘
                                    │ 10.99 overlay (wg0)
             ┌──────────────────────▼─────────────────────┐
             │ talos-cloud-00: pgbouncer → postgres18     │
             │ db vault-data (vault_kv_store, …)          │
             └────────────────────────────────────────────┘
      Old (until cutover): unRAID hashicorp-vault:2.0.3 · same DB · azure seal
```

- No published ports on the OpenBao project; caddy is the single entrypoint.
- OCI KMS: Standard Vault (`homelab-kms`) + AES-256 key (`openbao-seal`) in
  ap-singapore-1; Dynamic Group + policy for talos-cloud-01's instance principal.

## 4. Arcane "OpenBao" Project (talos-cloud-01)

Files (mirrored in git `docker/talos-cloud-01/openbao/`):

- `compose.yaml`:
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
- `bao-config.hcl` (cutover variant; stage variant = azure-only + `vault-data-stage`):
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
  tenant_id = "<from old vault env>"; client_id = …; client_secret = …;
  vault_name = …; key_name = "unseal-key-hcl"
  disabled = "true"
}
seal "ocikms" {
  key_id              = "<oci-kms-key-ocid>"
  crypto_endpoint     = "https://<vault>-crypto.kms.ap-singapore-1.oraclecloud.com"
  management_endpoint = "https://<vault>-management.kms.ap-singapore-1.oraclecloud.com"
}
```
- Credentials (PG URL, Azure) fetched at deploy time from the **live Vault**
  (`kubernetes/docker-secrets` + `kubernetes/openbao/…`), rendered by
  `deploy_bao.sh`; never committed.
- OpenBao version pinned **2.6.x** deliberately (ocikms stays built-in; from
  2.7 it becomes an external plugin).

## 5. OCI KMS Provisioning (cost $0/month)

- `oci kms management vault create` — Standard/DEFAULT vault `homelab-kms`
  (root compartment), software-protected keys = **Free** (HSM key versions &
  Private Vault are paid; not used).
- `oci kms management key create` — AES, 32 bytes, `openbao-seal`.
- Capture `crypto_endpoint` / `management_endpoint` from vault get.
- **Dynamic Group** (`talos-cloud-01-openbao`) containing the instance OCID;
  policy: `allow dynamic-group … to use keys in compartment …` — instance
  principal => no credentials stored anywhere.
- CLI: controller `oci` 3.90.3, region ap-singapore-1, API-key user
  `johnashuy21091996` (tenancy root).

## 6. Arcane "Proxy" Project (caddy, talos-cloud-01)

- `caddy:2.x` on network `proxy`, publishes 80/443 (only public surface).
- `Caddyfile`:
```
vault.mcb-homelab.com {
    reverse_proxy openbao:8200
}
```
- Structure mirrors the caddy project on talos-cloud-00 (config fetched from
  that host when reachable; single-route above is sufficient otherwise).
- **TLS:** caddy ACME (Let's Encrypt). During cutover the Cloudflare record is
  grey-clouded to allow issuance; afterwards re-enable CF proxy, SSL mode
  Full(strict). DNS A record → talos-cloud-01 public IP.
- Human step: Cloudflare DNS/TLS changes (user has console access).

## 7. Migration Sequence

### Phase 0 — OCI KMS (no impact)
1. Create vault + key; record endpoints; create dynamic group + policy.

### Phase 1 — Stage (Vault untouched)
2. `pg_dump -Fc` (consistent) of `vault-data` → restore as `vault-data-stage`
   on postgres18.
3. Arcane project **OpenBao** with azure-only seal + `vault-data-stage`.
4. Start → auto-unseals via Azure → **parity checks**:
   - `bao secrets list` / `bao auth list` == `vault …` (mounts + types)
   - sample KV reads equal (`kubernetes/*`, `docker-secrets`, …)
   - policies, identity/entity count sane; token pool healthy

### Phase 2 — Cutover (downtime ≈10-15 min)
5. `docker stop hashicorp-vault` on unRAID (data intact).
6. Config → real `vault-data`; seals azure(`disabled=true`) + ocikms; recreate.
7. `bao operator unseal -migrate` with **3 recovery shares** → master key
   re-wrapped to OCI KMS. Verify `bao status`: `Seal Type ociKms`, unsealed.
8. Full parity + client checks (controller `vault`/`bao` over https domain,
   ESO status in k8s, Terraform dry-run config).

### Phase 3 — Finalize
9. Remove azure seal block; clean restart; verify auto-unseal via OCI KMS only.
10. Keep pre-cutover `pg_dump` (talos-cloud-01 + one external copy); drop
    `vault-data-stage`.
11. Update clients: Terraform `vault.mcb-svc.work` → `https://vault.mcb-homelab.com`;
    repo scripts `VAULT_ADDR`; controller env; AGENTS.md/runbooks; install `bao`
    CLI on controller.

### Phase 4 — Azure decommission (after 24-48h soak)
12. Soak: OpenBao runs clean ≥24h including ≥1 restart + OCI-KMS auto-unseal.
13. `az login` once; `az keyvault delete --name <vault> --resource-group <rg>`
    then `az keyvault purge …`.
14. Old unRAID Vault is now permanently unsealable (frozen backup); document.

## 8. Consistency & Verification

- Single storage backend (`vault-data`) at every step — no divergent copies.
- Parity checks run at **both** stage and cutover (mounts, secrets, policies,
  identities).
- `reject`/rollback thresholds: any parity mismatch ⇒ do NOT proceed to next
  phase; diagnose, fix, re-run.
- Post-cutover client probes: `bao kv get kubernetes/docker-secrets`
  (via domain), ESO `kubectl get externalsecrets`, Terraform provider init.

## 9. Rollback

- Stage phase: non-destructive — delete stage DB/project.
- Cutover: restart unRAID Vault (its DB was untouched until unseal -migrate;
  even after re-wrap, restore from pre-cutover `pg_dump`).
- Seal migration: reversible while AKV still exists; AKV purge happens only
  after soak + explicit confirmation.

## 10. Risks & Notes

| Risk | Mitigation |
|---|---|
| talos-cloud-00 unreachable (pgbouncer/data source) | observed transient today; stage phase waits for healthy host; no cutover without DB reachability |
| OpenBao reading Vault-2.0.3 storage format | proven via stage parity before cutover (docs tested 1.14-1.15; 2.x expected compatible — evidence over assumption) |
| Cloudflare TLS dance | grey-cloud window booked into cutover; fallback `tls internal` + CF Full (non-strict) |
| ocikms plugin shift in 2.7 | pin 2.6.x |
| OCI KMS availability dependency | same-as-cloud class of risk as today's AKV; accepted |
| User steps | Cloudflare console, `az login`, recovery shares input, final AKV purge confirmation |

## 11. Out of Scope

- Vault Enterprise features / namespaces.
- Shifting the PostgreSQL backend itself (stays on talos-cloud-00).
- OpenBao HA/multi-node (single instance; Postgres HA params unused).
- Migrating the unRAID Vault's TLS/UI domain (vault.mcb-homelab.com only).