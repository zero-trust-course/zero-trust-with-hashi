#!/bin/bash

########################
# include the magic
########################
. /usr/local/bin/demo-magic.sh
TYPE_SPEED=80
clear

pe "ls -l"
pe "cd 02-hcp"
pe "ls -l"
pe "cat remote.tf"
[ ! -f remote.tf.bck ] && cp remote.tf remote.tf.bck
sed "s#\"\"#\"$TF_VAR_tfc_organization_name\"#g" remote.tf.bck > remote.tf
p 'add organization'
pe "cat remote.tf"
p "use ${TF_VAR_tfc_token} to login"
pe "terraform login"
pe "terraform init"

p "Lets get configurations from our terraform outputs and put the in environment variables"

pe 'export VAULT_TOKEN=$(terraform output --raw vault_admin_token)'
pe 'echo $VAULT_TOKEN'
pe 'export VAULT_ADDR=$(terraform output --raw vault_public_endpoint_url)'
pe 'echo $VAULT_ADDR'
pe 'export VAULT_PRIVATE_ADDR=$(terraform output --raw vault_private_endpoint_url)'
pe 'echo $VAULT_PRIVATE_ADDR'
p "Default namespace in hcp is admin"
pe "export VAULT_NAMESPACE=admin"
pe "vault status"


p "Now let's get kubectl_config output and put in in /tmp/kubeconfig but it's in another directory (and state) 03-eks"
pe "cd ../03-eks"
[ ! -f remote.tf.bck ] && cp remote.tf remote.tf.bck
sed "s#\"\"#\"$TF_VAR_tfc_organization_name\"#g" remote.tf.bck > remote.tf
pe "terraform init"
pe "terraform output --raw kubectl_config > /tmp/kubeconfig"
#p "clean the file a bit and let's see it"
#sed "/.*EOT$/d" /tmp/kubeconfig_raw > /tmp/kubeconfig

pe "cat /tmp/kubeconfig"
pe "export KUBECONFIG=/tmp/kubeconfig"
pe "chmod 600 /tmp/kubeconfig"

pe "kubectl get pods -A"


# mysql deployment
pe 'clear'
pe "helm repo add bitnami https://charts.bitnami.com/bitnami"

pe "helm install --wait mysql bitnami/mysql --set 'primary.service.type=LoadBalancer'"

pe "kubectl get pods"
pe "kubectl get services"


pe 'export ROOT_PASSWORD=$(kubectl get secret --namespace default mysql -o jsonpath="{.data.mysql-root-password}" | base64 --decode)'

pe "vault secrets enable database"


pe "export MYSQL_SVC=\"$(kubectl get services mysql -o=jsonpath='{.status.loadBalancer.ingress[0].hostname}')\""

pe "vault write database/config/mysql plugin_name=mysql-database-plugin connection_url=\"{{username}}:{{password}}@tcp(${MYSQL_SVC}:3306)/\"  allowed_roles=\"readonly\"  username=\"root\" password=\"$ROOT_PASSWORD\""

#pe 'vault write -force database/rotate-root/mysql'
pe "vault write database/roles/readonly db_name=mysql  creation_statements=\"CREATE USER '{{name}}'@'%' IDENTIFIED BY '{{password}}';GRANT SELECT ON *.* TO '{{name}}'@'%';\"  default_ttl=\"1m\"  max_ttl=\"1m\""

pe "vault read database/creds/readonly > /tmp/creds"
pe "cat /tmp/creds"
pe "export TEST_MYSQL_PASS=$(cat /tmp/creds | grep password | awk '{print $2}')"
pe "export TEST_MYSQL_USER=$(cat /tmp/creds | grep user | awk '{print $2}')"
pe "mysql -h ${MYSQL_SVC} -u ${TEST_MYSQL_USER}  -p${TEST_MYSQL_PASS}"


pe "clear"

p "Let install vault injector in EKS"
pe "helm repo add hashicorp https://helm.releases.hashicorp.com && helm repo update"

cat > values.yaml << EOF
injector:
   enabled: true
   externalVaultAddr: "${VAULT_PRIVATE_ADDR}"
EOF

pe "cat values.yaml"
pe "helm install --wait vault -f values.yaml hashicorp/vault"

