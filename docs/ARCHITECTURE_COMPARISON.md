# Architecture Comparison: VM vs Kubernetes Deployment

## Executive Summary

The Affiliate Junction Demo has **two distinct deployment architectures** with different infrastructure components:

### VM Deployment (setup.sh)
- **Presto/MinIO**: Provided by **watsonx.data Developer Edition** (all-in-one container)
- **HCD**: Runs locally via Docker at `172.17.0.1`
- **Application**: Python services via systemd

### Kubernetes Deployment (setup-k8s.sh)
- **Presto/MinIO**: Provided by **IBM Cloud watsonx.data** (managed service)
- **HCD**: Deployed via **Mission Control** on IBM Cloud IKS
- **Application**: Containerized workloads on Kubernetes

## Detailed Architecture Comparison

### 1. VM Deployment Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Single RHEL 9.6 VM                        │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  watsonx.data Developer Edition (Containers)         │  │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐    │  │
│  │  │   Presto   │  │   MinIO    │  │    Spark   │    │  │
│  │  │  (Engine)  │  │ (Storage)  │  │   (ETL)    │    │  │
│  │  └────────────┘  └────────────┘  └────────────┘    │  │
│  │         ↓              ↓                             │  │
│  │    Iceberg Tables   Object Storage                  │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                               │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  HCD (Docker Container)                              │  │
│  │  Running at 172.17.0.1:9042                          │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                               │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Python Application (systemd services)               │  │
│  │  • generate_traffic.service                          │  │
│  │  • hcd_to_presto.service (Spark ETL)                │  │
│  │  • presto_to_hcd.service                             │  │
│  │  • presto_insights.service                           │  │
│  │  • presto_cleanup.service                            │  │
│  │  • uvicorn.service (Web UI)                          │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

**Key Points:**
- ✅ All components run on a single VM
- ✅ watsonx.data Developer Edition provides Presto + MinIO + Spark
- ✅ HCD runs in Docker container
- ✅ Application services managed by systemd
- ✅ Suitable for development, testing, and demos
- ❌ Not production-ready (single point of failure)
- ❌ Limited scalability

### 2. Kubernetes Deployment Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        IBM Cloud                                     │
├─────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  ┌────────────────────────────────────────────────────────────┐    │
│  │  watsonx.data (Managed Service)                            │    │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐          │    │
│  │  │   Presto   │  │    COS     │  │    Spark   │          │    │
│  │  │  (Engine)  │  │ (Storage)  │  │   (ETL)    │          │    │
│  │  └────────────┘  └────────────┘  └────────────┘          │    │
│  │         ↓              ↓                                   │    │
│  │    Iceberg Tables   Object Storage                        │    │
│  │                                                            │    │
│  │  Accessed via: ibm-lh-presto-svc:8443                    │    │
│  └────────────────────────────────────────────────────────────┘    │
│                                                                       │
│  ┌────────────────────────────────────────────────────────────┐    │
│  │  IBM Cloud IKS Cluster (3 worker nodes)                   │    │
│  │                                                            │    │
│  │  ┌──────────────────────────────────────────────────┐    │    │
│  │  │  Mission Control Namespace                       │    │    │
│  │  │  • Mission Control UI (Deployment)               │    │    │
│  │  │  • Mission Control API (Deployment)              │    │    │
│  │  │  • Loki (Logging)                                │    │    │
│  │  └──────────────────────────────────────────────────┘    │    │
│  │                                                            │    │
│  │  ┌──────────────────────────────────────────────────┐    │    │
│  │  │  Demo HCD Namespace (sample-2p43q6vg)            │    │    │
│  │  │  • HCD StatefulSet (3 replicas)                  │    │    │
│  │  │  • HCD Service (ClusterIP)                       │    │    │
│  │  │  • HCD LoadBalancer (External Access)            │    │    │
│  │  └──────────────────────────────────────────────────┘    │    │
│  │                                                            │    │
│  │  ┌──────────────────────────────────────────────────┐    │    │
│  │  │  Application Namespace (affiliate-junction)      │    │    │
│  │  │  • Web UI (Deployment, 2 replicas)               │    │    │
│  │  │  • Populate Data (Job)                           │    │    │
│  │  │  • HCD→Presto ETL (CronJob, every minute)       │    │    │
│  │  │  • Presto→HCD (CronJob, every minute)           │    │    │
│  │  │  • Insights (CronJob, every 5 min)               │    │    │
│  │  │  • Cleanup (CronJob, hourly)                     │    │    │
│  │  │  • Truncate Tables (Job)                         │    │    │
│  │  └──────────────────────────────────────────────────┘    │    │
│  │                                                            │    │
│  └────────────────────────────────────────────────────────────┘    │
│                                                                       │
└─────────────────────────────────────────────────────────────────────┘
```

**Key Points:**
- ✅ Production-ready with high availability
- ✅ watsonx.data as managed IBM Cloud service
- ✅ HCD deployed via Mission Control (managed)
- ✅ Application runs as Kubernetes workloads
- ✅ Automatic scaling and orchestration
- ✅ LoadBalancers for external access
- ❌ More complex setup
- ❌ Requires IBM Cloud account and licenses

## Component Mapping

| Component | VM Deployment | Kubernetes Deployment |
|-----------|---------------|----------------------|
| **Presto Engine** | watsonx.data Developer Edition container | IBM Cloud watsonx.data managed service |
| **Object Storage** | MinIO (local container) | IBM Cloud Object Storage (COS) |
| **Spark ETL** | watsonx.data Developer Edition container | IBM Cloud watsonx.data managed service |
| **HCD Database** | Docker container at 172.17.0.1 | Mission Control MissionControlCluster CR |
| **Application Services** | systemd units | Kubernetes Deployments/Jobs/CronJobs |
| **Web UI** | uvicorn.service (systemd) | Deployment with 2 replicas + LoadBalancer |
| **Configuration** | .env file | ConfigMap + Secrets |
| **Service Discovery** | Hardcoded IPs/hostnames | Kubernetes DNS |

## Why Presto/MinIO Are NOT Deployed in K8s

### VM Deployment
In the VM deployment, Presto and MinIO are **bundled** with watsonx.data Developer Edition:
- Single container image includes all components
- Designed for development and testing
- Easy to set up on a single machine
- Not production-ready

### Kubernetes Deployment
In the K8s deployment, Presto and MinIO are **external managed services**:
- **Presto**: Provided by IBM Cloud watsonx.data (managed service)
- **Object Storage**: IBM Cloud Object Storage (COS), not MinIO
- **Reason**: Production deployments use managed services for:
  - High availability
  - Automatic scaling
  - Professional support
  - Enterprise features
  - Separation of concerns

## What setup-k8s.sh Actually Deploys

### Infrastructure Phase (--phase cloud)
1. **IBM Cloud VPC** - Virtual Private Cloud
2. **IKS Cluster** - 3 worker nodes (bx2.4x16)
3. **Mission Control** - HCD management platform
4. **Demo HCD Database** - 3-node HCD cluster via Mission Control

### Application Phase (--phase build + app-deploy)
1. **Container Image** - Built and pushed to IBM Cloud Container Registry
2. **Application Workloads**:
   - Web UI Deployment (2 replicas)
   - Populate Data Job
   - ETL CronJobs (HCD↔Presto)
   - Analytics CronJobs
   - Cleanup CronJob

### What It Does NOT Deploy
- ❌ Presto (uses existing IBM Cloud watsonx.data)
- ❌ MinIO (uses IBM Cloud Object Storage)
- ❌ Spark (uses IBM Cloud watsonx.data Spark)

## Connection Configuration

### VM Deployment (.env file)
```bash
# HCD connection
HCD_HOST=172.17.0.1
HCD_PORT=9042
HCD_USERNAME=cassandra
HCD_PASSWORD=cassandra

