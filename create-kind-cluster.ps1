param (
  [switch]$EnableRegistry
)

# Helper Function to Run Commands Silently
function Run-Command {
  param (
    [Parameter(Mandatory)] [string]$Command
  )

  # Split the command into executable and arguments
  $cmdParts = $Command -split ' '
  $executable = $cmdParts[0]
  $arguments = $cmdParts[1..($cmdParts.Length - 1)]

  # Execute the command, suppressing all output
  Write-Host "Executing: $Command" -ForegroundColor DarkGray
  & $executable @arguments *> $null 2>&1
}

# Delete the existing Kind cluster if it exists
Start-Sleep -Seconds 2
Write-Host "Deleting existing Kind cluster (if any)..." -ForegroundColor Cyan
Run-Command "kind delete cluster --name kind-cluster"

# Registry-specific setup
$regName = "kind-registry"
$regPort = 5001

# Define the Kind Cluster Configuration
$kindConfig = @"
kind: Cluster
name: kind-cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
    - containerPort: 80
      hostPort: 80
      protocol: TCP
    - containerPort: 443
      hostPort: 443
      protocol: TCP
"@

# Add registry configuration to Kind if enabled
if ($EnableRegistry) {
  Write-Host "Enabling registry configuration in Kind config..." -ForegroundColor Cyan
  $kindConfig += @"
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "/etc/containerd/certs.d"
"@
}

# Write the Kind cluster configuration to a file
$kindConfigPath = "$env:TEMP\kind-config.yaml"
$kindConfig | Out-File -FilePath $kindConfigPath -Encoding UTF8

Write-Host "Creating Kind cluster..." -ForegroundColor Cyan
Run-Command "kind create cluster --config $kindConfigPath"

# Registry setup: create and configure Docker registry if enabled
if ($EnableRegistry) {
  Write-Host "Checking for existing local Docker registry..." -ForegroundColor Cyan
  if (-not (docker inspect -f '{{.State.Running}}' $regName 2>$null)) {
    Write-Host "Creating local Docker registry..." -ForegroundColor Cyan
    Run-Command "docker run -d --restart=always -p 127.0.0.1:${regPort}:5000 --network bridge --name $regName registry:2"
  }
  else {
    Write-Host "Local Docker registry already running." -ForegroundColor Green
  }

  # Connect the registry to the Kind network
  Write-Host "Connecting local registry to Kind network..." -ForegroundColor Cyan
  $networkCheck = docker inspect -f '{{json .NetworkSettings.Networks.kind}}' $regName *> $null
  if ($networkCheck -eq "null") {
    Run-Command "docker network connect kind $regName"
  }

  # Add registry configuration to Kind nodes
  Write-Host "Adding registry configuration to Kind nodes..." -ForegroundColor Cyan
  $registryDir = "/etc/containerd/certs.d/localhost:${regPort}"
  foreach ($node in (kind get nodes --name kind-cluster)) {
    Write-Host "Configuring node: $node" -ForegroundColor Cyan
    Run-Command "docker exec $node mkdir -p $registryDir"
    $registryConfig = @"
[host."http://kind-registry:5000"]
"@
    $registryConfig | docker exec -i $node sh -c "cat > ${registryDir}/hosts.toml"
  }

  # Document the local registry in Kubernetes
  Write-Host "Documenting the local registry in Kubernetes..." -ForegroundColor Cyan
  $registryConfigMap = @"
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${regPort}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
"@
  $registryConfigMap | kubectl apply -f - *>$null
}

# Helm Repository Setup
Write-Host "Adding Helm repositories..." -ForegroundColor Cyan
Run-Command "helm repo add jetstack https://charts.jetstack.io"
Run-Command "helm repo add istio https://istio-release.storage.googleapis.com/charts"
Run-Command "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts"
Run-Command "helm repo update"

# Install Cert-Manager
Write-Host "Installing Cert-Manager..." -ForegroundColor Cyan
Run-Command "helm upgrade --install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --version v1.16.2 --set crds.enabled=true"

Start-Sleep -Seconds 2

# Install kube-prometheus-stack
Write-Host "Installing kube-prometheus-stack for monitoring..." -ForegroundColor Cyan
Run-Command "helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack --namespace monitoring --create-namespace --wait"

Start-Sleep -Seconds 2

# Install Istio
Write-Host "Installing Istio components..." -ForegroundColor Cyan
Run-Command "helm upgrade --install istio-base istio/base -n istio-system --set defaultRevision=default --create-namespace"
Start-Sleep -Seconds 2
Run-Command "helm upgrade --install istio-cni istio/cni -n istio-system --wait"
Start-Sleep -Seconds 2
Run-Command "helm upgrade --install istiod istio/istiod -n istio-system --wait"
Start-Sleep -Seconds 5

# Create and label the istio-ingress namespace for Istio injection
Write-Host "Creating and labeling the istio-ingress namespace..." -ForegroundColor Cyan
kubectl create namespace istio-ingress
kubectl label namespace istio-ingress istio-injection=enabled --overwrite

# Install Istio Gateway
Write-Host "Installing Istio Gateway..." -ForegroundColor Cyan
$istioGatewayValues = @"
service:
  type: NodePort
  ports:
    - name: status-port
      port: 15021
      protocol: TCP
      targetPort: 15021
    - name: http2
      port: 80
      protocol: TCP
      targetPort: 80
    - name: https
      port: 443
      protocol: TCP
      targetPort: 443
"@
$istioGatewayValuesPath = "$env:TEMP\istio-gateway-values.yaml"
$istioGatewayValues | Out-File -FilePath $istioGatewayValuesPath -Encoding UTF8

Run-Command "helm upgrade --install istio-ingress istio/gateway -n istio-ingress --create-namespace -f $istioGatewayValuesPath --wait"


# Generate Wildcard TLS Certificate
Write-Host "Generating wildcard TLS certificate for multiple domains..." -ForegroundColor Cyan

# Remove existing files if they exist
if (Test-Path "cert.pem") { Remove-Item -Force "cert.pem" }
if (Test-Path "key.pem") { Remove-Item -Force "key.pem" }

# Generate certificates for multiple domains
$domains = "*.local-cluster.com local-cluster.com"
Write-Host "Generating certificates for domains: $domains" -ForegroundColor Cyan
mkcert -key-file key.pem -cert-file cert.pem *.local-cluster.com local-cluster.com

# Verify certificate files exist
if (-Not (Test-Path "cert.pem") -or -Not (Test-Path "key.pem")) {
    Write-Host "Error: Certificate files not generated. Check mkcert installation and configuration." -ForegroundColor Red
    Exit 1
}

# Create Kubernetes TLS secret
Write-Host "Creating Kubernetes TLS secret..." -ForegroundColor Cyan
kubectl create secret tls mkcert-tls `
    --cert=cert.pem `
    --key=key.pem `
    -n istio-ingress

# Clean up certificate files
if(Test-Path "cert.pem") { Remove-Item -Force "cert.pem" }
if(Test-Path "key.pem") { Remove-Item -Force "key.pem" }

Write-Host "TLS secret created successfully for *.local-cluster and local-cluster!" -ForegroundColor Green
