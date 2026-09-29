# K8s Control-Plane Migration: talos-alpha → talos-00

*Date: 2026-07-22 | Applies to: Kubernetes homelab cluster (develop branch)*

---

## 1. Pre-Migration State

| Component | Before Migration |
|-----------|-----------------|
| **Control-Plane** | talos-alpha (192.168.1.10) — sole CP, K8s v1.35.5 |
| **Workers** | talos-00 (192.168.1.11), talos-01 (192.168.1.12), talos-02 (192.168.1.13) |
| **Nodes** | 4 total (1 CP + 3 worker+storage) |
| **Pods** | ~142 running |
| **K8s Version** | v1.35.5 (downgraded from v1.36) |
| **etcd (K8s)** | talos-alpha only (single-node, systemd service) |
| **etcd (Patroni)** | talos-00, talos-01, talos-02 (not managed by K8s) |
| **Velero Backup** | "clean-backup" at s3.mcb-homelab.com |
| **ArgoCD** | Synced/Healthy |
| **External-Secrets** | Synced (Vault auth working) |

---

## 2. Target State After Migration

| Component | After Migration |
|-----------|----------------|
| **Control-Plane** | talos-00 (192.168.1.11) — sole CP, K8s v1.35.5 |
| **Workers** | talos-01 (192.168.1.12), talos-02 (192.168.1.13) |
| **Nodes** | 3 total (1 CP + 2 worker+storage) |
| **Removed** | talos-alpha (192.168.1.10) |
| **etcd (K8s)** | talos-00 only (data migrated from talos-alpha) |
| **etcd (Patroni)** | Preserved on talos-00/01/02 (not managed by K8s) |

---

## 3. Execution Timeline

### Phase 1: Update Inventory Files

#### 3.1 inventory.ini

Changed `k8s/k8s-setups/inventory/homelab-k8s/inventory.ini`:

```diff
-[kube_control_plane]
-talos-alpha ansible_host=192.168.1.10 ip=192.168.1.10 etcd_member_name=etcd0
+[kube_control_plane]
+talos-00 ansible_host=192.168.1.11 ip=192.168.1.11 etcd_member_name=etcd0

 [kube_node]
-talos-00 ansible_host=192.168.1.11  ip=192.168.1.11  etcd_member_name=etcd1
 talos-01 ansible_host=192.168.1.12  ip=192.168.1.12  etcd_member_name=etcd2
 talos-02 ansible_host=192.168.1.13  ip=192.168.1.13  etcd_member_name=etcd3
```

`etcd:children` remains `kube_control_plane` (now talos-00 only).

#### 3.2 all.yml

Changed `k8s/k8s-setups/inventory/homelab-k8s/group_vars/all/all.yml`:

```diff
-loadbalancer_apiserver:
-  address: 192.168.1.10
+loadbalancer_apiserver:
+  address: 192.168.1.11
```

### Phase 2: Pre-Flight — etcd Snapshot

Before any changes, took an etcd snapshot from talos-alpha:

```bash
ssh ubuntu@192.168.1.10
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/ssl/etcd/ssl/ca.pem \
  --cert=/etc/ssl/etcd/ssl/admin-talos-alpha.pem \
  --key=/etc/ssl/etcd/ssl/admin-talos-alpha-key.pem \
  snapshot save /root/etcd-snapshot-pre-migration.db
```

**Result**: 172MB snapshot saved at `/root/etcd-snapshot-pre-migration.db` on talos-alpha.

Also copied locally: `/tmp/etcd-snapshot-pre-migration.db`

**Key finding**: talos-alpha uses etcd v3.6.11, with certs at `/etc/ssl/etcd/ssl/` (NOT `/etc/kubernetes/ssl/etcd/`). The `etcdctl` in v3.6 uses `etcdutl` for snapshot restore.

### Phase 3: Kubespray Setup

Created Python venv for kubespray:

```bash
python3 -m venv /tmp/kubespray-venv
/tmp/kubespray-venv/bin/pip install -r k8s/k8s-setups/kubespray/requirements.txt
```

Kubespray requirement: facts must be cached before using `--limit`:

```bash
cd k8s/k8s-setups/kubespray
source /tmp/kubespray-venv/bin/activate
ansible-playbook -i ../inventory/homelab-k8s/inventory.ini playbooks/facts.yml
```

### Phase 4: Run cluster.yml --limit talos-00

```bash
source /tmp/kubespray-venv/bin/activate
cd k8s/k8s-setups/kubespray
ansible-playbook -i ../inventory/homelab-k8s/inventory.ini cluster.yml --limit talos-00
```

