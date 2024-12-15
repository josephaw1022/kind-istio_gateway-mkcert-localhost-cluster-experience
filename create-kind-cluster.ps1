



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

# Step 1: Create the Local Docker Registry
$regName = "kind-registry"
$regPort = 5001

Write-Host "Checking for existing local Docker registry..." -ForegroundColor Cyan
if (-not (docker inspect -f '{{.State.Running}}' $regName 2>$null)) {
    Write-Host "Creating local Docker registry..." -ForegroundColor Cyan
    Run-Command "docker run -d --restart=always -p 127.0.0.1:${regPort}:5000 --network bridge --name $regName registry:2"
} else {
    Write-Host "Local Docker registry already running." -ForegroundColor Green
}

# Step 2: Define the Kind Cluster Configuration
$kindConfig = @"
kind: Cluster
name: kind-cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "/etc/containerd/certs.d"
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

$kindConfigPath = "$env:TEMP\kind-config.yaml"
$kindConfig | Out-File -FilePath $kindConfigPath -Encoding UTF8

Write-Host "Creating Kind cluster..." -ForegroundColor Cyan
Run-Command "kind create cluster --config $kindConfigPath"



# Step 4: Connect the Registry to the Kind Network
Write-Host "Connecting local registry to Kind network..." -ForegroundColor Cyan
$networkCheck = docker inspect -f '{{json .NetworkSettings.Networks.kind}}' $regName *> $null
if ($networkCheck -eq "null") {
    Run-Command "docker network connect kind $regName"
}

# Step 5: Document the Local Registry in Kubernetes
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

# Step 6: Helm Repository Setup
Write-Host "Adding Helm repositories..." -ForegroundColor Cyan
Run-Command "helm repo add jetstack https://charts.jetstack.io"
Run-Command "helm repo add istio https://istio-release.storage.googleapis.com/charts"
Run-Command "helm repo update"

# Step 7: Install Cert-Manager
Write-Host "Installing Cert-Manager..." -ForegroundColor Cyan
Run-Command "helm upgrade --install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --version v1.16.2 --set crds.enabled=true"

Start-Sleep -Seconds 2

# Step 8: Install Istio
Write-Host "Installing Istio components..." -ForegroundColor Cyan
Run-Command "helm upgrade --install istio-base istio/base -n istio-system --set defaultRevision=default --create-namespace"
Start-Sleep -Seconds 2
Run-Command "helm upgrade --install istio-cni istio/cni -n istio-system --wait"
Start-Sleep -Seconds 2
Run-Command "helm upgrade --install istiod istio/istiod -n istio-system --wait"
Start-Sleep -Seconds 5

# Step 9: Install Istio Gateway
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

Write-Host "Installing Istio Gateway..." -ForegroundColor Cyan
Run-Command "helm upgrade --install istio-ingress istio/gateway -n istio-ingress --create-namespace -f $istioGatewayValuesPath --wait"

# Step 10: Generate and Install Wildcard TLS Certificate
Write-Host "Generating wildcard TLS certificate..." -ForegroundColor Cyan

if (Test-Path "_wildcard.localhost.pem") {
    Remove-Item -Force "_wildcard.localhost.pem"
}

if (Test-Path "_wildcard.localhost-key.pem") {
    Remove-Item -Force "_wildcard.localhost-key.pem"
}

Run-Command "mkcert '*.localhost'"
Run-Command "kubectl create secret tls wildcard-localhost-tls -n istio-ingress --cert=_wildcard.localhost.pem --key=_wildcard.localhost-key.pem"

# Cleanup temporary files
Remove-Item -Force $kindConfigPath, $istioGatewayValuesPath

Write-Host "Kind cluster with local registry, Istio Gateway, and wildcard TLS setup completed!" -ForegroundColor Green
