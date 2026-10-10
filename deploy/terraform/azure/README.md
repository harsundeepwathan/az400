# Azure reference deployment (Terraform)

Creates:
- Container Apps: web (public), backend (public ingest, internal control), api (internal)
- a migrate job
- PostgreSQL Flexible Server 16 (14-day PITR)
- Key Vault (RBAC) holding every secret, read by a user-assigned identity
- Log Analytics

```bash
terraform init
terraform apply -var subscription_id=… -var registry=ghcr.io/you -var image_tag=v0.1.0 \
  -var public_hostname=https://skywatch.example.com -var ingest_hostname=https://ingest.skywatch.example.com
terraform output -raw role_bootstrap_sql | psql "$(az keyvault secret show --vault-name $(terraform output -raw key_vault) -n migrate-dsn --query value -o tsv)"
az containerapp job start -n caj-skywatch-migrate -g rg-skywatch
```

Known gaps (tracked in docs/MILESTONES.md):
- The KEK is a Key Vault *secret* consumed by the local keyring. A Key Vault *key* with wrap/unwrap (HSM-backed `KeyProvider`) is the target design.
- PostgreSQL uses public access restricted to Azure services. Use VNet integration plus a private endpoint for production.
- All roles run in one backend app. Split them into separate apps to scale the collector and ingest independently.
