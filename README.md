# NGINX + Istio Demo with Kind Cluster

This project sets up a Kind Kubernetes cluster, installs Istio, and deploys a basic NGINX app using Helm.

---

## Prerequisites

Ensure the following tools are installed:
- **PowerShell** (cross-platform)
- **mkcert** (run `mkcert install` after installation)
- **Podman** or **Docker Desktop** (running)
- **Task CLI** ([Install Task](https://taskfile.dev/installation/))

---

## Tasks

Run the following commands to automate setup and cleanup:

- **Create the cluster**:
   ```bash
   task create-cluster
   ```

- **Deploy or upgrade the Helm chart**:
   ```bash
   task upgrade-chart
   ```

- **Delete the Helm chart**:
   ```bash
   task delete-chart
   ```

- **Delete the cluster**:
   ```bash
   task delete-cluster
   ```

---

## Access the Demo

After running `task upgrade-chart`, visit:

```
https://nginx.localhost
```

---

## Cleanup

To remove everything:
```bash
task delete-chart
task delete-cluster
```