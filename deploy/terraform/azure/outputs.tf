output "web_url" { value = "https://${azurerm_container_app.web.ingress[0].fqdn}" }
output "ingest_url" { value = "https://${azurerm_container_app.backend.ingress[0].fqdn}" }
output "key_vault" { value = azurerm_key_vault.kv.name }
output "postgres_host" { value = azurerm_postgresql_flexible_server.pg.fqdn }

# One-time bootstrap of the runtime roles (run with the admin DSN from Key Vault secret
# "migrate-dsn" BEFORE the first migrate job): creates the roles with the generated
# passwords. BYPASSRLS needs azure_pg_admin membership on Flexible Server.
output "role_bootstrap_sql" {
  sensitive = true
  value     = <<-SQL
    CREATE ROLE skywatch_api LOGIN PASSWORD '${random_password.api_role.result}' NOBYPASSRLS;
    CREATE ROLE skywatch_worker LOGIN PASSWORD '${random_password.worker_role.result}' BYPASSRLS;
  SQL
}
