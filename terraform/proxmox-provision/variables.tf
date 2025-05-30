variable "vm_definitions" {
  type = map(object({
    node         = string
    name         = string
    cores        = number
    memory       = number
    disk_size    = string
    ipconfig0    = string
    tags         = string
    disk_storage = string
  }))
}
