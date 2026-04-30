# Kubernetes Troubleshooting Guide

Common issues and solutions for the Affiliate Junction Kubernetes deployment.

## Table of Contents

1. [Pod Issues](#pod-issues)
2. [Database Connectivity](#database-connectivity)
3. [CronJob Issues](#cronjob-issues)
4. [Configuration Problems](#configuration-problems)
5. [Performance Issues](#performance-issues)
6. [Networking Issues](#networking-issues)

---

## Pod Issues

### Pods Not Starting (ImagePullBackOff)

**Symptoms:**
```bash
kubectl get pods -n affiliate-junction
# NAME                      READY   STATUS             RESTARTS   AGE
# web-ui-xxx-yyy           0/1     ImagePullBackOff   0          2m
```

**Causes & Solutions:**

1. **Image not found in registry**
   ```bash
   # Check image name in deployment
   kubectl describe pod <pod-name> -n affiliate-junction | grep Image
   
   # Verify image exists
   ibmcloud cr images | grep affiliate-junction
   
   # Solution: Build and push image
   docker build -t icr.io/<namespace>/affiliate-junction:v1.0.0 .
   docker push icr.io/<namespace>/affiliate-junction:v1.0.0
   ```

2. **Registry authentication failed**
   ```bash
   # Create image pull secret
   kubectl create secret docker-registry icr-secret \
     --docker-server=icr.io \
     --docker-username=iamapikey \
     --docker-password=<api-key> \
     -n affiliate-junction
   
   # Add to deployment
   kubectl patch deployment web-ui -n affiliate-junction \
     -p '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"icr-secret"}]}}}}'
   ```

### Pods Crashing (CrashLoopBackOff)

**Symptoms:**
```bash
kubectl get pods -n affiliate-junction
# NAME                      READY   STATUS             RESTARTS   AGE
# web-ui-xxx-yyy           0/1     CrashLoopBackOff   5          5m
```

**Diagnosis:**
```bash
# Check pod logs
kubectl logs <pod-name> -n affiliate-junction

# Check previous container logs
kubectl logs <pod-name> -n affiliate-junction --previous

# Describe pod for events
kubectl describe pod <pod-name> -n affiliate-junction
```

**Common Causes:**

1. **Missing environment variables**
   ```bash
   # Verify secrets exist
   kubectl get secret affiliate-junction-secrets -n affiliate-junction
   
   # Check secret contents
   kubectl describe secret affiliate-junction-secrets -n affiliate-junction
   ```

2. **Database connection failure**
   ```bash
   # Test connectivity from pod
   kubectl exec -it <pod-name> -n affiliate-junction -- \
     /app/scripts/test_hcd_connection.sh
   ```

3. **Configuration file not found**
   ```bash
   # Verify ConfigMap is mounted
   kubectl exec -it <pod-name> -n affiliate-junction -- \
     ls -la /config/
   
   # Check ConfigMap exists
   kubectl get configmap affiliate-junction-config -n affiliate-junction
   ```

### Pods Not Ready (Readiness Probe Failed)

**Symptoms:**
```bash
kubectl get pods -n affiliate-junction
# NAME                      READY   STATUS    RESTARTS   AGE
# web-ui-xxx-yyy           0/1     Running   0          2m
```

**Diagnosis:**
```bash
# Check readiness probe
kubectl describe pod <pod-name> -n affiliate-junction | grep -A 10 Readiness

# Test readiness endpoint manually
kubectl exec -it <pod-name> -n affiliate-junction -- \
  curl http://localhost:10000/ready
```

**Solutions:**

1. **Database not ready**
   - Wait for HCD and Presto to be fully operational
   - Check external service endpoints

2. **Increase probe timeouts**
   ```bash
   kubectl edit deployment web-ui -n affiliate-junction
   # Increase initialDelaySeconds and timeoutSeconds
   ```

---

## Database Connectivity

### Cannot Connect to HCD

**Symptoms:**
- Pods crash with "Connection refused" errors
- Readiness probe fails
- Application logs show Cassandra connection errors

**Diagnosis:**
```bash
# Test from pod
kubectl exec -it <pod-name> -n affiliate-junction -- \
  /app/scripts/test_hcd_connection.sh

# Check service resolution
kubectl exec -it <pod-name> -n affiliate-junction -- \
  nslookup hcd-service.affiliate-junction.svc.cluster.local

# Test port connectivity
kubectl exec -it <pod-name> -n affiliate-junction -- \
  nc -zv hcd-service 9042
```

**Solutions:**

1. **External service not configured**
   ```bash
   # Create ExternalName service
   kubectl apply -f - <<EOF
   apiVersion: v1
   kind: Service
   metadata:
     name: hcd-service
     namespace: affiliate-junction
   spec:
     type: ExternalName
     externalName: <hcd-loadbalancer-hostname>
     ports:
     - port: 9042
       targetPort: 9042
   EOF
   ```

2. **Incorrect credentials**
   ```bash
   # Update secret
   kubectl create secret generic affiliate-junction-secrets \
     --from-literal=HCD_PASSWORD='<correct-password>' \
     --dry-run=client -o yaml | kubectl apply -f -
   
   # Restart pods
   kubectl rollout restart deployment/web-ui -n affiliate-junction
   ```

3. **Firewall/Network policy blocking**
   - Check IBM Cloud security groups
   - Verify VPC network ACLs
   - Check Kubernetes NetworkPolicies

### Cannot Connect to Presto

**Symptoms:**
- Presto queries fail
- "Connection timeout" errors
- SSL/TLS errors

**Diagnosis:**
```bash
# Test from pod
kubectl exec -it <pod-name> -n affiliate-junction -- \
  /app/scripts/test_presto_connection.sh

# Check SSL certificate
kubectl exec -it <pod-name> -n affiliate-junction -- \
  openssl s_client -connect presto-service:8443
```

**Solutions:**

1. **SSL certificate issues**
   ```bash
   # Mount certificate as ConfigMap
   kubectl create configmap presto-cert \
     --from-file=presto.crt=/path/to/cert \
     -n affiliate-junction
   
   # Update deployment to mount cert
   kubectl edit deployment web-ui -n affiliate-junction
   ```

2. **Catalog not configured**
   - Follow instructions in `scripts/create_presto_catalog.sh`
   - Verify catalog exists in watsonx.data console

---

## CronJob Issues

### CronJobs Not Running

**Symptoms:**
- No jobs created
- Data not being transferred

**Diagnosis:**
```bash
# Check CronJob status
kubectl get cronjobs -n affiliate-junction

# Check recent jobs
kubectl get jobs -n affiliate-junction --sort-by=.metadata.creationTimestamp

# Describe CronJob
kubectl describe cronjob hcd-to-presto -n affiliate-junction
```

**Solutions:**

1. **Schedule syntax error**
   ```bash
   # Verify cron schedule
   kubectl get cronjob hcd-to-presto -n affiliate-junction -o yaml | grep schedule
   
   # Fix schedule
   kubectl edit cronjob hcd-to-presto -n affiliate-junction
   ```

2. **CronJob suspended**
   ```bash
   # Check if suspended
   kubectl get cronjob hcd-to-presto -n affiliate-junction -o yaml | grep suspend
   
   # Resume CronJob
   kubectl patch cronjob hcd-to-presto -n affiliate-junction \
     -p '{"spec":{"suspend":false}}'
   ```

### Jobs Failing

**Symptoms:**
- Jobs complete with errors
- Data inconsistencies

**Diagnosis:**
```bash
# List failed jobs
kubectl get jobs -n affiliate-junction | grep -v Complete

# Check job logs
kubectl logs job/<job-name> -n affiliate-junction

# Check job events
kubectl describe job <job-name> -n affiliate-junction
```

**Solutions:**

1. **Increase backoff limit**
   ```bash
   kubectl edit cronjob hcd-to-presto -n affiliate-junction
   # Increase spec.jobTemplate.spec.backoffLimit
   ```

2. **Add resource limits**
   ```bash
   kubectl edit cronjob hcd-to-presto -n affiliate-junction
   # Add resources.requests and resources.limits
   ```

---

## Configuration Problems

### ConfigMap Changes Not Applied

**Symptoms:**
- Configuration changes don't take effect
- Pods still using old configuration

**Solution:**
```bash
# ConfigMaps are not automatically reloaded
# Must restart pods after ConfigMap changes

# Edit ConfigMap
kubectl edit configmap affiliate-junction-config -n affiliate-junction

# Restart all deployments
kubectl rollout restart deployment -n affiliate-junction

# Restart specific deployment
kubectl rollout restart deployment web-ui -n affiliate-junction
```

### Secret Not Found

**Symptoms:**
- Pods fail to start
- "Secret not found" errors

**Solution:**
```bash
# Verify secret exists
kubectl get secret affiliate-junction-secrets -n affiliate-junction

# Recreate secret if missing
kubectl create secret generic affiliate-junction-secrets \
  --from-literal=HCD_USERNAME=cassandra \
  --from-literal=HCD_PASSWORD='<password>' \
  --from-literal=PRESTO_USERNAME=ibmlhadmin \
  --from-literal=PRESTO_PASSWORD='<password>' \
  --from-literal=WEB_AUTH_PASSWD='watsonx.data' \
  -n affiliate-junction
```

---

## Performance Issues

### High Memory Usage

**Symptoms:**
- Pods being OOMKilled
- Slow response times

**Diagnosis:**
```bash
# Check resource usage
kubectl top pods -n affiliate-junction

# Check pod events for OOMKilled
kubectl describe pod <pod-name> -n affiliate-junction | grep -i oom
```

**Solutions:**

1. **Increase memory limits**
   ```bash
   kubectl set resources deployment web-ui \
     --limits=memory=2Gi \
     --requests=memory=1Gi \
     -n affiliate-junction
   ```

2. **Scale horizontally**
   ```bash
   kubectl scale deployment web-ui --replicas=3 -n affiliate-junction
   ```

### Slow Query Performance

**Symptoms:**
- Timeouts
- Slow dashboard loading

**Solutions:**

1. **Check database performance**
   - Monitor HCD metrics
   - Check Presto query execution times

2. **Optimize queries**
   - Review query patterns in logs
   - Add appropriate indexes

3. **Increase connection pool**
   - Edit ConfigMap to increase pool sizes
   - Restart pods

---

## Networking Issues

### LoadBalancer Pending

**Symptoms:**
```bash
kubectl get svc web-ui -n affiliate-junction
# NAME     TYPE           EXTERNAL-IP   PORT(S)
# web-ui   LoadBalancer   <pending>     10000:xxxxx/TCP
```

**Solutions:**

1. **Check IBM Cloud LoadBalancer**
   ```bash
   # List LoadBalancers
   ibmcloud ks nlb-dns ls --cluster <cluster-name>
   
   # Check cluster workers
   ibmcloud ks workers --cluster <cluster-name>
   ```

2. **Use NodePort temporarily**
   ```bash
   kubectl patch svc web-ui -n affiliate-junction \
     -p '{"spec":{"type":"NodePort"}}'
   
   # Get NodePort
   kubectl get svc web-ui -n affiliate-junction
   ```

### DNS Resolution Failures

**Symptoms:**
- Services cannot resolve each other
- "Name or service not known" errors

**Diagnosis:**
```bash
# Test DNS from pod
kubectl exec -it <pod-name> -n affiliate-junction -- \
  nslookup hcd-service.affiliate-junction.svc.cluster.local

# Check CoreDNS
kubectl get pods -n kube-system | grep coredns
kubectl logs -n kube-system <coredns-pod>
```

**Solutions:**

1. **Restart CoreDNS**
   ```bash
   kubectl rollout restart deployment coredns -n kube-system
   ```

2. **Use FQDN**
   - Update service references to use fully qualified domain names
   - Example: `hcd-service.affiliate-junction.svc.cluster.local`

---

## Getting Help

### Collect Diagnostic Information

```bash
# Create diagnostic bundle
kubectl cluster-info dump -n affiliate-junction > cluster-dump.txt

# Get all resources
kubectl get all -n affiliate-junction -o yaml > resources.yaml

# Get events
kubectl get events -n affiliate-junction --sort-by='.lastTimestamp' > events.txt
```

### Enable Debug Logging

```bash
# Update deployment with debug logging
kubectl set env deployment/web-ui LOG_LEVEL=DEBUG -n affiliate-junction
```

### Contact Support

Include the following information:
- Kubernetes version: `kubectl version`
- Cluster info: `kubectl cluster-info`
- Pod logs: `kubectl logs <pod-name> -n affiliate-junction`
- Events: `kubectl get events -n affiliate-junction`
- Resource definitions: `kubectl get <resource> <name> -n affiliate-junction -o yaml`