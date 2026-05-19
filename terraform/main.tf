terraform {
  backend "azurerm" {}
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "project_name" {
  type = string
}

variable "azure_region" {
  type    = string
  default = "eastus"
}

variable "azure_db_region" {
  type    = string
  default = ""
}

variable "container_image" {
  type    = string
  default = "placeholder"
}

variable "app_port" {
  type    = number
  default = 3000
}

variable "replica_count" {
  type    = number
  default = 2
}

variable "node_count" {
  type    = number
  default = 1
}

variable "vm_size" {
  type    = string
  # AKS has its own per-subscription SKU allowlist that's NARROWER than plain
  # VM SKUs. Free-trial subscriptions in many regions only allow DC-series
  # (confidential compute) for AKS. Standard_DC2as_v5 is the smallest one
  # that's broadly available; users with paid subscriptions can override.
  default = "Standard_DC2ads_v5"
}

variable "kubernetes_version" {
  type = string
  # AKS retires versions on a rolling cadence; older versions like 1.30 became
  # LTS-only (Premium tier) and Free tier rejects them with K8sVersionNotSupported.
  # Leave empty to let Azure choose its current default for the region.
  default = ""
}

variable "registry_server" {
  type    = string
  default = "ghcr.io"
}

variable "registry_username" {
  type    = string
  default = ""
}

variable "registry_password" {
  type      = string
  sensitive = true
  default   = ""
}

variable "db_name" {
  type    = string
  default = ""
}

variable "db_username" {
  type    = string
  default = "appuser"
}

variable "db_password" {
  type      = string
  sensitive = true
  default   = ""
}

locals {
  name_safe = substr(lower(replace(replace(var.project_name, "_", "-"), " ", "-")), 0, 24)
  namespace = local.name_safe
  effective_db_region    = var.azure_db_region != "" ? var.azure_db_region : var.azure_region
  db_is_cross_region     = var.azure_db_region != "" && var.azure_db_region != var.azure_region
  _db_name               = var.db_name != "" ? var.db_name : "${replace(var.project_name, "-", "_")}db"
  _db_port               = "10255"
  _db_scheme             = "mongodb"
}

resource "azurerm_resource_group" "rg" {
  name     = "${var.project_name}-rg"
  location = var.azure_region
  tags = {
    Project   = var.project_name
    ManagedBy = "udap"
  }
}

resource "azurerm_resource_group" "db_rg" {
  count    = local.db_is_cross_region ? 1 : 0
  name     = "${var.project_name}-db-rg"
  location = var.azure_db_region
  tags = {
    Project   = var.project_name
    ManagedBy = "udap"
  }
}

locals {
  db_resource_group_name = local.db_is_cross_region ? azurerm_resource_group.db_rg[0].name : azurerm_resource_group.rg.name
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = "${var.project_name}-aks"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = local.name_safe
  # Omit kubernetes_version when blank so Azure picks the current default for
  # the region. Pinning to a specific version (e.g. 1.30.x) breaks once Azure
  # moves that version to LTS-only.
  kubernetes_version  = var.kubernetes_version != "" ? var.kubernetes_version : null
  sku_tier            = "Free"

  default_node_pool {
    name       = "default"
    node_count = var.node_count
    vm_size    = var.vm_size
    type       = "VirtualMachineScaleSets"
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "kubenet"
    load_balancer_sku = "standard"
  }

  tags = {
    Project   = var.project_name
    ManagedBy = "udap"
  }
}

# Azure Cosmos DB with MongoDB API — Azure's native managed Mongo product.
# Free tier (`enable_free_tier = true`) covers 1000 RU/s + 25 GB; one Free
# Tier per subscription. Server 4.2 is the latest stable Mongo wire version.
resource "azurerm_cosmosdb_account" "db" {
  name                = "${var.project_name}-cosmos"
  resource_group_name = local.db_resource_group_name
  location            = local.effective_db_region
  offer_type          = "Standard"
  kind                = "MongoDB"

  capabilities {
    name = "EnableMongo"
  }
  capabilities {
    # Lets us use the modern Mongo wire protocol (matches MongoDB 4.0+).
    name = "MongoDBv3.4"
  }
  capabilities {
    name = "EnableServerless"
  }

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = local.effective_db_region
    failover_priority = 0
  }

  # Public network — Cosmos's firewall + key-based auth is the security layer.
  # For private VNet ingress add `is_virtual_network_filter_enabled = true`
  # plus a virtual_network_rule block (out of scope for the wizard default).
  public_network_access_enabled = true

  tags = {
    Project   = var.project_name
    ManagedBy = "udap"
  }
}

resource "azurerm_cosmosdb_mongo_database" "appdb" {
  name                = local._db_name
  resource_group_name = local.db_resource_group_name
  account_name        = azurerm_cosmosdb_account.db.name
}

output "cluster_name" {
  value = azurerm_kubernetes_cluster.aks.name
}

output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "namespace" {
  value = local.namespace
}

output "app_port" {
  value = var.app_port
}

# Cosmos DB returns a ready-made connection string that includes the primary
# key as the password — emit it sensitively. Apps just read MONGO_URI.
output "mongo_connection_string" {
  value     = azurerm_cosmosdb_account.db.primary_mongodb_connection_string
  sensitive = true
}

output "mongo_database" {
  value = azurerm_cosmosdb_mongo_database.appdb.name
}

output "db_host" {
  # cosmos.endpoint is https://...documents.azure.com:443 — strip the scheme/port
  # for apps that build their own URI from host/db.
  value = replace(replace(azurerm_cosmosdb_account.db.endpoint, "https://", ""), ":443/", "")
}

output "db_port" {
  value = "10255"
}

output "db_name" {
  value = local._db_name
}
