
#!/usr/bin/env bash

set -Eeuo pipefail

CLUSTER_NAME="demo"
NAMESPACE="demo"
RELEASE_NAME="demo"
IMAGE_NAME="enterprisebot"
IMAGE_TAG="v1"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo " Starting Setup"

# Check required tools
for cmd in docker kind kubectl helm; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: $cmd is not installed."
        exit 1
    fi
done

# 1. Create or reuse the kind cluster
if kind get clusters | grep -qx "$CLUSTER_NAME"; then
    echo "Kind cluster '$CLUSTER_NAME' already exists. Reusing it."
else
    echo "Creating kind cluster '$CLUSTER_NAME'..."

    kind create cluster --name "$CLUSTER_NAME" --config - <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    labels:
      ingress-ready: "true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
EOF
fi

kubectl cluster-info --context "kind-${CLUSTER_NAME}"

# Ensure the control-plane node has the ingress label
kubectl label node "${CLUSTER_NAME}-control-plane" \
    ingress-ready=true --overwrite

# 2. Install ingress-nginx only if not already installed
echo "Checking ingress-nginx controller..."

if kubectl get deployment ingress-nginx-controller \
    -n ingress-nginx >/dev/null 2>&1; then

    echo "ingress-nginx controller is already installed. Skipping installation."

else
    echo "Installing ingress-nginx controller..."

    kubectl apply -f \
        https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
fi

echo "Waiting for ingress-nginx controller..."

kubectl rollout status deployment/ingress-nginx-controller \
    -n ingress-nginx --timeout=180s

echo "ingress-nginx controller is ready."

# 3. Build Docker image
echo "Building application Docker image..."

docker build \
    -t "${IMAGE_NAME}:${IMAGE_TAG}" \
    "${ROOT_DIR}/service"

# 4. Load image into kind cluster
echo "Loading Docker image into kind..."

kind load docker-image "${IMAGE_NAME}:${IMAGE_TAG}" \
    --name "$CLUSTER_NAME"

# 5. Install or upgrade Helm release
echo "Deploying application using Helm..."

helm upgrade --install "$RELEASE_NAME" "${ROOT_DIR}/chart" \
    --namespace "$NAMESPACE" \
    --create-namespace \
    --set image.repository="$IMAGE_NAME" \
    --set image.tag="$IMAGE_TAG" \
    --wait \
    --timeout 300s

# 6. Verify deployment
echo "Waiting for application deployment..."

kubectl rollout status deployment/enterprisebot-deployment \
    --namespace "$NAMESPACE" \
    --timeout=180s

echo " Setup completed successfully!"

echo ""
echo "Application resources:"
kubectl get pods,services,ingress -n "$NAMESPACE"

echo ""
echo "Application URL: http://demo.local"
echo "Health endpoint: http://demo.local/healthz"
