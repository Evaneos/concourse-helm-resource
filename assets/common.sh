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

setup_tls() {
  tls_enabled=$(jq -r '.source.tls_enabled // "false"' < $payload)
  tillerless=$(jq -r '.source.tillerless // "false"' < $payload)
  if [ "$tls_enabled" = true ]; then
    if [ "$tillerless" = true ]; then
      echo "Setting both tls_enabled and tillerless is not supported"
      exit 1
    fi

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
  # $1 is the name of the payload file
  # $2 is the name of the source directory
  init_server=$(jq -r '.source.helm_init_server // "false"' < $1)

  # Compute tiller_namespace as follows:
  # If kubeconfig_tiller_namespace is set, then tiller_namespace is the namespace from the kubeconfig
  # If tiller_namespace is set and it is the name of a file, then tiller_namespace is the contents of the file
  # If tiller_namespace is set and it is not the name of a file, then tiller_namespace is the literal
  # Otherwise tiller_namespace defaults to kube-system
  kubeconfig_tiller_namespace=$(jq -r '.source.kubeconfig_tiller_namespace // "false"' <$1)
  if [ "$kubeconfig_tiller_namespace" = "true" ]
  then
    tiller_namespace=$(kubectl config view --minify -ojson | jq -r .contexts[].context.namespace)
  else
    tiller_namespace=$(jq -r '.source.tiller_namespace // "kube-system"' < $1)
    if [ "$tiller_namespace" != "kube-system" -a -f "$2/$tiller_namespace" ]
    then
      tiller_namespace=$(cat "$2/$tiller_namespace")
    fi
  fi

  tillerless=$(jq -r '.source.tillerless // "false"' < $payload)
  tls_enabled=$(jq -r '.source.tls_enabled // "false"' < $payload)
  history_max=$(jq -r '.source.helm_history_max // "0"' < $1)
  stable_repo=$(jq -r '.source.stable_repo // ""' < $payload)

  if [ "$tillerless" = true ]; then
    echo "Using tillerless helm"
    helm_bin="helm tiller run ${tiller_namespace} -- helm"
  else
    helm_bin="helm"
  fi

  if [ -n "$stable_repo" ]; then
    echo "Stable Repo URL : ${stable_repo}"
    stable_repo="--stable-repo-url=${stable_repo}"
  fi

  if [ "$init_server" = true ]; then
    if [ "$tillerless" = true ]; then
      echo "Setting both init_server and tillerless is not supported"
      exit 1
    fi
    tiller_service_account=$(jq -r '.source.tiller_service_account // "default"' < $1)

    helm_init_wait=$(jq -r '.source.helm_init_wait // "false"' <$1)
    helm_init_wait_arg=""
    if [ "$helm_init_wait" = "true" ]; then
      helm_init_wait_arg="--wait"
    fi

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
      $helm_bin init --tiller-tls --tiller-tls-cert $tiller_cert_path --tiller-tls-key $tiller_key_path --tiller-tls-verify --tls-ca-cert $tiller_key_path --tiller-namespace=$tiller_namespace --service-account=$tiller_service_account --history-max=$history_max $stable_repo --upgrade $helm_init_wait_arg
    else
      $helm_bin init --tiller-namespace=$tiller_namespace --service-account=$tiller_service_account --history-max=$history_max $stable_repo --upgrade $helm_init_wait_arg
    fi
    wait_for_service_up tiller-deploy 10
  else
    export HELM_HOST=$(jq -r '.source.helm_host // ""' < $1)
    $helm_bin init -c --tiller-namespace $tiller_namespace $stable_repo > /dev/null
  fi

  tls_enabled_arg=""
  if [ "$tls_enabled" = true ]; then
    tls_enabled_arg="--tls"
  fi
  $helm_bin version $tls_enabled_arg --tiller-namespace $tiller_namespace

  helm_setup_purge_all=$(jq -r '.source.helm_setup_purge_all // "false"' <$1)
  if [ "$helm_setup_purge_all" = "true" ]; then
    local release
    for release in $(helm ls -aq --tiller-namespace $tiller_namespace )
    do
      helm delete $tls_enabled_arg --purge "$release" --tiller-namespace $tiller_namespace
    done
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
  plugins=$(jq -c '(try .source.plugins[] catch [][])' < $1)

  kubeconfig_tiller_namespace=$(jq -r '.source.kubeconfig_tiller_namespace // "false"' <$1)
  if [ "$kubeconfig_tiller_namespace" = "true" ]
  then
    tiller_namespace=$(kubectl config view --minify -ojson | jq -r .contexts[].context.namespace)
  else
    tiller_namespace=$(jq -r '.source.tiller_namespace // "kube-system"' < $1)
  fi

  local IFS=$'\n'

  for pl in $plugins; do
    plurl=$(echo $pl | jq -cr '.url')
    plversion=$(echo $pl | jq -cr '.version // ""')
    if [ -n "$plversion" ]; then
      plversionflag="--version $plversion"
    fi
    helm plugin install $plurl $plversionflag
  done

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
  done

  helm repo update
}

setup_resource() {
  tracing_enabled=$(jq -r '.source.tracing_enabled // "false"' < $1)
  if [ "$tracing_enabled" = "true" ]; then
    set -x
  fi

  echo "Initializing kubectl..."
  setup_kubernetes $1 $2
  echo "Initializing helm..."
  setup_tls $1
  setup_helm $1 $2
  setup_repos $1
}

# exe executes the command after printing the command trace to stdout
exe() {
  echo "+ $*"; "$@"
}