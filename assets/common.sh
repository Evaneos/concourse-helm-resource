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

setup_helm() {
  init_server=$(jq -r '.source.helm_init_server // "false"' < $1)
  tiller_namespace=$(jq -r '.source.tiller_namespace // "kube-system"' < $1)

  if [ "$init_server" = true ]; then
    tiller_service_account=$(jq -r '.source.tiller_service_account // "default"' < $1)
    helm init --tiller-namespace=$tiller_namespace --service-account=$tiller_service_account --upgrade
    wait_for_service_up tiller-deploy 10
  else
    helm init -c --tiller-namespace $tiller_namespace > /dev/null
  fi

  helm version --tiller-namespace $tiller_namespace
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
  repos=$(jq -r '(try .source.repos[] catch [][]) | (.name+" "+.url)' < $1)
  tiller_namespace=$(jq -r '.source.tiller_namespace // "kube-system"' < $1)

  IFS=$'\n'
  for r in $repos; do
    name=$(echo $r | cut -f1 -d' ')
    url=$(echo $r | cut -f2 -d' ')
    echo Installing helm repository $name $url
    helm repo add --tiller-namespace $tiller_namespace $name $url
  done
}

setup_resource() {
  echo "Initializing kubectl..."
  setup_kubernetes $1 $2
  echo "Initializing helm..."
  setup_helm $1
  setup_repos $1
}
