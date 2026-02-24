terraform {
  backend "azurerm" {
     resource_group_name  = "rg-ray-tfstate"
     storage_account_name = "raytfstate12345"
     container_name       = "tfstate"
     key                  = "aks-sec-baseline.tfstate"
     use_azuread_auth     = true
  }
}
