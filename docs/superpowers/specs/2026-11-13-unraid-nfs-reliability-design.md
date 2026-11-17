# unRAID NFS Reliability — Root Cause & Production Design

**Date:** 2026-11-13
**Author:** HuyNguyen2109
**Status:** Phase 1 implemented and validated 2026-11-16 (two reboot cycles). Phases 2–5 pending.
**Scope:** `tower.local` (unRAID 7.4.0) as NFS server; `prx-prd-01` (PVE 9.2.26), Linux clients and Docker workloads as NFS clients

---

## 1. Verdict

The failure is **not** an RPC problem, **not** an NFSv3 problem, and **not** a
`rpc.statd` problem. NFSv4.1 was a correct hypothesis to test, but it addresses
session recovery, and this failure is a **file identity** failure.

**Root cause:** every NFS export is a path under `/mnt/user`, which is the
`fuse.shfs` union filesystem. shfs fabricates inode numbers by packing an
internal *branch index* into the high bits:

```
shfs inode = (branch_index << 48) | underlying_inode
```

The branch index is reassigned when the array restarts. An NFSv4 file handle is
`(fsid, fileid, generation)`, so **every NAS reboot changes the file handle of
the export root**. A client can recover a changed handle for an ordinary file by
re-resolving the name, but **there is no name to re-resolve for an export root**.
The client therefore returns `ESTALE` forever. The mount still exists in
`/proc/mounts`, so neither systemd nor Proxmox will ever remount it.

This was measured directly on this infrastructure (see §3.2) and reproduces the
well-known unRAID "stale file handle" family of reports.

**Blast radius observed:** the Proxmox `ISO` storage fails in long stretches.
`pvestatd` logs one failure per 10 s (≈360/hour); the journal holds 373 467 such
lines — roughly 43 days of accumulated failure time, with individual outages
lasting days to weeks. It recovered only when something removed the mount, and
broke again at the next NAS reboot.

---

## 2. Environment as found

| Item | Value | Source |
|---|---|---|
| unRAID | **7.4.0**, kernel `6.18.60-Unraid` (built 2026-11-02) | `/etc/unraid-version`, `uname -a` |
| NFS server versions | `+3 +4 -4.0 +4.1 +4.2` (v4.0 disabled) | `/proc/fs/nfsd/versions` |
| nfsd threads | 32 | `/proc/fs/nfsd/threads` |
| Client tracking | `nfsdcld` running (PID 15570) | `ps` |
| Grace / lease | 90 s / 90 s | `/proc/fs/nfsd/nfsv4{gracetime,leasetime}` |
| RPC daemons | `rpcbind -w`, `rpc.statd --no-notify`, `rpc.mountd`, `rpc.idmapd`, `nfsdcld` | `ps` |
| Exports | `/mnt/user/appdata` (fsid 105), `/mnt/user/backups` (106), `/mnt/user/isos` (103) | `/etc/exports` |
| `/mnt/user` | **`fuse.shfs`** | `/proc/mounts` |
| `/mnt/disk1` | `xfs` on `/dev/md1p1` | `/proc/mounts` |
| `/mnt/zfs` | ZFS, 2× mirror vdevs (4 disks), scrubbed clean | `zpool status` |
| `/mnt/fast` | ZFS 2-way mirror | `zpool status` |
| Proxmox | `pve-manager/9.2.26`, kernel `7.0.14-28-pve` | `pveversion` |
| PVE NFS storage | only `ISO` → `192.168.1.40:/mnt/user/isos` | `/etc/pve/storage.cfg` |

Relevant unRAID global share settings (`/boot/config/share.cfg`):

```
shareUserExclusive="no"     # exclusive shares disabled
fuse_useino="yes"           # shfs reports underlying inodes (with branch prefix)
fuse_remember="330"
shareNFSEnabled="yes"
```

`/boot/config/network-extra.cfg`:

```
include_interfaces="tailscale1"
```

---

## 3. Evidence

### 3.1 shfs fabricates inode numbers

```
$ stat -c '%d %i %n' /mnt/zfs/isos /mnt/user/isos /mnt/disk1/appdata /mnt/user/appdata
56   34                  /mnt/zfs/isos
60   15762598695796770   /mnt/user/isos
2305 131                 /mnt/disk1/appdata
60   648799821318062211  /mnt/user/appdata
```

Decoding: `15762598695796770 = (0x38 << 48) | 34`. `0x38` = 56 = the `%d`
(device index) shfs reports for that branch; `34` is the real ZFS inode. The
same holds for appdata: `(2305 << 48) | 131`.

**Consequence:** identity of a file in `/mnt/user` depends on a runtime index,
not on the file.

### 3.2 The branch index changes on reboot — captured in the client log

```
$ journalctl -k | grep -A1 'fileid changed'
Nov 10 20:29:47 prx-prd-01 kernel: NFS: server 192.168.1.40 error: fileid changed
                   fsid 0:76: expected fileid 0x37000000000022, got 0x39000000000022
```

`0x37` → `0x39`: the shfs branch index for the `isos` share moved from 55 to 57
across that server reboot. The low 32 bits (`0x22` = 34, the real ZFS inode) are
unchanged. unRAID's boot log for that reboot is
`/boot/logs/boot-dmesg-20261110-202919.txt`; the Proxmox message lands 28 s
later.

### 3.3 The dead mount, while the server is perfectly healthy

```
$ stat /mnt/pve/ISO
stat: cannot statx '/mnt/pve/ISO': Stale file handle          # exit 1

$ grep pve/ISO /proc/mounts
192.168.1.40:/mnt/user/isos /mnt/pve/ISO nfs4 rw,noatime,vers=4.2,...,hard,...

$ pvesm status
ISO   nfs   inactive   ...   unable to activate storage 'ISO'
                              - directory '/mnt/pve/ISO' does not exist or is unreachable

$ rpcinfo -t 192.168.1.40 100003 4
program 100003 version 4 ready and waiting
```

