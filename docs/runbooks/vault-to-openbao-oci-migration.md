# Vault → OpenBao + Azure→OCI KMS Seal Migration (Complete Record)

Status: **MIGRATED & ACTIVE (2026-09-12)** · Branch: develop · Read with AGENTS.md (Secrets Architecture).

## 1. Final architecture
- **OpenBao 2.6.2** (`ghcr.io/openbao/openbao:2.6.2`) on talos-cloud-01:
  - Container `openbao-oci` on docker network `proxy` (no published ports), Arcane project **`OpenBao`** (env talos-cloud-01).
  - **Seal: OCI KMS** (`ocikms`, instance-principal) — `homelab-kms` vault, `openbao-seal` AES key, dynamic group `talos-cloud-01-openbao` + policy. Auto-unseals on start (verified).
  - Storage: PostgreSQL **`vault-data-oci`** on talos-cloud-00 postgres18 (via `db-tunnel` SSH forward: `172.18.0.1:5432 → <postgres18 IP>:5432`; direct-PG path used to bypass a pgbouncer scram quirk for vault-admin).
  - Public entry: `vault.mcb-homelab.com` (Cloudflare → **caddy** `Proxy` project on talos-cloud-01 → `openbao-oci:8200`).
- **Data**: KV `kubernetes/{azure,cloudflare-api,docker-secrets,terraform}`; policies; auth: `approle` (roles: `argocd-avp`, `vault-agent`), `kubernetes` (role `eso-role`), `kubernetes-k3s-oracle`, `oidc` (role `zitadel`); identity: 15 entities / 1 group; pki (new CA) with roles `docker-server`, `rustfs-certs`, `postgres-ha` (used by vault-agent templates).
- **Consumers**: ESO (k8s, `vault-backend` CSStore → `https://vault.mcb-homelab.com`, kubernetes auth, role `eso-role`); vault-agent (192.168.1.7, AppRole `vault-agent`, fresh secret_id redeployed); Terraform (`https://vault.mcb-homelab.com`); deploy scripts (`docker-*/**`).

## 2. How we got here (objectives + method)
1. **Vault → OpenBao (2026-09-10)**: staged cutover on the same Postgres (`vault-data`), Azure seal retained (recovery shares lost).
2. **Seal → OCI KMS (2026-09-11/12)**: official migration impossible without recovery keys → chose **rebuild**:
   - provisioned `openbao-oci` + fresh DB + `ocikms` seal; initialized (5 recovery keys / threshold 3 — **MUST SAVE**);
   - exported everything via API with the **root token** (policies, KV, auth configs+roles+role-ids, identity), imported to the new instance; **value-parity confirmed**;
   - recreated pki + cert roles for vault-agent templates;
   - cutover: caddy → `openbao-oci`, stopped old instance; re-issued vault-agent secret-id; ESO + agent verified.
3. **Azure decommission (2026-09-12)**: Key Vault `hashicorp-unseal-vault` (rg `Homelab`) — soft-deleted, **purge-protected, permanent purge scheduled 2026-12-11**; AD app/SP `vault-unseal` deleted. No other AKV remains. (Old Azure-sealed OpenBao is stopped as rollback twin, now unsealable.)

## 3. 2026-09-11 incident record (context of this migration)
- talos-cloud-00 OOM (5.8 GiB, **no swap**) → manual reboot. Added 4 GiB swap (`/swapfile`, swappiness 10), container mem limits, OOM-score priorities (`pgbouncer/postgres18 -800`, netbird -500, jenkins/kan-web +200). See `talos-cloud-00-hardening.md`.
- **UDP 51821 (and general UDP) from talos-cloud-01 → talos-cloud-00 is dropped at provider/upstream level** (proven: 01 sends, 00 NIC receives nothing on any port, other sources+ports pass). Breaks wg0 legs → NFS (home NAS via wg) hangs, NetBird mgmt instability, observability bind outages. **Action: talos-cloud-00 provider firewall must open UDP 51821** (permanent fix); interim relied on SSH tunnel.
- NFS hard-mount caused app hangs → **all docker bind data moved off NFS to `/mnt/docker-data`** on talos-cloud-00 (jenkins, rustdesk, zitadel, arcane projects+templates; per-project `MASTER_DIR` + `.env` updated; containers recreated; Arcane redeployed with key `arc_58cf…` — not stored in Vault by request).
- `caddy-proxy` on talos-cloud-00 is a TEMPORARY standalone (local `/opt/caddy/Caddyfile`, named volumes) while Arcane `caddy` project is stopped; routes: `idp.mcb-homelab.com → zitadel-api:8080`, `netbird.mcb-homelab.com` (management/relay/signal with h2c).

