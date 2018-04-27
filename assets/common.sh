#!/bin/bash
set -e

setup_kubernetes() {
  local payload=$1

  export KUBECONFIG=$(mktemp $TMPDIR/kubernetes-resource-kubeconfig.XXXXXX)

  # Optional. The path of kubeconfig file
  local kubeconfig_file="$(jq -r '.params.kubeconfig_file // ""' < $payload)"
  # Optional. The content of kubeconfig
  local kubeconfig="$(jq -r '.source.kubeconfig // ""' < $payload)"

  if [[ -n "$kubeconfig_file"  ]]; then
    if [[ ! -f "$kubeconfig_file" ]]; then
      echoerr "kubeconfig file '$kubeconfig_file' does not exist"
      exit 1
    fi

    cat "$kubeconfig_file" > $KUBECONFIG
  elif [[ -n "$kubeconfig" ]]; then
    echo "$kubeconfig" > $KUBECONFIG
  else
    # Optional. The address and port of the API server. Requires token.
    local server="$(jq -r '.source.server // ""' < $payload)"
    # Optional. Bearer token for authentication to the API server. Requires server.
    local token="$(jq -r '.source.token // ""' < $payload)"
    # Optional. The namespace scope. Defaults to default if doesn't specify in kubeconfig.
    local namespace="$(jq -r '.source.namespace // ""' < $payload)"
    # Optional. A certificate file for the certificate authority.
    local certificate_authority="$(jq -r '.source.certificate_authority // ""' < $payload)"
    # Optional. If true, the API server's certificate will not be checked for
    # validity. This will make your HTTPS connections insecure. Defaults to false.
    local insecure_skip_tls_verify="$(jq -r '.source.insecure_skip_tls_verify // ""' < $payload)"

    if [[ -z "$server" || -z "$token" ]]; then
      echoerr 'You must specify "server" and "token", if not specify "kubeconfig".'
      exit 1
    fi

    local -r AUTH_NAME=auth
    local -r CLUSTER_NAME=cluster
    local -r CONTEXT_NAME=kubernetes-resource

    # Build options for kubectl config set-credentials
    # Avoid to expose the token string by using placeholder
    local set_credentials_opts="--token=**********"
    exe kubectl config set-credentials $AUTH_NAME $set_credentials_opts
    # placeholder is replaced with actual token string
    sed -i -e "s/[*]\{10\}/$token/" $KUBECONFIG

    # Build options for kubectl config set-cluster
    local set_cluster_opts="--server=$server"
    if [[ -n "$certificate_authority" ]]; then
      local ca_file=$(mktemp $TMPDIR/kubernetes-resource-ca_file.XXXXXX)
      echo -e "$certificate_authority" > $ca_file
      set_cluster_opts="$set_cluster_opts --certificate-authority=$ca_file"
    fi
    if [[ "$insecure_skip_tls_verify" == "true" ]]; then
      set_cluster_opts="$set_cluster_opts --insecure-skip-tls-verify"
    fi
    exe kubectl config set-cluster $CLUSTER_NAME $set_cluster_opts

    # Build options for kubectl config set-context
    local set_context_opts="--user=$AUTH_NAME --cluster=$CLUSTER_NAME"
    if [[ -n "$namespace" ]]; then
      set_context_opts="$set_context_opts --namespace=$namespace"
    fi
    exe kubectl config set-context $CONTEXT_NAME $set_context_opts

    exe kubectl config use-context $CONTEXT_NAME
  fi

  # Optional. The name of the kubeconfig context to use.
  local context="$(jq -r '.source.context // ""' < $payload)"
  if [[ -n "$context" ]]; then
    exe kubectl config use-context $context
  fi

  # Display the client and server version information
  exe kubectl version

  # Ignore the error from `kubectl cluster-info`. From v1.9.0, this command
  # fails if it cannot find the cluster services.
  # See https://github.com/kubernetes/kubernetes/commit/998f33272d90e4360053d64066b9722288a25aae
  exe kubectl cluster-info 2>/dev/null ||:
}

setup_gcloud() {
  local payload=$1

  local GCLOUDSERVICEACCOUNT=$(mktemp $TMPDIR/gcloud-service-account.json.XXXXXX)

  # Optional. The content of a Google Cloud service account JSON
  local gcloud_service_account="$(jq -r '.source.gcloud_service_account // ""' < $payload)"

  # Optional. The path of a Google Cloud service account JSON
  local gcloud_service_account_file="$(jq -r '.params.gcloud_service_account_file // ""' < $payload)"

  if [[ -n "$gcloud_service_account_file"  ]]; then
    if [[ ! -f "$gcloud_service_account_file" ]]; then
      echoerr "gcloud service account file '$gcloud_service_account_file' does not exist"
      exit 1
    fi

    cat "$gcloud_service_account_file" > ${GCLOUDSERVICEACCOUNT}
  elif [[ -n "$gcloud_service_account" ]]; then
    echo "$gcloud_service_account" > ${GCLOUDSERVICEACCOUNT}
  else
    echo "No gcloud service account info found..."
    return 0
  fi

  echo "Activating gcloud service account..."
  exe gcloud auth activate-service-account --key-file=${GCLOUDSERVICEACCOUNT}
}