A **fresh** mount of the same export at the same moment succeeded instantly and
listed files, then unmounted cleanly. The server, the network, the export and
NFSv4 were all healthy. Only the existing handle was dead.

### 3.4 Proxmox cannot self-heal, and does self-heal once the mount is gone

`/usr/share/perl5/PVE/Storage/NFSPlugin.pm`:

```perl
sub nfs_is_mounted {
    ...
    $mountdata = PVE::ProcFSTools::parse_proc_mounts() if !$mountdata;
    return $mountpoint if grep {
        $_->[2] =~ /^nfs/ && $_->[0] =~ m|^\Q$source\E/?$| && $_->[1] eq $mountpoint
    } @$mountdata;
    return undef;
}

sub activate_storage {
    ...
    if (!nfs_is_mounted($server, $export, $path, $cache->{mountdata})) {
        ... nfs_mount($server, $export, $path, $scfg->{options});
    }
    $class->SUPER::activate_storage($storeid, $scfg, $cache);   # <- stat() fails here
}
```

The only health test is "is there a line in `/proc/mounts`". A stale mount
passes. Proxmox therefore skips the remount and then fails its own `stat()`
check, forever.

Recovery test performed:

```
$ umount /mnt/pve/ISO          # exit 0, nothing held it open
$ sleep 25 && pvesm status
ISO  nfs  active  7650410496  3266939904  4383470592  42.70%
$ grep pve/ISO /proc/mounts
... vers=4.1 ...               # storage.cfg options finally applied
```

**Proxmox remounts automatically within one `pvestatd` cycle once the stale
mount is removed.** This is the entire recovery procedure.

### 3.5 systemd does not model the mount

```
$ systemctl cat mnt-pve-ISO.mount
No files found for mnt-pve-ISO.mount.
$ systemctl show mnt-pve-ISO.mount -p ActiveState -p SubState
ActiveState=active
SubState=mounted
```

Proxmox creates the mount with `mount(8)`, not as a systemd unit. systemd
publishes a *shadow* unit for it (no fragment, no dependencies, no `ExecStop`).
It reported `active/mounted` for a filesystem that could not be `stat()`ed.

There is no `_netdev`, `x-systemd.automount`, `nofail`, or ordering semantics
for Proxmox-managed NFS storage. Those options only exist for unit-managed
mounts and, in any case, they govern *activation*, not *recovery of an existing
mount*.

### 3.6 The tailscale bind list (secondary, affects boot and restarts)

`/boot/config/network-extra.cfg` adds `tailscale1` to unRAID's global service
bind list. `rc.library.source:check()` then produces:

```
/etc/default/rpc: RPCBIND_OPTS="-h 192.168.1.40 -h 100.70.225.21 -h fd7a:115c:a1e0::7537:e116"
/etc/default/nfs: RPC_NFSD_BIND="-H 192.168.1.40 -H 127.0.0.1 -H 100.70.225.21 -H fd7a:115c:a1e0::7537:e116"
```

Observed process birth times after the 2026-11-12 boot:

```
14:19:20  rpc.idmapd, nfsdcld
14:19:22  [nfsd] ×8          <- nfsd started BEFORE rpcbind existed
14:20:20  rpcbind -w, rpc.statd
14:20:22  [nfsd] ×32 + rpc.mountd
```

and on every nfsd stop:

```
svc: failed to register nfsdv3 RPC service (errno 107).
failed to unregister tcp with rpcbind
```

`errno 107` is `ENOTCONN`: the kernel RPC layer could not reach `rpcbind` on the
address it was told to use. This is benign at shutdown but shows that the
registration path is bound to a volatile address. At boot, if `tailscale1` has
no address yet, `rpc.nfsd -H <tailnet IP>` can fail or partially bind, which is
exactly the "RPC services fail to start after reboot" symptom. Treat the
boot-time half as a **hypothesis to confirm at the next planned reboot** (§3.7).

### 3.7 Not confirmed (evidence lost)

The kernel ring buffer is flooded by a UPS USB HID re-enumeration loop
(`0764:0501 Cyber Power`, one disconnect/reconnect every ~8 s, ~1 MB of kernel
log per day). Boot-time NFS/RPC messages from the current boot have been evicted
(`dmesg | grep -ci nfsd` → 0). The exact boot-time failure, if any, can only be
captured at the next reboot — the runbook includes the collection step.

This does not weaken the root cause: the stale mount was reproduced with the
server healthy, three days after the reboot.

---

## 4. Root-cause classification

| ID | Finding | Status | Evidence |
|---|---|---|---|
| C1 | Exports are served from `fuse.shfs`, whose inodes carry a runtime branch index | **Confirmed** | §3.1 |
| C2 | The branch index changes across array restart/reboot | **Confirmed** | §3.2 |
| C3 | The export root's file handle therefore changes; the client cannot re-resolve an export root, so it returns `ESTALE` permanently | **Confirmed** | §3.2, §3.3 |
| C4 | Proxmox treats "present in `/proc/mounts`" as healthy and never remounts a stale mount | **Confirmed** | §3.4 (code + logs) |
| C5 | systemd's shadow mount unit reports `active/mounted` for a dead filesystem; no recovery semantics | **Confirmed** | §3.5 |
| C6 | Removing the stale mount is sufficient; Proxmox remounts in ≤25 s | **Confirmed** | §3.4 |
| C7 | NFSv4.1 session/lease recovery itself works (`nfsdcld`, grace 90 s); it cannot repair file identity | **Confirmed** | §3.3, §5 |
| C8 | unRAID binds `rpcbind`/`nfsd` to volatile tailnet addresses, forcing nfsd restarts and risking boot-time start failure | **Confirmed config / boot impact hypothesised** | §3.6 |
| H1 | nfsd double-start at boot (8 threads before rpcbind, 32 after) | **Hypothesis** | §3.6 |
| H2 | `async` exports + `hard` mounts can lose in-flight writes on NAS power loss | **Hypothesis, standard NFS semantics** | §8 |
| D1 | `rpc.statd` is the root cause | **Debunked** — statd serves NFSv3 NSM only; NFSv4 has integrated locking | §5 |
| D2 | NFSv4.1 vs 4.2 is the cause | **Debunked** — same failure on both | §5 |
| D3 | NFS daemon is broken / not started | **Debunked at the time of failure** — `rpcinfo` ready, fresh mount OK | §3.3 |

