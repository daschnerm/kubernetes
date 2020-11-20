KUBE_ROOT=/home/dev/go/src/kubernetes/
KUBEMARK_DIRECTORY="${KUBE_ROOT}/test/kubemark"
RESOURCE_DIRECTORY="${KUBEMARK_DIRECTORY}/resources"


# Get kubeconfig from minikube
minikube ssh 'sudo cat /etc/kubernetes/admin.conf' > /tmp/kubeconfig

# Get secret from kubeconfig
export KUBELET_KEY_BASE64=$(grep client-key-data /tmp/kubeconfig | awk '{print $2}' | head -n 1 |  tr -d '\r' )
export KUBELET_CERT_BASE64=$(grep client-certificate-data /tmp/kubeconfig | awk '{print $2}' | head -n 1 | tr -d '\r' )
export CA_CERT_BASE64=$(grep certificate-authority /tmp/kubeconfig | awk '{print $2}' | head -n 1 | tr -d '\r')

#export MASTER_IP="kubernetes.default.svc:6443"

export MASTER_IP=$(minikube ip):"8443"

export ENABLE_KUBEMARK_CLUSTER_AUTOSCALER=true
export KUBE_AUTOSCALER_MIN_NODES=3
export KUBEMARK_AUTOSCALER_MAX_NODES=20
export KUBE_AUTOSCALER_ENABLE_SCALE_DOWN=true


# Generate secret and configMap for the hollow-node pods to work, prepare
# manifests of the hollow-node and heapster replication controllers from
# templates, and finally create these resources through kubectl.
function create-kube-hollow-node-resources {
  # Create kubeconfig for Kubelet.
  KUBELET_KUBECONFIG_CONTENTS="$(cat <<EOF
apiVersion: v1
kind: Config
users:
- name: kubelet
  user:
    client-certificate-data: "${KUBELET_CERT_BASE64}"
    client-key-data: "${KUBELET_KEY_BASE64}"
clusters:
- name: kubemark
  cluster:
    certificate-authority-data: "${CA_CERT_BASE64}"
    server: https://${MASTER_IP}
contexts:
- context:
    cluster: kubemark
    user: kubelet
  name: kubemark-context
current-context: kubemark-context
EOF
)"

  # Create kubeconfig for Kubeproxy.
  KUBEPROXY_KUBECONFIG_CONTENTS="$(cat <<EOF
apiVersion: v1
kind: Config
users:
- name: kube-proxy
  user:
    client-certificate-data: "${KUBELET_CERT_BASE64}"
    client-key-data: "${KUBELET_KEY_BASE64}"
clusters:
- name: kubemark
  cluster:
    insecure-skip-tls-verify: true
    server: https://${MASTER_IP}
contexts:
- context:
    cluster: kubemark
    user: kube-proxy
  name: kubemark-context
current-context: kubemark-context
EOF
  )"

 # Create kubeconfig for Cluster Autoscaler.
  CLUSTER_AUTOSCALER_KUBECONFIG_CONTENTS="$(cat <<EOF
apiVersion: v1
kind: Config
users:
- name: cluster-autoscaler
  user:
    client-certificate-data: "${KUBELET_CERT_BASE64}"
    client-key-data: "${KUBELET_KEY_BASE64}"
clusters:
- name: kubemark
  cluster:
    insecure-skip-tls-verify: true
    server: https://${MASTER_IP}
contexts:
- context:
    cluster: kubemark
    user: cluster-autoscaler
  name: kubemark-context
current-context: kubemark-context
EOF
)"

mkdir -p "${RESOURCE_DIRECTORY}/addons"

  # Cluster Autoscaler.
  if [[ "${ENABLE_KUBEMARK_CLUSTER_AUTOSCALER:-}" == "true" ]]; then
    echo "Setting up Cluster Autoscaler"
    KUBEMARK_AUTOSCALER_MIG_NAME="${KUBEMARK_AUTOSCALER_MIG_NAME:-${NODE_INSTANCE_PREFIX}-group}"
    KUBEMARK_AUTOSCALER_MIN_NODES="${KUBEMARK_AUTOSCALER_MIN_NODES:-0}"
    KUBEMARK_AUTOSCALER_MAX_NODES="${KUBEMARK_AUTOSCALER_MAX_NODES:-${DESIRED_NODES}}"
    NUM_NODES=${KUBEMARK_AUTOSCALER_MAX_NODES}
    echo "Setting maximum cluster size to ${NUM_NODES}."
    KUBEMARK_MIG_CONFIG="autoscaling.k8s.io/nodegroup: ${KUBEMARK_AUTOSCALER_MIG_NAME}"
    sed "s/{{master_ip}}/${MASTER_IP}/g" "${RESOURCE_DIRECTORY}/cluster-autoscaler_template.json" > "${RESOURCE_DIRECTORY}/addons/cluster-autoscaler.json"
    sed -i'' -e "s/{{kubemark_autoscaler_mig_name}}/${KUBEMARK_AUTOSCALER_MIG_NAME}/g" "${RESOURCE_DIRECTORY}/addons/cluster-autoscaler.json"
    sed -i'' -e "s/{{kubemark_autoscaler_min_nodes}}/${KUBEMARK_AUTOSCALER_MIN_NODES}/g" "${RESOURCE_DIRECTORY}/addons/cluster-autoscaler.json"
    sed -i'' -e "s/{{kubemark_autoscaler_max_nodes}}/${KUBEMARK_AUTOSCALER_MAX_NODES}/g" "${RESOURCE_DIRECTORY}/addons/cluster-autoscaler.json"
  fi

  # https://github.com/kubernetes/autoscaler/blob/36fd6ea329bbe2415b93a68b1f1b3aaff56c7cbc/cluster-autoscaler/main.go
  # 


  if kubectl get ns | grep -Fq "kubemark"; then
  	 kubectl delete ns kubemark
  	 while kubectl get ns | grep -Fq "kubemark"
  	 do
  	 	sleep 10
  	 done
  fi
  kubectl create -f "${RESOURCE_DIRECTORY}/kubemark-ns.json"

    # Create configmap for configuring hollow- kubelet, proxy and npd.
  kubectl create configmap "node-configmap" --namespace="kubemark" \
    --from-literal=content.type="${TEST_CLUSTER_API_CONTENT_TYPE}" \
    --from-file=kernel.monitor="${RESOURCE_DIRECTORY}/kernel-monitor.json"

  ## Create secret
kubectl create secret generic "kubeconfig" --type=Opaque --namespace="kubemark" \
    --from-literal=kubelet.kubeconfig="${KUBELET_KUBECONFIG_CONTENTS}" \
    --from-literal=kubeproxy.kubeconfig="${KUBEPROXY_KUBECONFIG_CONTENTS}" \
    --from-literal=cluster_autoscaler.kubeconfig="${CLUSTER_AUTOSCALER_KUBECONFIG_CONTENTS}" \

kubectl create -f "${RESOURCE_DIRECTORY}/hollow-node_simplified.yaml" --namespace="kubemark"

kubectl create -f "${RESOURCE_DIRECTORY}/addons" --namespace="kubemark"

}

create-kube-hollow-node-resources





