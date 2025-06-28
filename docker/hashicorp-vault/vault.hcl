# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: BUSL-1.1

# Full configuration options can be found at https://developer.hashicorp.com/vault/docs/configuration

ui = true

#mlock = true
disable_mlock = true

storage "postgresql" {
  connection_url = "postgresql://amin:M%40%24ter21091996@homelab-db.postgres.database.azure.com:5432/vault-data?sslmode=verify-full"
}

#storage "file" {
#  path = "/vault/file"
#}

#storage "consul" {
#  address = "127.0.0.1:8500"
#  path    = "vault"
#}

# HTTP listener
listener "tcp" {
  address = "0.0.0.0:8200"
  tls_disable = 1
}

# HTTPS listener
#listener "tcp" {
#  address       = "0.0.0.0:8200"
#  tls_cert_file = "/opt/vault/tls/tls.crt"
#  tls_key_file  = "/opt/vault/tls/tls.key"
#}

# Enterprise license_path
# This will be required for enterprise as of v1.8
#license_path = "/etc/vault.d/vault.hclic"

# Example AWS KMS auto unseal
#seal "awskms" {
#  region = "us-east-1"
#  kms_key_id = "REPLACE-ME"
#}

# Example HSM auto unseal
#seal "pkcs11" {
#  lib            = "/usr/vault/lib/libCryptoki2_64.so"
#  slot           = "0"
#  pin            = "AAAA-BBBB-CCCC-DDDD"
#  key_label      = "vault-hsm-key"
#  hmac_key_label = "vault-hsm-hmac-key"
#}
seal "azurekeyvault" {
  tenant_id      = "51915c63-2929-472b-bcc2-01b2f4ff4592"
  client_id      = "da5983bd-049e-4845-ac33-f0f6ba47fff0"
  client_secret  = "hAi8Q~rVhCwa_JnJ0KbJHng0TawDMCny6XCq3a9M"
  vault_name     = "hashicorp-unseal-vault"
  key_name       = "unseal-key-hcl"
}