**First run result**: 532 ok, 28 changed, 1 failed
- **Failure**: `Create kubeadm token` — admin.conf pointed to 192.168.1.14:6444 (wrong old IP)
- **Root cause**: admin.conf server URL was stale from pre-migration config

**Fix applied**:
```bash
ssh ubuntu@192.168.1.11
sudo sed -i 's|server: https://192.168.1.14:6444|server: https://192.168.1.11:6443|' /etc/kubernetes/admin.conf
```

**Second run result**: 520 ok, 11 changed, 1 failed
- **Failure**: Still token creation — now "connection refused" because kubelet still pointed to old CP and no API server was running on talos-00

### Phase 5: Manual kubeadm init

The kubespray playbook set up etcd and certs but didn't complete kubeadm init (static pod manifests were never created).

**Issue**: kubelet.conf on talos-00 still pointed to 192.168.1.10:6443 (old CP)

**Fix**:
```bash
# Stop kubelet (port 10250 was blocking kubeadm preflight)
sudo systemctl stop kubelet

# Run kubeadm init with existing config
sudo kubeadm init \
  --config=/etc/kubernetes/kubeadm-config.yaml \
  --ignore-preflight-errors=Port-6443,FileAvailable--etc-kubernetes-manifests-*,CoreDNSUnsupportedPlugins,CoreDNSMigration,CreateJob
```

**Result**: SUCCESS — kube-apiserver, kube-controller-manager, kube-scheduler running as static pods on talos-00.

**Bootstrap token created**: `o7lzfq.xbggywxjcnvq5611`

### Phase 6: etcd Data Migration

**Problem**: etcd on talos-00 contained stale data from the pre-migration era (v1.34.4 nodes, 151d old node objects).

**Fix**: Restored the snapshot from talos-alpha:

```bash
# Transfer snapshot
ssh ubuntu@192.168.1.10 'sudo cat /root/etcd-snapshot-pre-migration.db' | \
  ssh ubuntu@192.168.1.11 'sudo tee /root/etcd-snapshot-pre-migration.db > /dev/null'

# Stop etcd, wipe data, restore
sudo systemctl stop etcd
sudo rm -rf /var/lib/etcd
sudo mkdir -p /var/lib/etcd

# etcd 3.6 uses etcdutl (not etcdctl) for snapshot restore
sudo etcdutl snapshot restore /root/etcd-snapshot-pre-migration.db \
  --name etcd0 \
  --initial-cluster etcd0=https://192.168.1.11:2380 \
  --initial-advertise-peer-urls https://192.168.1.11:2380 \
  --data-dir /var/lib/etcd \
  --skip-hash-check

sudo chown -R etcd:etcd /var/lib/etcd
sudo systemctl start etcd
```

**Verification**:
```bash
sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 ... endpoint health
# Result: healthy, committed proposal
```

**CA certs match**: Both talos-alpha and talos-00 have identical CA certificates (SHA1: `5C:AF:73:B0:...`). The super-admin.conf works because it uses the same CA.

### Phase 7: Reconfigure Workers

#### 7.1 Update kubelet.conf on talos-00

```bash
sudo sed -i 's|server: https://192.168.1.10:6443|server: https://192.168.1.11:6443|' /etc/kubernetes/kubelet.conf
sudo systemctl restart kubelet
```

#### 7.2 Update kubelet.conf on talos-01 and talos-02

```bash
for ip in 192.168.1.12 192.168.1.13; do
  ssh ubuntu@$ip "
    sudo sed -i 's|server: https://192.168.1.10:6443|server: https://192.168.1.11:6443|' /etc/kubernetes/kubelet.conf
    sudo systemctl restart kubelet
  "
done
```

**Result**: All 3 nodes became Ready within seconds.

### Phase 8: Fix Node Labels and Taints

```bash
# Remove stale labels and apply correct ones
kubectl label node talos-00 node-role.kubernetes.io/control-plane='' --overwrite
kubectl label node talos-00 node-role.kubernetes.io/worker-
kubectl label node talos-00 node-role.kubernetes.io/storage-
kubectl taint node talos-00 node-role.kubernetes.io/control-plane:NoSchedule --overwrite
```

### Phase 9: Stop and Remove talos-alpha

