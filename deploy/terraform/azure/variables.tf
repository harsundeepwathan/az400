variable "subscription_id" { type = string }
variable "name" {
  type        = string
  default     = "skywatch"
  description = "Prefix for resource names (lowercase letters and digits)."
}
variable "location" {
  type    = string
  default = "westeurope"
}
variable "image_tag" {
  type        = string
  description = "Tag of skywatch/backend, skywatch/api and skywatch/web in the registry."
}
variable "registry" {
  type        = string
  description = "Registry hosting the images, e.g. ghcr.io/your-org."
}
variable "public_hostname" {
  type        = string
  description = "Public URL users browse to (custom domain on the web app), e.g. https://skywatch.example.com"
}
variable "ingest_hostname" {
  type        = string
  description = "Public URL agents connect to, e.g. https://ingest.skywatch.example.com"
}
variable "oidc" {
  type      = object({ issuer = string, client_id = string, client_secret = string })
  default   = null
  sensitive = true
}
variable "postgres_sku" {
  type    = string
  default = "GP_Standard_D2ds_v5"
}
