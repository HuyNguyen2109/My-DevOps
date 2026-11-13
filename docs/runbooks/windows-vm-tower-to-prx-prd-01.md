# Windows Server 2025 — tower.local (libvirt) → prx-prd-01 (Proxmox)

*Date: 2026-11-13 | Applies to: WS2025-Inspect-Lab, tower.local, prx-prd-01 (192.168.1.9)*

---

## Summary

Migrated the `WS2025-Inspect-Lab` Windows Server 2025 VM off the unRAID/libvirt
host (`tower.local`) onto the production Proxmox node `prx-prd-01`
(`192.168.1.9`, PVE 9.2.26) as VMID **102**, keeping the guest's static IP and
halving vCPU while shrinking the virtual disk to 128 GiB.

| Item | Before (tower.local) | After (prx-prd-01) |
|------|----------------------|--------------------|
| Hypervisor | libvirt/KVM (unRAID) | Proxmox VE 9.2.26 |
| VMID / name | domain `WS2025-Inspect-Lab` | `102` / `WS2025-Inspect-Lab` |
| vCPU | 8 (4 cores × 2 threads) | **4** (1 socket × 4 cores) |
| RAM | 8192 MB | **8192 MB** |
| Disk | 256 GiB raw (64 GiB used) | **128 GiB qcow2**, `local` storage |
| Firmware | OVMF, no Secure Boot, TPM 2.0 | OVMF 4M, `pre-enrolled-keys=0`, TPM 2.0 |
| NIC | virtio, `52:54:00:c9:f4:0e` | virtio, same MAC, `vmbr0` |
| IP | 192.168.1.252/24, gw .1, DNS .3/.4 | **unchanged** |
| Disk bus | virtio-blk | `virtio0` (same driver) |
| Autostart | enabled | enabled on PVE, disabled on source |

## Why the disk is 128 GiB

`C:` was 254.94 GiB with 80 GiB used. Shrinking to 128 GiB required, inside the
guest, before shutdown:

1. `reagentc /disable` (move WinRE into `C:\Windows\System32\Recovery`).
2. `Resize-Partition -DriveLetter C -Size 136137670656` (126.79 GiB).
3. Replace the old 865 MB recovery partition (it sat at the 255 GiB mark) with a
   **1023 MB** recovery partition at `136365211648`, leaving **1 MiB of slack**
   at the end of the disk for the GPT backup header. Ending the partition
   exactly at the 128 GiB boundary makes Windows drop it as invalid.
4. Recreate + format + `gpt attributes=0x8000000000000001`, then
   `reagentc /enable`.

Host side: `qemu-img convert -O qcow2` then `qemu-img resize --shrink 128G`.
The source raw disk was **not** modified (kept for rollback).

## Procedure (reproducible)

```bash
# 0. Source backup
ssh root@192.168.1.40 'virsh dumpxml WS2025-Inspect-Lab > /root/ws2025-migration-backup/WS2025-Inspect-Lab.xml'
# also back up /etc/libvirt/qemu/nvram/<uuid>_VARS-pure-efi-tpm.fd and /var/lib/libvirt/swtpm/<uuid>/

# 1. Guest partition work (online, via qemu-guest-agent)
#    reagentc /disable -> shrink C: -> replace recovery partition -> reagentc /enable
#    Verify: 4 partitions, C: 126.79 GiB, recovery at 136365211648 size 1072693248

# 2. Shut down and disable source autostart
virsh autostart --disable WS2025-Inspect-Lab
virsh shutdown WS2025-Inspect-Lab          # wait for "shut off"

# 3. Convert + shrink on tower (source raw file untouched)
qemu-img convert -p -O qcow2 \
  /mnt/user/domains/WS2025-Inspect-Lab/vdisk1.img \
  /mnt/fast/domains/WS2025-Inspect-Lab/migrate-128g.qcow2
qemu-img resize --shrink /mnt/fast/domains/WS2025-Inspect-Lab/migrate-128g.qcow2 128G
qemu-img check /mnt/fast/domains/WS2025-Inspect-Lab/migrate-128g.qcow2   # no errors

# 4. Copy to PVE (tar -S preserves the qcow2 holes)
ssh root@192.168.1.40 'tar -S -cf - -C /mnt/fast/domains/WS2025-Inspect-Lab migrate-128g.qcow2' \
  | ssh root@192.168.1.9 'tar -S -xf - -C /var/lib/vz/images/102'
mv /var/lib/vz/images/102/migrate-128g.qcow2 /var/lib/vz/images/102/vm-102-disk-2.qcow2
chown root:root /var/lib/vz/images/102/vm-102-disk-2.qcow2
chmod 600 /var/lib/vz/images/102/vm-102-disk-2.qcow2

# 5. Create the VM (disk-0 = efidisk, disk-1 = tpmstate, disk-2 = data)
qm create 102 --name WS2025-Inspect-Lab --ostype win11 --machine q35 --bios ovmf \
  --efidisk0 local:0,efitype=4m,pre-enrolled-keys=0 \
  --tpmstate0 local:0,version=v2.0 \
  --cpu host --sockets 1 --cores 4 --memory 8192 \
  --net0 virtio=52:54:00:c9:f4:0e,bridge=vmbr0 \
  --vga qxl --agent enabled=1 --onboot 1
qm set 102 --virtio0 local:102/vm-102-disk-2.qcow2,cache=writeback,discard=on
qm set 102 --boot order=virtio0
qm start 102
```