Mapping to the standard failure table:

| Failure mode | Applies | Note |
|---|---|---|
| Stale file handle | **Yes — primary** | Export/filesystem identity |
| Fresh mount succeeds, old mount fails | **Yes — primary** | Client lifecycle |
| RPC registration fails | Partial | Secondary, §3.6 |
| Connection timeout | Only during the outage window | Recovers on its own |
| Mount exists but I/O hangs | No | Fails fast with `ESTALE`, does not hang |
| Mount disappears | No | It stays in `/proc/mounts` |
| TCP 2049 unavailable | No | Verified reachable |
| Fresh mount fails | No | Verified working |

---

## 5. Why NFSv4.1 did not help — and why it never could

| Layer | NFSv3 | NFSv4.1 |
|---|---|---|
| Portmapper | `rpcbind` required | not required for data |
| Mount protocol | `rpc.mountd` required | integrated (`PUTROOTFH`) |
| Locking | NLM: `lockd` + `rpc.statd` (NSM) | integrated, lease-based |
| State recovery | none | sessions, `SEQUENCE`, `RECLAIM_COMPLETE`, `nfsdcld` |
| **File identity** | **file handle from inode** | **file handle from inode** |

NFSv4.1 removes the RPC daemons from the data path and adds robust session
recovery. It does **not** abstract file identity: a handle is still derived from
the backing filesystem's inode and generation. If the server hands out a
different fileid for the same object, the protocol's only answer is
`NFS4ERR_STALE`, and the client's only remedy is to re-resolve the path.

Re-resolving works for children of the export root. It cannot work for the
export root itself, because the client has no parent to look it up from. That is
why the mount is dead rather than merely slow, and why a fresh mount of the same
export works.

`rpc.statd --no-notify` is present but irrelevant to this mount: it exists for
v3 NSM callbacks. Removing it would change nothing for `vers=4.1` clients, which
is consistent with the observation that forcing `vers=4.1` changed nothing.

---

## 6. Architecture comparison

Scoring: **R**eliability, **S**implicity, **D**ata integrity, **C**ompatibility.

### Option A — Native unRAID NFS, real paths (recommended)

