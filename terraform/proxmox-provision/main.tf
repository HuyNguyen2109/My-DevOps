terraform {
  cloud { 
    organization = "Mcbourdeux-Homelab" 
    workspaces { 
      name = "Proxmox" 
    } 
  }
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.1-rc8"
    }
    vault = {
      source = "hashicorp/vault"
      version = "5.0.0"
    }
  }
}

provider "vault" {
  address         = "https://vault.mcb-svc.work"
}

data "vault_generic_secret" "proxmox-credentials" {
  path = "terraform/secrets"
}

provider "proxmox" {
  pm_api_url      = "https://proxmox.mcb-svc.work/api2/json"
  pm_user         = "root@pam"
  pm_password     = data.vault_generic_secret.proxmox-credentials.data["proxmox-root"]
  pm_tls_insecure = true
  pm_api_token_id  = null
  pm_api_token_secret = null
}

resource "proxmox_vm_qemu" "k8s_nodes" {
  for_each = var.vm_definitions

  name        = each.value.name
  target_node = each.value.node
  clone       = "rocky9-cloud" # name of your cloud-init-enabled template
  full_clone  = true

  cores   = each.value.cores
  memory  = each.value.memory
  sockets = 1
  cpu_type = "host"

  scsihw   = "virtio-scsi-single"
  bootdisk = "scsi0"

  ciupgrade = true

  disk {
    slot     = "scsi0"
    size     = each.value.disk_size
    type     = "disk"
    storage  = each.value.disk_storage
    iothread = true
  }

  # Explicitly attach cloud-init disk
  disk {
    slot    = "ide2"
    type    = "cloudinit"
    storage = "local"
    size    = "4M" 
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = "vmbr0"
  }

  serial {
    id   = 0
    type = "socket"
  }

  tags = each.value.tags
  onboot = true
  startup = "order=0,up=1"

  os_type    = "cloud-init"
  ipconfig0  = each.value.ipconfig0
  ciuser     = "rocky"
  cipassword = "M@$ter21091996"
  # sshkeys    = file("/home/mcbourdeux/ssh-keys/homelab-linux.pub")
  sshkeys    = data.vault_generic_secret.proxmox-credentials.data["qemu-vm-sshkeys"]
 
  skip_ipv6 = true
  agent = 1
}