# Presto connection (watsonx.data Developer Edition)
PRESTO_HOST=ibm-lh-presto-svc
PRESTO_PORT=8443
PRESTO_USERNAME=ibmlhadmin
PRESTO_PASSWORD=password
```

### Kubernetes Deployment (ConfigMap + Secrets)
```yaml
# ConfigMap (config/domains/affiliate-junction/domain.yaml)
databases:
  hcd:
    service_name: hcd-service  # Kubernetes Service DNS
    port: 9042
  presto:
    service_name: presto-service  # External endpoint
    port: 8443

# Secrets (config/domains/affiliate-junction/.env.*)
HCD_USERNAME: demo-superuser
HCD_PASSWORD: <from Mission Control>
PRESTO_USERNAME: ibmlhadmin
PRESTO_PASSWORD: <from watsonx.data>
```

## Prerequisites Comparison

### VM Deployment
- RHEL 9.6 VM
- Docker installed
- watsonx.data Developer Edition
- Python 3.11
- systemd

### Kubernetes Deployment
- IBM Cloud account
- Mission Control license
- watsonx.data instance (managed service)
- kubectl, helm, ibmcloud CLI
- Podman or Docker (for building images)

## Cost Comparison

### VM Deployment
- **Cost**: Free (Developer Edition)
- **Resources**: Single VM (8+ cores, 32+ GB RAM recommended)
- **Suitable for**: Development, testing, demos

### Kubernetes Deployment
- **Cost**: IBM Cloud charges apply
  - IKS cluster (3 x bx2.4x16 workers)
  - Mission Control license
  - watsonx.data usage
  - Cloud Object Storage
  - LoadBalancers
- **Resources**: Production-grade infrastructure
- **Suitable for**: Production, workshops, enterprise demos

## Migration Path

If you have a VM deployment and want to migrate to Kubernetes:

1. **Keep existing watsonx.data Developer Edition** for development
2. **Set up IBM Cloud watsonx.data** for production Presto/COS
3. **Deploy Mission Control + HCD** on IKS
4. **Build and deploy application** using setup-k8s.sh
5. **Update connection strings** to point to new endpoints
6. **Test thoroughly** before decommissioning VM

## Conclusion

The two deployment architectures serve different purposes:

- **VM Deployment**: Quick setup for development and demos using all-in-one watsonx.data Developer Edition
- **Kubernetes Deployment**: Production-ready deployment using managed IBM Cloud services

**Presto and MinIO are NOT deployed by setup-k8s.sh** because they are provided as managed services in the IBM Cloud watsonx.data offering. This is by design and follows cloud-native best practices of using managed services for data infrastructure.