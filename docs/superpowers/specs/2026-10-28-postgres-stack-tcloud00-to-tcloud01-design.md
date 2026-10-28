# PostgreSQL Stack Migration: talos-cloud-00 → talos-cloud-01

**Date**: 2026-10-28

## Purpose

Move the `postgresql` and `pgbouncer` Docker stacks from `talos-cloud-00` (x86_64)
to `talos-cloud-01` (aarch64 / ARMv8), then re-point every DB client on every node
and validate. Zitadel is **out of scope** for this phase (it stays on talos-cloud-00
and is re-pointed to the new DB).

## Source (talos-cloud-00, `100.116.205.94` Tailscale)

| Stack | Project dir (Arcane) | Services | Data |
|---|---|---|---|
| postgresql | `/mnt/docker-data/arcane/projects/PostgreSQL` | `postgres18` (pgvector pg18-trixie, internal 5432), `pgadmin4` (`100.116.205.94:3000`), `databasus` (`:4005`) | `/var/lib/docker-stack-data/postgres` — postgres-data 1.3 GB, databasus 103 MB, pgadmin 296 KB |
| pgbouncer | `/mnt/docker-data/arcane/projects/PgBouncer` | `pgbouncer` (`100.116.205.94:5432`, db-intranet) | pgbouncer config 12 KB |

- Networks: `db-intranet` (postgres18, pgbouncer, pgadmin4, databasus, zitadel-api, kan-web), `proxy`.
- Databases (9): `benchmarkdb`, `immichdb`, `kanbn`, `pocketid-db`, `postgres`, `termix`, `vault-data`, `vault-data-oci`, `zitadel`.
- Databasus: continuous physical WAL streaming (slot `databasus_slot_2cbac9339c6c4249aecd615688593104`) + S3 backups.

## Target (talos-cloud-01 = `remote-homelab`, `100.88.110.94` Tailscale, aarch64)

- Docker 29.9.2, 22 GB RAM, `/docker-volume` = **122 GB free**.
- Arcane agent running; project dir `/docker-volume/arcane/projects/` (no name conflicts).
- Existing `proxy` network; `db-intranet` must be created.
- Port 3000 is taken by `obs-grafana` → pgAdmin uses **3001**.
- All images verified to publish `linux/arm64`: pgvector, pgadmin4, databasus, pgbouncer, zitadel (+login), dragonfly.

## Design decisions

- **Overlay**: all nodes on Tailscale; target IP `100.88.110.94`. No Netbird.
- **Bindings**: pgbouncer `100.88.110.94:5432`; pgAdmin `100.88.110.94:3001`; databasus `100.88.110.94:4005`; postgres internal only.
- **Data path (target)**: `/docker-volume/docker-stack-data/postgres`.
- **Architecture**: physical `pg_basebackup` is portable x86_64 → arm64 (both little-endian, same PG major). No logical dump required.
- **Arcane**: projects created under `/docker-volume/arcane/projects/{PostgreSQL,PgBouncer}` so the t01 agent/dashboard manages them.
- **OpenBao (t01)**: currently reads/writes `vault-data-oci` through `db-tunnel.service` → **mis-pointed to `172.21.0.3` (kan-web)**. After migration it must connect directly to the new Postgres (attach `openbao-oci` to `db-intranet`, use `postgres:5432`; retire `db-tunnel.service`).

## Client inventory & post-cutover target

| Client | Host | Config | New endpoint |
|---|---|---|---|
| zitadel-api | talos-cloud-00 | `Zitadel/.env` `ZITADEL_DATABASE_POSTGRES_DSN` | `100.88.110.94:5432` |
| kanbn (kan-web) | talos-cloud-00 | `kanbn/.env` `POSTGRES_URL` | `100.88.110.94:5432` |
| immich-server | tower | `Immich/.env` `DB_HOSTNAME` | `100.88.110.94` |
| termix | tower | termix `DATABASE_URL` | `100.88.110.94:5432` |
| openbao-oci | talos-cloud-01 | `bao-config.hcl` storage URL + `db-tunnel.service` | `postgres:5432` (db-intranet), tunnel retired |
| databasus, pgadmin4 | migrated stack | own config | new postgres |

No k8s consumers of this external DB (harbor uses in-cluster CNPG). `vault-data`,
`pocketid-db`, `benchmarkdb` have no active clients.

## Approach (same proven pattern as tower → talos-cloud-00)

1. **Rehearsal**: `pg_basebackup` + `pg_dumpall` → provision t01 stack → restore →
   verify 9 DBs/roles/sizes → connectivity tests from t00, tower, t01.
2. **Cutover**: freeze writes (stop pgbouncer + openbao; databasus is replication-only) →
   final basebackup → restore over rehearsal data → recreate slot → verify.
3. **Client re-point**: update each client above, restart, verify health/read query.
4. **Rollback**: old t00 stack kept intact until all clients verified; revert DSNs to
   `100.116.205.94`/`pgbouncer` and restart.

## Risks

| Risk | Mitigation |
|---|---|
| ARM vs x86 data | physical backup portable; verify row counts/sizes after restore |
| pgbouncer SCRAM quirk for `vault-admin` | OpenBao connects direct to `postgres:5432`, not pgbouncer |
| OpenBao briefly unavailable at freeze | short window; k8s ESO uses cached secrets |
| Port 3000 conflict | pgAdmin on 3001 |
| Databasus loses config | copy full `databasus/` dir; re-point; recreate slot; verify S3/streaming |
| Clients left pointing at old DB | per-client checklist + verification in plan; source kept as rollback |
