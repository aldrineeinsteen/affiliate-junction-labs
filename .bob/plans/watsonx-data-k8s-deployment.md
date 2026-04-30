# watsonx.data Deployment Plan for Kubernetes

## Overview

Add watsonx.data (Presto + MinIO) deployment to the Kubernetes setup to create a fully self-contained demo environment where all components are visible in Mission Control's Infrastructure Manager.

## Current State Analysis

### What We Have
- ✅ Mission Control deployed via Helm
- ✅ HCD deployed via `MissionControlCluster` CRD
- ✅ IBM Cloud Object Storage (COS) for Loki logs
- ✅ Application workloads (Web UI, ETL jobs)

### What's Missing
- ❌ Presto engine deployment
- ❌ MinIO object storage deployment
- ❌ Iceberg catalog configuration
- ❌ Integration with Mission Control Infrastructure Manager

## Architecture Decision

### Option 1: Mission Control Managed (RECOMMENDED)
Deploy Presto and MinIO as Mission Control managed resources using CRDs, similar to how HCD is deployed.

**Pros:**
- Integrated with Mission Control UI
- Visible in Infrastructure Manager
- Consistent management experience
- Automatic monitoring and logging

**Cons:**
- Requires Mission Control CRDs for Presto/MinIO
- May have version/feature limitations

### Option 2: Standalone Helm Charts
Deploy Presto and MinIO using community Helm charts, then register with Mission Control.

**Pros:**
- More control over versions
- Access to latest features
- Well-documented Helm charts

**Cons:**
- Manual registration with Mission Control
- Separate management interface
- More complex setup

### Option 3: watsonx.data Operator
Use IBM's watsonx.data operator if available for IKS.

**Pros:**
- Official IBM support
- Production-ready
- Full feature set

**Cons:**
- May require additional licenses
- Complexity

## Recommended Approach: Mission Control + Standalone Components

Deploy MinIO and Presto as standalone components, then register them with Mission Control's Infrastructure Manager.

## Implementation Plan

### Phase 1: MinIO Deployment

#### 1.1 Create MinIO Namespace and Resources
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: minio-system
---
apiVersion: v1
kind: Secret
metadata:
  name: minio-credentials
  namespace: minio-system
type: Opaque
stringData:
  rootUser: minioadmin
  rootPassword: <generated-password>
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-data
  namespace: minio-system
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ibmc-vpc-block-10iops-tier
  resources:
    requests:
      storage: 50Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: minio-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
      - name: minio
        image: quay.io/minio/minio:latest
        args:
        - server
        - /data
        - --console-address
        - :9001
        env:
        - name: MINIO_ROOT_USER
          valueFrom:
            secretKeyRef:
              name: minio-credentials
              key: rootUser
        - name: MINIO_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: minio-credentials
              key: rootPassword
        ports:
        - containerPort: 9000
          name: api
        - containerPort: 9001
          name: console
        volumeMounts:
        - name: data
          mountPath: /data
        resources:
          requests:
            cpu: 500m
            memory: 2Gi
          limits:
            cpu: 2000m
            memory: 4Gi
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: minio-data
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: minio-system
spec:
  type: ClusterIP
  ports:
  - port: 9000
    targetPort: 9000
    name: api
  - port: 9001
    targetPort: 9001
    name: console
  selector:
    app: minio
---
apiVersion: v1
kind: Service
metadata:
  name: minio-lb