Serve NFS from the kernel nfsd, but ensure the exported directory is a **real
filesystem** (`/mnt/<pool>/<share>` or `/mnt/disk1/<share>`), never `fuse.shfs`.
unRAID supports this natively for pool-only shares via **exclusive shares**
(`Permit Exclusive Shares` → `/mnt/user/<share>` becomes a symlink to
`/mnt/<pool>/<share>`, bypassing FUSE). This is supported for NFS export since
unRAID **7.2.0** ("Improvement: Exclusive shares may be selected for NFS
export") and the host runs 7.4.0.

- **R:** High. Handles derive from XFS/ZFS inode + generation, which are stable
  across reboots. `fsid=` is already pinned per export.
- **S:** Highest. No new hosts, no new daemons, no container privileges, no
  boot-order dependency. One global setting plus per-share storage settings.
- **D:** High, once `sync` is used where it matters and `async` is confined to
  replaceable data (ISOs).
- **C:** Full. Proxmox, Linux, Docker all speak v4.1/4.2.

Limits: array-only shares cannot be exclusive (they are multi-disk by
definition). A share that must stay on the array has to be pinned to one disk
and exported by its disk path, or served another way.

### Option B — Dedicated Linux NFS VM

- Backend options are all worse than they look: NFS back to unRAID reinstates
  the FUSE handle problem (the VM's client would break the same way); SMB/CIFS
  gives weaker POSIX semantics (no reliable `flock`/`fcntl` across clients,
  case/ACL translation, no stable inode identity); a virtual disk on the pool
  turns the NAS into block storage and reintroduces a single point of failure
  with an extra hop.
- Adds a SPOF whose own storage depends on the NAS it is meant to abstract, plus
  a boot-order dependency and a second place to debug.
- **R:** Not better than A for this failure mode. **S:** Much worse.
  **D:** Depends entirely on the backend. **C:** Good.
- Only justified if the requirement is a POSIX filesystem over a multi-disk
  union with stable handles — i.e. if `/mnt/user` semantics are non-negotiable.

### Option C — NFS-Ganesha in Docker

- The VFS FSAL derives handles via `name_to_handle_at()`/`open_by_handle_at()`
  on its backend. Pointed at `/mnt/user`, that backend is `fuse.shfs`, whose
  handles are exactly what is unstable here. Ganesha would inherit the defect,
  not fix it.
- Container requires `CAP_SYS_ADMIN`, host bind mounts, and persistent
  `/var/lib/nfs/ganesha` state; NFSv4 state in a restartable container is an
  additional failure domain.
- **R:** No improvement over A. **S:** Worse (privileged container, new config
  language, new state directory). **D:** Equivalent at best. **C:** Good.
- Verdict: reject. It moves the failure, it does not remove it.

### Option D — Kernel nfsd in a container

- `nfsd` is a host-kernel service controlled through `/proc/fs/nfsd`. A
  container can only drive the host kernel; it adds a namespace/privilege layer
  around the same daemon unRAID already runs, plus Docker networking and
  lifecycle coupling.
- **R:** Worse than A for no gain. **S:** Worse. **D:** Same. **C:** Same.
- Verdict: reject. This is unRAID's own NFS with extra steps.

### Summary

| | A (native, real paths) | B (NFS VM) | C (Ganesha) | D (nfsd container) |
|---|---|---|---|---|
| Fixes stale handles | **Yes** | Only with a non-FUSE backend | **No** | **No** |
| New SPOF | No | **Yes** | Yes | Yes |
| Privileged container | No | No | **Yes** | **Yes** |
| Boot-order dependency | No | **Yes** | Yes | Yes |
| Operational surface | Smallest | Large | Medium | Medium |

---

## 7. Recommended architecture

### 7.1 Diagram

```
                       LAN 192.168.1.0/24 (NFSv4.1, TCP/2049)
  ┌──────────────┐   ┌───────────────┐   ┌────────────────┐   ┌──────────────┐
  │ prx-prd-01   │   │ talos-01/02   │   │ Docker hosts   │   │ other Linux  │
  │ .9           │   │ .12 / .13     │   │                │   │ clients      │
  └──────┬───────┘   └──────┬────────┘   └───────┬────────┘   └──────┬───────┘
         │  hard,vers=4.1   │                    │                   │
         └──────────────────┴─────────┬──────────┴───────────────────┘
                                      │
                             ┌────────▼─────────┐
                             │ tower.local .40  │
                             │ kernel nfsd      │  fsid 103 / 106 (+105)
                             │ 32 threads       │
                             └────────┬─────────┘
                                      │  real filesystem paths only
                    ┌─────────────────┴──────────────────┐
                    │                                    │
          ┌─────────▼─────────┐                ┌─────────▼─────────┐
          │ /mnt/zfs/isos     │                │ /mnt/zfs/backups  │
          │ ZFS dataset       │                │ ZFS dataset       │
          │ mirror (4 disks)  │                │ mirror (4 disks)  │
          └───────────────────┘                └───────────────────┘

  ❌ never:  nfsd ──► /mnt/user/... ──► fuse.shfs ──► pool/disk
  ✅ always: nfsd ──► /mnt/<pool>/<share>        (real inode + generation)
```

### 7.2 Storage flow

1. Client resolves `192.168.1.40:/mnt/zfs/isos`.
2. Because `isos` is an **exclusive share**, unRAID generates the export from
   the resolved pool path, not from `/mnt/user/isos` — verified: `/etc/exports`
   contains `"/mnt/zfs/isos" -fsid=103,...`. `/mnt/user/isos` remains a symlink
   for SMB/Docker, but NFS no longer traverses it.
3. nfsd hands out a file handle built from `fsid=103` + ZFS inode + ZFS
   generation. ZFS inode and generation survive export reload, nfsd restart,
   array restart and reboot.
4. On NAS reboot the client's handle is still valid; the v4.1 session is
   re-established and I/O resumes with no remount.

### 7.3 Network requirements

| Requirement | Value |
|---|---|
| Client → server | TCP/2049 only |
| Bind address | `192.168.1.40` (LAN) — **not** the tailnet |
| MTU | Standard 1500; verify if jumbo frames are ever enabled on `br0` |
| DNS | Export path is IP-based today; keep it IP-based (no DNS dependency at boot) |
| Firewall | Export ACL limits clients; tailnet must not be in the bind list |

Removing `tailscale1` from `/boot/config/network-extra.cfg` eliminates the
`-h`/`-H` tailnet binds, the `errno 107` registration noise, and the nfsd restart
triggered when the tailnet address changes.

### 7.4 Failure dependencies

| Dependency | Needed for mount | Needed for existing mount to survive |
|---|---|---|
| Network path | yes | yes |
| unRAID up, array started | yes | yes (pools unmount with the array) |
| Pool imported | yes | yes |
| `nfsd` running | yes | yes (session re-established on return) |
| shfs / FUSE | **no** | **no** (exclusive shares bypass it) |
| Mover | no | no |
| `rpc.statd`, `rpc.mountd`, `rpcbind` | no (v4-only clients) | no |
| tailscale | no | no |

### 7.5 Recovery behaviour

| Event | Expected behaviour after this design |
|---|---|
| NAS reboot | Client reconnects, handles stay valid, I/O resumes; no remount |
| nfsd restart | 90 s grace, clients reclaim; no remount |
| Network interruption (< lease) | Transparent resume |
| Network interruption (> lease) | Session re-established, handles still valid |
| Export/pool rebuilt (handles genuinely change) | Watchdog unmounts, Proxmox remounts in ≤25 s |
| Proxmox reboot | Mount recreated by `pvestatd` |
| Client reboot | Mount recreated by systemd/`pvestatd` |

---

## 8. Implementation plan

Ordered so that each phase is independently reversible. Phase 1 is the actual
fix; Phases 2–4 remove secondary failure modes and add the safety net.

### Phase 0 — Current state (done during investigation)

The stale `ISO` mount was unmounted (`umount /mnt/pve/ISO`, no open handles) and
`pvestatd` remounted it as `vers=4.1`. Storage is `active`. Nothing else was
changed.

### Phase 1 — Remove FUSE from the NFS path

Requires an array stop (unRAID requires it to change the global setting).

1. **Pre-check** that each NFS-exported share lives on exactly one volume:

   ```bash
   ls -d /mnt/disk*/isos /mnt/disk*/backups /mnt/zfs/isos /mnt/zfs/backups
   stat -c '%d %i %n' /mnt/zfs/isos /mnt/user/isos
   ```

2. Settings → Global Share Settings → **Permit Exclusive Shares: Yes**.
3. Shares → `isos`: Primary `zfs`, Secondary **none**.
   Shares → `backups`: Primary `zfs`, Secondary **none**.
4. Start the array. Verify exclusivity took effect:

   ```bash
   ls -l /mnt/user/isos              # -> symlink to ../zfs/isos
   stat -c '%i %n' /mnt/user/isos /mnt/zfs/isos   # identical inode (34 here)
   cat /etc/exports                  # contains "/mnt/zfs/isos", NOT /mnt/user/isos
   exportfs -v                       # fsid=103 still present
   ```

   **Acceptance gate:** the inode of `/mnt/user/isos` must equal
   `/mnt/zfs/isos`. If it does not, exclusivity did not apply (check that the
   share exists on no other volume) — stop and fix before proceeding.
   Measured on 2026-11-16: `34` on both, down from the synthetic
   `15762598695796770`.

   **The export path changes, and clients must follow it.** unRAID resolves the
   symlink when generating `/etc/exports`, so the share is exported as
   `/mnt/zfs/isos`. A client still mounting `NAS:/mnt/user/isos` now gets
   `mount.nfs: ... No such file or directory`. Update `storage.cfg` / `fstab`
   to the real path. This is a one-time change.

   **Binding caveat:** an exclusive share is presented as a *symlink*. Docker
   bind mounts that reference a whole directory (`-v /mnt/user:/array`) will
   follow the symlink and misbehave; bind mounts that reference the share
   itself (`-v /mnt/user/isos:/isos`) resolve correctly. Audit containers that
   mount `/mnt/user` wholesale before enabling this.

5. Remount each client **once**. This remount is expected and unavoidable: the
   export identity genuinely changes from FUSE inode to ZFS inode, so the old
   file handle is invalid by construction. On Proxmox: `umount /mnt/pve/ISO`,
   then let `pvestatd` remount.

6. Reboot the NAS again and verify the inode is unchanged and the client mount
   recovers **without** a remount. This second reboot is the actual acceptance
   test; the first one is the migration.

Rollback: set `Permit Exclusive Shares` back to `No`, restart the array. Data is
untouched; only the `/mnt/user` presentation changes.

### Phase 2 — Stop binding NFS to the tailnet

**Applied 2026-11-16.** Editing `/boot/config/network-extra.cfg` alone does
**not** work: unRAID's Tailscale plugin (`unraid-tailscale-utils/System.php`)
re-adds `tailscale1` from its own `INCLUDE_INTERFACE` setting every time
Tailscale starts. The authoritative knob is the plugin setting.

1. Disable the plugin's interface inclusion (this is the "Adds tailscale
   interface to Unraid services" option on the Tailscale settings page):

   ```
   # /boot/config/plugins/tailscale/tailscale.cfg
   INCLUDE_INTERFACE="0"
   ```

   `unraid-tailscale-utils/System.php` then *removes* `tailscale1` instead of
   adding it, and skips `restartSystemServices()`.

2. Clear the bind list:

   ```bash
   # /boot/config/network-extra.cfg
   include_interfaces=""
   exclude_interfaces=""
   ```

3. Apply in a maintenance window:

   ```bash
   /etc/rc.d/rc.rpc restart
   /etc/rc.d/rc.nfsd update
   ss -lntp | grep 2049            # expect only 192.168.1.40 and 127.0.0.1
   grep BIND /etc/default/nfs      # expect -H 192.168.1.40 -H 127.0.0.1
   ```

   Note: `rc.nfsd update` is **not** idempotent in unRAID 7.4 — every call
   restarts NFSD and starts a new grace period, even when the list matches.
   Do not call it routinely; it is not a health check.

**Why this matters:** the plugin's `restartSystemServices()` runs
`/usr/local/emhttp/webGui/scripts/reload_services`, whose `SERVICES` list is
`rpc nfsd ntpd nginx sshd avahidaemon samba`. That is what restarted NFSD ~1
minute after the array started and produced the second grace period.

**Trade-off (accepted):** unRAID's bind list is global. With
`INCLUDE_INTERFACE="0"`, nginx:443, sshd:22 and smbd:139/445 no longer bind
`100.70.225.21`, so the WebUI/SMB/SSH are LAN-only. Tailscale itself keeps
running (tailnet presence, exit node). For remote access use `tailscale serve`
against localhost, or re-enable the setting and accept the NFSD restarts.

Rollback: `INCLUDE_INTERFACE="1"`, restore `network-extra.cfg` from
`network-extra.cfg.bak-20261116`, then
`/usr/local/emhttp/webGui/scripts/reload_services` (or reboot).

### Phase 3 — Tighten exports and Proxmox content types

`/etc/pve/storage.cfg` — remove VM-disk content from NFS:

```
nfs: ISO
	export /mnt/zfs/isos
	path /mnt/pve/ISO
	server 192.168.1.40
	content iso,vztmpl,snippets,import
	options vers=4.1,proto=tcp,hard,timeo=600,retrans=5,noatime
	prune-backups keep-all=1
```

Note the export path: after Phase 1 it is the **real pool path**, not
`/mnt/user/isos`. This block is already applied on `prx-prd-01` (2026-11-16);
only the export path and content types were changed.

Apply with `pvesm set ISO --content iso,vztmpl,snippets,import` (or edit and
remount). **Never** put `images`/`rootdir` on a NAS-backed NFS store that has no
HA: a VM disk on a hard NFS mount turns a NAS reboot into a VM I/O stall, and a
stale handle into data loss.

unRAID share NFS rules — replace the current world-writable exports:

| Share | Current | Proposed |
|---|---|---|
| `isos` | `*(rw,async,no_subtree_check,all_squash,anonuid=99,anongid=100)` | `192.168.1.0/24(rw,async,no_subtree_check,all_squash,anonuid=99,anongid=100)` |
| `backups` | same, `*` | `192.168.1.9(rw,sync,no_subtree_check,all_squash,anonuid=99,anongid=100)` |
| `appdata` | `*(rw,async,no_subtree_check,no_root_squash)` | **remove export**, or restrict to the Docker nodes with the narrowest rule that works |

`no_root_squash` to `*` on `appdata` lets any LAN host write container configs as
root. That is a privilege-escalation path and should not survive this change.

### Phase 4 — Stale-mount watchdog (safety net, not the fix)

Even with stable handles, an export rebuild or a `fsid` change can produce a
genuinely stale handle. The watchdog converts that into a 25-second blip instead
of a multi-day outage.

`/usr/local/sbin/nfs-stale-guard` (Proxmox, and the same on Linux clients with
the mount unit name substituted):

```bash
#!/bin/bash
# Unmount NFS mounts whose root returns ESTALE. Proxmox/systemd remount.
set -uo pipefail
MOUNTS=${MOUNTS:-"/mnt/pve/ISO"}
LOG=/var/log/nfs-stale-guard.log
exec 9>/run/nfs-stale-guard.lock; flock -n 9 || exit 0

for m in $MOUNTS; do
  out=$(timeout -k 1 5 stat -c %i "$m" 2>&1) && continue
  # timeout (server down) -> do nothing, the hard mount resumes on its own
  [[ $? -eq 124 ]] && { echo "$(date -Is) $m probe timeout, not acting" >>$LOG; continue; }
  if grep -qi 'stale file handle' <<<"$out"; then
    echo "$(date -Is) $m ESTALE, unmounting" >>$LOG
    umount "$m" 2>>$LOG || umount -l "$m" 2>>$LOG
  fi
done
```

`/etc/systemd/system/nfs-stale-guard.service` + `.timer` (every 2 min):

```ini
[Unit]
Description=Unmount stale NFS mounts
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nfs-stale-guard
```

```ini
[Unit]
Description=Run nfs-stale-guard every 2 minutes
[Timer]
OnBootSec=3min
OnUnitActiveSec=2min
[Install]
WantedBy=timers.target
```

Guard rails:

- **Only** enable it for mounts that carry no VM disks (ISO, templates, backup
  targets, application data with its own client-side recovery). Unmounting a
  mount that holds a running VM's disk is worse than the outage.
- It acts on `ESTALE` only; timeouts are logged and ignored, so a NAS reboot does
  not cause a churn of unmounts.
- `flock` prevents overlap; a probe stuck in `D` state cannot pile up unbounded.

### Phase 5 — Optional: Docker/appdata over NFS

Only if Docker data must be shared across hosts:

- Move `appdata` to the `zfs` pool (Primary `zfs`, Secondary `none`) so it
  qualifies as exclusive. Requires Docker stopped, `rsync -aH`, then switch the
  share setting, then verify the inode gate from Phase 1.
- Or keep `appdata` on the array and **do not export it**; the two `fstab`
  entries on `talos-01`/`talos-02` are already commented out, so nothing depends
  on it today.
- Array-only shares cannot be exclusive; a single-disk array share can be
  exported by its real path (`/mnt/disk1/appdata`) but unRAID does not generate
  that export, so it needs a post-array-start hook. Prefer the pool move.

### Rollback summary

| Phase | Rollback | Risk |
|---|---|---|
| 1 | `Permit Exclusive Shares: No`, restart array | None to data; `/mnt/user` reverts |
| 2 | Restore `network-extra.cfg`, restart services | Brief nfsd restart |
| 3 | Restore `storage.cfg` / share rules, remount | None |
| 4 | `systemctl disable --now nfs-stale-guard.timer` | None |
| 5 | Move share back to array | Requires Docker stop; keep source until validated |

---

## 9. Failure-injection test plan

Run in a maintenance window. Record `stat -c '%i'` on the export root **before
and after** each test — an unchanged inode is the pass signal.

| # | Test | Procedure | Pass criteria |
|---|---|---|---|
| T1 | NAS reboot | `reboot` on tower; wait for array + NFS | Existing Proxmox mount never goes stale; `stat` works after the server returns; no `umount` needed |
| T2 | NFS service restart | `/etc/rc.d/rc.nfsd restart` | Clients survive the 90 s grace; no remount; `pvesm status` stays `active` |
| T3 | Network interruption | `ip link set br0 down` on tower for 30 s, then up | I/O resumes; no `ESTALE`; `nfsstat -c` retrans increments only |
| T4 | Long network interruption | Same, 10 min (> lease) | Session re-established; handles still valid; no remount |
| T5 | Proxmox reboot | `reboot` prx-prd-01 | `ISO` active within one `pvestatd` cycle; mount options match `storage.cfg` |
| T6 | Linux client reboot | Reboot a client with a systemd mount | Mount active at boot; no manual step |
| T7 | Array stop/start (no reboot) | Stop and start the array | Export root inode unchanged; clients unaffected |
| T8 | Temporary unavailability | Stop the array for 5 min, restart | Clients resume without remount |
| T9 | Deliberate stale handle | Change the export `fsid` (e.g. 103→113), `exportfs -r` | Watchdog unmounts; Proxmox remounts ≤2 min; data intact |
| T10 | Concurrent access + locking | `flock` loop on two clients, 5 min, plus `fsx`/`fio` verify | No lock errors, no corruption, `fio --verify` clean |
| T11 | Client reconnect during write | `fio` write + `umount -l`/remount | No corruption; `fio` reports clean or fails loudly |
| T12 | Boot-order race | Reboot NAS, capture `rc.nfsd status`, `/proc/fs/nfsd/threads`, `ss -lntp \| grep 2049`, `rpcinfo -p localhost` at +30 s | nfsd up, 32 threads, port bound to LAN only, no `errno 107` |

T9 is the only test that intentionally breaks handles; it validates the
watchdog. T1, T7 and T12 validate the actual fix.

---

## 10. Acceptance criteria

1. `stat` on the export root returns the same inode before and after a NAS
   reboot (Phase 1 gate, repeated after two reboots).
2. `pvesm status` reports `ISO` **active** within 5 minutes of a NAS reboot,
   with no operator action.
3. No `Stale file handle` on any client after T1–T8.
4. No manual `umount` or `mount` required in normal operation.
5. `nfsstat -m` shows `hard`, `vers=4.1` (or 4.2), `proto=tcp` on every client.
6. Concurrent `flock` + `fio --verify` clean across two clients.
7. `ss -lntp | grep 2049` on the NAS shows only LAN/loopback addresses.
8. No `svc: failed to register ... (errno 107)` in the boot log.
9. New alert fires within 3 minutes when an export is made unreachable.
10. Rollback of Phase 1 restores the previous behaviour (proves reversibility).

---

## 11. Monitoring and alerting

| Check | Where | Threshold | Alert |
|---|---|---|---|
| `timeout 5 stat /mnt/pve/ISO` | prx-prd-01 | non-zero for 3 consecutive runs | page |
| `pvesm status` | prx-prd-01 | `ISO != active` for 3 min | page |
| `rpcinfo -t 192.168.1.40 100003 4` | monitoring host | 2 failures | warn |
| `nfsstat -c` retrans | clients | > 5 % of RPC calls over 15 min | warn |
| `ss -lntp \| grep 2049` | tower | no listener on 192.168.1.40 | page |
| `cat /proc/fs/nfsd/threads` | tower | 0 | page |
| ZFS pool health | tower | not `ONLINE` | page |
| Export root inode | tower | changes between boots | page (regression signal) |

The last one is the early-warning indicator for this specific defect: if the
inode of an export root ever changes across a reboot, the design has regressed.

---

## 12. Security findings (out of scope but must not be ignored)

1. `appdata` is exported to `*` with `no_root_squash` and `async`. Any host on
   the LAN can write container configuration as root. Remove this export or
   restrict it.
2. All three exports use `*`. Replace with `192.168.1.0/24` or explicit hosts.
3. `sec=sys` only; NFSv4 with `krb5` is not configured. For a homelab this is an
   accepted trade-off, but it means NFS trusts the network. Keep NFS on the LAN
   and off the tailnet.
4. `backups` uses `async`. A NAS power loss can lose acknowledged writes. Use
   `sync` for backup targets and anything that must survive a crash.
5. Proxmox `ISO` currently allows `images` and `rootdir` content. Narrow it.

---

## 13. Open questions

1. **Boot-time RPC start** — **answered 2026-11-16.** Boot log now survives (UPS
   flood fixed). NFSD starts **4 times per boot** (4 grace periods) and logs
   `svc: failed to register nfsdv3 RPC service (errno 107)`. Cause: `tailscale1`
   in the bind list. See §14 and Phase 2.
2. **Does exclusive-share NFS export resolve to the real path on 7.4.0?** —
   **answered: yes.** unRAID writes `"/mnt/zfs/isos" -fsid=103,...` into
   `/etc/exports`. Clients must use the real path; `/mnt/user/isos` no longer
   strips as an NFS export (`ENOENT` on mount).
3. **`appdata` NFS requirement** — if Docker data must be shared, move it to the
   pool (Phase 5); otherwise drop the export.
4. **UPS USB enumeration loop** — a separate defect (device re-enumerating every
   ~8 s), which was evicting the NFS boot evidence. Root-caused and fixed on
   2026-11-14: CyberPower firmware resets the USB interface until a driver
   claims it, and `usbhid-ups` was losing the race. See
   `docs/runbooks/nut-ups-shutdown.md` → "UPS USB device disconnects/reconnects
   every ~10 s".

---

## 14. Validation results — 2026-11-16

Two real reboot cycles of `tower.local`, monitored continuously from
`prx-prd-01` (2 s port probe + `stat`, kernel and `pvestatd` journals).

### Reboot 1 — migration (expected to break the old handle)

| | Result |
|---|---|
| Inode before | `15762598695796770` (`0x38<<48 \| 34`, FUSE) |
| Inode after | `34` (real ZFS) |
| Client log | `fileid changed ... expected 0x38000000000022, got 0x22` |
| Storage | stale, then `pvesm` failed to remount: `mounting 192.168.1.40:/mnt/user/isos ... No such file or directory` |
| Action | one-time `umount`, `storage.cfg` export → `/mnt/zfs/isos`, content narrowed |

This is inherent to the change: the export identity changes from FUSE inode to
ZFS inode. It is **not** a regression.

### Reboot 2 — acceptance (no config change)

| | Result |
|---|---|
| Inode before / after | `34` / `34` |
| `fileid changed` / `ESTALE` | **none** |
| Mount survived | yes — no remount, no operator action |
| Unreachable window | 09:22:05 → 09:28:02 (NAS down); NFSD up 09:29:24 |
| Client healthy again | 09:29:50 — ~26 s after NFSD, after the 90 s grace period expired |
| `ls` during grace | returned `ENOENT`; `stat` returned a **cached** inode — both misleading |
| `pvesm status` | `active`, 4.1 TiB, mount `192.168.1.40:/mnt/zfs/isos` |
| Write test | 8 MiB `dd` + `sync` + read-back, clean |
| Docker | 13/13 containers back |
| VMs | `PBS` running, `192.168.1.5:8007` reachable |
| NUT | `OL`, **0** USB disconnects after reboot (udev rule worked) |
| Boot NFS log | captured (previously evicted by the UPS loop) |

### Issue found in the test: NFSD starts 4 times per boot

```
[162s] NFSD: starting 90-second grace period
[169s] NFSD: starting 90-second grace period
[192s] svc: failed to register nfsdv3 RPC service (errno 107).   (x6)
[~250s] NFSD: starting 90-second grace period                (rc.nfsd update)
[~250s] NFSD: starting 90-second grace period
```

Syslog shows the trigger explicitly:

```
09:29:49 rc.nfsd: /usr/sbin/rpc.nfsd -u -H 192.168.1.40 -H 127.0.0.1 -H 100.70.225.21 -H fd7a:... -s 32
09:30:40 rc.nfsd: Updating NFS server daemon...
09:30:40 rc.nfsd: Restarting NFS server daemon...
```

`tailscale1` gets its address ~70 s after the array starts; `check()` then
returns a different `BIND`, and `nfsd_update` restarts NFSD. Each restart forces
a fresh 90 s grace period. The client rode through it silently in this test, but
it doubles the recovery window and produces the `errno 107` noise.

Fix = Phase 2 (remove `tailscale1` from `/boot/config/network-extra.cfg`).
Trade-off: unRAID's bind list is global, so SMB/SSH/WebUI also stop binding to
the tailnet address. Not applied — needs a decision.

### Phase 2 result (2026-11-16, later the same day)

Applied via the Tailscale plugin (`INCLUDE_INTERFACE="0"`) plus an empty
`network-extra.cfg`. NFSD and rpcbind now bind only `192.168.1.40` and
`127.0.0.1`.

- First attempt by editing `network-extra.cfg` alone was **reverted 40 s after
  boot** by `unraid-tailscale-utils/System.php`, which enforces
  `include_interfaces="tailscale1"` from the plugin setting.
- The plugin's `restartSystemServices()` runs
  `/usr/local/emhttp/webGui/scripts/reload_services`
  (`rpc nfsd ntpd nginx sshd avahidaemon samba`). That is the caller that
  restarted NFSD at 10:04:16 and produced the extra grace period.
- With `INCLUDE_INTERFACE="0"` the plugin no longer adds the interface and no
  longer calls `reload_services`.
- `rc.nfsd update` is **not** idempotent: three manual calls produced three
  restarts (grace 5 → 8). It must not be used as a routine refresh.
- Client unaffected throughout: `ls` OK, inode 34, storage `active`, 4 MiB
  write+sync clean after each restart.

Residual: at the next reboot, `nginx:443`, `sshd:22` and `smbd:139/445` will
stop listening on `100.70.225.21` (they still hold the old sockets now). This
is the accepted trade-off; rollback is in the Phase 2 section.

### appdata exclusivity + subdirectory mount (2026-11-16 evening)

Finished Phase 1 for `appdata` and tested a subdirectory export from a cloud
client.

| Step | Result |
|---|---|
| `/mnt/disk1/appdata` | empty, `rmdir` |
| `zfs/appdata` | empty dataset; `zfs destroy` blocked ("dataset is busy") by shfs and by Docker container mount namespaces |
| Workaround | `zfs rename zfs/appdata zfs/zz-appdata-old` (succeeded), then the share had one branch; shfs re-evaluated on its own and `/mnt/user/appdata` became a symlink |
| `zfs/zz-appdata-old` | destroyed after the rename, no data loss (96 K, empty) |
| Inode gate | `34` == `34` |
| `/etc/exports` | regenerated at next boot as `"/mnt/fast/appdata" -fsid=105,...` |

`mdcmd stop` is **not** usable to stop the array while services hold it
(`write error: Device or resource busy`); an OS reboot is the practical path.

Subdirectory export tested from `talos-cloud-00` (public cloud VM, reaches the
NAS through Tailscale; unRAID advertises `192.168.1.40` as a route):

```
mount -t nfs4 -o vers=4.1,proto=tcp,hard,timeo=600,retrans=5,noasync=... \
  192.168.1.40:/mnt/fast/appdata/arcane/projects /mnt/arcane-projects
# clientaddr=100.116.205.94, inode 35924, uid 1000 writes OK
```

NFSv4 resolves subpaths inside the exported tree, so no extra export entry is
needed. This works **without** re-enabling the tailnet bind, because the
destination address is still the LAN IP `192.168.1.40`.

Reboot test with both clients mounted (`isos` on prx-prd-01, `arcane/projects`
on talos-cloud-00):

| | prx-prd-01 | talos-cloud-00 |
|---|---|---|
| Mount survived | yes | yes |
| Remount needed | no | no |
| Inode before/after | 34 / 34 | 35924 / 35924 |
| Storage state | `ISO` active | `ls` + write OK |
| `fileid changed` | none | none |
| Grace periods this boot | **1** | — |
| `errno 107` | **0** | — |

**Nuance discovered:** the cloud client logged `ESTALE` for ~18 s *during the
NAS shutdown* (16:41:08–16:41:23), while the port still accepted connections
but the export had been removed. It recovered on its own after the reboot
because the identity (`fsid=105` + inode `35924`) was unchanged. So `ESTALE`
is permanent only when the identity actually changes; `ESTALE` from a
temporary export removal is recoverable.

---

## 15. References

- unRAID 7.2.0 release notes — "Improvement: Exclusive shares may be selected
  for NFS export" — <https://docs.unraid.net/unraid-os/release-notes/7.2.0/>
- unRAID 7.4.0 release notes (kernel 6.18.60, no NFS fixes) —
  <https://docs.unraid.net/unraid-os/release-notes/7.4.0/>
- unRAID docs, Shares / exclusive shares —
  <https://docs.unraid.net/unraid-os/using-unraid-to/manage-storage/shares/>
- unRAID forum — NFS best practices, shfs inode behaviour —
  <https://forums.unraid.net/topic/185576-working-with-nfs-on-unraid-best-practices/>
- unRAID forum — `fileid changed` on an export root after array restart —
  <https://forums.unraid.net/topic/143578-nfs-stale-file-handle-on-the-root-directory-of-a-shared-folder/>
- unRAID forum — shfs inode = branch inode, `fuse_remember` rationale —
  <https://forums.unraid.net/topic/65720-shfs-memory-leak/page/4/>
- Proxmox `PVE::Storage::NFSPlugin` (`nfs_is_mounted`, `activate_storage`) —
  `/usr/share/perl5/PVE/Storage/NFSPlugin.pm` on prx-prd-01
