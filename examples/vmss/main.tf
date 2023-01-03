resource "random_id" "id" {
  byte_length = 2
}

data "curl" "public_ip" {
  count = var.my_public_ip == null ? 1 : 0

  http_method = "GET"
  uri         = "https://api.ipify.org?format=json"
}

resource "azurerm_resource_group" "rg" {
  count = var.create_resource_group ? 1 : 0

  location = var.location
  name     = coalesce(var.resource_group_name, "tf-vmmod-vmss-${random_id.id.hex}")
}

locals {
  resource_group = {
    name     = try(azurerm_resource_group.rg[0].name, var.resource_group_name)
    location = var.location
  }
}

module "vnet" {
  source  = "Azure/vnet/azurerm"
  version = "4.0.0"

  resource_group_name = local.resource_group.name
  use_for_each        = true
  vnet_location       = local.resource_group.location
  address_space       = ["192.168.0.0/24"]
  vnet_name           = "vnet-vm-${random_id.id.hex}"
  subnet_names        = ["subnet-virtual-machine"]
  subnet_prefixes     = ["192.168.0.0/28"]
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = "4096"
}

resource "azurerm_public_ip" "pip" {
  allocation_method   = "Dynamic"
  location            = local.resource_group.location
  name                = "pip-${random_id.id.hex}"
  resource_group_name = local.resource_group.name
}

resource "azurerm_orchestrated_virtual_machine_scale_set" "vmss" {
  location                    = local.resource_group.location
  name                        = "vmssflex-${random_id.id.hex}"
  platform_fault_domain_count = 1
  resource_group_name         = local.resource_group.name

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
  source_image_reference {
    offer     = "UbuntuServer"
    publisher = "Canonical"
    sku       = "18.04-LTS"
    version   = "latest"
  }
}

module "linux" {
  source = "../.."

  location                   = local.resource_group.location
  image_os                   = "linux"
  resource_group_name        = local.resource_group.name
  allow_extension_operations = false
  boot_diagnostics           = false
  new_network_interface = {
    ip_forwarding_enabled = false
    ip_configurations = [
      {
        public_ip_address_id = try(azurerm_public_ip.pip.id, null)
        primary              = true
      }
    ]
  }
  nsg_public_open_port        = "22"
  nsg_source_address_prefixes = [try(jsondecode(data.curl.public_ip[0].response).ip, var.my_public_ip)]
  admin_ssh_keys = [
    {
      public_key = tls_private_key.ssh.public_key_openssh
      username   = "azureuser"
    }
  ]
  name = "ubuntu-${random_id.id.hex}"
  os_disk = {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
  os_simple                    = "UbuntuServer"
  size                         = var.size
  subnet_id                    = module.vnet.vnet_subnets[0]
  virtual_machine_scale_set_id = azurerm_orchestrated_virtual_machine_scale_set.vmss.id
}

resource "local_file" "ssh_private_key" {
  filename = "${path.module}/key.pem"
  content  = tls_private_key.ssh.private_key_pem
}