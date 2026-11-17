# NFS Diagnostic & Recovery Runbook — unRAID (tower.local) ↔ Proxmox / Linux

*Applies to: unRAID 7.4.0 (`tower.local`, 192.168.1.40), Proxmox `prx-prd-01` (192.168.1.9), Linux clients*
*Created: 2026-11-13 · See design: `docs/superpowers/specs/2026-11-13-unraid-nfs-reliability-design.md`*

---

## 0. Read this first

There are **two different failures** that look similar and need opposite
responses:

| Symptom | Meaning | Correct action |
|---|---|---|
| `stat` returns **Stale file handle** immediately | The handle is dead. Nothing will fix it. | **Unmount.** Proxmox remounts in ≤25 s. |
| `stat` **hangs** / `server not responding` | The server is down or unreachable. | **Wait.** A hard mount resumes on its own. Do not unmount. |

Unmounting during an ordinary NAS reboot turns a transparent recovery into a
manual one. Only unmount on `ESTALE`.

`ESTALE` on unRAID NFS is almost always caused by the export root living under
`/mnt/user` (FUSE). See the design doc.

---

## 1. Triage (2 minutes)

Run on the **client**:

```bash
timeout 5 stat -c '%i %n' /mnt/pve/ISO
```

| Result | Go to |
|---|---|
| inode printed | Healthy |
| `Stale file handle`, fast | §4.1 |
| times out (exit 124) | §4.2 |
| `No such file or directory` | §4.3 |
| `Permission denied` | §4.4 |

Then confirm the server is actually serving:

```bash
rpcinfo -t 192.168.1.40 100003 4
# expect: program 100003 version 4 ready and waiting
```

- `rpcinfo` OK **and** client `ESTALE` → client-side stale mount → §4.1.
- `rpcinfo` fails → server-side → §5.

---

## 2. Server checks (tower.local)

```bash
ssh root@192.168.1.40
```

### 2.1 Service up?

```bash
cat /proc/fs/nfsd/threads          # expect: 32 (0 = nfsd not serving)
cat /proc/fs/nfsd/versions         # expect: +3 +4 -4.0 +4.1 +4.2
ss -lntp | grep 2049               # expect: 192.168.1.40:2049 and 127.0.0.1:2049
rpcinfo -p localhost               # nfs v3+v4, mountd, nlockmgr, status
ps -eo pid,lstart,cmd | grep -E 'rpc\.|nfsd' | grep -v grep
```

Healthy baseline on this host:

```
2049/tcp  LISTEN  192.168.1.40:2049
2049/tcp  LISTEN  127.0.0.1:2049
rpcbind, rpc.statd --no-notify, rpc.mountd, rpc.idmapd, nfsdcld + 32 [nfsd]
```

### 2.2 Exports present?

```bash
cat /etc/exports
exportfs -v
cat /var/lib/nfs/etab
```

Expect `fsid=103` (isos), `fsid=106` (backups), `fsid=105` (appdata).

### 2.3 The FUSE check — run this whenever handles look unstable

```bash
stat -c '%d %i %n' /mnt/user/isos /mnt/zfs/isos
cat /etc/exports | grep isos
```

- **Same inode** (currently `34`) and `/etc/exports` names `/mnt/zfs/isos` →
  correct, FUSE is out of the NFS path.
- **Different inode**, `/mnt/user` inode looks like `(N << 48) | small` →
  export is going through `fuse.shfs`; handles will break on the next array
  restart.

```bash
ls -l /mnt/user/isos      # symlink => exclusive share, good
findmnt /mnt/user         # fuse.shfs => union view still in play
```

**Since 2026-11-16 the NFS export path is the real pool path**
(`/mnt/zfs/isos`), not `/mnt/user/isos`. Clients must mount the real path;
mounting `/mnt/user/isos` returns `No such file or directory`.

### 2.4 Array / pool health

```bash
mdcmd status | grep -E 'mdState|mdNumDisks'
zpool status
df -h /mnt/zfs /mnt/disk1
```

### 2.5 Boot-time NFS evidence

The kernel ring buffer is routinely evicted by a UPS USB re-enumeration loop.
Use the saved boot logs instead:

