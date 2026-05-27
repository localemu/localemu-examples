# 17-eks-demo

End-to-end walkthrough of the LocalEmu EKS k3d backend:

1. Prerequisite check (k3d, kubectl, Docker)
2. `aws eks create-cluster`: LocalEmu spins up a real k3s cluster in Docker
3. Wait for cluster ACTIVE and first node Ready
4. Fetch the kubeconfig from k3d
5. `kubectl get nodes` + `kubectl get namespaces`
6. Create an `nginx:alpine` Deployment with 2 replicas
7. Expose it as a NodePort service
8. Scale to 3 replicas, verify rollout, tail logs
9. `kubectl get all`
10. Delete the Kubernetes resources
11. `aws eks delete-cluster`: k3d cluster and containers are destroyed
12. Verify the k3d cluster is gone

## Requires

- LocalEmu started with `EKS_K8S_PROVIDER=k3d`
- `k3d` on PATH (`brew install k3d` or the k3d install script)
- `kubectl` on PATH

```sh
EKS_K8S_PROVIDER=k3d localemu start
```

## Running

```sh
./scripts/demo.sh
./scripts/teardown.sh
```

Cluster creation typically takes 15-30 seconds. The demo uses about
500 MB of RAM while the k3s cluster is running.
