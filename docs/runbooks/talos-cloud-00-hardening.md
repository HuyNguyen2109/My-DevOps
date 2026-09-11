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