## Gotchas (read before repeating)

- **Windows re-enumerates the NIC.** Moving the virtio NIC to a different PCI
  slot creates a new adapter (`Ethernet 3`) with DHCP; the old static config
  stays on a ghost `Ethernet 2`. Re-apply inside the guest:

  ```powershell
  $idx = (Get-NetAdapter | ? MacAddress -eq '52-54-00-C9-F4-0E').InterfaceIndex
  Remove-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -Confirm:$false
  Remove-NetRoute    -InterfaceIndex $idx -AddressFamily IPv4 -Confirm:$false
  New-NetIPAddress   -InterfaceIndex $idx -IPAddress 192.168.1.252 -PrefixLength 24 -DefaultGateway 192.168.1.1
  Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses 192.168.1.3,192.168.1.4
  Set-NetConnectionProfile   -InterfaceIndex $idx -NetworkCategory Private
  ```

- **Recovery partition vs. GPT backup.** A partition ending exactly at the
  virtual disk end overlaps the 33-sector GPT backup area; Windows silently
  drops it and WinRE breaks. Leave ≥1 MiB slack.
- **WinRE image.** If `Winre.wim` is missing after replacing the partition,
  copy it from the source disk's recovery partition (mounted read-only with
  `mount -t ntfs3 -o ro,loop,offset=136365211648 ...`) and restore it:
  `reagentc /setreimage /path C:\Windows\System32\Recovery` → `reagentc /enable`.
- **NVMe throughput collapse.** prx-prd-01's 512 GB NVMe (LENSE20512GMSP34MEAT2TA)
  fell to ~12 MB/s after ~50 GiB of writes. `fstrim -v /` (159 GiB trimmed)
  restored ~800 MB/s. Check `findmnt -no OPTIONS /` — the root fs has no
  `discard`; rely on `fstrim.timer`.
- **Secure Boot errors in the log are expected**: the source used OVMF without
  Secure Boot, and the new efidisk uses `pre-enrolled-keys=0`.

## Verification

- `ping 192.168.1.252` — blocked by Windows Firewall by default; use TCP 3389.
- `qm guest cmd 102 network-get-interfaces` → 192.168.1.252/24.
- In-guest: 4 logical processors, 7.9 GB RAM, Disk 0 = 128 GB GPT,
  C: 126.79 GB (≈47 GB free), WinRE Enabled, LicenseStatus = 1 (Licensed).
- `qm config 102`: 4 cores, 8192 MB, MAC unchanged, `virtio0` 128G.

## Rollback

Source VM and raw disk are intact on tower.local; the guest partition table was
shrunk but Windows still boots on the 256 GiB virtual disk.

```bash
ssh root@192.168.1.9 'qm shutdown 102'          # stop the migrated VM first
ssh root@192.168.1.40 'virsh start WS2025-Inspect-Lab'
```

Re-enable source autostart if rolling back permanently:
`virsh autostart WS2025-Inspect-Lab`.

## Follow-ups

- Source VM/disk kept as rollback; delete after a burn-in period and re-enable
  nothing on tower.local.
- `local` storage has ~60 GB free after the import (128 GiB qcow2, ~80 GiB
  allocated). Watch it before adding snapshots.
- Windows may need reactivation on future hardware changes; currently Licensed.
