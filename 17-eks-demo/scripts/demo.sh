#!/usr/bin/env bash
# End-to-end EKS walkthrough: create a cluster via the EKS API, get the
# real kubeconfig from k3d, use kubectl to deploy an nginx Deployment,
# scale it, expose it as a NodePort, tail logs, tear down.
#
# Requires:
#   - LocalEmu started with EKS_K8S_PROVIDER=k3d
#   - k3d installed on PATH (https://k3d.io)
#   - kubectl on PATH
set -euo pipefail

export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
export AWS_DEFAULT_REGION=us-east-1
ENDPOINT="--endpoint-url=http://localhost:4566"

CLUSTER=le-demo-eks
KUBECONFIG_FILE=/tmp/le-demo-eks.kubeconfig

bold() { printf "\n\033[1;36m== %s ==\033[0m\n" "$1"; }

# Clean slate
aws $ENDPOINT eks delete-cluster --name "$CLUSTER" 2>/dev/null || true
k3d cluster delete "localemu-eks-$CLUSTER" 2>/dev/null || true
rm -f "$KUBECONFIG_FILE"
sleep 1

bold "1. Prerequisites"
echo "k3d $(k3d version 2>&1 | head -1 | awk '{print $NF}')"
echo "kubectl $(kubectl version --client=true 2>&1 | head -1 | awk '{print $NF}')"
docker info >/dev/null 2>&1 && echo "docker running" || { echo "docker NOT running"; exit 1; }

bold "2. Create EKS cluster (k3d backend spins up a real k3s cluster; ~15-30 s)"
aws $ENDPOINT eks create-cluster \
  --name "$CLUSTER" \
  --role-arn arn:aws:iam::000000000000:role/eks-role \
  --resources-vpc-config subnetIds=subnet-12345,securityGroupIds=sg-12345 \
  --query 'cluster.{Name:name,Status:status,Endpoint:endpoint,Version:version}'

bold "3. Wait for cluster ACTIVE + first node Ready"
aws $ENDPOINT eks wait cluster-active --name "$CLUSTER" 2>/dev/null || sleep 10

bold "4. Get kubeconfig from k3d"
k3d kubeconfig get "localemu-eks-$CLUSTER" > "$KUBECONFIG_FILE"
chmod 600 "$KUBECONFIG_FILE"
echo "kubeconfig saved to $KUBECONFIG_FILE"
export KUBECONFIG="$KUBECONFIG_FILE"

bold "5. kubectl get nodes"
for i in $(seq 1 20); do
  if kubectl get nodes --no-headers 2>/dev/null | grep -q Ready; then break; fi
  sleep 2
done
kubectl get nodes

bold "6. kubectl get namespaces"
kubectl get namespaces

bold "7. Deploy nginx with 2 replicas"
kubectl create deployment nginx --image=nginx:alpine --replicas=2
kubectl rollout status deployment/nginx --timeout=90s

bold "8. kubectl get pods"
kubectl get pods

bold "9. Expose as NodePort service"
kubectl expose deployment nginx --port=80 --type=NodePort
kubectl get service nginx

bold "10. Scale to 3 replicas"
kubectl scale deployment nginx --replicas=3
kubectl rollout status deployment/nginx --timeout=60s
kubectl get pods

bold "11. Tail nginx logs"
kubectl logs deployment/nginx --tail=3 2>/dev/null | head -10

bold "12. kubectl get all"
kubectl get all

bold "13. Clean up Kubernetes resources"
kubectl delete service nginx
kubectl delete deployment nginx

bold "14. Delete the EKS cluster (k3d cluster is also destroyed)"
aws $ENDPOINT eks delete-cluster --name "$CLUSTER" \
  --query 'cluster.{Name:name,Status:status}'

sleep 3
bold "15. Verify the k3d cluster is gone"
if k3d cluster list | awk 'NR>1' | grep -q "localemu-eks-$CLUSTER"; then
  echo "  WARNING: k3d cluster still present"
  k3d cluster list
else
  echo "  k3d cluster 'localemu-eks-$CLUSTER' is gone"
fi

aws $ENDPOINT eks list-clusters --query 'clusters'

rm -f "$KUBECONFIG_FILE"

echo
echo "→ demo complete."
