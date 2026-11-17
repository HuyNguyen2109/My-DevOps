# NUT UPS Shutdown — Configuration & Troubleshooting

*Date: 2026-05-28 | Applies to: tower.local (master), proxmox-00, talos-01, talos-02*

---

## Architecture

```
UPS hardware (VP1200ELCD, USB)
  └─ usbhid-ups driver
       └─ upsd (tower.local:3493)
            ├─ upsmon master (tower.local) + nut-notify (40% poller)
            ├─ upsmon slave (proxmox-00) → SHUTDOWNCMD
            ├─ upsmon slave (talos-01)   → SHUTDOWNCMD
            └─ upsmon slave (talos-02)   → SHUTDOWNCMD
```

### 40% Shutdown Mechanism (unRAID nut-dw plugin)

The 40% threshold is **NOT** a native NUT feature. It is implemented by the `nut-dw` plugin:

1. `NOTIFYFLAG ONBATT SYSLOG+EXEC` triggers `/usr/sbin/nut-notify`
2. `nut-notify` polls `battery.charge` every second while on battery
3. At ≤40%, it runs `upsmon -c fsd` (Forced Shutdown Directive)
4. FSD propagates to all connected slaves → each runs `SHUTDOWNCMD`

The native NUT `LB` flag (`battery.charge.low`) is set to 40% as a second-line safety net via `override.battery.charge.low = 40` in `ups.conf`.

### Key Credentials

| User | Password | Role |
|------|----------|------|
| `admin` | `adminpass` | Full control (`instcmds = all`, `actions = set/fsd`) |
| `monuser` | `Master2109` | Master upsmon (tower.local) |
| `slaveuser` | `Master2109` | Slave upsmon (proxmox-00, talos-01, talos-02) |

UPS name: `VP1200ELCD`, driver: `usbhid-ups`, port: `auto`, host: `127.0.0.1`

---

## Configuration Files (tower.local)

### Persistence Model (unRAID nut-dw)

> ⚠️ `/etc/nut/` is ephemeral (initramfs). Changes MUST be made to **both** locations:
>
> | Live (ephemeral) | Persistent (flash) |
> |---|---|
> | `/etc/nut/<file>` | `/boot/config/plugins/nut-dw/ups/<file>` |
>
> On every boot: `doinst.sh` runs `cp -rf $BOOT/ups/* /etc/nut/`, then `write_config()` patches lines 1–8 of `ups.conf` and lines 1/3/8 of `upsmon.conf`. **Lines 9+ in both files survive reboots** and `write_config` patches.

### `/etc/nut/ups.conf` (lines 9+ survive reboots)
```ini
[VP1200ELCD]
driver = usbhid-ups
port = auto
# line 9 (persistent):
override.battery.charge.low = 40
```

Apply changes:
```bash
upsdrvctl stop VP1200ELCD && upsdrvctl start VP1200ELCD
# verify:
upsc VP1200ELCD battery.charge.low   # should return 40
```

### `/etc/nut/upsmon.conf` (lines 9+ survive reboots)
```
# lines 9–10 (persistent):
NOTIFYFLAG LOWBATT SYSLOG+EXEC
NOTIFYFLAG FSD SYSLOG+EXEC
```

Apply changes: `upsmon -c reload`

### `/boot/config/plugins/nut-dw/nut-dw.cfg`
Source of truth for nut-dw GUI settings. Key relevant fields:
```
BATTERYLEVEL="40"
SHUTDOWN="batt_level"
SERVICE="enable"
MODE="netserver"
UPSKILL=disable
```
> Do NOT edit manually unless necessary.

---

## Slave Node Configuration

All slaves use the same upsmon configuration:
```
MONITOR VP1200ELCD@192.168.1.40 1 slaveuser Master2109 slave
SHUTDOWNCMD "/sbin/poweroff"
POLLFREQ 5
DEADTIME 15
FINALDELAY 5
NOCOMMWARNTIME 300
```

Check service status on slaves:
```bash
# proxmox-00
ssh -i $HOME/ssh-keys/homelab-linux root@192.168.1.9 "systemctl status nut-monitor"
# talos-01/02
ssh -i $HOME/ssh-keys/homelab-linux ubuntu@192.168.1.12 "sudo systemctl status nut-monitor"
```

> ⚠️ On talos nodes, `/etc/nut/upsmon.conf` is owned `root:nut 640` — unreadable by `ubuntu` user. Use `sudo cat`.

---

## Bi-Weekly Battery Test Script

**Location (tower.local):** `/boot/config/plugins/user.scripts/scripts/lxc-auto-backup/script`
*(folder misnamed; "name" file = "bi-weekly-ups-battery-check")*

**Repo template:** `scripts/bi-weekly-ups-battery-test.sh`

### Dry Run
```bash
bash script --dry-run
```

### Live Run Requirements
- `NUT_USER` must be `admin` (not `monuser`/`slaveuser` — those lack `instcmds`)
- UPS must be `OL` (on-line) at start
- Battery ≥85% at start
- Must not have run in the last 13 days (bi-weekly gate via statefile)

### Sending Commands
```bash
# Send battery test
upscmd -u admin -p adminpass VP1200ELCD@127.0.0.1 test.battery.start.deep
# Stop test early
upscmd -u admin -p adminpass VP1200ELCD@127.0.0.1 test.battery.stop
# Check status
upsc VP1200ELCD@127.0.0.1
```

### Statefile
Written to `/tmp/bi-weekly-ups-battery-test.state` after each successful run. Note: `/tmp` on unRAID is ephemeral (RAM); statefile is lost on reboot. The script uses the creation time of this file to enforce the 13-day gate.

