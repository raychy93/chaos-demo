variable "location" {
  type    = string
  default = "eastus"
}

variable "resource_group_name" {
  type    = string
  default = "rg-ray-sec-aks"
}

variable "name_prefix" {
  type    = string
  default = "raysec"
}

variable "acr_name" {
  type = string
  # Must be globally unique, lowercase, 5-50 chars
  default = "rayacr12345"
}

variable "aks_name" {
  type    = string
  default = "aks-ray-sec"
}

variable "vnet_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "subnet_aks_cidr" {
  type    = string
  default = "10.10.1.0/24"
}

variable "subnet_pe_cidr" {
  type    = string
  default = "10.10.2.0/24"
}

variable "node_vm_size" {
  type    = string
  default = "Standard_DC2as_v5"
}

variable "min_count" {
  type    = number
  default = 1
}

variable "max_count" {
  type    = number
  default = 2
}
