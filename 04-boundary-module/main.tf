terraform {
  required_providers {
    boundary = {
      source  = "hashicorp/boundary"
      version = "1.0.5"
    }
  }
}
variable "vault_addr" {}
variable "vault_boundary_token" {}
provider "boundary" {
  addr                            = "http://:9200"
  auth_method_id                  = "ampw_1234567890" # changeme
  password_auth_method_login_name = "admin"           # changeme
  password_auth_method_password   = "zerotrust"        # changeme
}
resource "boundary_scope" "org" {
  name                     = "zerotrust"
  description              = "Trust noone"
  scope_id                 = "global"
  auto_create_admin_role   = true
  auto_create_default_role = true
}

resource "boundary_scope" "project" {
  name                   = "Hashicorp-Terasky"
  description            = "Workshop"
  scope_id               = boundary_scope.org.id
  auto_create_admin_role = true
}

resource "boundary_host_catalog" "aws_eks" {
  type = "static"
  name = "eks services"
  scope_id = boundary_scope.project.id
}

resource "boundary_host" "boundary_host" {
  for_each = var.services

  name            = "${each.value.id}"
  type            = "static"
  description     = "${each.value.name}"
  address         = each.value.address
  host_catalog_id = boundary_host_catalog.aws_eks.id
}


resource "boundary_host_set" "eks_hosts" {
  for_each = toset(distinct([ for i,z in var.services : z.name ]))
  name = "${each.value}"
  host_catalog_id = boundary_host_catalog.aws_eks.id
  type            = "static"
  host_ids        = [for i in boundary_host.boundary_host : i.id if i.description == each.value ]
}
resource "boundary_target" "mysql_target" {
  for_each = toset([ for hs in boundary_host_set.eks_hosts: hs.name if length(regexall(".*mysql.*", hs.name )) > 0 ])
  name         = "${each.value} - 3306"
  description  = "Connect to ${each.value} service on 3306 port "
  type         = "tcp"
  scope_id     = boundary_scope.project.id
  host_source_ids =  [ for hs in boundary_host_set.eks_hosts: hs.id if hs.name == each.value ]
  default_port = "3306"
  application_credential_source_ids = [
    boundary_credential_library_vault.mysql_creds.id
  ]
}

resource "boundary_credential_store_vault" "vault_hcp" {
  name        = "vault-hcp"
  description = "Vault to pull our secrets from"
  address     = var.vault_addr
  token       = var.vault_boundary_token
  namespace   = "admin"
  scope_id    = boundary_scope.project.id
}
resource "boundary_credential_library_vault" "mysql_creds" {
  name                = "mysql-creds"
  description         = "Credentials for mysql"
  credential_store_id = boundary_credential_store_vault.vault_hcp.id
  path                = "database/creds/readonly"
  http_method         = "GET"
}
