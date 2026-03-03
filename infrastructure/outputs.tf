output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "acr_login_server" {
  value = azurerm_container_registry.acr.login_server
}

output "acr_admin_username" {
  value     = azurerm_container_registry.acr.admin_username
  sensitive = true
}

output "container_app_url" {
  value = azurerm_container_app.app.ingress[0].fqdn
}

output "grafana_url" {
  value = azurerm_container_app.grafana.ingress[0].fqdn
}

output "storage_account_name" {
  value = azurerm_storage_account.sa.name
}