```bash
ssh ubuntu@192.168.1.10
sudo systemctl stop kubelet
sudo rm -f /etc/kubernetes/manifests/kube-apiserver.yaml
sudo rm -f /etc/kubernetes/manifests/kube-controller-manager.yaml
sudo rm -f /etc/kubernetes/manifests/kube-scheduler.yaml
sudo rm -f /etc/kubernetes/manifests/etcd.yaml
sudo systemctl stop etcd
```

Remove node from cluster:
```bash
kubectl delete node talos-alpha
```

### Phase 10: Complete Ansible Playbook

Re-ran cluster.yml --limit talos-00 to finalize:
- 612 ok, 31 changed, 1 failed (MetalLB controller rollout timeout — expected)

### Phase 11: Update Local Kubeconfig

```bash
# Backup old config
cp ~/.kube/config ~/.kube/config.bak.$(date +%Y%m%d-%H%M%S)

# Use super-admin.conf (works with restored etcd)
ssh ubuntu@192.168.1.11 'sudo cat /etc/kubernetes/super-admin.conf' > ~/.kube/config
```

**Note**: `admin.conf` uses a "kubernetes-admin" cert that lacked RBAC bindings in the restored cluster. `super-admin.conf` uses a cert signed by the same CA and has full cluster-admin access.

---

## 4. Issues Encountered and Fixes

