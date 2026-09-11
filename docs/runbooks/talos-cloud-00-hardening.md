# talos-cloud-00 OOM Hardening (2026-09-11)

Node critical: PostgreSQL (vault-data, pg 18), NetBird management, Zitadel.
Incident: host hit OOM with NO swap → manual reboot → wg0 data path + NFS-backed caddy broken.

Applied:
- 4G `/swapfile` (fstab + `vm.swappiness=10`)
- Runtime `docker update` mem limits (see OOM-HARDENING.md on the share)
- OOM-score protection: `pgbouncer/postgres18 -800`, `netbird-* -500`, sacrificial `kan-web/jenkins/rustdesk* +200`

Persistence note: compose files live in Arcane projects on the NFS share
(`/mnt/nfs-server.d/docker-share/arcane/projects/*/compose.yaml`); add `mem_limit`/`memswap_limit`
per service there on next scheduled change. `oom_score_adj` is not in the compose spec — re-apply
via `/proc/<pid>/oom_score_adj` after container recreates (or a systemd oneshot).

Recommend: OCI dashboards/usage alerts via the central observability stack
(node_memory_available on talos-cloud-00) once alert rules are imported.

## 2026-09-11 Incident log (Vault/OpenBao outage)
- talos-cloud-00 OOM (no swap) -> manual reboot -> wg0 data path 01->00 lost (provider-level UDP drop; confirmed via tcpdump both sides).
- Recovery: OpenBao now reaches postgres18 via SSH tunnel from talos-cloud-01
  (`db-tunnel.service`, `172.18.0.1:5432 -> <postgres18 container IP>:5432`; direct PG bypasses a pgbouncer scram/verifier quirk for vault-admin).
- Talos-cloud-01: temp DNS `1.1.1.1/8.8.8.8`; SELinux `semanage permissive -a init_t` (+auditd) to allow systemd->ssh exec - REFINE LATER.
- Boot-volume backup: `talos-cloud-01-pre-reboot-20260911-0848`.
- AZURE: rotate `client_secret` (hashicorp-unseal-vault app) - value was exposed in a chat transcript.
- TODO: restore original caddy Caddyfile (talos-cloud-00, routes incl. relay/signal) -> netbird mesh -> observability bind 100.88.153.244; then wg0/provider UDP fix to drop the tunnel.

## 2026-09-11 Docker data move: NFS -> /mnt/docker-data (talos-cloud-00)
- Copied (copy-only, sources NOT deleted): jenkins/ (115M home+cacerts), rustdesk/ (240K), zitadel/ (bootstrap), arcane/{projects,templates}
- Updated `.env.global` MASTER_DIR=/mnt/docker-data (this single var feeds every project's volume paths)
- arcane-agent recreated with local mounts: /mnt/docker-data/arcane/{projects,templates}
- Remaining: redeploy projects in Arcane dashboard (Jenkins, RustDesk, Zitadel, Netbird, alloy-talosc00) to switch running containers to local paths
- Rollback: revert MASTER_DIR + agent mounts to /mnt/nfs-server.d/docker-share (NFS originals untouched)

## 2026-09-11 (II) NFS -> /mnt/docker-data EXECUTED (post NFS-remount)
- Full mirror of /mnt/nfs-server.d/docker-share -> /mnt/docker-data (arcane, caddy, jenkins, rustdesk, zitadel; #recycle excluded). NFS originals UNTOUCHED (rollback available).
- All local project compose.yaml + per-project .env prefix-swapped: /mnt/nfs-server.d/docker-share -> /mnt/docker-data. Per-project MASTER_DIR: Jenkins=/mnt/docker-data/jenkins, Zitadel=/mnt/docker-data/zitadel, rustdesk=/mnt/docker-data, caddy=/mnt/docker-data/caddy; global .env.global MASTER_DIR=/mnt/docker-data.
- arcane-agent recreated earlier on local projects/templates. Containers recreated from local composes: jenkins(+init), zitadel-api/login (healthy), rustdesk-hbbs/hbbr, netbird-management+coturn, alloy. Mounts verified local.
- NOTE: Arcane MANAGER-side per-project env may still hold NFS MASTER_DIR -> confirm/sync in dashboard before next Redeploy.
- Known residual: alloy -> central Loki push failing (mesh/100.88.153.244 flakiness, not the move); jenkins :8080 answered 407 (proxy-server?) - revisit.
