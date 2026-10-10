# Reference production topology on Azure:
#   Container Apps (web, api, backend, migrate job) + PostgreSQL Flexible Server 16 +
#   Key Vault (all secrets, RBAC) + Log Analytics. Ingress terminates TLS; the control
#   API and the management API are internal-only.
data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "rg" {
  name     = "rg-${var.name}"
  location = var.location
}

resource "azurerm_log_analytics_workspace" "logs" {
  name                = "log-${var.name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# ---------------------------------------------------------------- secrets
resource "random_password" "pg_admin" {
  length  = 32
  special = false
}
resource "random_password" "api_role" {
  length  = 32
  special = false
}
resource "random_password" "worker_role" {
  length  = 32
  special = false
}
resource "random_password" "control" {
  length  = 48
  special = false
}
resource "random_password" "cookie" {
  length  = 48
  special = false
}
resource "random_bytes" "kek" { length = 32 }

resource "azurerm_key_vault" "kv" {
  name                       = "kv-${var.name}-${substr(md5(azurerm_resource_group.rg.id), 0, 6)}"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = var.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 30
}

resource "azurerm_role_assignment" "deployer_kv" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

locals {
  pg_host = azurerm_postgresql_flexible_server.pg.fqdn
  secrets = merge({
    "worker-dsn"  = "postgres://skywatch_worker:${random_password.worker_role.result}@${local.pg_host}:5432/skywatch?sslmode=require"
    "api-dsn"     = "postgres://skywatch_api:${random_password.api_role.result}@${local.pg_host}:5432/skywatch?sslmode=require"
    "migrate-dsn" = "postgres://skywatchadmin:${random_password.pg_admin.result}@${local.pg_host}:5432/skywatch?sslmode=require"
    # Local keyring until the Key Vault KeyProvider is implemented (docs/SECURITY.md).
    "keks"          = "v1:${random_bytes.kek.base64}"
    "control-token" = random_password.control.result
    "cookie-secret" = random_password.cookie.result
  }, var.oidc == null ? {} : { "oidc-client-secret" = var.oidc.client_secret })
}

resource "azurerm_key_vault_secret" "s" {
  for_each     = nonsensitive(toset(keys(local.secrets)))
  name         = each.key
  value        = local.secrets[each.key]
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [azurerm_role_assignment.deployer_kv]
}

resource "azurerm_user_assigned_identity" "apps" {
  name                = "id-${var.name}-apps"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
}

resource "azurerm_role_assignment" "apps_kv" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.apps.principal_id
}

# ---------------------------------------------------------------- database
resource "azurerm_postgresql_flexible_server" "pg" {
  name                          = "psql-${var.name}-${substr(md5(azurerm_resource_group.rg.id), 0, 6)}"
  resource_group_name           = azurerm_resource_group.rg.name
  location                      = var.location
  version                       = "16"
  sku_name                      = var.postgres_sku
  storage_mb                    = 131072
  backup_retention_days         = 14
  geo_redundant_backup_enabled  = false
  administrator_login           = "skywatchadmin"
  administrator_password        = random_password.pg_admin.result
  public_network_access_enabled = true # restrict with the firewall rule below, or use VNet integration
  lifecycle { ignore_changes = [zone] }
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "azure" {
  name             = "allow-azure-services"
  server_id        = azurerm_postgresql_flexible_server.pg.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_postgresql_flexible_server_database" "db" {
  name      = "skywatch"
  server_id = azurerm_postgresql_flexible_server.pg.id
}

resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.pg.id
  value     = "PGCRYPTO"
}

# ---------------------------------------------------------------- container apps
resource "azurerm_container_app_environment" "env" {
  name                       = "cae-${var.name}"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = var.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.logs.id
}

locals {
  kv_ref = { for k in keys(local.secrets) : k => azurerm_key_vault_secret.s[k].versionless_id }
}

resource "azurerm_container_app" "backend" {
  name                         = "ca-${var.name}-backend"
  resource_group_name          = azurerm_resource_group.rg.name
  container_app_environment_id = azurerm_container_app_environment.env.id
  revision_mode                = "Single"
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.apps.id]
  }
  dynamic "secret" {
    for_each = toset(["worker-dsn", "keks", "control-token"])
    content {
      name                = secret.value
      key_vault_secret_id = local.kv_ref[secret.value]
      identity            = azurerm_user_assigned_identity.apps.id
    }
  }
  # Agents reach ingest over HTTPS through the environment's managed ingress.
  ingress {
    external_enabled = true
    target_port      = 8443
    transport        = "http"
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }
  template {
    min_replicas = 1
    max_replicas = 1 # scale roles out by splitting into separate apps (see docs/ARCHITECTURE.md)
    container {
      name   = "backend"
      image  = "${var.registry}/skywatch/backend:${var.image_tag}"
      cpu    = 1
      memory = "2Gi"
      args   = ["serve", "--roles=collector,evaluator,ingest,notifier,probe,maintenance"]
      env {
        name        = "SKYWATCH_DATABASE_URL"
        secret_name = "worker-dsn"
      }
      env {
        name        = "SKYWATCH_KEKS"
        secret_name = "keks"
      }
      env {
        name        = "SKYWATCH_CONTROL_TOKEN"
        secret_name = "control-token"
      }
      env {
        name  = "SKYWATCH_CONTROL_ADDR"
        value = "0.0.0.0:8081"
      }
      env {
        name  = "SKYWATCH_TRUST_PROXY"
        value = "true"
      }
      env {
        name  = "SKYWATCH_PUBLIC_URL"
        value = var.public_hostname
      }
      liveness_probe {
        transport = "HTTP"
        port      = 8443
        path      = "/healthz"
      }
    }
  }
}

