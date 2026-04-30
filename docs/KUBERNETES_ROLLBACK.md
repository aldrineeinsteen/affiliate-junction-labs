# Kubernetes Rollback Procedures

This guide covers rollback strategies and procedures for the Affiliate Junction Kubernetes deployment.

## Table of Contents

1. [Rollback Strategies](#rollback-strategies)
2. [Application Rollback](#application-rollback)
3. [Configuration Rollback](#configuration-rollback)
4. [Database Rollback](#database-rollback)
5. [Emergency Procedures](#emergency-procedures)

---

## Rollback Strategies

### Types of Rollbacks

1. **Application Rollback** - Revert to previous container image version
2. **Configuration Rollback** - Restore previous ConfigMap/Secret values
3. **Database Rollback** - Restore database schema or data
4. **Full Stack Rollback** - Complete environment restoration

### Rollback Decision Matrix

| Issue | Rollback Type | Time to Execute | Risk Level |
|-------|--------------|-----------------|------------|
| Bad deployment | Application | 1-2 minutes | Low |
| Config error | Configuration | 2-5 minutes | Low |
| Schema change | Database | 5-30 minutes | Medium |
| Data corruption | Full Stack | 30+ minutes | High |

---

## Application Rollback

### Quick Rollback (Recommended)

Use Kubernetes built-in rollback for deployments:

```bash
# View deployment history
kubectl rollout history deployment/web-ui -n affiliate-junction

# Rollback to previous version
kubectl rollout undo deployment/web-ui -n affiliate-junction

# Rollback to specific revision
kubectl rollout undo deployment/web-ui --to-revision=2 -n affiliate-junction

# Monitor rollback progress
kubectl rollout status deployment/web-ui -n affiliate-junction
```

### Manual Image Rollback

If you need to specify an exact image version:

```bash
# Set specific image version
kubectl set image deployment/web-ui \
  web-ui=icr.io/<namespace>/affiliate-junction:v1.0.0 \
  -n affiliate-junction

# Verify rollback
kubectl get deployment web-ui -n affiliate-junction -o yaml | grep image:
```

### Rollback All Workloads

```bash
# Rollback all deployments
kubectl rollout undo deployment --all -n affiliate-junction

# Restart all CronJobs (they'll use previous image)
for cronjob in $(kubectl get cronjobs -n affiliate-junction -o name); do
  kubectl patch $cronjob -n affiliate-junction \
    -p '{"spec":{"jobTemplate":{"spec":{"template":{"spec":{"containers":[{"name":"*","image":"icr.io/<namespace>/affiliate-junction:v1.0.0"}]}}}}}}'
done
```

### Verify Rollback Success

```bash
# Check pod status
kubectl get pods -n affiliate-junction

# Check pod events
kubectl get events -n affiliate-junction --sort-by='.lastTimestamp'

# Test application
curl http://<external-ip>:10000/health
curl http://<external-ip>:10000/ready
```

---

## Configuration Rollback

### ConfigMap Rollback

Kubernetes doesn't version ConfigMaps automatically. Use these strategies:

#### Strategy 1: Git-Based Rollback

```bash
# Revert to previous commit
git log k8s/base/configmap.yaml
git checkout <commit-hash> k8s/base/configmap.yaml

# Apply previous version
kubectl apply -f k8s/base/configmap.yaml

# Restart pods to pick up changes
kubectl rollout restart deployment/web-ui -n affiliate-junction
```

#### Strategy 2: Manual Backup/Restore

```bash
# Before making changes, backup current ConfigMap
kubectl get configmap affiliate-junction-config -n affiliate-junction -o yaml > configmap-backup-$(date +%Y%m%d-%H%M%S).yaml

# To restore from backup
kubectl apply -f configmap-backup-20260430-120000.yaml

# Restart pods
kubectl rollout restart deployment/web-ui -n affiliate-junction
```

#### Strategy 3: Edit and Revert

```bash
# Edit ConfigMap directly
kubectl edit configmap affiliate-junction-config -n affiliate-junction

# If you need to revert, restore from backup or git
kubectl apply -f k8s/base/configmap.yaml

# Restart affected pods
kubectl rollout restart deployment -n affiliate-junction
```

### Secret Rollback

```bash
# Backup current secret (base64 encoded)
kubectl get secret affiliate-junction-secrets -n affiliate-junction -o yaml > secret-backup-$(date +%Y%m%d-%H%M%S).yaml

# Restore from backup
kubectl apply -f secret-backup-20260430-120000.yaml

# Restart pods to use new secret values
kubectl rollout restart deployment/web-ui -n affiliate-junction
```

### Configuration Rollback Checklist

- [ ] Backup current configuration before changes
- [ ] Apply previous configuration
- [ ] Restart affected pods
- [ ] Verify application functionality
- [ ] Check logs for errors
- [ ] Test database connectivity
- [ ] Validate web UI access

---

## Database Rollback

### HCD Schema Rollback

```bash
# Connect to HCD
kubectl exec -it <pod-name> -n affiliate-junction -- \
  /app/hcd-1.2.3/bin/hcd cqlsh <hcd-host> -u cassandra -p <password>

# Drop and recreate keyspace (DESTRUCTIVE)
DROP KEYSPACE IF EXISTS affiliate_junction;

# Recreate from schema file
SOURCE '/app/hcd_schema.cql';
```

### Presto Schema Rollback

```bash
# Connect to Presto
kubectl exec -it <pod-name> -n affiliate-junction -- bash

# Run Presto CLI
presto --server https://<presto-host>:8443 \
  --user ibmlhadmin \
  --password \
  --catalog iceberg_data \
  --schema affiliate_junction

# Drop tables
DROP TABLE IF EXISTS traffic;
DROP TABLE IF EXISTS sales;
-- ... drop all tables

# Recreate from schema file
# (Run SQL from presto_schema.sql)
```

### Data Backup and Restore

#### Before Major Changes

```bash
# Backup HCD data
kubectl exec -it <pod-name> -n affiliate-junction -- \
  /app/hcd-1.2.3/bin/hcd nodetool snapshot affiliate_junction

# Backup Presto data (if using S3/Object Storage)
# Use your cloud provider's backup tools
```

#### Restore from Backup

```bash
# Restore HCD snapshot
kubectl exec -it <pod-name> -n affiliate-junction -- \
  /app/hcd-1.2.3/bin/hcd nodetool refresh affiliate_junction <table_name>

# For Presto/Iceberg, restore from S3 backup
# This depends on your storage configuration
```

---

## Emergency Procedures

### Complete Environment Rollback

When everything goes wrong:

```bash
# 1. Delete current deployment
kubectl delete -k k8s/overlays/affiliate-junction/

# 2. Restore from known-good state
git checkout <stable-tag>

# 3. Redeploy
kubectl apply -k k8s/overlays/affiliate-junction/

# 4. Wait for pods to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=affiliate-junction -n affiliate-junction --timeout=300s

# 5. Verify
kubectl get all -n affiliate-junction
```

### Rollback to Previous Release

```bash
# Tag current state for safety
git tag rollback-point-$(date +%Y%m%d-%H%M%S)

# Checkout previous stable release
git checkout v1.0.0

# Rebuild and push image
docker build -t icr.io/<namespace>/affiliate-junction:v1.0.0 .
docker push icr.io/<namespace>/affiliate-junction:v1.0.0

# Deploy previous version
kubectl apply -k k8s/overlays/affiliate-junction/

# Update image in running deployments
kubectl set image deployment/web-ui \
  web-ui=icr.io/<namespace>/affiliate-junction:v1.0.0 \
  -n affiliate-junction
```

### Pause All Automated Operations

In case of cascading failures:

```bash
# Suspend all CronJobs
kubectl patch cronjob hcd-to-presto -n affiliate-junction -p '{"spec":{"suspend":true}}'
kubectl patch cronjob presto-to-hcd -n affiliate-junction -p '{"spec":{"suspend":true}}'
kubectl patch cronjob presto-insights -n affiliate-junction -p '{"spec":{"suspend":true}}'
kubectl patch cronjob presto-cleanup -n affiliate-junction -p '{"spec":{"suspend":true}}'

# Scale down web UI to prevent user access
kubectl scale deployment web-ui --replicas=0 -n affiliate-junction

# Investigate and fix issues

# Resume operations
kubectl patch cronjob hcd-to-presto -n affiliate-junction -p '{"spec":{"suspend":false}}'
kubectl patch cronjob presto-to-hcd -n affiliate-junction -p '{"spec":{"suspend":false}}'
kubectl patch cronjob presto-insights -n affiliate-junction -p '{"spec":{"suspend":false}}'
kubectl patch cronjob presto-cleanup -n affiliate-junction -p '{"spec":{"suspend":false}}'
kubectl scale deployment web-ui --replicas=2 -n affiliate-junction
```

### Data Corruption Recovery

```bash
# 1. Stop all data operations
kubectl scale deployment web-ui --replicas=0 -n affiliate-junction
kubectl patch cronjob --all -n affiliate-junction -p '{"spec":{"suspend":true}}'

# 2. Truncate corrupted tables
kubectl create job truncate-recovery --from=cronjob/truncate-tables -n affiliate-junction

# 3. Restore from backup or regenerate
kubectl create job populate-recovery --from=cronjob/populate-data -n affiliate-junction

# 4. Verify data integrity
kubectl exec -it <pod-name> -n affiliate-junction -- \
  /app/scripts/test_hcd_connection.sh

# 5. Resume operations
kubectl scale deployment web-ui --replicas=2 -n affiliate-junction
kubectl patch cronjob --all -n affiliate-junction -p '{"spec":{"suspend":false}}'
```

---

## Rollback Best Practices

### Before Deployment

1. **Tag the current state**
   ```bash
   git tag pre-deployment-$(date +%Y%m%d-%H%M%S)
   git push --tags
   ```

2. **Backup configurations**
   ```bash
   kubectl get configmap affiliate-junction-config -n affiliate-junction -o yaml > backup/configmap.yaml
   kubectl get secret affiliate-junction-secrets -n affiliate-junction -o yaml > backup/secret.yaml
   ```

3. **Document the change**
   - What is being changed
   - Why it's being changed
   - Expected impact
   - Rollback plan

### During Deployment

1. **Deploy to staging first**
2. **Use canary deployments** (if applicable)
3. **Monitor metrics closely**
4. **Have rollback commands ready**

### After Deployment

1. **Verify functionality**
2. **Check logs for errors**
3. **Monitor for 30 minutes**
4. **Document any issues**

### Rollback Testing

Regularly test rollback procedures:

```bash
# Monthly rollback drill
# 1. Deploy test version
# 2. Perform rollback
# 3. Verify success
# 4. Document time taken
# 5. Update procedures if needed
```

---

## Communication During Rollback

### Stakeholder Notification Template

```
Subject: [ACTION REQUIRED] Rollback in Progress - Affiliate Junction

Status: ROLLBACK IN PROGRESS
Start Time: [TIME]
Expected Duration: [DURATION]
Reason: [BRIEF DESCRIPTION]

Actions Taken:
- [ACTION 1]
- [ACTION 2]

Current Status:
- [STATUS UPDATE]

Next Steps:
- [NEXT STEP]

Contact: [YOUR NAME/TEAM]
```

### Post-Rollback Report Template

```
Subject: [RESOLVED] Rollback Complete - Affiliate Junction

Incident Summary:
- Issue: [DESCRIPTION]
- Detection Time: [TIME]
- Rollback Start: [TIME]
- Rollback Complete: [TIME]
- Total Downtime: [DURATION]

Root Cause:
[DESCRIPTION]

Actions Taken:
1. [ACTION 1]
2. [ACTION 2]

Verification:
- [VERIFICATION STEP 1]
- [VERIFICATION STEP 2]

Prevention:
- [PREVENTION MEASURE 1]
- [PREVENTION MEASURE 2]

Lessons Learned:
- [LESSON 1]
- [LESSON 2]
```

---

## Additional Resources

- [Kubernetes Deployment Guide](KUBERNETES_DEPLOYMENT.md)
- [Troubleshooting Guide](KUBERNETES_TROUBLESHOOTING.md)
- [Kubernetes Official Docs - Rollback](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-back-a-deployment)