## 4. Secrets & operational notes
- **Recovery keys (NEW, critical):** talos-cloud-01 `/docker-volume/openbao-oci/recovery-keys.txt` (5/3) + `init-keys.json` (root token). **Back them up NOW** (copies: one offline).
- Auto-unseal: OCI instance-principal (no stored creds); restart-safe.
- `db-tunnel.service` (systemd on talos-cloud-01, ssh forward to postgres18) is the DB lifeline — do not stop; if postgres18's container IP changes, retarget `172.18.0.1:5432:<IP>:5432`.
- **Azure creds in old `.env` (`hashicorp-unseal-vault`)** are now defunct (resources deleted) — keeping the env file harms nothing but rotation of nothing is required.
- New PKI CA is self-signed fresh: systems relying on the old docker/rustfs certs must re-trust the new CA (certificates are reissued by vault-agent).
- `control-group` policy is auto-managed by OpenBao; `agent-registry` mount is internal.

## 5. Rollback / emergency
- The old Azure-sealed OpenBao container `openbao` is **stopped** on talos-cloud-01 (rollback twin; **cannot unseal** after AKV deletion — treat as archived only).
- Pre-migration `pg_dump` backups exist from earlier phases (see previous runbooks); `vault-data` DB retained (encrypted-at-rest archive).
- Repoint caddy `Proxy/Caddyfile` back to `openbao:8200` if a software regression requires momentary restore of the old instance (requires re-deploying Azure seal — not possible post-decommission: **no rollback path after 2026-12-11**).

## 6. Known open items
1. talos-cloud-00 provider: open UDP 51821 (wg0 permanent fix).
2. Arcane manager per-project env review for `MASTER_DIR` on talos-cloud-00 (local paths), and re-import `caddy` project when ready.
3. Alloy (talos-cloud-00) → central Loki push pragmatic over mesh; mesh stabilizes after #1.
4. Central alerting rules (load/CPU for talos-cloud-00) not yet wired (Alertmanager→Telegram ready).
5. Cleanup: the 4 skipped historical entity aliases regenerate lazily on login.

## 7. Key commands (operational)
- Status: `BAO_ADDR=https://vault.mcb-homelab.com bao status`
- Consumers test: `vault kv get kubernetes/docker-secrets` (any root/privileged token).
- Tunnel: `systemctl status db-tunnel` (talos-cloud-01); `ss -tlnp | grep :5432`.
- New instance files: talos-cloud-01 `/docker-volume/openbao-oci/`.

## 8. Troubleshooting: ESO returns `403 permission denied` on login

Symptom — every `ExternalSecret` shows:

```
error processing spec.data[0]: unable to log in with Kubernetes auth:
URL: PUT https://vault.mcb-homelab.com/v1/auth/kubernetes/login
Code: 403. Errors: * permission denied
```

**Root cause (hit 2026-11-17):** the `token_reviewer_jwt` stored in
`auth/kubernetes/config` must be a token valid for the **Kubernetes API
audience**. The token in `kube-system/vault-auth-token` has
`aud=["vault"]` — it is the *client* token, and the API server rejects it as a
caller, so OpenBao's TokenReview returns 401 and the login surfaces as 403.
A fresh `kubectl create token ... --audience=vault` has the same problem.

**Fix:** keep two tokens with different audiences.

```bash
# 1. reviewer token: API audience (legacy SA secret => no audience claim, non-expiring)
kubectl -n kube-system apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: vault-reviewer-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: vault-auth
type: kubernetes.io/service-account-token
EOF

# 2. write it into OpenBao (keep the existing CA/host)
rev=$(kubectl -n kube-system get secret vault-reviewer-token -o jsonpath='{.data.token}' | base64 -d)
bao write auth/kubernetes/config \
  kubernetes_host="https://192.168.1.11:6443" \
  kubernetes_ca_cert=@/path/to/cluster-ca.crt \
  token_reviewer_jwt="$rev" \
  disable_iss_validation=true \
  disable_local_ca_jwt=true
```

Verify before touching ESO:

```bash
curl -s -X POST http://<openbao>:8200/v1/auth/kubernetes/login \
  -H 'Content-Type: application/json' \
  -d "{\"jwt\":\"<aud=vault token>\",\"role\":\"eso-role\"}"
# expect an auth.client_token, not an error
```

Then force a resync (ESO backs off for a long time after repeated failures):

```bash
kubectl -n kube-system rollout restart deploy/external-secrets
kubectl -n <ns> annotate externalsecret --all force-sync="$(date +%s)" --overwrite
```

Note: `aud=vault` alone is correct for the *client* token; only the reviewer
needs the API audience. Do not "fix" this by giving the reviewer `aud=vault`.

**Hardening applied 2026-11-17:** the ClusterSecretStore no longer uses a static
token. `secretRef` was removed and only `serviceAccountRef` remains, so ESO
mints short-lived tokens through the Kubernetes `TokenRequest` API (default
10 min). `kube-system/vault-auth-token` was deleted. The only long-lived
credential left is `kube-system/vault-reviewer-token`, which OpenBao uses to
call TokenReview and which never leaves the server.

If you ever need to revert, re-add `secretRef` and recreate the token secret
from a TokenRequest.
