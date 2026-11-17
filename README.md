# My-DevOps

Personal homelab DevOps monorepo: bash provisioning scripts, Kubernetes manifests
(ArgoCD), Terraform (Proxmox VM provisioning), and Docker Swarm stack definitions.

See [AGENTS.md](AGENTS.md) for the full workspace guide.

## Infrastructure Nodes

| Hostname        | Type                  | IP               | User     | NTP source                       |
|-----------------|-----------------------|------------------|----------|----------------------------------|
| proxmox-00      | Bare-metal hypervisor | 192.168.1.9      | root     | 0-3.asia.pool.ntp.org (chrony)   |
| talos-00        | VM (control-plane)    | 192.168.1.11     | ubuntu   | 0-3.asia.pool.ntp.org (ntpsec)   |
| talos-01        | Bare-metal (CP)       | 192.168.1.12     | ubuntu   | 0-3.asia.pool.ntp.org (ntpsec)   |
| talos-02        | Bare-metal (CP)       | 192.168.1.13     | ubuntu   | 0-3.asia.pool.ntp.org (ntpsec)   |
| tower.local     | unRAID server         | 192.168.1.40     | root     | 0-3.asia.pool.ntp.org (ntpd)     |
| talos-cloud-00  | Cloud VM              | 14.225.220.145   | root     | 0-3.asia.pool.ntp.org (timesyncd)|
| talos-cloud-01  | Cloud VM              | 140.245.100.82   | opc      | 0-3.asia.pool.ntp.org (chrony)   |
| vault-agent     | LXC container         | 192.168.1.7      | root     | inherits proxmox-00 host clock   |

> Standardised NTP: all hosts sync to `0.asia.pool.ntp.org` .. `3.asia.pool.ntp.org`
> (applied 2026-09-07, config backups as `<conf>.bak.20260907`).