---

## Troubleshooting

### Symptom: Slaves don't shut down at 40% battery

1. **Verify threshold is set:**
   ```bash
   upsc VP1200ELCD battery.charge.low  # should be 40
   ```
   If not: add `override.battery.charge.low = 40` to `ups.conf` (both paths).

2. **Verify nut-notify is running when on battery:**
   ```bash
   ps aux | grep nut-notify  # should appear when OB
   ```

3. **Verify FSD propagates to slaves:**
   ```bash
   # Simulate FSD (controlled test only!)
   upsmon -c fsd  # on tower.local
   # Monitor slave logs:
   ssh ubuntu@192.168.1.12 "sudo journalctl -u nut-monitor -f"
   ```

4. **Verify slave connectivity:**
   ```bash
   upsc VP1200ELCD@192.168.1.40  # from a slave node
   ```

### Symptom: "Failed to send test.battery.start.deep" permission error

The script is using `monuser` or `slaveuser`. Change `NUT_USER` to `admin`.
Verify: `grep 'instcmds' /etc/nut/upsd.users`

### Symptom: proxmox-00 shows periodic "No route to host" to tower.local

Root cause: USB NIC (`enxc84d44233e49`) r8152 driver periodically performs USB firmware resets.
The bond reselects the USB NIC as primary after each reset, causing brief TCP teardowns.

Mitigation: Existing infrastructure on proxmox-00 handles re-enslavement:
- `/etc/udev/rules.d/99-usb-autosuspend.rules` — disables autosuspend + triggers readd
- `/usr/local/sbin/usb-nic-bond-readd` — re-enslaves and sets USB NIC as primary after reconnect

Monitor USB resets: `dmesg | grep r8152`

### Symptom: UPS USB device disconnects/reconnects every ~10 s, NUT won't start

Log signature:

```
kernel: usb 1-1.x: USB disconnect, device number N
kernel: usb 1-1.x: new low-speed USB device number N+1 using xhci_hcd
kernel: hid-generic 0003:0764:0501....: ... [CPS VP1200ELCD]
rc.nut: No matching HID UPS found
rc.nut: Driver failed to start (exit status=1)
```

**Root cause:** CyberPower firmware resets the USB interface every ~10 s
**until a driver claims the device**. `usbhid-ups` scans once, loses the race
against the reset cycle, exits, and then nothing ever claims the UPS — so the
loop is self-sustaining. It is *not* a cable, port, hub or kernel problem:
moving the port only moves the loop (`1-1.2` → `1-1.3`).

The device number also wraps at 127 and restarts at 4; that is normal.

**Proof of mechanism:** with NUT down, `dmesg | grep -c 'USB disconnect'`
increases ~6/min. Start the driver once and the counter stops immediately:

```bash
/usr/sbin/upsdrvctl -u root start
upsc VP1200ELCD ups.status      # OL
```

**Permanent fix** (survives unRAID's RAM root, installed 2026-11-14):

`/boot/config/udev/99-nut-ups-attach.rules` — unRAID copies `*.rules` from
`/boot/config/udev` to `/etc/udev/rules.d/` and `*.sh` to `/etc/udev/scripts/`
at boot (`rc.S.cont`):

```
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0764", ATTR{idProduct}=="0501", RUN+="/etc/udev/scripts/nut-ups-attach.sh"
```

`/boot/config/udev/nut-ups-attach.sh` — claims the UPS on every enumeration,
starts `upsd`/`upsmon` if they are down:

```bash
#!/bin/bash
exec 9>/run/nut-ups-attach.lock
flock -n 9 || exit 0
pgrep -x usbhid-ups >/dev/null && exit 0
for _ in 1 2 3 4 5; do
    /usr/sbin/upsdrvctl -u root start >/dev/null 2>&1 && break
    sleep 2
done
pgrep -x usbhid-ups >/dev/null || exit 0
pgrep -x upsd   >/dev/null || /usr/sbin/upsd   -u root >/dev/null 2>&1
pgrep -x upsmon >/dev/null || /usr/sbin/upsmon -p        >/dev/null 2>&1
logger -t nut-usb-attach "usbhid-ups attached after UPS re-enumeration"
```

Apply without rebooting:

```bash
install -p -D -m 0644 /boot/config/udev/99-nut-ups-attach.rules /etc/udev/rules.d/
install -p -D -m 0755 /boot/config/udev/nut-ups-attach.sh     /etc/udev/scripts/
udevadm control --reload-rules
udevadm test --action=add /sys/bus/usb/devices/1-1.3 2>&1 | grep nut-ups-attach
```

Verify: `dmesg | grep -c 'USB disconnect'` must stop increasing, and
`upsc VP1200ELCD ups.status` must return a value.

**Do not** "fix" this by unplugging the cable and leaving NUT down: with no
driver there is **no UPS protection at all**, and no graceful shutdown at 40 %.

Note: NUT prints `You may want to set 'pollonly' flag on CPS devices` on
startup. Do **not** enable `pollonly` — it is known to make the driver fail to
recover after a device reset (NUT issue #1986).

---

## SSH Access Reference

```bash
# tower.local (password auth)
sshpass -p "$(cat $HOME/ssh-keys/.unraid-password.txt)" ssh root@192.168.1.40

# proxmox-00
ssh -i $HOME/ssh-keys/homelab-linux root@192.168.1.9

# talos-01
ssh -i $HOME/ssh-keys/homelab-linux ubuntu@192.168.1.12

# talos-02
ssh -i $HOME/ssh-keys/homelab-linux ubuntu@192.168.1.13
```
