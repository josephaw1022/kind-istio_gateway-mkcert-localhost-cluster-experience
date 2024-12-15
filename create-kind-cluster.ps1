
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
Run-Command "kind delete cluster --name localkindcluster"

# Registry-specific setup
$regName = "kind-registry"
$regPort = 5001


Run-Command "kind create cluster --config .\kind-config.yaml"


# Helm Repository Setup
Write-Host "Adding Helm repositories..." -ForegroundColor Cyan
Run-Command "helm repo add appscode https://charts.appscode.com/stable/"
Run-Command "helm repo add jetstack https://charts.jetstack.io"
Run-Command "helm repo add istio https://istio-release.storage.googleapis.com/charts"
Run-Command "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts"
Run-Command "helm repo update"


# Install Gateway API
Write-Host "Installing Gateway API..." -ForegroundColor Cyan
Run-Command "helm install my-gateway-api appscode/gateway-api --version 2024.8.30"


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
Run-Command "helm upgrade --install istio-base istio/base -n istio-system --create-namespace --wait"
Start-Sleep -Seconds 2
Run-Command "helm upgrade --install istio-cni istio/cni -n istio-system --wait"
Start-Sleep -Seconds 2
Run-Command "helm upgrade --install istiod istio/istiod -n istio-system --wait"
Start-Sleep -Seconds 8

# # Create and label the istio-ingress namespace for Istio injection
# Write-Host "Creating and labeling the istio-ingress namespace..." -ForegroundColor Cyan
# kubectl create namespace istio-ingress
# kubectl label namespace istio-ingress istio-injection=enabled --overwrite


# Create and label the nginx-app namespace for Istio injection
Write-Host "Creating and labeling the nginx-app namespace for Istio injection..." -ForegroundColor Cyan
kubectl create namespace nginx-app
kubectl label namespace nginx-app istio-injection=enabled --overwrite

# Install Istio Gateway
Write-Host "Installing Istio Gateway..." -ForegroundColor Cyan

helm upgrade --install istio-ingress istio/gateway -n istio-ingress --create-namespace -f ./istio-gateway-config.yaml --wait


# Generate Wildcard TLS Certificate
Write-Host "Generating wildcard TLS certificate for multiple domains..." -ForegroundColor Cyan

# Remove existing files if they exist
if (Test-Path "cert.pem") { Remove-Item -Force "cert.pem" }
if (Test-Path "key.pem") { Remove-Item -Force "key.pem" }

# Generate certificates for multiple domains
$domains = "*.local-cluster.com local-cluster.com"
Write-Host "Generating certificates for domains: $domains" -ForegroundColor Cyan
mkcert -key-file key.pem -cert-file cert.pem *.localhost localhost

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

Write-Host "TLS secret created successfully from mkcert!" -ForegroundColor Green
