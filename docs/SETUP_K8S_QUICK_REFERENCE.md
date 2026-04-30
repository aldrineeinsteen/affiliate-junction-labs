# setup-k8s.sh Quick Reference

## Overview

`setup-k8s.sh` is the Kubernetes deployment script for the Affiliate Junction Demo. It replaces the VM-based `setup.sh` for cloud deployments.

## Key Differences from setup.sh

| Feature | setup.sh (VM) | setup-k8s.sh (K8s) |
|---------|---------------|-------------------|
| **Runtime** | systemd services | Kubernetes workloads |
| **Config** | `.env` file | ConfigMap + Secrets |
| **Deployment** | Single VM | IBM Cloud IKS cluster |
| **Services** | 6 Python services | Deployment + Jobs + CronJobs |
| **Database** | Local HCD | IBM Cloud Mission Control + HCD |

## Usage

```bash
./setup-k8s.sh --domain <domain> --mission-control-license "<LICENSE>" [--phase <phase>]
```

## Phases

### Infrastructure Phases

1. **validate** - Validate configuration and prerequisites
   ```bash
   ./setup-k8s.sh --domain affiliate-junction --phase validate
   ```

2. **cloud** - Provision IBM Cloud infrastructure (VPC, IKS, Mission Control, HCD)
   ```bash
   ./setup-k8s.sh --domain affiliate-junction \
                  --mission-control-license "LICENSE" \
                  --phase cloud
   ```

3. **mission-control** - Install/upgrade Mission Control only
   ```bash
   ./setup-k8s.sh --domain affiliate-junction \
                  --mission-control-license "LICENSE" \
                  --phase mission-control
   ```

4. **hcd** - Create demo HCD database only
   ```bash
   ./setup-k8s.sh --domain affiliate-junction --phase hcd
   ```

5. **platform** - Full platform setup (cloud + mission-control, no demo DB)
   ```bash
   ./setup-k8s.sh --domain affiliate-junction \
                  --mission-control-license "LICENSE" \
                  --phase platform
   ```

### Application Phases

6. **presto** - Configure Presto catalog
   ```bash
   ./setup-k8s.sh --domain affiliate-junction --phase presto
   ```

7. **build** - Build and push container image to IBM Cloud Container Registry
   ```bash
   ./setup-k8s.sh --domain affiliate-junction --phase build
   ```

8. **app-deploy** - Deploy application to Kubernetes (ConfigMap, Secret, workloads)
   ```bash
   ./setup-k8s.sh --domain affiliate-junction --phase app-deploy
   ```

9. **test** - Run connectivity tests
   ```bash
   ./setup-k8s.sh --domain affiliate-junction --phase test
   ```

### Legacy/Utility Phases

10. **domain** - Show domain configuration (dry-run)
    ```bash
    ./setup-k8s.sh --domain affiliate-junction --phase domain
    ```

11. **deploy** - Deploy domain manifests to Kubernetes (legacy, use app-deploy instead)
    ```bash
    ./setup-k8s.sh --domain affiliate-junction --phase deploy
    ```

12. **all** - Execute all phases (default)
    ```bash
    ./setup-k8s.sh --domain affiliate-junction \
                   --mission-control-license "LICENSE" \
                   --phase all
    ```

## Common Workflows

### Full Deployment (First Time)

```bash
# 1. Full infrastructure + application deployment
./setup-k8s.sh --domain affiliate-junction \
               --mission-control-license "3D1vFKhq3ke1ylcGH3XATicvpKk" \
               --phase all
```

### Application Update (After Infrastructure Exists)

```bash
# 1. Build new container image
./setup-k8s.sh --domain affiliate-junction --phase build

# 2. Deploy updated application
./setup-k8s.sh --domain affiliate-junction --phase app-deploy
```

### Infrastructure Only

```bash
# Setup platform without demo database
./setup-k8s.sh --domain affiliate-junction \
               --mission-control-license "LICENSE" \
               --phase platform
```

### Troubleshooting

```bash
# 1. Validate configuration
./setup-k8s.sh --domain affiliate-junction --phase validate

# 2. Test connections
./setup-k8s.sh --domain affiliate-junction --phase test
```

## Environment Variables

The script supports these environment variables for customization:

### IBM Cloud Settings
- `REGION` - IBM Cloud region (default: `eu-de`)
- `ZONE` - IBM Cloud zone (default: `eu-de-1`)
- `RG` - Resource group (default: `itz-wxd-69f1c82604915752070c1b`)
- `PREFIX` - Resource name prefix (default: `hcd-student-69f1c82604`)

