variable "vm_definitions" {
  type = map(object({
    node         = string
    name         = string
    cores        = number
    memory       = number
    disk_size    = number
    ipconfig0    = string
    tags         = string
    disk_storage = string
    network = object({
      address         = string
      gateway         = string
      dns_nameservers = list(string)
    })
  }))
}