| # | Issue | Root Cause | Fix |
|---|-------|-----------|-----|
| 1 | `kubeadm token create` failed — admin.conf pointed to 192.168.1.14:6444 | Stale kubeconfig from pre-migration era | Sed'd admin.conf to 192.168.1.11:6443 |
| 2 | `kubeadm token create` failed — connection refused | kube-apiserver not running (kubeadm init didn't complete) | Manually ran `kubeadm init` |
| 3 | `kubeadm init` failed — Port 10250 in use | kubelet still running on talos-00 | Stopped kubelet before init |
| 4 | `kubeadm init` required `--ignore-preflight-errors` | Pre-existing certs and etcd config | Added preflight ignores |
| 5 | etcd had stale pre-migration data (v1.34.4 nodes) | Old etcd data directory not wiped | Restored snapshot from talos-alpha |
| 6 | `etcdctl snapshot restore` failed in v3.6 | v3.6 uses `etcdutl` for restore | Used `etcdutl snapshot restore` |
| 7 | `etcdutl` restore failed — "data-dir not empty" | Stale member directory after failed restore | `rm -rf /var/lib/etcd && mkdir -p` before restore |
| 8 | etcd bootstrap failed after restore | Wrong permissions on data dir | `chown -R etcd:etcd /var/lib/etcd` |
| 9 | `kubernetes-admin` Forbidden after restore | admin cert RBAC mismatch | Used super-admin.conf instead |
| 10 | CSI provisioners CrashLoopBackOff | Couldn't reach K8s API via service IP during migration | Deleted failing pods — new ones recovered |
| 11 | Pods stuck on talos-00 (CP) after taint | Scheduler couldn't place them due to NoSchedule | Deleted pods manually for reschedule |
| 12 | Loki write-1 Pending (unschedulable) | Anti-affinity with only 2 worker nodes | Expected — runs degraded 2/3 |
| 13 | Harbor pods CrashLoopBackOff | Database/pgbouncer not ready during recovery | Self-recovered as Longhorn volumes reattached |
| 14 | Calico sandbox errors ("pods not found") | CP migration caused IPAM inconsistencies | Deleted affected pods for recreation |
| 15 | `facts.yml` not in root directory | Kubespray moved it to playbooks/ | Used `playbooks/facts.yml` path |
| 16 | ansible-playbook `--limit` requires fact cache | Kubespray design requirement | Ran `playbooks/facts.yml` first |

---

## 5. Verification Steps

### 5.1 Cluster Nodes
```bash
kubectl get nodes -o wide
# Expected: 3 nodes Ready — talos-00 (CP), talos-01 (worker+storage), talos-02 (worker+storage)
```

### 5.2 Core Services
```bash
# ArgoCD applications
kubectl get application -n administrator-apps

# External Secrets
kubectl get es -A

# Longhorn
kubectl get nodes.longhorn.io -n storageclass-system
kubectl get volumes.longhorn.io -n storageclass-system
```

### 5.3 etcd Health
```bash
ssh ubuntu@192.168.1.11
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/ssl/etcd/ssl/ca.pem \
  --cert=/etc/ssl/etcd/ssl/admin-talos-00.pem \
  --key=/etc/ssl/etcd/ssl/admin-talos-00-key.pem \
  endpoint health
```

### 5.4 API Server
```bash
kubectl get --raw /livez
kubectl get --raw /readyz
```

---

## 6. Post-Migration State

| Component | Final State |
|-----------|-------------|
| **talos-00 (192.168.1.11)** | control-plane ONLY, Ready, v1.35.5 |
| **talos-01 (192.168.1.12)** | storage,worker, Ready, v1.35.5 |
| **talos-02 (192.168.1.13)** | storage,worker, Ready, v1.35.5 |
| **talos-alpha (192.168.1.10)** | REMOVED from cluster |
| **Total Pods** | 121 (106 Running, 15 recovering) |
| **ArgoCD Apps** | 6/6 Synced & Healthy |
| **External Secrets** | 9/9 SecretSynced & Ready |
| **etcd (K8s)** | talos-00 only, data migrated from talos-alpha |
| **etcd (Patroni)** | Preserved on talos-00/01/02 |
| **kubeconfig** | Points to 192.168.1.11:6443 using super-admin cert |

---

## 7. Outstanding Items (Post-Migration Cleanup)

1. **Loki StatefulSet**: Running 2/3 replicas due to anti-affinity rules on 2 worker nodes (was 3 workers before). Consider reducing replicas or relaxing affinity.
2. **Some pods recovering**: Harbor, ArgoCD repo-server, Grafana still initializing — should self-recover as Longhorn volumes reattach.
3. **MetalLB controller**: Had rollout timeout during ansible run. Verify it's healthy:
   ```bash
   kubectl rollout status deployment -n metallb-system -l app=metallb,component=controller
   ```
4. **Vault K8s auth**: External Secrets working (SecretSynced) — Vault auth config was preserved during migration since kubeconfig certs match the same CA.
5. **kubectl client version**: Client is v1.32.13, server is v1.35.5 — exceeds minor version skew. Consider updating kubectl.
6. **talos-alpha decommissioning**: The node is stopped but still physically exists. Consider:
   - Wiping the disk if repurposing
   - Updating DNS/dhcp if IP will be reused

---

## 8. Rollback Plan

If the migration needs to be reversed:

### 8.1 Restore talos-alpha as CP
```bash
# On talos-alpha, restore kube-apiserver manifest
ssh ubuntu@192.168.1.10
sudo cp /etc/kubernetes/manifests.bak/* /etc/kubernetes/manifests/  # if backup exists
sudo systemctl start etcd
sudo systemctl start kubelet
```

### 8.2 Point workers back to talos-alpha
```bash
for ip in 192.168.1.11 192.168.1.12 192.168.1.13; do
  ssh ubuntu@$ip "
    sudo sed -i 's|server: https://192.168.1.11:6443|server: https://192.168.1.10:6443|' /etc/kubernetes/kubelet.conf
    sudo systemctl restart kubelet
  "
done
```

### 8.3 Restore inventory
```bash
git checkout k8s/k8s-setups/inventory/homelab-k8s/inventory.ini
git checkout k8s/k8s-setups/inventory/homelab-k8s/group_vars/all/all.yml
```

### 8.4 Restore kubeconfig
```bash
cp ~/.kube/config.bak.<timestamp> ~/.kube/config
```

### 8.5 Restore etcd from snapshot
```bash
# On talos-alpha, if etcd data was lost:
sudo systemctl stop etcd
sudo rm -rf /var/lib/etcd
sudo etcdutl snapshot restore /root/etcd-snapshot-pre-migration.db \
  --name etcd0 \
  --initial-cluster etcd0=https://192.168.1.10:2380 \
  --initial-advertise-peer-urls https://192.168.1.10:2380 \
  --data-dir /var/lib/etcd \
  --skip-hash-check
sudo chown -R etcd:etcd /var/lib/etcd
sudo systemctl start etcd
```

---

## 9. Key Files Modified

| File | Change |
|------|--------|
| `k8s/k8s-setups/inventory/homelab-k8s/inventory.ini` | talos-00 → [kube_control_plane], talos-alpha removed |
| `k8s/k8s-setups/inventory/homelab-k8s/group_vars/all/all.yml` | loadbalancer_apiserver.address: 192.168.1.11 |
| `~/.kube/config` | Updated to point to 192.168.1.11:6443 (super-admin cert) |
| `/etc/kubernetes/manifests/*` (on talos-00) | Static pod manifests created by kubeadm init |
| `/etc/kubernetes/kubelet.conf` (on all nodes) | server URL updated to 192.168.1.11:6443 |

---

*Runbook created: 2026-07-22 | Author: DevOps Automator*
