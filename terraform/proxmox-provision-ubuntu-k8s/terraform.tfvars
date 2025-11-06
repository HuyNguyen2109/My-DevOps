vm_definitions = {
  # k3s-server-03-wura = {
  #   node      = "prx-prd-00"
  #   name      = "k3s-server-03-wura"
  #   cores     = 4
  #   memory    = 6144
  #   disk_size = 64
  #   ipconfig0 = "ip=192.168.1.13/24,gw=192.168.1.1"
  #   tags      = "k8s,terraform,control-plane"
  #   disk_storage = "local2"
  #   network = {
  #     address         = "192.168.1.13/24"
  #     gateway         = "192.168.1.1"
  #     dns_nameservers = ["1.1.1.1", "8.8.8.8"]
  #   }
  # }

  # k3s-server-04-wura = {
  #   node      = "prx-prd-01"
  #   name      = "k3s-server-04-wura"
  #   cores     = 4
  #   memory    = 6144
  #   disk_size = 64
  #   ipconfig0 = "ip=192.168.1.14/24,gw=192.168.1.1"
  #   tags      = "k8s,terraform,control-plane"
  #   disk_storage = "local"
  #   network = {
  #     address         = "192.168.1.14/24"
  #     gateway         = "192.168.1.1"
  #     dns_nameservers = ["1.1.1.1", "8.8.8.8"]
  #   }
  # }

  # k3s-server-05-wura = {
  #   node      = "prx-prd-02"
  #   name      = "k3s-server-05-wura"
  #   cores     = 4
  #   memory    = 6144
  #   disk_size = 64
  #   ipconfig0 = "ip=192.168.1.15/24,gw=192.168.1.1"
  #   tags      = "k8s,terraform,control-plane"
  #   disk_storage = "local"
  #   network = {
  #     address         = "192.168.1.15/24"
  #     gateway         = "192.168.1.1"
  #     dns_nameservers = ["1.1.1.1", "8.8.8.8"]
  #   }
  # }

  k3s-worker-03-wura = {
    node      = "prx-prd-01"
    name      = "k3s-worker-03-wura"
    cores     = 6
    memory    = 32768
    disk_size = 128
    ipconfig0 = "ip=192.168.1.16/24,gw=192.168.1.1"
    tags      = "k8s,terraform,worker"
    disk_storage = "local"
    network = {
      address         = "192.168.1.16/24"
      gateway         = "192.168.1.1"
      dns_nameservers = ["1.1.1.1", "8.8.8.8"]
    }
  }

  k3s-worker-04-wura = {
    node      = "prx-prd-02"
    name      = "k3s-worker-04-wura"
    cores     = 6
    memory    = 32768
    disk_size = 128
    ipconfig0 = "ip=192.168.1.17/24,gw=192.168.1.1"
    tags      = "k8s,terraform,worker"
    disk_storage = "local"
    network = {
      address         = "192.168.1.17/24"
      gateway         = "192.168.1.1"
      dns_nameservers = ["1.1.1.1", "8.8.8.8"]
    }
  }
}
