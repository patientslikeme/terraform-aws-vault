#!/bin/bash
# This script is meant to be run in the User Data of each EC2 Instance while it's booting. The script uses the
# run-consul script to configure and start Consul in client mode and then the run-vault script to configure and start
# Vault in server mode. Note that this script assumes it's running in an AMI built from the Packer template in
# examples/vault-consul-ami/vault-consul.json.

set -e

# Send the log output from this script to user-data.log, syslog, and the console
# From: https://alestic.com/2010/12/ec2-user-data-output/
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

# The Packer template puts the TLS certs in these file paths
readonly VAULT_TLS_CERT_FILE="/opt/vault/tls/vault.crt.pem"
readonly VAULT_TLS_KEY_FILE="/opt/vault/tls/vault.key.pem"

# The cluster_tag variables below are filled in via Terraform interpolation
/opt/consul/bin/run-consul --client --cluster-tag-key "${consul_cluster_tag_key}" --cluster-tag-value "${consul_cluster_tag_value}"
/opt/vault/bin/run-vault --tls-cert-file "$VAULT_TLS_CERT_FILE"  --tls-key-file "$VAULT_TLS_KEY_FILE"

# Initializes a vault server
# run-vault is running on the background, so in case it fails we retry
for i in $(seq 1 10); do server_output=$(/opt/vault/bin/vault operator init) && s=0 && break || s=$? && sleep 20; done; (exit $s)

# The expected output should be similar to this:
# ==========================================================================
# Unseal Key 1: ddPRelXzh9BdgqIDqQO9K0ldtHIBmY9AqsTohM6zCRl7
# Unseal Key 2: liSgypzdVrAxz73KbKyCMjVeSnRMuxCZMk1PWIZdjENS
# Unseal Key 3: pmgeVu/fs8+jl8bOzf3Cq56BFufm4o7Sxt2oaUcvt6Dp
# Unseal Key 4: i3W2xJEyUqUqcO1QSjTA+Ua0RUPxnNWM27AqaC8wW7Zh
# Unseal Key 5: vHsQtCRgfblPeFYw1hhCVbji0MoNUP8zyIWhLWs3PebS
#
# Initial Root Token: cb076fc1-cc1f-6766-795f-b3822ba1ac57
#
# Vault initialized with 5 key shares and a key threshold of 3. Please securely
# distribute the key shares printed above. When the Vault is re-sealed,
# restarted, or stopped, you must supply at least 3 of these keys to unseal it
# before it can start servicing requests.
#
# Vault does not store the generated master key. Without at least 3 key to
# reconstruct the master key, Vault will remain permanently sealed!
#
# It is possible to generate new unseal keys, provided you have a quorum of
# existing unseal keys shares. See "vault operator rekey" for more information.
# ==========================================================================

# Unseals the server with 3 keys from this output
echo "$server_output" | head -n 3 | awk '{ print $4; }' | xargs -l /opt/vault/bin/vault operator unseal

# Exports the client token environment variable necessary for running the following vault commands
export VAULT_TOKEN=$(echo "$server_output" | head -n 7 | tail -n 1 | awk '{ print $4; }')

# Enables AWS authentication
/opt/vault/bin/vault auth enable aws

# Creates a policy that allows writing and reading from an "example_" prefix at "secret" backend
/opt/vault/bin/vault policy write "example-policy" -<<EOF
path "secret/example_*" {
  capabilities = ["create", "read"]
}
EOF

# Creates authentication role
# The role name & ami id are being passed by terraform
# This example uses the ami id as a criteria for whitelisting, but there are multiple
# other settings you can pick for EC2 metadata auth.
# Read more at:
/opt/vault/bin/vault write \
  auth/aws/role/${example_role_name}\
  auth_type=ec2 \
  policies=example-policy \
  max_ttl=500h \
  bound_ami_id=${ami_id}

# Writes some secret, this secret is being written by terraform for test purposes
/opt/vault/bin/vault write secret/example_gruntwork the_answer=${example_secret}