pe "kubectl get pods"

pe "let us make EKS workloads authenticate with Vault"

pe "vault auth enable kubernetes"

p "Now we need to get some info to connect EKS and Vault HCP"

#p "TOKEN_REVIEW_JWT is a secret token from vault service account"
#pe "kubectl get secret $(kubectl get serviceaccount vault -o jsonpath='{.secrets[0].name}') -o jsonpath='{ .data.token }' | base64 --decode"
echo '#example of configuration' > config_example
echo "export TOKEN_REVIEW_JWT=\$(kubectl get secret \$(kubectl get serviceaccount vault -o jsonpath='{.secrets[0].name}')  -o jsonpath='{ .data.token }' | base64 --decode)" >> config_example
echo "export KUBE_CA_CERT=\$(kubectl get secret  \$(kubectl get serviceaccount vault -o jsonpath='{.secrets[0].name}') -o jsonpath='{ .data.ca\.crt }' | base64 --decode)" >> config_example
echo "export KUBE_HOST=\$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[].cluster.server}')" >> config_example

pe "cat config_example"
export TOKEN_REVIEW_JWT=$(kubectl get secret \
   $(kubectl get serviceaccount vault -o jsonpath='{.secrets[0].name}') \
   -o jsonpath='{ .data.token }' | base64 --decode)

export KUBE_CA_CERT=$(kubectl get secret  $(kubectl get serviceaccount vault -o jsonpath='{.secrets[0].name}') -o jsonpath='{ .data.ca\.crt }' | base64 --decode)
echo
export KUBE_HOST=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[].cluster.server}')
echo
p "Let's get oidc issuer"
pe "kubectl proxy &"
pe "curl --silent http://127.0.0.1:8001/.well-known/openid-configuration | jq -r .issuer"
export ISSUER="$(curl --silent http://127.0.0.1:8001/.well-known/openid-configuration | jq -r .issuer)"
pe "kill %1"

pe 'vault write auth/kubernetes/config \
   token_reviewer_jwt="$TOKEN_REVIEW_JWT" \
   kubernetes_host="$KUBE_HOST" \
   kubernetes_ca_cert="$KUBE_CA_CERT" \
   issuer="$ISSUER"'

p "Creating devwebapp policy:"
echo '"database/creds/readonly" {
  capabilities = ["read"]
}'
p "vault policy write devwebapp devwebapp.hcl"
vault policy write devwebapp - <<EOF
path "database/creds/readonly" {
  capabilities = ["read"]
}
EOF

pe "vault write auth/kubernetes/role/devweb-app bound_service_account_names=internal-app bound_service_account_namespaces=default policies=devwebapp ttl=24h"


cat > devwebapp.yaml <<EOF
---
apiVersion: v1
kind: Pod
metadata:
  name: devwebapp
  labels:
    app: devwebapp
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/agent-cache-enable: "true"
    vault.hashicorp.com/role: "devweb-app"
    vault.hashicorp.com/namespace: "admin"
    vault.hashicorp.com/agent-inject-secret-database-connect.txt: "database/creds/readonly"
    vault.hashicorp.com/agent-inject-template-database-connect.txt: |
      config:
      {{ with secret "database/creds/readonly" -}}
      username: {{ .Data.username }}
      password: {{ .Data.password }}
      {{- end -}}
spec:
  serviceAccountName: internal-app
  containers:
    - name: devwebapp
      image: jweissig/app:0.0.1
EOF
p "let's create some workload now"
pe "cat devwebapp.yaml"
cat > internal-app.yaml <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: internal-app
EOF

pe "cat internal-app.yaml"
pe "kubectl apply -f internal-app.yaml"
pe "kubectl apply -f devwebapp.yaml"

pe 'kubectl wait pod/devwebapp --for condition=ready'

pe "kubectl get pods"

pe "kubectl describe pod devwebapp"

pe "kubectl exec -it devwebapp -c vault-agent -- cat /home/vault/config.json | jq ."

pe "kubectl exec -it devwebapp -c devwebapp -- cat /vault/secrets/database-connect.txt"

pe ""

pe "sleep 60"

pe "kubectl exec -it devwebapp -c devwebapp -- cat /vault/secrets/database-connect.txt"
