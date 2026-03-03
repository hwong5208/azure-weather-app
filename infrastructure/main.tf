# 1. Resource Group
resource "azurerm_resource_group" "rg" {
  name     = "rg-${var.project_name}-${var.environment}"
  location = var.location
}

# 2. Azure Container Registry (ACR)
# Used to store the Docker image securely
resource "azurerm_container_registry" "acr" {
  name                = "acr${var.project_name}${var.environment}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = true # Required for ACA to pull images using admin credentials simply
}

# 3. Azure Storage Account (For Serverless Metrics Table)
resource "random_string" "storage_suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_storage_account" "sa" {
  name                     = "st${var.project_name}${var.environment}${random_string.storage_suffix.result}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_table" "metrics_table" {
  name                 = "sitevisits"
  storage_account_name = azurerm_storage_account.sa.name
}

# 4. Azure Log Analytics Workspace
# Required for Azure Container Apps Environment
resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-${var.project_name}-${var.environment}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# 4. Azure Container App Environment
resource "azurerm_container_app_environment" "env" {
  name                       = "cae-${var.project_name}-${var.environment}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id
}

# 5. Azure Container App
resource "azurerm_container_app" "app" {
  name                         = "ca-${var.project_name}-${var.environment}"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

  template {
    container {
      name   = "weather-api"
      image  = "${azurerm_container_registry.acr.login_server}/vancouver-weather-app:latest"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "PORT"
        value = "8000"
      }
      env {
        name        = "AZURE_STORAGE_CONNECTION_STRING"
        secret_name = "storage-conn-string"
      }
    }
    min_replicas = 0 # Scale to zero for cost savings
    max_replicas = 2
  }

  ingress {
    external_enabled = true
    target_port      = 8000
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  registry {
    server               = azurerm_container_registry.acr.login_server
    username             = azurerm_container_registry.acr.admin_username
    password_secret_name = "acr-password"
  }

  secret {
    name  = "acr-password"
    value = azurerm_container_registry.acr.admin_password
  }

  secret {
    name  = "storage-conn-string"
    value = azurerm_storage_account.sa.primary_connection_string
  }
}

# 6. Grafana Azure Container App (On-Demand Scale-to-Zero)
resource "azurerm_container_app" "grafana" {
  name                         = "ca-grafana-${var.project_name}-${var.environment}"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

  template {
    container {
      name   = "metrics-grafana"
      image  = "${azurerm_container_registry.acr.login_server}/weather-grafana:latest"
      cpu    = 0.5
      memory = "1.0Gi"

      env {
        name  = "GF_AUTH_ANONYMOUS_ENABLED"
        value = "true"
      }
      env {
        name  = "GF_AUTH_ANONYMOUS_ORG_ROLE"
        value = "Viewer"
      }
      env {
        name  = "API_METRICS_URL"
        value = "https://${azurerm_container_app.app.ingress[0].fqdn}"
      }
    }
    min_replicas = 0 # FinOps: Scale Grafana to zero when not viewed
    max_replicas = 1
  }

  ingress {
    external_enabled = true
    target_port      = 3000
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  registry {
    server               = azurerm_container_registry.acr.login_server
    username             = azurerm_container_registry.acr.admin_username
    password_secret_name = "acr-password"
  }

  secret {
    name  = "acr-password"
    value = azurerm_container_registry.acr.admin_password
  }
}


