#!/bin/bash

########################
# include the magic
########################
. /usr/local/bin/demo-magic.sh
TYPE_SPEED=80
clear

pe 'ls -l'
pe 'cd 02-hcp'
pe 'ls -l'
pe 'cat outputs.tf'
pe 'export CONSUL_HTTP_TOKEN=$(terraform output --raw consul_root_token_secret_id )'

p "Open $(terraform output consul_public_endpoint) and use ${CONSUL_HTTP_TOKEN} token to login"

pe 'terraform output --raw consul_ca_file |  base64 -d> ./ca.pem'
pe 'export KUBECONFIG=/tmp/kubeconfig'
pe "kubectl create secret generic \"consul-ca-cert\" --from-file='tls.crt=./ca.pem'"

pe 'terraform output --raw consul_config_file | base64 -d | jq > client_config.json'
pe 'cat client_config.json'
pe 'kubectl create secret generic "consul-gossip-key" --from-literal="key=$(jq -r .encrypt client_config.json)"'

pe 'kubectl create secret generic "consul-bootstrap-token" --from-literal="token=${CONSUL_HTTP_TOKEN}"'
# read about bootstrap ACL
#https://learn.hashicorp.com/tutorials/consul/access-control-setup-production?in=consul/security

pe 'export DATACENTER=$(jq -r .datacenter client_config.json)'
pe 'export RETRY_JOIN=$(jq -r --compact-output .retry_join client_config.json)'
pe 'export K8S_HTTP_ADDR=$(kubectl config view -o jsonpath="{.clusters[?(@.name == \"$(kubectl config current-context)\")].cluster.server}")'
pe 'echo $DATACENTER && \
  echo $RETRY_JOIN && \
  echo $K8S_HTTP_ADDR'

cat > config.yaml << EOF
global:
  logLevel: "debug"
  name: consul
  enabled: false
  datacenter: ${DATACENTER}
  acls:
    manageSystemACLs: true
    bootstrapToken:
      secretName: consul-bootstrap-token
      secretKey: token
  gossipEncryption:
    secretName: consul-gossip-key
    secretKey: key
  tls:
    enabled: true
    enableAutoEncrypt: true
    caCert:
      secretName: consul-ca-cert
      secretKey: tls.crt
externalServers:
  enabled: true
  hosts: ${RETRY_JOIN}
  httpsPort: 443
  useSystemRoots: true
  k8sAuthMethodHost: ${K8S_HTTP_ADDR}
client:
  enabled: true
  join: ${RETRY_JOIN}
connectInject:
  enabled: true
  default: true
  transparentProxy:
    defaultEnabled: true
controller:
  enabled: true
ingressGateways:
  enabled: false
syncCatalog:
  enabled: false
EOF

pe 'cat config.yaml'
pe 'helm install --wait consul -f config.yaml hashicorp/consul --version "0.39.0" --set global.image=hashicorp/consul-enterprise:1.10.6-ent'

pe 'kubectl get pods'

p "Open $(terraform output consul_public_endpoint) and use ${CONSUL_HTTP_TOKEN} token to login"
pe 'kubectl get svc'


pe 'cd /tmp'
pe 'git clone https://github.com/GoogleCloudPlatform/microservices-demo.git'
pe 'diff  /02-hcp/kubernetes-manifests.yaml /tmp/microservices-demo/release/kubernetes-manifests.yaml'
pe 'cp  /02-hcp/kubernetes-manifests.yaml /tmp/microservices-demo/release/kubernetes-manifests.yaml'

pe 'for i in checkoutservice adservice cartservice currencyservice emailservice frontend loadgenerator paymentservice productcatalogservice recommendationservice redis-cart shippingservice; do kubectl create sa ${i};done'

pe 'cd microservices-demo'

#add service account matching the service in consul
kubectl apply -f ./release/kubernetes-manifests.yaml

pe 'helm repo add traefik https://helm.traefik.io/traefik'

pe 'helm repo update'

export KUBERNETES_SVC_IP=$(kubectl get svc kubernetes -o=jsonpath='{.spec.clusterIP}')
cat <<EOF > traefik_values.yaml
deployment:
   podAnnotations:
      consul.hashicorp.com/connect-inject: "true"
      consul.hashicorp.com/connect-service: "traefik"
      consul.hashicorp.com/transparent-proxy: "true"
      consul.hashicorp.com/transparent-proxy-overwrite-probes: "true"
      consul.hashicorp.com/transparent-proxy-exclude-inbound-ports: "9000,8000,8443"
      consul.hashicorp.com/transparent-proxy-exclude-outbound-ports: "443"
      consul.hashicorp.com/transparent-proxy-exclude-outbound-cidrs: "${KUBERNETES_SVC_IP}/32"

logs:
   general:
      level: DEBUG
EOF
pe 'cat traefik_values.yaml'

pe 'helm install -n default traefik traefik/traefik -f traefik_values.yaml'

cat <<EOF > consul.yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ServiceDefaults
metadata:
  name: traefik
spec:
  protocol: http
EOF

pe 'cat consul.yaml'
pe 'kubectl apply -f consul.yaml'
pe 'kubectl get svc traefik'
export TRAEFIK_SVC=$(kubectl get services traefik -o=jsonpath='{.status.loadBalancer.ingress[0].hostname}')
pe 'echo $TRAEFIK_SVC'
cat <<EOF > openssl.cnf
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no
[req_distinguished_name]
C = IL
ST = TA
L = Tel Aviv
O = Terasky
OU = IT
CN = *.elb.amazonaws.com
[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${TRAEFIK_SVC}
EOF
pe 'cat openssl.cnf'
pe 'openssl req -config openssl.cnf -newkey rsa:4096  -x509 -sha256 -days 3650 -nodes -out server.crt -keyout server.key'
pe 'kubectl create secret generic traefik --from-file=tls.crt=./server.crt --from-file=tls.key=./server.key'

cat <<EOF > ingress.yaml
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: frontend
spec:
  entryPoints:
    - websecure
  routes:
  - match: PathPrefix(\`/\`)
    kind: Rule
    services:
    - name: frontend
      port: 80
      passHostHeader: false
  tls:
    domains:
    - main: ${TRAEFIK_SVC}
---
apiVersion: traefik.containo.us/v1alpha1
kind: TLSStore
metadata:
  name: default
  namespace: default
spec:
  defaultCertificate:
    secretName: traefik
EOF

pe 'cat ingress.yaml'
pe 'kubectl apply -f ingress.yaml'

cat <<EOF > frontend.yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ServiceDefaults
metadata:
  name: frontend
spec:
  protocol: http
  transparentProxy:
    dialedDirectly: true
EOF
pe 'cat frontend.yaml'
pe 'kubectl apply -f frontend.yaml'
pe 'cat /02-hcp/intentions.yaml'
pe 'kubectl apply -f /02-hcp/intentions.yaml'
p "Browse to https://${TRAEFIK_SVC}"