```bash
ls -lt /boot/logs/ | head
grep -iE 'nfs|rpc|svc:' /boot/logs/boot-dmesg-<latest>.txt
dmesg | grep -iE 'nfs|rpc|svc:' | tail -30    # current buffer, may be empty
```

`svc: failed to register nfsdv3 RPC service (errno 107)` = `ENOTCONN` while
talking to `rpcbind`. Expected on `rpc.nfsd 0` (stop). Unexpected during start.

---

## 3. Client checks

### 3.1 Proxmox

```bash
pvesm status
findmnt -t nfs,nfs4 -o TARGET,SOURCE,FSTYPE,OPTIONS
nfsstat -m
cat /etc/pve/storage.cfg
journalctl -k -b --no-pager | grep -iE 'nfs|rpc|sunrpc' | tail -40
```

Interpretation:

| Output | Meaning |
|---|---|
| `pvesm status` inactive + `stat` ESTALE, `findmnt` still lists the mount | Stale mount → §4.1 |
| `pvesm status` inactive + mount **absent** | Activation failure → check `rpcinfo`, then let `pvestatd` retry |
| `NFS: server X error: fileid changed` + `expected fileid 0x.., got 0x..` | Export-root handle changed → §4.1 (this is the unRAID FUSE signature) |
| `NFS: state manager: check lease failed ... error 13` | Client lost the lease; self-heals if handles are valid |
| `nfs: server X not responding, timed out` | Server unreachable → §4.2 |
| `ls: cannot access ...: No such file or directory` right after the NAS returns | **Grace period.** Wait ≥90 s (see below) |

Note: `systemctl status mnt-pve-ISO.mount` is **not** a health check. It reports
`active/mounted` for a dead filesystem and has no unit file.

Note: during the post-reboot grace period, `ls` returns `ENOENT` and `stat` can
return the **cached** inode even though the server has no data yet. Neither is a
reliable signal. Measured 2026-11-16: NFSD up 09:29:24, client healthy
09:29:50 — 26 s after NFSD, ~90 s after boot. Judge the mount at least 90 s
after NFSD starts, and prefer `ls` over `stat`.

### 3.2 Linux clients

```bash
findmnt -t nfs,nfs4 -o TARGET,SOURCE,OPTIONS
nfsstat -m
systemctl --failed --type=mount
timeout 5 stat -c '%i %n' <mountpoint>
dmesg | grep -iE 'nfs|stale|fileid' | tail -20
```

`_netdev`, `nofail` and `x-systemd.automount` control **mount activation at
boot**. They do **not** repair an existing stale mount. That needs §4.1.

### 3.3 Mounting a subdirectory of a share

NFSv4 resolves subpaths inside the exported tree, so no extra export entry is
needed. Example: `appdata/arcane/projects` from a cloud client:

```bash
mkdir -p /mnt/arcane-projects
mount -t nfs4 \
  -o vers=4.1,proto=tcp,hard,timeo=600,retrans=5,rsize=1048576,wsize=1048576,noatime \
  192.168.1.40:/mnt/fast/appdata/arcane/projects /mnt/arcane-projects
```

fstab (IP, not DNS, plus `bg` so boot does not depend on name resolution):

```fstab
192.168.1.40:/mnt/fast/appdata/arcane/projects /mnt/arcane-projects nfs4 vers=4.1,proto=tcp,hard,timeo=600,retrans=5,rsize=1048576,wsize=1048576,noatime,_netdev,nofail,bg 0 0
```

Verified 2026-11-16 from `talos-cloud-00` over Tailscale
(`clientaddr=100.116.205.94`, inode `35924`, uid 1000 writes OK). It works even
though NFSD binds only the LAN address, because the destination is still
`192.168.1.40`.

A subdirectory mount is convenience, not isolation: the server still exports
the whole share. Restrict the export host list if you need a boundary.

---

## 4. Recovery procedures

### 4.1 Stale file handle

Preconditions: `stat` returns `ESTALE` **immediately**; the server answers
`rpcinfo`.

