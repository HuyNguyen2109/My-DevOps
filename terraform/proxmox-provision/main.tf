terraform {
  cloud { 
    organization = "Mcbourdeux-Homelab" 
    workspaces { 
      name = "Proxmox" 
    } 
  }
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      version = "0.80.0"
    }
    vault = {
      source = "hashicorp/vault"
      version = "5.1.0"
    }
  }
}

# === PROVIDERS ===

provider "vault" {
  address         = "https://vault.mcb-svc.work"
}

provider "proxmox" {
  endpoint      = "https://proxmox.mcb-svc.work/api2/json"
  username         = "root@pam"
  password     = data.vault_generic_secret.terraform.data["proxmox-credentials"]
  insecure = true
  ssh {
    agent = false
    username = "root"
    password = data.vault_generic_secret.terraform.data["proxmox-credentials"]
    node {
      name = "prx-prd-00"
      address = "192.168.1.10"
    }
    node {
      name = "prx-prd-01"
      address = "192.168.1.11"
    }
    node {
      name = "prx-prd-02"
      address = "192.168.1.12"
    }
  }
}

# === DATA SOURCES ===

data "vault_generic_secret" "terraform" {
  path = "kubernetes/terraform"
}

# === RESOURCES ===
resource "proxmox_virtual_environment_file" "user_data_cloud_config" {
  for_each = var.vm_definitions

  content_type = "snippets"
  datastore_id = each.value.disk_storage
  node_name    = each.value.node

  source_raw {
    data = <<-EOF
    #cloud-config
    hostname: ${each.value.name}
    timezone: Asia/Ho_Chi_Minh
    users:
      - default
      - name: ubuntu
        groups:
          - sudo
        shell: /bin/bash
        ssh_authorized_keys:
          - ${trimspace(data.vault_generic_secret.terraform.data["proxmox-qemu-vm-sshkeys"])}
        sudo: ALL=(ALL) NOPASSWD:ALL
    package_update: true
    packages:
      - qemu-guest-agent
      - net-tools
      - curl
    runcmd:
      - echo "${data.vault_generic_secret.terraform.data["cloudflare-origin-ca-pem-b64"]}" | base64 -d > /etc/ssl/certs/cloudflare-origin-ca.pem
      - chmod 0644 /etc/ssl/certs/cloudflare-origin-ca.pem
      - echo "${data.vault_generic_secret.terraform.data["cloudflare-cert-pem-b64"]}" | base64 -d > /etc/ssl/certs/cloudflare-cert.pem
      - chmod 0644 /etc/ssl/certs/cloudflare-cert.pem
      - echo "${data.vault_generic_secret.terraform.data["cloudflare-key-pem-b64"]}" | base64 -d > /etc/ssl/private/cloudflare-key.pem
      - chmod 0600 /etc/ssl/private/cloudflare-key.pem
      - systemctl enable qemu-guest-agent
      - systemctl start qemu-guest-agent
      - curl -fsSL https://tailscale.com/install.sh | sh
      - tailscale up --authkey ${trimspace(data.vault_generic_secret.terraform.data["ts-auth-key"])} --exit-node= --accept-routes=false
      - echo "done" > /tmp/cloud-config.done
    EOF

    file_name = "user-data-cloud-config-${each.value.name}.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "ubuntu_vm" {
  for_each = var.vm_definitions
  name      = each.value.name
  node_name = each.value.node

  startup {
    order = 1
  }

  agent {
    enabled = true
  }

  operating_system {
    type = "l26"
  }

  cpu {
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = each.value.disk_storage
    import_from  = proxmox_virtual_environment_download_file.ubuntu_cloud_image[each.key].id
    interface    = "scsi0"
    iothread     = true
    discard      = "on"
    size         = each.value.disk_size
  }

  tpm_state {
    datastore_id = each.value.disk_storage
  }

  initialization {
    datastore_id = each.value.disk_storage
    ip_config {
      ipv4 {
        address = each.value.network.address
        gateway = each.value.network.gateway
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.user_data_cloud_config[each.key].id
  }

  network_device {
    bridge = "vmbr0"
  }

}

resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" {
  for_each = var.vm_definitions
  content_type = "import"
  datastore_id = each.value.disk_storage
  node_name    = each.value.node
  url          = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  # need to rename the file to *.qcow2 to indicate the actual file format for import
  file_name = "noble-server-cloudimg-amd64.qcow2"
}

output "vm_ipv4_address" {
  value = {
    for k, vm in proxmox_virtual_environment_vm.ubuntu_vm :
    k => vm.initialization[0].ip_config[0].ipv4[0].address
  }
}