### Cluster Settings
- `CLUSTER_NAME` - IKS cluster name (default: `${PREFIX}-iks`)
- `WORKER_FLAVOR` - Worker node flavor (default: `bx2.4x16`)
- `WORKER_COUNT` - Number of worker nodes (default: `3`)

### Container Registry Settings
- `ICR_REGION` - IBM Cloud Container Registry region (default: `us.icr.io`)
- `ICR_NAMESPACE` - ICR namespace (default: `affiliate-junction`)
- `IMAGE_NAME` - Container image name (default: `affiliate-junction-demo`)
- `IMAGE_TAG` - Container image tag (default: `latest`)

### Mission Control Settings
- `MC_NAMESPACE` - Mission Control namespace (default: `mission-control`)
- `MC_ADMIN_USER` - Admin username (default: `admin`)
- `MC_ADMIN_PASSWORD` - Admin password (default: `Password123!`)

### Demo Database Settings
- `CREATE_DEMO_DB` - Create demo HCD database (default: `true`)
- `DEMO_NAMESPACE` - Demo database namespace (default: `sample-2p43q6vg`)
- `DEMO_SUPERUSER_NAME` - Demo superuser name (default: `demo-superuser`)
- `DEMO_SUPERUSER_PASSWORD` - Demo superuser password (default: `Password123!`)

## Configuration Files

### Domain Configuration
- `config/domains/<domain>/domain.yaml` - Domain-specific configuration
- `config/domains/<domain>/.env.hcd` - HCD credentials
- `config/domains/<domain>/.env.presto` - Presto credentials
- `config/domains/<domain>/.env.web` - Web UI credentials

### Kubernetes Manifests
- `k8s/base/` - Base Kubernetes manifests
- `k8s/overlays/<domain>/` - Domain-specific overlays

## Output Files

The script creates these files during execution:

- `.env.setup` - IBM Cloud setup environment
- `.env.cos` - IBM Cloud Object Storage configuration
- `.env.cos.hmac` - COS HMAC credentials
- `.env.image` - Container image reference (from build phase)

## Prerequisites

### Required Tools
- `ibmcloud` - IBM Cloud CLI
- `kubectl` - Kubernetes CLI
- `helm` - Helm package manager
- `jq` - JSON processor
- `podman` or `docker` - Container tool

### IBM Cloud Plugins
- `container-service` - IKS management
- `container-registry` - ICR management

### IBM Cloud Access
- Valid IBM Cloud account
- Mission Control license ID
- Appropriate IAM permissions for VPC, IKS, COS

## Troubleshooting

See [KUBERNETES_TROUBLESHOOTING.md](KUBERNETES_TROUBLESHOOTING.md) for detailed troubleshooting guide.

### Common Issues

1. **LoadBalancer not getting external IP**
   - Check IBM Cloud provider ConfigMap exists
   - Verify cluster has public gateway
   - Wait 2-3 minutes for provisioning

2. **Image pull errors**
   - Verify ICR namespace exists: `ibmcloud cr namespace-list`
   - Check image exists: `ibmcloud cr image-list`
   - Verify image pull secret in namespace

3. **ConfigMap/Secret not found**
   - Run `app-deploy` phase to create them
   - Check namespace: `kubectl get configmap,secret -n <namespace>`

4. **Mission Control UI not accessible**
   - Verify LoadBalancer service: `kubectl get svc -n mission-control`
   - Check pod status: `kubectl get pods -n mission-control`
   - Review logs: `kubectl logs -n mission-control -l app=mission-control-ui`

## Next Steps

After successful deployment:

1. Access Mission Control UI at the LoadBalancer URL
2. Access Affiliate Junction web UI at http://<web-ui-lb>:10000
3. Login with credentials: `watsonx` / `watsonx.data`
4. Explore the dashboards and query system

## Related Documentation

- [KUBERNETES_DEPLOYMENT.md](KUBERNETES_DEPLOYMENT.md) - Complete deployment guide
- [KUBERNETES_TROUBLESHOOTING.md](KUBERNETES_TROUBLESHOOTING.md) - Troubleshooting guide
- [KUBERNETES_ROLLBACK.md](KUBERNETES_ROLLBACK.md) - Rollback procedures
- [k8s-migration.md](../.bob/plans/k8s-migration.md) - Migration plan