Since 2026-11-16 the export root is a real ZFS inode, so a NAS reboot should
**not** produce `ESTALE`. If it does, the export identity has changed again —
check `stat -c '%i' /mnt/user/isos /mnt/zfs/isos` on the NAS and compare with
the baseline (34), and treat a change as a regression (§2.3).

Expected exceptions:

| Situation | Remount needed | Why |
|---|---|---|
| First reboot after enabling exclusive shares | **Yes, once** | Export moves from FUSE inode to ZFS inode |
| Export path changed in `storage.cfg` | Yes, once | Different export |
| Pool rebuilt / dataset recreated | Yes | Inode + generation genuinely new |
| Ordinary NAS reboot | **No** | Handle is stable |
| `ESTALE` **only while the NAS is shutting down** | **No** | Export temporarily removed; identity unchanged, so the old handle becomes valid again when the export returns |

The last row was measured on 2026-11-16: `talos-cloud-00` saw `ESTALE` for ~18 s
between `rpc.nfsd 0` and the host halting, then recovered on its own after the
reboot with the same inode (`35924`). Do not unmount during that window.

1. **Check nothing is using the mount.**

   ```bash
   ls -l /proc/[0-9]*/fd 2>/dev/null | grep -c '<mountpoint>'
   ```

   Must be `0`. If not, stop the consumer first (see §4.1.1).

2. **Unmount.**

   ```bash
   umount /mnt/pve/ISO
   ```

   If `EBUSY`: `umount -l /mnt/pve/ISO` (detach; the mount dies when the last
   user closes). Never `umount -f` on a mount holding VM disks.

3. **Let the platform remount.** Do not mount manually.

   ```bash
   sleep 30 && pvesm status
   ```

   `pvestatd` remounts on its next cycle (measured: 25 s). The new mount picks up
   the options from `storage.cfg`.

4. **Verify.**

   ```bash
   stat /mnt/pve/ISO && grep pve/ISO /proc/mounts
   ```

   #### 4.1.1 If a VM or container is using the mount

   A hard NFS mount that returns `ESTALE` cannot be recovered underneath a
   running guest. Stop the guest first (`qm stop <vmid>` / `pct stop <ctid>`),
   then follow 4.1. This is the reason VM disks must not live on this NFS store.

### 4.2 Server unreachable / I/O hanging

**Do not unmount.** A hard mount is designed to wait.

1. Confirm the NAS is up:

   ```bash
   ping -c3 192.168.1.40
   ssh root@192.168.1.40 'mdcmd status | grep mdState; cat /proc/fs/nfsd/threads'
   ```

2. If the array is stopped, start it (WebUI → Main → Start). NFS follows the
   array.
3. If the array is started but `threads` is `0`:

   ```bash
   /etc/rc.d/rc.rpc start
   /etc/rc.d/rc.nfsd start
   cat /proc/fs/nfsd/threads
   ```

4. Watch the client recover:

   ```bash
   dmesg -w | grep -i nfs     # "server ... OK" then normal I/O
   ```

5. If the client comes back with `ESTALE` instead, go to §4.1.

### 4.3 Mount point missing on the client

`pvestatd` creates `/mnt/pve/<id>` on activation. If it is missing and the
storage cannot activate, verify the parent:

```bash
ls -ld /mnt/pve
pvesm status
```

Do not `mkdir` a path that should be a mountpoint while the mount is supposed to
be active — you will write into the root filesystem.

### 4.4 Permission denied

```bash
exportfs -v                                  # server: check client ACL
id; namei -l /mnt/pve/ISO/some-file          # client: uid/gid mapping
```

`all_squash,anonuid=99,anongid=100` means the server maps every client user to
unRAID `nobody:users`. `no_root_squash` is only on `appdata`.

---

## 5. Server-side repair (NFS not serving after boot)

Symptom: `cat /proc/fs/nfsd/threads` → `0`, or `ss -lntp | grep 2049` empty.

1. Inspect the configured bind list — this is the usual culprit:

   ```bash
   grep BIND /etc/default/nfs
   cat /etc/default/rpc | grep RPCBIND
   cat /boot/config/network-extra.cfg
   ```

   If a tailnet/WireGuard address is listed and that interface is not up, nfsd
   can fail to bind. Confirm:

   ```bash
   ip -br addr show | grep -E 'tailscale|wg'
   ```

