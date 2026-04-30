# Kubernetes Deployment Guide

This guide covers deploying the Affiliate Junction Demo on IBM Cloud Kubernetes Service (IKS) with watsonx.data integration.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Quick Start](#quick-start)
3. [Detailed Deployment Steps](#detailed-deployment-steps)
4. [Configuration](#configuration)
5. [Accessing the Application](#accessing-the-application)
6. [Monitoring and Troubleshooting](#monitoring-and-troubleshooting)
7. [Scaling](#scaling)
8. [Cleanup](#cleanup)

---

## Prerequisites

### Required Tools

- **kubectl** (v1.28+) - Kubernetes CLI
- **IBM Cloud CLI** (v2.0+) with IKS plugin
- **Podman** (v5.0+) - For building container images (IBM standard)
- **kustomize** (v5.0+) - For manifest management (built into kubectl)

### IBM Cloud Resources

- IBM Cloud account with appropriate permissions
- **Resource Group**: `itz-wxd-xxxx` (ID: `7769949db67648a8ad80241b49c9c354`)
- IBM Cloud IKS cluster (3 worker nodes, bx2.4x16 recommended)
- watsonx.data instance with Presto engine
- Mission Control instance for HCD deployment

### Installation Commands

```bash
# Install IBM Cloud CLI
curl -fsSL https://clis.cloud.ibm.com/install/linux | sh

# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

# Install Podman (if not already installed)
# On RHEL/Fedora
sudo dnf install -y podman

# On macOS
brew install podman

# Verify installations
ibmcloud --version
kubectl version --client
podman version
```

---

## Quick Start

For a fully automated deployment:

```bash
# 1. Clone the repository
git clone <repository-url>
cd affiliate-junction-labs

# 2. Set up IBM Cloud credentials
ibmcloud login --sso
ibmcloud resource groups # List resource groups
ibmcloud target -r eu-de -g itz-wxd-xxx

# 3. Run automated setup (requires Mission Control license)
./setup.sh --domain affiliate-junction \
           --mission-control-license "YOUR_LICENSE_ID" \
           --phase all
```

This will:
- Provision IBM Cloud infrastructure (VPC, IKS, Mission Control, HCD)
- Configure watsonx.data Presto catalog
- Build and push container image
- Deploy application to Kubernetes
- Run connectivity tests

---

## Detailed Deployment Steps

### Step 1: Prepare Configuration

```bash
# Copy configuration templates
cp config/config.yaml.example config/config.yaml
cp config/secrets.yaml.example config/secrets.yaml

# Edit configuration files
vim config/config.yaml
vim config/secrets.yaml
```

**Key Configuration Items:**

- `databases.hcd.service_name` - HCD service endpoint
- `databases.presto.service_name` - Presto service endpoint
- Update secrets with actual credentials

### Step 2: Build Container Image

```bash
# Build the container image with Podman
podman build -t affiliate-junction:v1.0.0 .

# Tag for IBM Cloud Container Registry
podman tag affiliate-junction:v1.0.0 \
  icr.io/<namespace>/affiliate-junction:v1.0.0

# Login to IBM Cloud Container Registry
ibmcloud cr login

# Push to registry
podman push icr.io/<namespace>/affiliate-junction:v1.0.0
```

**Note:** Podman is Docker-compatible. If you have `podman-docker` installed, you can also use `docker` commands which will be aliased to `podman`.

### Step 3: Create Kubernetes Secrets

```bash
# Create namespace
kubectl create namespace affiliate-junction

# Create secrets from file
kubectl create secret generic affiliate-junction-secrets \
  --from-literal=HCD_USERNAME=cassandra \
  --from-literal=HCD_PASSWORD='<your-password>' \
  --from-literal=PRESTO_USERNAME=ibmlhadmin \
  --from-literal=PRESTO_PASSWORD='<your-password>' \
  --from-literal=WEB_AUTH_PASSWD='watsonx.data' \
  --from-literal=MC_LICENSE_ID='<your-license>' \
  -n affiliate-junction
```

### Step 4: Deploy with Kustomize

```bash
# Deploy using kustomize overlay
kubectl apply -k k8s/overlays/affiliate-junction/

# Verify deployment
kubectl get all -n affiliate-junction
```

### Step 5: Configure External Services

```bash
# Create Kubernetes Services for external endpoints
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: hcd-service
  namespace: affiliate-junction
spec:
  type: ExternalName
  externalName: <hcd-loadbalancer-hostname>
---
apiVersion: v1
kind: Service
metadata:
  name: presto-service
  namespace: affiliate-junction
spec:
  type: ExternalName
  externalName: <watsonx-data-hostname>
EOF
```

### Step 6: Initialize Data

```bash
# Run populate data job
kubectl create job populate-data-init \
  --from=cronjob/populate-data \
  -n affiliate-junction

# Monitor job
kubectl logs -f job/populate-data-init -n affiliate-junction
```

---

## Configuration

### ConfigMap Structure

The application configuration is stored in a ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: affiliate-junction-config
data:
  config.yaml: |
    domain:
      name: affiliate-junction
      namespace: affiliate-junction
    application:
      advertisers_count: 500
      publishers_count: 1000
      # ... more settings
```

### Updating Configuration

```bash
# Edit ConfigMap
kubectl edit configmap affiliate-junction-config -n affiliate-junction

# Restart pods to pick up changes
kubectl rollout restart deployment/web-ui -n affiliate-junction
```

### Environment-Specific Overlays

Create custom overlays for different environments:

```bash
# Create production overlay
mkdir -p k8s/overlays/production
cp k8s/overlays/affiliate-junction/* k8s/overlays/production/

# Modify for production
vim k8s/overlays/production/config-patch.yaml
```

---

## Accessing the Application

### Get LoadBalancer IP

```bash
# Get web UI service external IP
kubectl get svc web-ui -n affiliate-junction

# Output:
# NAME     TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)
# web-ui   LoadBalancer   172.21.xxx.xxx  169.xx.xxx.xxx   10000:xxxxx/TCP
```

### Access Web UI

```
URL: http://<EXTERNAL-IP>:10000
Username: watsonx
Password: watsonx.data
```

### Port Forwarding (Development)

```bash
# Forward local port to service
kubectl port-forward svc/web-ui 10000:10000 -n affiliate-junction

# Access at http://localhost:10000
```

---

## Monitoring and Troubleshooting

### Check Pod Status

```bash
# List all pods
kubectl get pods -n affiliate-junction

# Describe pod for details
kubectl describe pod <pod-name> -n affiliate-junction

# View pod logs
kubectl logs <pod-name> -n affiliate-junction

# Follow logs in real-time
kubectl logs -f <pod-name> -n affiliate-junction
```

### Check CronJob Status

```bash
# List CronJobs
kubectl get cronjobs -n affiliate-junction

# View recent jobs
kubectl get jobs -n affiliate-junction

# Check job logs
kubectl logs job/<job-name> -n affiliate-junction
```

### Health Checks

```bash
# Check liveness
kubectl exec -it <pod-name> -n affiliate-junction -- \
  curl http://localhost:10000/health

# Check readiness
kubectl exec -it <pod-name> -n affiliate-junction -- \
  curl http://localhost:10000/ready
```

### Database Connectivity

```bash
# Test HCD connection
kubectl exec -it <pod-name> -n affiliate-junction -- \
  /app/scripts/test_hcd_connection.sh

# Test Presto connection
kubectl exec -it <pod-name> -n affiliate-junction -- \
  /app/scripts/test_presto_connection.sh
```

### Common Issues

See [KUBERNETES_TROUBLESHOOTING.md](KUBERNETES_TROUBLESHOOTING.md) for detailed troubleshooting guide.

---

## Scaling

### Scale Web UI

```bash
# Scale to 3 replicas
kubectl scale deployment web-ui --replicas=3 -n affiliate-junction

# Verify scaling
kubectl get deployment web-ui -n affiliate-junction
```

### Adjust CronJob Schedule

```bash
# Edit CronJob
kubectl edit cronjob hcd-to-presto -n affiliate-junction

# Change schedule field (cron format)
spec:
  schedule: "*/2 * * * *"  # Every 2 minutes
```

### Resource Limits

```bash
# Update resource limits
kubectl set resources deployment web-ui \
  --limits=cpu=1000m,memory=2Gi \
  --requests=cpu=500m,memory=1Gi \
  -n affiliate-junction
```

---

## Cleanup

### Remove Application

```bash
# Delete all resources
kubectl delete -k k8s/overlays/affiliate-junction/

# Or delete namespace (removes everything)
kubectl delete namespace affiliate-junction
```

### Remove IBM Cloud Resources

```bash
# Use setup.sh cleanup
./setup.sh --domain affiliate-junction --phase cleanup

# Or manually delete resources
ibmcloud ks cluster rm <cluster-name> -g itz-wxd-69f1c82604915752070c1b
ibmcloud resource service-instance-delete <watsonx-data-instance> -g itz-wxd-69f1c82604915752070c1b
```

---

## Next Steps

- Review [KUBERNETES_TROUBLESHOOTING.md](KUBERNETES_TROUBLESHOOTING.md) for common issues
- See [DEMO_SCRIPT.md](../DEMO_SCRIPT.md) for demonstration scenarios
- Check [DEVELOPER.md](../DEVELOPER.md) for development guidelines