resource "azurerm_container_app" "api" {
  name                         = "ca-${var.name}-api"
  resource_group_name          = azurerm_resource_group.rg.name
  container_app_environment_id = azurerm_container_app_environment.env.id
  revision_mode                = "Single"
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.apps.id]
  }
  dynamic "secret" {
    for_each = toset(concat(["api-dsn", "keks", "control-token", "cookie-secret"], var.oidc == null ? [] : ["oidc-client-secret"]))
    content {
      name                = secret.value
      key_vault_secret_id = local.kv_ref[secret.value]
      identity            = azurerm_user_assigned_identity.apps.id
    }
  }
  ingress {
    external_enabled = false
    target_port      = 4000
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }
  template {
    min_replicas = 1
    max_replicas = 3
    container {
      name   = "api"
      image  = "${var.registry}/skywatch/api:${var.image_tag}"
      cpu    = 0.5
      memory = "1Gi"
      env {
        name        = "SKYWATCH_API_DATABASE_URL"
        secret_name = "api-dsn"
      }
      env {
        name        = "SKYWATCH_KEKS"
        secret_name = "keks"
      }
      env {
        name        = "SKYWATCH_CONTROL_TOKEN"
        secret_name = "control-token"
      }
      env {
        name        = "SKYWATCH_COOKIE_SECRET"
        secret_name = "cookie-secret"
      }
      env {
        # The backend's control listener is reachable inside the environment only.
        name  = "SKYWATCH_CONTROL_URL"
        value = "http://${azurerm_container_app.backend.name}:8081"
      }
      env {
        name  = "SKYWATCH_PUBLIC_URL"
        value = var.public_hostname
      }
      env {
        name  = "SKYWATCH_INGEST_PUBLIC_URL"
        value = var.ingest_hostname
      }
      env {
        name  = "SKYWATCH_TRUST_PROXY"
        value = "true"
      }
      dynamic "env" {
        for_each = var.oidc == null ? {} : { SKYWATCH_OIDC_ISSUER = var.oidc.issuer, SKYWATCH_OIDC_CLIENT_ID = var.oidc.client_id }
        content {
          name  = env.key
          value = env.value
        }
      }
      dynamic "env" {
        for_each = var.oidc == null ? [] : ["x"]
        content {
          name        = "SKYWATCH_OIDC_CLIENT_SECRET"
          secret_name = "oidc-client-secret"
        }
      }
    }
  }
}

resource "azurerm_container_app" "web" {
  name                         = "ca-${var.name}-web"
  resource_group_name          = azurerm_resource_group.rg.name
  container_app_environment_id = azurerm_container_app_environment.env.id
  revision_mode                = "Single"
  ingress {
    external_enabled = true
    target_port      = 3000
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }
  template {
    min_replicas = 1
    max_replicas = 3
    container {
      name = "web"
      # Build the web image with --build-arg SKYWATCH_API_ORIGIN=http://ca-<name>-api
      image  = "${var.registry}/skywatch/web:${var.image_tag}"
      cpu    = 0.5
      memory = "1Gi"
    }
  }
}

# Run once per release before rolling the apps: `az containerapp job start -n caj-<name>-migrate -g rg-<name>`
resource "azurerm_container_app_job" "migrate" {
  name                         = "caj-${var.name}-migrate"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = var.location
  container_app_environment_id = azurerm_container_app_environment.env.id
  replica_timeout_in_seconds   = 600
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.apps.id]
  }
  secret {
    name                = "migrate-dsn"
    key_vault_secret_id = local.kv_ref["migrate-dsn"]
    identity            = azurerm_user_assigned_identity.apps.id
  }
  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }
  template {
    container {
      name   = "migrate"
      image  = "${var.registry}/skywatch/backend:${var.image_tag}"
      cpu    = 0.5
      memory = "1Gi"
      args   = ["migrate"]
      env {
        name        = "SKYWATCH_MIGRATE_DATABASE_URL"
        secret_name = "migrate-dsn"
      }
    }
  }
}