2. Start in order and watch each step:

   ```bash
   /etc/rc.d/rc.rpc start
   rpcinfo -p localhost | head
   /etc/rc.d/rc.nfsd start
   cat /proc/fs/nfsd/threads
   ss -lntp | grep 2049
   ```

3. If it still fails, force a clean restart:

   ```bash
   /etc/rc.d/rc.nfsd stop
   /etc/rc.d/rc.rpc restart
   /etc/rc.d/rc.nfsd start
   ```

4. Permanent fix: remove the volatile address from
   `/boot/config/network-extra.cfg`, then `/etc/rc.d/rc.rpc restart` and
   `/etc/rc.d/rc.nfsd update` (see design doc, Phase 2).

---

## 6. Verification after any repair

```bash
# server
cat /proc/fs/nfsd/threads                       # 32
exportfs -v                                     # fsid 103/105/106 present
stat -c '%i %n' /mnt/user/isos /mnt/zfs/isos    # identical after Phase 1

# client
timeout 5 stat /mnt/pve/ISO                     # no ESTALE
pvesm status                                    # ISO active
nfsstat -m                                      # hard, vers=4.1, proto=tcp

# end-to-end write test (non-destructive)
f=$(mktemp /mnt/pve/ISO/.nfs-test.XXXX); dd if=/dev/urandom of=$f bs=1M count=16 status=none
sync; cmp <(dd if=$f bs=1M count=16 status=none) /dev/zero >/dev/null 2>&1; rm -f $f
```

---

## 7. Known-good baseline (2026-11-16)

| Item | Value |
|---|---|
| unRAID | 7.4.0, kernel 6.18.60-Unraid |
| nfsd versions | `+3 +4 -4.0 +4.1 +4.2` |
| nfsd threads | 32 |
| grace / lease | 90 s / 90 s |
| Exports | `/mnt/zfs/isos` fsid 103, `/mnt/zfs/backups` 106, `/mnt/fast/appdata` 105, `/mnt/fast/k8s-data` 107 |
| NFS clients | `isos`: LAN; `appdata`: `*` (to be restricted); `k8s-data`: `192.168.1.11-13` |
| Export root inode | **34** for `isos` and `appdata` (`/mnt/user/<share>` == `/mnt/<pool>/<share>`) |
| Subdir export in use | `192.168.1.40:/mnt/fast/appdata/arcane/projects` → `/mnt/arcane-projects` on talos-cloud-00 (inode 35924) |
| Proxmox mount | `192.168.1.40:/mnt/zfs/isos`, `vers=4.1,proto=tcp,hard,timeo=600,retrans=5,noatime` |
| Proxmox content | `iso,vztmpl,snippets,import` (no VM disks) |
| `/mnt/user` | `fuse.shfs` for `appdata` only; `isos`/`backups`/`system` are symlinks to pools |
| `/mnt/zfs` | ZFS, 2 mirror vdevs, clean scrub |
| `/mnt/disk1` | XFS on `/dev/md1p1` |

---

## 8. Do not do these

| Action | Why |
|---|---|
| `umount -f` on a mount holding VM disks | Kills the guest's I/O; risks corruption |
| `soft` mounts for VM disks or backup targets | Silent short writes, truncated backups, corruption |
| Editing `storage.cfg` and expecting the live mount to change | Options apply only on the next mount; remount explicitly |
| Exporting `/mnt/user/...` for anything long-lived | FUSE handles change on array restart → permanent `ESTALE` |
| Editing `/boot/config/network-extra.cfg` to drop `tailscale1` | The Tailscale plugin re-adds it from `INCLUDE_INTERFACE`; change that setting instead |
| Running `/etc/rc.d/rc.nfsd update` as a refresh | Not idempotent — every call restarts NFSD and starts a new 90 s grace period |
| Trusting `systemctl status mnt-pve-*.mount` | Shadow unit; reports `active` for a dead filesystem |
| Adding NFS on top of a second NFS server pointed at `/mnt/user` | Inherits the same handle instability |
