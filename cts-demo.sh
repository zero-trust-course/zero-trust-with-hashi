#!/bin/bash

########################
# include the magic
########################
. /usr/local/bin/demo-magic.sh
TYPE_SPEED=80
clear

#####hashicorp/consul-terraform-sync
pe 'ls -l'
pe 'cd 02-hcp'
pe 'ls -l'
pe 'export CONSUL_HTTP_TOKEN=$(terraform output --raw consul_root_token_secret_id)'
pe 'export CONSUL_PRIVATE_ADDRESS=$(terraform output --raw consul_private_endpoint)'

pe 'cd ../01-vpc'
pe "cat remote.tf"
[ ! -f remote.tf.bck ] && cp remote.tf remote.tf.bck
sed "s#\"\"#\"$TF_VAR_tfc_organization_name\"#g" remote.tf.bck > remote.tf
pe "cat remote.tf"
pe "terraform init"
pe 'export BOUNDARY_IP=$(terraform output --raw boundary_public_ip)'
p "browse to http://${BOUNDARY_IP}:9200"
[ ! -f ../04-boundary-module/main.tf.bck  ] && cp ../04-boundary-module/main.tf ../04-boundary-module/main.tf.bck
sed "s#http://:9200#http://${BOUNDARY_IP}:9200#g"  ../04-boundary-module/main.tf.bck > ../04-boundary-module/main.tf

cat > cts.hcl << EOF
consul {
  address = "${CONSUL_PRIVATE_ADDRESS}"
  token = "${CONSUL_HTTP_TOKEN}"
}

log_level = "DEBUG"

task {
  name = "example-task"
  description = "Writes the service name, id, and IP address to a file"
  source      = "./boundary-module"
#  source  = "mkam/hello/cts"
  providers = ["local"]
  condition "services" {
    regexp = ".*"
  }
  variable_files = ["/consul-terraform-sync/vars/vault.tfvars"]
}

driver "terraform" {
  backend "local" {
    path = "./terraform.tfstate"
  }
  required_providers {
    local = {
      source = "hashicorp/local"
      version = "2.1.0"
    }
  }
}

terraform_provider "local" {
}
EOF
pe 'cat cts.hcl'
pe 'export KUBECONFIG=/tmp/kubeconfig'
pe 'kubectl create secret generic cts-config --from-file=./cts.hcl'
p 'Now we configure credential store'

pe "cd ../02-hcp"
pe 'export VAULT_TOKEN=$(terraform output --raw vault_admin_token)'
pe 'export VAULT_ADDR=$(terraform output --raw vault_public_endpoint_url)'
pe 'export VAULT_PRIVATE_ADDR=$(terraform output --raw vault_private_endpoint_url)'
pe "export VAULT_NAMESPACE=admin"
pe "curl https://boundaryproject.io/data/vault/boundary-controller-policy.hcl -O -s -L"
pe "cat boundary-controller-policy.hcl"
pe "vault policy write boundary-controller boundary-controller-policy.hcl"
pe "export VAULT_BOUNDARY_TOKEN=$(vault token create -no-default-policy=true -policy="boundary-controller" -policy="devwebapp" -orphan=true -period=20m -renewable=true| grep '^token ' | awk '{print $2}')"
[ ! -f ../04-boundary-module/main.tf.bck  ] && cp ../04-boundary-module/main.tf ../04-boundary-module/main.tf.bck
sed "s#http://:9200#http://${BOUNDARY_IP}:9200#g"  ../04-boundary-module/main.tf.bck > ../04-boundary-module/main.tf
echo "vault_addr=\"${VAULT_ADDR}\"" > ./vault.tfvars
echo "vault_boundary_token=\"${VAULT_BOUNDARY_TOKEN}\"" >> ./vault.tfvars
pe "cat ./vault.tfvars"
pe 'kubectl create secret generic vault-vars --from-file=./vault.tfvars'
pe 'kubectl create secret generic boundary-module --from-file=../04-boundary-module'
p "Let's deploy terraform consul sync"
cat > cts.yaml <<EOF
---
apiVersion: v1
kind: Pod
metadata:
  name: cts
  labels:
    app: cts
spec:
  containers:
    - name: cts
      image: hashicorp/consul-terraform-sync
      args:
      - "-config-file"
      - "/etc/cts/cts.hcl"
      volumeMounts:
      - name: cts-config
        mountPath: "/etc/cts"
      - name: boundary-module
        mountPath: "/consul-terraform-sync/boundary-module"
      - name: vault-vars
        mountPath: "/consul-terraform-sync/vars"
  volumes:
  - name: cts-config
    secret:
      secretName: cts-config
  - name: boundary-module
    secret:
      secretName: boundary-module
  - name: vault-vars
    secret:
      secretName: vault-vars
EOF
pe 'cat cts.yaml'
pe 'kubectl apply -f cts.yaml'
pe 'kubectl wait pod/cts --for condition=ready'
pe 'kubectl logs cts'
pe 'kubectl exec -it cts -- cat /consul-terraform-sync/sync-tasks/example-task/terraform.tfvars'
p "browse to http://${BOUNDARY_IP}:9200"

#####
