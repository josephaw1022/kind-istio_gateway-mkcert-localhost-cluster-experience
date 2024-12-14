# Delete the existing kind cluster if it exists
Start-Sleep -Seconds 2
kind delete cluster --name kind-cluster


# Define the Kind cluster configuration
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

# Write the configuration to a temporary file
$kindConfigPath = "$env:TEMP\kind-config.yaml"
$kindConfig | Out-File -FilePath $kindConfigPath -Encoding UTF8

# Define the Istio Gateway values.yaml
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

# Write the Istio Gateway values to a temporary file
$istioGatewayValuesPath = "$env:TEMP\istio-gateway-values.yaml"
$istioGatewayValues | Out-File -FilePath $istioGatewayValuesPath -Encoding UTF8

# Install the helm repos 
helm repo add jetstack https://charts.jetstack.io
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

# Create the Kind cluster using the config file
kind create cluster --config $kindConfigPath

# Install Cert-Manager
helm upgrade --install `
  cert-manager jetstack/cert-manager `
  --namespace cert-manager `
  --create-namespace `
  --version v1.16.2 `
  --set crds.enabled=true

Start-Sleep -Seconds 2

# Install Base Istio
helm upgrade --install istio-base istio/base -n istio-system --set defaultRevision=default --create-namespace
Start-Sleep -Seconds 2

# Install Istio CNI
helm upgrade --install istio-cni istio/cni -n istio-system --wait
Start-Sleep -Seconds 2

# Install Istiod
helm upgrade --install istiod istio/istiod -n istio-system --wait
Start-Sleep -Seconds 5

# Install Istio Gateway using the custom values file
helm upgrade --install istio-ingress istio/gateway -n istio-ingress --create-namespace `
    -f $istioGatewayValuesPath --wait

# Delete existing certificate files if they exist
Remove-Item -Force -ErrorAction SilentlyContinue "_wildcard.localhost.pem", "_wildcard.localhost-key.pem"

# Generate wildcard TLS certificate
mkcert "*.localhost"

# Create Kubernetes TLS secret in istio-ingress namespace
kubectl create secret tls wildcard-localhost-tls -n istio-ingress `
    --cert=_wildcard.localhost.pem `
    --key=_wildcard.localhost-key.pem

# Delete the certificate files
Remove-Item -Force "_wildcard.localhost.pem", "_wildcard.localhost-key.pem"

# Delete the temporary files
Remove-Item -Force $kindConfigPath, $istioGatewayValuesPath


Write-Host "Kind cluster with Istio Gateway and wildcard TLS setup completed!" -ForegroundColor Green