setup_tls() {
  tls_enabled=$(jq -r '.source.tls_enabled // "false"' < $payload)
  if [ "$tls_enabled" = true ]; then
    helm_ca=$(jq -r '.source.helm_ca // ""' < $payload)
    helm_key=$(jq -r '.source.helm_key // ""' < $payload)
    helm_cert=$(jq -r '.source.helm_cert // ""' < $payload)
    if [ -z "$helm_ca" ]; then
      echo "invalid payload (missing helm_ca)"
      exit 1
    fi
    if [ -z "$helm_key" ]; then
      echo "invalid payload (missing helm_key)"
      exit 1
    fi
    if [ -z "$helm_cert" ]; then
      echo "invalid payload (missing helm_cert)"
      exit 1
    fi
    helm_ca_cert_path="/root/.helm/ca.pem"
    helm_key_path="/root/.helm/key.pem"
    helm_cert_path="/root/.helm/cert.pem"
    echo "$helm_ca" > $helm_ca_cert_path
    echo "$helm_key" > $helm_key_path
    echo "$helm_cert" > $helm_cert_path
  fi
}

setup_helm() {
  init_server=$(jq -r '.source.helm_init_server // "false"' < $1)
  tiller_namespace=$(jq -r '.source.tiller_namespace // "kube-system"' < $1)
  tls_enabled=$(jq -r '.source.tls_enabled // "false"' < $payload)
  if [ "$init_server" = true ]; then
    tiller_service_account=$(jq -r '.source.tiller_service_account // "default"' < $1)
    if [ "$tls_enabled" = true ]; then
      tiller_key=$(jq -r '.source.tiller_key // ""' < $payload)
      tiller_cert=$(jq -r '.source.tiller_cert // ""' < $payload)
      if [ -z "$tiller_key" ]; then
        echo "invalid payload (missing tiller_key)"
        exit 1
      fi
      if [ -z "$tiller_cert" ]; then
        echo "invalid payload (missing tiller_cert)"
        exit 1
      fi
      tiller_key_path="/root/.helm/tiller_key.pem"
      tiller_cert_path="/root/.helm/tiller_cert.pem"
      helm_ca_cert_path="/root/.helm/ca.pem"
      echo "$tiller_key" > $tiller_key_path
      echo "$tiller_cert" > $tiller_cert_path
      helm init --tiller-tls --tiller-tls-cert $tiller_cert_path --tiller-tls-key $tiller_key_path --tiller-tls-verify --tls-ca-cert $tiller_key_path --tiller-namespace=$tiller_namespace --service-account=$tiller_service_account --upgrade
    else
      helm init --tiller-namespace=$tiller_namespace --service-account=$tiller_service_account --upgrade
    fi
    wait_for_service_up tiller-deploy 10
  else
    export HELM_HOST=$(jq -r '.source.helm_host // ""' < $1)
    helm init -c --tiller-namespace $tiller_namespace > /dev/null
  fi
  if [ "$tls_enabled" = true ]; then
    helm version --tls --tiller-namespace $tiller_namespace
  else
    helm version --tiller-namespace $tiller_namespace
  fi
}

wait_for_service_up() {
  SERVICE=$1
  TIMEOUT=$2
  if [ "$TIMEOUT" -le "0" ]; then
    echo "Service $SERVICE was not ready in time"
    exit 1
  fi
  RESULT=`kubectl get endpoints --namespace=$tiller_namespace $SERVICE -o jsonpath={.subsets[].addresses[].targetRef.name} 2> /dev/null || true`
  if [ -z "$RESULT" ]; then
    sleep 1
    wait_for_service_up $SERVICE $((--TIMEOUT))
  fi
}

setup_repos() {
  repos=$(jq -c '(try .source.repos[] catch [][])' < $1)
  tiller_namespace=$(jq -r '.source.tiller_namespace // "kube-system"' < $1)

  local IFS=$'\n'
  for r in $repos; do
    name=$(echo $r | jq -r '.name')
    url=$(echo $r | jq -r '.url')
    username=$(echo $r | jq -r '.username // ""')
    password=$(echo $r | jq -r '.password // ""')

    echo Installing helm repository $name $url
    if [[ -n "$username" && -n "$password" ]]; then
      helm repo add $name $url --tiller-namespace $tiller_namespace --username $username --password $password
    else
      helm repo add $name $url --tiller-namespace $tiller_namespace
    fi
    helm repo update
  done
}

setup_resource() {
  setup_gcloud $1
  echo "Initializing kubectl..."
  setup_kubernetes $1 $2
  echo "Initializing helm..."
  setup_tls $1
  setup_helm $1
  setup_repos $1
}
