#!/usr/bin/env bash

set -Eeuo pipefail

# ==============================================================================
# HCD / Mission Control workshop setup on IBM Cloud IKS
#
# This script:
#   1. Checks required tools
#   2. Logs into IBM Cloud
#   3. Installs IBM Cloud plugins
#   4. Creates or reuses VPC, public gateway, subnet, IKS cluster
#   5. Configures kubectl
#   6. Disables outbound traffic protection
#   7. Installs or upgrades cert-manager
#   8. Discovers IBM COS / watsonx.data bucket
#   9. Creates or reuses COS HMAC credentials
#  10. Logs into Replicated Helm registry
#  11. Creates Mission Control Helm values with Dex username/password
#  12. Installs or upgrades Mission Control
#  13. Optionally creates a demo HCD database using MissionControlCluster YAML
#
# Re-runnable:
#   - Existing VPC/subnet/public gateway/cluster are reused.
#   - Existing COS HMAC service key is reused.
#   - Existing Helm releases are upgraded.
#   - Existing Kubernetes secrets are applied idempotently.
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh --domain banking --mission-control-license "Input"
#
# Optional:
#   ./setup.sh --phase validate --domain banking
#   ./setup.sh --phase domain --domain banking
#   ./setup.sh --phase test --domain banking
#   ./setup.sh --phase presto --domain banking
#   ./setup.sh --phase cloud --domain banking --mission-control-license "Input"
#   CLEAN_MC=true ./setup.sh              # deletes Mission Control namespace/release first
#   CLEAN_DEMO_DB=true ./setup.sh         # deletes demo DB namespace first
#   CREATE_DEMO_DB=false ./setup.sh       # skip demo DB creation
# ==============================================================================

if [ "${DEBUG:-false}" = "true" ]; then
  set -x
fi

# ------------------------------------------------------------------------------
# Defaults - override by exporting variables before running the script
# ------------------------------------------------------------------------------

REGION="${REGION:-eu-de}"
ZONE="${ZONE:-eu-de-1}"
RG="${RG:-itz-wxd-69f1c82604915752070c1b}"
PREFIX="${PREFIX:-hcd-student-69f1c82604}"

VPC_NAME="${VPC_NAME:-${PREFIX}-vpc}"
SUBNET_NAME="${SUBNET_NAME:-${PREFIX}-subnet}"
PGW_NAME="${PGW_NAME:-${PREFIX}-pgw}"
CLUSTER_NAME="${CLUSTER_NAME:-${PREFIX}-iks}"

WORKER_FLAVOR="${WORKER_FLAVOR:-bx2.4x16}"
WORKER_COUNT="${WORKER_COUNT:-3}"

BUCKET_PREFIX="${BUCKET_PREFIX:-watsonx-data-}"

MC_NAMESPACE="${MC_NAMESPACE:-mission-control}"
MC_RELEASE="${MC_RELEASE:-mission-control}"
MC_CHART="${MC_CHART:-oci://registry.replicated.com/mission-control/mission-control}"
MC_CHART_VERSION="${MC_CHART_VERSION:-}"

MC_ADMIN_USER="${MC_ADMIN_USER:-admin}"
MC_ADMIN_EMAIL="${MC_ADMIN_EMAIL:-admin@local}"
MC_ADMIN_PASSWORD="${MC_ADMIN_PASSWORD:-Password123!}"
MC_ADMIN_USER_ID="${MC_ADMIN_USER_ID:-9f35c506-cac8-4d4d-8e66-05c55624624b}"

LOKI_SECRET_NAME="${LOKI_SECRET_NAME:-loki-s3-secrets}"

CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.16.1}"

CREATE_DEMO_DB="${CREATE_DEMO_DB:-true}"
CLEAN_MC="${CLEAN_MC:-false}"
CLEAN_DEMO_DB="${CLEAN_DEMO_DB:-false}"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-sample-2p43q6vg}"
DEMO_CLUSTER_NAME="${DEMO_CLUSTER_NAME:-demo}"
DEMO_STORAGE_CLASS="${DEMO_STORAGE_CLASS:-ibmc-vpc-block-10iops-tier}"
DEMO_SUPERUSER_NAME="${DEMO_SUPERUSER_NAME:-demo-superuser}"
DEMO_SUPERUSER_PASSWORD="${DEMO_SUPERUSER_PASSWORD:-Password123!}"
DEMO_HCD_VERSION="${DEMO_HCD_VERSION:-1.2.5}"
DEMO_STORAGE_SIZE="${DEMO_STORAGE_SIZE:-2Gi}"

COS_HMAC_ROLE="${COS_HMAC_ROLE:-Writer}"
COS_HMAC_KEY_NAME="${COS_HMAC_KEY_NAME:-${PREFIX}-cos-hmac}"

ENV_FILE=".env.setup"
COS_ENV_FILE=".env.cos"
COS_HMAC_ENV_FILE=".env.cos.hmac"

DOMAIN="${DOMAIN:-banking}"
PHASE="${PHASE:-all}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAIN_DIR=""
DOMAIN_DESCRIPTOR=""
DOMAIN_CONFIG=""

# shellcheck source=common/schema_runner.sh
source "$ROOT_DIR/common/schema_runner.sh"
# shellcheck source=common/env_loader.sh
source "$ROOT_DIR/common/env_loader.sh"

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

log() {
  echo
  echo "================================================================================"
  echo "$1"
  echo "================================================================================"
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1"
    echo "Please install it and re-run."
    exit 1
  fi
}

usage() {
  cat <<'USAGE'
Usage:
  ./setup-k8s.sh --domain <domain> --mission-control-license "<LICENSE>" [--phase <phase>]

Required:
  --domain <domain>                    Domain name (e.g., banking, affiliate-junction)
  --mission-control-license <license>  Mission Control license ID (required for cloud/mission-control/hcd/platform/all phases)

Optional:
  --phase <phase>                      Execution phase (default: all)
                                       Phases:
                                         validate        - Validate configuration and prerequisites
                                         cloud           - Provision IBM Cloud infrastructure (VPC, IKS, Mission Control, HCD)
                                         mission-control - Install/upgrade Mission Control only
                                         hcd             - Create demo HCD database only
                                         presto          - Configure Presto catalog
                                         build           - Build and push container image to IBM Cloud Container Registry
                                         app-deploy      - Deploy application to Kubernetes (ConfigMap, Secret, workloads)
                                         domain          - Show domain configuration (dry-run)
                                         deploy          - Deploy domain manifests to Kubernetes (legacy)
                                         test            - Run connectivity tests
                                         platform        - Full platform setup (cloud + mission-control, no demo DB)
                                         all             - Execute all phases (default)

  -h, --help                           Show this help.

Environment variables are still supported for existing workshop settings.
Secrets belong in local .env.* files or Kubernetes Secrets, not in Git.

Examples:
  # Full deployment (infrastructure + application)
  ./setup-k8s.sh --domain affiliate-junction --mission-control-license "LICENSE" --phase all

  # Build and deploy application only (after infrastructure is ready)
  ./setup-k8s.sh --domain affiliate-junction --phase build
  ./setup-k8s.sh --domain affiliate-junction --phase app-deploy

  # Infrastructure only
  ./setup-k8s.sh --domain affiliate-junction --mission-control-license "LICENSE" --phase platform
USAGE
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --domain)
        if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
          echo "Missing value for --domain"
          usage
          exit 1
        fi
        DOMAIN="$2"
        shift 2
        ;;
      --mission-control-license)
        if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
          echo "Missing value for --mission-control-license"
          usage
          exit 1
        fi
        MC_LICENSE_ID="$2"
        export MC_LICENSE_ID
        shift 2
        ;;
      --phase)
        if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
          echo "Missing value for --phase"
          usage
          exit 1
        fi
        PHASE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done
}

validate_args() {
  case "$PHASE" in
    validate|cloud|mission-control|hcd|presto|build|app-deploy|domain|deploy|test|all|platform)
      ;;
    *)
      echo "Invalid phase: $PHASE"
      usage
      exit 1
      ;;
  esac

  DOMAIN_DIR="$ROOT_DIR/domains/$DOMAIN"
  DOMAIN_DESCRIPTOR="$DOMAIN_DIR/domain.yaml"

  if ! load_domain_config "$DOMAIN" "$ROOT_DIR"; then
    exit 1
  fi

  case "$PHASE" in
    all|cloud|mission-control|hcd|platform)
      if [ -z "${MC_LICENSE_ID:-}" ]; then
        echo "Missing required setup parameter: --mission-control-license"
        usage
        exit 1
      fi
      ;;
  esac

}

require_env_var() {
  local var_name="$1"
  local example_file="$2"

  if [ -z "${!var_name:-}" ]; then
    echo "Missing required environment variable for phase '$PHASE': $var_name"
    echo "Create/fill the matching env file from: $example_file"
    exit 1
  fi
}

validate_phase_env() {
  case "$PHASE" in
    presto)
      require_env_var "PRESTO_HOST" "config/.env.presto.example"
      require_env_var "PRESTO_ENGINE_HOST" "config/.env.presto.example"
      require_env_var "PRESTO_USERNAME" "config/.env.presto.example"
      require_env_var "PRESTO_PASSWORD_OR_APIKEY" "config/.env.presto.example"
      ;;
    test)
      require_env_var "HCD_CONTACT_POINTS" "config/.env.hcd.example"
      require_env_var "HCD_USERNAME" "config/.env.hcd.example"
      require_env_var "HCD_PASSWORD" "config/.env.hcd.example"
      require_env_var "PRESTO_ENGINE_HOST" "config/.env.presto.example"
      require_env_var "PRESTO_USERNAME" "config/.env.presto.example"
      require_env_var "PRESTO_PASSWORD_OR_APIKEY" "config/.env.presto.example"
      ;;
  esac
}

run_validate_phase() {
  log "Validation phase"
  print_missing_env_guidance "$ROOT_DIR" "$DOMAIN"
  print_domain_plan "$DOMAIN" "$ROOT_DIR"
}

run_presto_phase() {
  log "Presto/watsonx.data phase"
  scripts/create_presto_catalog.sh
}

run_build_phase() {
  log "Build phase - Building container image"
  
  # Determine container tool (podman or docker)
  if command -v podman &> /dev/null; then
    CONTAINER_TOOL="podman"
  elif command -v docker &> /dev/null; then
    CONTAINER_TOOL="docker"
  else
    echo "ERROR: Neither podman nor docker found. Please install one of them."
    exit 1
  fi
  
  log "Using container tool: $CONTAINER_TOOL"
  
  # Get IBM Cloud Container Registry info
  ICR_REGION="${ICR_REGION:-us.icr.io}"
  ICR_NAMESPACE="${ICR_NAMESPACE:-affiliate-junction}"
  IMAGE_NAME="${IMAGE_NAME:-affiliate-junction-demo}"
  IMAGE_TAG="${IMAGE_TAG:-latest}"
  
  FULL_IMAGE="${ICR_REGION}/${ICR_NAMESPACE}/${IMAGE_NAME}:${IMAGE_TAG}"
  
  log "Building image: $FULL_IMAGE"
  
  # Build the image
  $CONTAINER_TOOL build -t "$FULL_IMAGE" -f Dockerfile .
  
  if [ $? -ne 0 ]; then
    echo "ERROR: Image build failed"
    exit 1
  fi
  
  log "Image built successfully: $FULL_IMAGE"
  
  # Login to IBM Cloud Container Registry
  log "Logging into IBM Cloud Container Registry..."
  ibmcloud cr login
  
  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to login to IBM Cloud Container Registry"
    exit 1
  fi
  
  # Create namespace if it doesn't exist
  log "Ensuring ICR namespace exists: $ICR_NAMESPACE"
  ibmcloud cr namespace-add "$ICR_NAMESPACE" 2>/dev/null || true
  
  # Push the image
  log "Pushing image to registry..."
  $CONTAINER_TOOL push "$FULL_IMAGE"
  
  if [ $? -ne 0 ]; then
    echo "ERROR: Image push failed"
    exit 1
  fi
  
  log "Image pushed successfully: $FULL_IMAGE"
  
  # Save image reference for deploy phase
  echo "export CONTAINER_IMAGE=\"$FULL_IMAGE\"" > .env.image
  
  log "Build phase complete. Image: $FULL_IMAGE"
}

run_app_deploy_phase() {
  log "Application deployment phase"
  
  # Load image reference if available
  if [ -f .env.image ]; then
    source .env.image
  fi
  
  # Verify domain config exists
  DOMAIN_CONFIG="config/domains/$DOMAIN/domain.yaml"
  if [ ! -f "$DOMAIN_CONFIG" ]; then
    echo "ERROR: Domain configuration not found: $DOMAIN_CONFIG"
    exit 1
  fi
  
  log "Loading domain configuration from: $DOMAIN_CONFIG"
  
  # Create namespace if it doesn't exist
  NAMESPACE=$(grep "namespace:" "$DOMAIN_CONFIG" | head -1 | awk '{print $2}')
  if [ -z "$NAMESPACE" ]; then
    NAMESPACE="$DOMAIN"
  fi
  
  log "Creating namespace: $NAMESPACE"
  kubectl create namespace "$NAMESPACE" 2>/dev/null || true
  
  # Create ConfigMap from domain config
  log "Creating ConfigMap from domain configuration..."
  kubectl create configmap "${DOMAIN}-config" \
    --from-file=config.yaml="$DOMAIN_CONFIG" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
  
  # Create Secret from environment files
  log "Creating Secret from environment configuration..."
  
  # Check for domain-specific env files
  ENV_HCD="config/domains/$DOMAIN/.env.hcd"
  ENV_PRESTO="config/domains/$DOMAIN/.env.presto"
  ENV_WEB="config/domains/$DOMAIN/.env.web"
  
  # Build secret data
  SECRET_DATA=""
  
  if [ -f "$ENV_HCD" ]; then
    log "Loading HCD credentials from: $ENV_HCD"
    while IFS='=' read -r key value; do
      # Skip comments and empty lines
      [[ "$key" =~ ^#.*$ ]] && continue
      [[ -z "$key" ]] && continue
      # Remove quotes from value
      value=$(echo "$value" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
      SECRET_DATA="$SECRET_DATA --from-literal=$key=$value"
    done < "$ENV_HCD"
  fi
  
  if [ -f "$ENV_PRESTO" ]; then
    log "Loading Presto credentials from: $ENV_PRESTO"
    while IFS='=' read -r key value; do
      [[ "$key" =~ ^#.*$ ]] && continue
      [[ -z "$key" ]] && continue
      value=$(echo "$value" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
      SECRET_DATA="$SECRET_DATA --from-literal=$key=$value"
    done < "$ENV_PRESTO"
  fi
  
  if [ -f "$ENV_WEB" ]; then
    log "Loading Web credentials from: $ENV_WEB"
    while IFS='=' read -r key value; do
      [[ "$key" =~ ^#.*$ ]] && continue
      [[ -z "$key" ]] && continue
      value=$(echo "$value" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
      SECRET_DATA="$SECRET_DATA --from-literal=$key=$value"
    done < "$ENV_WEB"
  fi
  
  if [ -n "$SECRET_DATA" ]; then
    eval "kubectl create secret generic ${DOMAIN}-secrets $SECRET_DATA --namespace=$NAMESPACE --dry-run=client -o yaml | kubectl apply -f -"
  else
    echo "WARNING: No environment files found. Secret not created."
    echo "Expected files: $ENV_HCD, $ENV_PRESTO, $ENV_WEB"
  fi
  
  # Update kustomization with image if provided
  if [ -n "${CONTAINER_IMAGE:-}" ]; then
    log "Updating kustomization with image: $CONTAINER_IMAGE"
    
    KUSTOMIZATION="k8s/overlays/$DOMAIN/kustomization.yaml"
    if [ -f "$KUSTOMIZATION" ]; then
      # Check if images section exists
      if grep -q "^images:" "$KUSTOMIZATION"; then
        # Update existing images section
        sed -i.bak "/^images:/,/^[^ ]/ s|newName:.*|newName: ${CONTAINER_IMAGE%:*}|" "$KUSTOMIZATION"
        sed -i.bak "/^images:/,/^[^ ]/ s|newTag:.*|newTag: ${CONTAINER_IMAGE##*:}|" "$KUSTOMIZATION"
      else
        # Add images section
        cat >> "$KUSTOMIZATION" <<EOF

images:
  - name: affiliate-junction-demo
    newName: ${CONTAINER_IMAGE%:*}
    newTag: ${CONTAINER_IMAGE##*:}
EOF
      fi
    fi
  fi
  
  # Deploy application using kustomize
  log "Deploying application to namespace: $NAMESPACE"
  kubectl apply -k "k8s/overlays/$DOMAIN"
  
  if [ $? -ne 0 ]; then
    echo "ERROR: Application deployment failed"
    exit 1
  fi
  
  log "Application deployed successfully"
  
  # Wait for deployment to be ready
  log "Waiting for web UI deployment to be ready..."
  kubectl wait --for=condition=available --timeout=300s \
    deployment/web-ui -n "$NAMESPACE" 2>/dev/null || true
  
  # Get service URL
  log "Getting service URL..."
  WEB_UI_LB=$(kubectl get svc web-ui-lb -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  
  if [ -n "$WEB_UI_LB" ]; then
    log "Web UI available at: http://${WEB_UI_LB}:10000"
  else
    log "Web UI service created. Use 'kubectl get svc -n $NAMESPACE' to get the LoadBalancer URL"
  fi
  
  log "Application deployment phase complete"
}

run_deploy_phase() {
  log "Legacy deploy phase - use 'app-deploy' for full application deployment"
  kubectl apply -k "k8s/overlays/$DOMAIN"
}

run_test_phase() {
  log "Running connection tests"
  scripts/test_hcd_connection.sh
  scripts/test_presto_connection.sh
}

ask_if_empty() {
  local var_name="$1"
  local prompt="$2"
  local secret="${3:-false}"
  local current_value="${!var_name:-}"

  if [ -z "$current_value" ]; then
    if [ "$secret" = "true" ]; then
      read -r -s -p "$prompt: " value
      echo
    else
      read -r -p "$prompt: " value
    fi
    export "$var_name=$value"
  fi
}

wait_for_namespace_deleted() {
  local ns="$1"
  for i in {1..60}; do
    if ! kubectl get ns "$ns" >/dev/null 2>&1; then
      return 0
    fi
    echo "Waiting for namespace $ns to be deleted..."
    sleep 10
  done

  echo "Namespace $ns still exists after waiting."
  exit 1
}

wait_for_iks_ready() {
  log "Waiting for IKS workers to become Ready"

  for i in {1..90}; do
    ibmcloud ks cluster get --cluster "$CLUSTER_NAME" || true
    ibmcloud ks workers --cluster "$CLUSTER_NAME" || true

    local ready_count
    ready_count="$(ibmcloud ks workers --cluster "$CLUSTER_NAME" --output json 2>/dev/null \
      | jq '[.[] | select((.health.state // .health.message // .state // "") | tostring | test("normal|Ready|ready"; "i"))] | length' || echo 0)"

    if [ "$ready_count" -ge "$WORKER_COUNT" ]; then
      echo "IKS workers appear ready."
      return 0
    fi

    echo "Workers not ready yet. Sleeping 60s..."
    sleep 60
  done

  echo "Timed out waiting for IKS workers."
  exit 1
}

parse_args "$@"
REQUESTED_DOMAIN="$DOMAIN"
REQUESTED_PHASE="$PHASE"
load_domain_env "$ROOT_DIR" "$DOMAIN"
DOMAIN="$REQUESTED_DOMAIN"
PHASE="$REQUESTED_PHASE"
REGION="${IBM_CLOUD_REGION:-$REGION}"
RG="${IBM_CLOUD_RESOURCE_GROUP:-$RG}"
DEMO_NAMESPACE="${DOMAIN_NAMESPACE:-$DEMO_NAMESPACE}"
export DOMAIN
export PHASE
validate_args
DEMO_NAMESPACE="${DOMAIN_NAMESPACE:-$DEMO_NAMESPACE}"
validate_phase_env

log "Loading domain configuration"
print_domain_plan "$DOMAIN" "$ROOT_DIR"

log "Selected setup phases"
echo "Preflight: parameter and domain validation"
if [ "$PHASE" = "all" ] || [ "$PHASE" = "platform" ] || [ "$PHASE" = "cloud" ] || [ "$PHASE" = "mission-control" ] || [ "$PHASE" = "hcd" ]; then
  echo "Platform: IBM Cloud login, IKS, Mission Control, HCD provisioning"
  echo "Data platform: Presto, Hive metastore, and Iceberg configuration hooks"
fi
if [ "$PHASE" = "all" ] || [ "$PHASE" = "domain" ] || [ "$PHASE" = "deploy" ]; then
  echo "Domain: schemas, generators, Kubernetes jobs, services, and UI labels"
fi

case "$PHASE" in
  validate)
    run_validate_phase
    exit 0
    ;;
  domain)
    log "Domain deployment phase"
    echo "Domain: $DOMAIN"
    echo "Descriptor: $DOMAIN_DESCRIPTOR"
    echo "Dry run only. Use scripts/deploy_domain.sh or ./setup-k8s.sh --phase app-deploy after platform setup to apply domain manifests."
    exit 0
    ;;
  presto)
    run_presto_phase
    exit 0
    ;;
  build)
    run_build_phase
    exit 0
    ;;
  app-deploy)
    run_app_deploy_phase
    exit 0
    ;;
  deploy)
    run_deploy_phase
    exit 0
    ;;
  test)
    run_test_phase
    exit 0
    ;;
esac

if [ "$PHASE" = "platform" ] || [ "$PHASE" = "cloud" ] || [ "$PHASE" = "mission-control" ]; then
  CREATE_DEMO_DB="false"
fi

helm_install_or_upgrade() {
  local release="$1"
  local namespace="$2"
  local chart="$3"
  local values="$4"
  local timeout="${5:-30m}"

  if helm status "$release" -n "$namespace" >/dev/null 2>&1; then
    if [ -n "${MC_CHART_VERSION:-}" ]; then
      helm upgrade "$release" "$chart" \
        --version "$MC_CHART_VERSION" \
        --namespace "$namespace" \
        -f "$values" \
        --wait \
        --timeout "$timeout" \
        --debug
    else
      helm upgrade "$release" "$chart" \
        --namespace "$namespace" \
        -f "$values" \
        --wait \
        --timeout "$timeout" \
        --debug
    fi
  else
    if [ -n "${MC_CHART_VERSION:-}" ]; then
      helm install "$release" "$chart" \
        --version "$MC_CHART_VERSION" \
        --namespace "$namespace" \
        --create-namespace \
        -f "$values" \
        --wait \
        --timeout "$timeout" \
        --debug
    else
      helm install "$release" "$chart" \
        --namespace "$namespace" \
        --create-namespace \
        -f "$values" \
        --wait \
        --timeout "$timeout" \
        --debug
    fi
  fi
}

# ------------------------------------------------------------------------------
# 1. Check tools
# ------------------------------------------------------------------------------

log "Checking required tools"

need_cmd ibmcloud
need_cmd jq
need_cmd kubectl
need_cmd helm
need_cmd base64

# ------------------------------------------------------------------------------
# 2. Inputs
# ------------------------------------------------------------------------------

log "Collecting inputs"

ask_if_empty "MC_LICENSE_ID" "Enter Mission Control / Replicated license ID" true

echo "Using:"
echo "DOMAIN=$DOMAIN"
echo "PHASE=$PHASE"
echo "DOMAIN_DESCRIPTOR=$DOMAIN_DESCRIPTOR"
echo "REGION=$REGION"
echo "ZONE=$ZONE"
echo "RG=$RG"
echo "PREFIX=$PREFIX"
echo "VPC_NAME=$VPC_NAME"
echo "SUBNET_NAME=$SUBNET_NAME"
echo "PGW_NAME=$PGW_NAME"
echo "CLUSTER_NAME=$CLUSTER_NAME"
echo "MC_NAMESPACE=$MC_NAMESPACE"
echo "MC_RELEASE=$MC_RELEASE"
echo "MC_ADMIN_USER=$MC_ADMIN_USER"
echo "MC_ADMIN_EMAIL=$MC_ADMIN_EMAIL"
echo "CREATE_DEMO_DB=$CREATE_DEMO_DB"
echo "DEMO_NAMESPACE=$DEMO_NAMESPACE"
echo "DEMO_STORAGE_CLASS=$DEMO_STORAGE_CLASS"

cat > "$ENV_FILE" <<ENVEOF
export DOMAIN="$DOMAIN"
export PHASE="$PHASE"
export REGION="$REGION"
export ZONE="$ZONE"
export RG="$RG"
export PREFIX="$PREFIX"
export VPC_NAME="$VPC_NAME"
export SUBNET_NAME="$SUBNET_NAME"
export PGW_NAME="$PGW_NAME"
export CLUSTER_NAME="$CLUSTER_NAME"
export WORKER_FLAVOR="$WORKER_FLAVOR"
export WORKER_COUNT="$WORKER_COUNT"
export MC_NAMESPACE="$MC_NAMESPACE"
export MC_RELEASE="$MC_RELEASE"
export MC_ADMIN_USER="$MC_ADMIN_USER"
export MC_ADMIN_EMAIL="$MC_ADMIN_EMAIL"
export DEMO_NAMESPACE="$DEMO_NAMESPACE"
export DEMO_CLUSTER_NAME="$DEMO_CLUSTER_NAME"
export DEMO_STORAGE_CLASS="$DEMO_STORAGE_CLASS"
ENVEOF

# ------------------------------------------------------------------------------
# 3. IBM Cloud login and plugins
# ------------------------------------------------------------------------------

log "Logging into IBM Cloud"

if ! ibmcloud target >/dev/null 2>&1; then
  ibmcloud login --sso -r "$REGION"
else
  ibmcloud target -r "$REGION" || ibmcloud login --sso -r "$REGION"
fi

ibmcloud target -g "$RG"
ibmcloud target
ibmcloud is target --gen 2

log "Installing IBM Cloud plugins"

ibmcloud plugin install container-service -f
ibmcloud plugin install container-registry -f
ibmcloud plugin install vpc-infrastructure -f
ibmcloud plugin install cloud-object-storage -f
ibmcloud plugin list

# ------------------------------------------------------------------------------
# 4. VPC
# ------------------------------------------------------------------------------

log "Creating or reusing VPC"

VPC_ID="$(
  ibmcloud is vpcs --output json \
    | jq -r --arg name "$VPC_NAME" '.[] | select(.name == $name) | .id' \
    | head -n 1
)"

if [ -z "$VPC_ID" ]; then
  ibmcloud is vpc-create "$VPC_NAME" --resource-group-name "$RG"
  VPC_ID="$(
    ibmcloud is vpcs --output json \
      | jq -r --arg name "$VPC_NAME" '.[] | select(.name == $name) | .id' \
      | head -n 1
  )"
fi

test -n "$VPC_ID"
echo "VPC_ID=$VPC_ID"

# ------------------------------------------------------------------------------
# 5. Public Gateway
# ------------------------------------------------------------------------------

log "Creating or reusing public gateway"

PGW_ID="$(
  ibmcloud is public-gateways --output json \
    | jq -r --arg name "$PGW_NAME" '.[] | select(.name == $name) | .id' \
    | head -n 1
)"

if [ -z "$PGW_ID" ]; then
  ibmcloud is public-gateway-create "$PGW_NAME" "$VPC_ID" "$ZONE" \
    --resource-group-name "$RG"

  PGW_ID="$(
    ibmcloud is public-gateways --output json \
      | jq -r --arg name "$PGW_NAME" '.[] | select(.name == $name) | .id' \
      | head -n 1
  )"
fi

test -n "$PGW_ID"
echo "PGW_ID=$PGW_ID"

# ------------------------------------------------------------------------------
# 6. Subnet
# ------------------------------------------------------------------------------

log "Creating or reusing subnet"

SUBNET_ID="$(
  ibmcloud is subnets --output json \
    | jq -r --arg name "$SUBNET_NAME" '.[] | select(.name == $name) | .id' \
    | head -n 1
)"

if [ -z "$SUBNET_ID" ]; then
  ibmcloud is subnet-create "$SUBNET_NAME" \
    "$VPC_ID" \
    --zone "$ZONE" \
    --ipv4-address-count 256 \
    --public-gateway-id "$PGW_ID" \
    --resource-group-name "$RG"

  SUBNET_ID="$(
    ibmcloud is subnets --output json \
      | jq -r --arg name "$SUBNET_NAME" '.[] | select(.name == $name) | .id' \
      | head -n 1
  )"
fi

test -n "$SUBNET_ID"
echo "SUBNET_ID=$SUBNET_ID"

cat >> "$ENV_FILE" <<ENVEOF
export VPC_ID="$VPC_ID"
export PGW_ID="$PGW_ID"
export SUBNET_ID="$SUBNET_ID"
ENVEOF

ibmcloud is vpcs
ibmcloud is public-gateways
ibmcloud is subnets

# ------------------------------------------------------------------------------
# 7. IKS cluster
# ------------------------------------------------------------------------------

log "Creating or reusing IKS cluster"

if ibmcloud ks cluster get --cluster "$CLUSTER_NAME" >/dev/null 2>&1; then
  echo "Cluster already exists: $CLUSTER_NAME"
else
  ibmcloud ks flavors --zone "$ZONE"

  ibmcloud ks cluster create vpc-gen2 \
    --name "$CLUSTER_NAME" \
    --flavor "$WORKER_FLAVOR" \
    --workers "$WORKER_COUNT" \
    --vpc-id "$VPC_ID" \
    --subnet-id "$SUBNET_ID" \
    --zone "$ZONE"
fi

wait_for_iks_ready

# ------------------------------------------------------------------------------
# 8. kubectl config
# ------------------------------------------------------------------------------

log "Configuring kubectl"

ibmcloud ks cluster config --cluster "$CLUSTER_NAME"

kubectl get nodes -o wide

# ------------------------------------------------------------------------------
# 9. Disable outbound traffic protection
# ------------------------------------------------------------------------------

log "Disabling outbound traffic protection"

ibmcloud ks vpc outbound-traffic-protection disable --cluster "$CLUSTER_NAME" || true
ibmcloud ks cluster get --cluster "$CLUSTER_NAME" | grep -i "Outbound Traffic Protection" || true

# Optional connectivity test. Do not fail the whole script if it flakes.
kubectl run curl-test \
  --image=curlimages/curl \
  --rm -it \
  --restart=Never \
  -- curl -I https://quay.io || true

# ------------------------------------------------------------------------------
# 10. cert-manager
# ------------------------------------------------------------------------------

log "Installing or upgrading cert-manager"

helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update

if helm status cert-manager -n cert-manager >/dev/null 2>&1; then
  helm upgrade cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --version "$CERT_MANAGER_VERSION" \
    --set crds.enabled=true \
    --set 'extraArgs[0]=--enable-certificate-owner-ref=true' \
    --wait \
    --timeout 10m \
    --debug
else
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version "$CERT_MANAGER_VERSION" \
    --set crds.enabled=true \
    --set 'extraArgs[0]=--enable-certificate-owner-ref=true' \
    --wait \
    --timeout 10m \
    --debug
fi

helm list -n cert-manager
kubectl get pods -n cert-manager
kubectl get jobs -n cert-manager || true

# ------------------------------------------------------------------------------
# 11. Discover COS / watsonx.data bucket
# ------------------------------------------------------------------------------

log "Discovering IBM COS / watsonx.data bucket"

ibmcloud target -g "$RG"

COS_INSTANCE_JSON="$(
  ibmcloud resource service-instances \
    --service-name cloud-object-storage \
    --output json
)"

COS_INSTANCE_NAME="$(
  echo "$COS_INSTANCE_JSON" | jq -r '.[0].name'
)"

COS_INSTANCE_CRN="$(
  echo "$COS_INSTANCE_JSON" | jq -r '.[0].crn'
)"

COS_INSTANCE_GUID="$(
  echo "$COS_INSTANCE_JSON" | jq -r '.[0].guid'
)"

test -n "$COS_INSTANCE_NAME"
test -n "$COS_INSTANCE_CRN"
test -n "$COS_INSTANCE_GUID"

ibmcloud cos config crn --crn "$COS_INSTANCE_CRN"

COS_BUCKET="$(
  ibmcloud cos buckets --output json \
    | jq -r --arg prefix "$BUCKET_PREFIX" '.Buckets[]?.Name | select(startswith($prefix))' \
    | head -n 1
)"

if [ -z "$COS_BUCKET" ]; then
  echo "Could not discover COS bucket with prefix: $BUCKET_PREFIX"
  echo "Available buckets:"
  ibmcloud cos buckets
  exit 1
fi

COS_ENDPOINT="https://s3.direct.${REGION}.cloud-object-storage.appdomain.cloud"
COS_REGION="$REGION"

cat > "$COS_ENV_FILE" <<COSEOF
export COS_INSTANCE_NAME="$COS_INSTANCE_NAME"
export COS_INSTANCE_CRN="$COS_INSTANCE_CRN"
export COS_INSTANCE_GUID="$COS_INSTANCE_GUID"
export COS_BUCKET="$COS_BUCKET"
export COS_ENDPOINT="$COS_ENDPOINT"
export COS_REGION="$COS_REGION"
COSEOF

echo "COS_INSTANCE_NAME=$COS_INSTANCE_NAME"
echo "COS_INSTANCE_CRN=$COS_INSTANCE_CRN"
echo "COS_INSTANCE_GUID=$COS_INSTANCE_GUID"
echo "COS_BUCKET=$COS_BUCKET"
echo "COS_ENDPOINT=$COS_ENDPOINT"
echo "COS_REGION=$COS_REGION"

# ------------------------------------------------------------------------------
# 12. COS HMAC credentials
# ------------------------------------------------------------------------------

log "Creating or reusing COS HMAC credentials"

if ibmcloud resource service-key "$COS_HMAC_KEY_NAME" >/dev/null 2>&1; then
  echo "Service key already exists: $COS_HMAC_KEY_NAME"
else
  ibmcloud resource service-key-create "$COS_HMAC_KEY_NAME" "$COS_HMAC_ROLE" \
    --instance-name "$COS_INSTANCE_NAME" \
    --parameters '{"HMAC":true}'
fi

COS_ACCESS_KEY_ID="$(
  ibmcloud resource service-key "$COS_HMAC_KEY_NAME" --output json \
    | jq -r '.[0].credentials.cos_hmac_keys.access_key_id'
)"

COS_SECRET_ACCESS_KEY="$(
  ibmcloud resource service-key "$COS_HMAC_KEY_NAME" --output json \
    | jq -r '.[0].credentials.cos_hmac_keys.secret_access_key'
)"

test -n "$COS_ACCESS_KEY_ID"
test -n "$COS_SECRET_ACCESS_KEY"

cat > "$COS_HMAC_ENV_FILE" <<HMACEOF
export COS_ACCESS_KEY_ID="$COS_ACCESS_KEY_ID"
export COS_SECRET_ACCESS_KEY="$COS_SECRET_ACCESS_KEY"
export COS_HMAC_KEY_NAME="$COS_HMAC_KEY_NAME"
HMACEOF

echo "COS_ACCESS_KEY_ID length: ${#COS_ACCESS_KEY_ID}"
echo "COS_SECRET_ACCESS_KEY length: ${#COS_SECRET_ACCESS_KEY}"

# ------------------------------------------------------------------------------
# 13. Namespace and reusable COS secret
# ------------------------------------------------------------------------------

log "Creating Mission Control namespace and COS secrets"

kubectl create namespace "$MC_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic hcd-cos-s3-credentials \
  --namespace "$MC_NAMESPACE" \
  --from-literal=accessKeyId="$COS_ACCESS_KEY_ID" \
  --from-literal=secretAccessKey="$COS_SECRET_ACCESS_KEY" \
  --from-literal=bucket="$COS_BUCKET" \
  --from-literal=endpoint="$COS_ENDPOINT" \
  --from-literal=region="$COS_REGION" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$MC_NAMESPACE" create secret generic "$LOKI_SECRET_NAME" \
  --from-literal=s3-access-key-id="$COS_ACCESS_KEY_ID" \
  --from-literal=s3-secret-access-key="$COS_SECRET_ACCESS_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl get secret hcd-cos-s3-credentials -n "$MC_NAMESPACE"
kubectl get secret "$LOKI_SECRET_NAME" -n "$MC_NAMESPACE"

# ------------------------------------------------------------------------------
# 14. Helm registry login
# ------------------------------------------------------------------------------

log "Configuring Helm registry auth"

HELM_REGISTRY_CONFIG="$(
  helm env | awk -F= '/HELM_REGISTRY_CONFIG/ {gsub(/"/, "", $2); print $2}'
)"

mkdir -p "$(dirname "$HELM_REGISTRY_CONFIG")"

if [ ! -f "$HELM_REGISTRY_CONFIG" ] || grep -q "credsStore" "$HELM_REGISTRY_CONFIG"; then
  cat > "$HELM_REGISTRY_CONFIG" <<REGEOF
{
  "auths": {}
}
REGEOF
fi

cat "$HELM_REGISTRY_CONFIG"

printf '%s' "$MC_LICENSE_ID" | helm registry login registry.replicated.com \
  --username "$MC_LICENSE_ID" \
  --password-stdin \
  --debug

# ------------------------------------------------------------------------------
# 15. Generate Dex bcrypt hash using Kubernetes, not local Docker/Podman/Python
# ------------------------------------------------------------------------------

log "Generating Dex bcrypt hash"

kubectl create namespace "$MC_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

MC_ADMIN_HASH="$(
  kubectl run bcrypt-hash \
    -n "$MC_NAMESPACE" \
    --image=httpd:2.4-alpine \
    --restart=Never \
    --rm -i \
    --quiet \
    --command -- htpasswd -bnBC 10 "" "$MC_ADMIN_PASSWORD" \
    | tr -d ':\r\n'
)"

if [ -z "$MC_ADMIN_HASH" ]; then
  echo "Failed to generate bcrypt hash."
  exit 1
fi

echo "Generated Dex bcrypt hash length: ${#MC_ADMIN_HASH}"

# ------------------------------------------------------------------------------
# 16. Generate Mission Control Helm values
# ------------------------------------------------------------------------------

log "Generating mission-control-values.yaml"

cat > mission-control-values.yaml <<MCEOF
controlPlane: true
disableCertManagerCheck: true

ui:
  enabled: true
  https:
    enabled: true
  ingress:
    enabled: false

grafana:
  enabled: true

dex:
  config:
    enablePasswordDB: true
    staticPasswords:
      - email: ${MC_ADMIN_EMAIL}
        hash: "${MC_ADMIN_HASH}"
        username: ${MC_ADMIN_USER}
        userID: ${MC_ADMIN_USER_ID}

loki:
  enabled: true

  loki:
    commonConfig:
      replication_factor: 1

    schemaConfig:
      configs:
        - from: "2024-04-01"
          store: tsdb
          object_store: s3
          schema: v13
          index:
            prefix: index_
            period: 24h

    storage:
      type: s3
      bucketNames:
        chunks: ${COS_BUCKET}
        ruler: ${COS_BUCKET}
        admin: ${COS_BUCKET}
      s3:
        accessKeyId: "\${AWS_ACCESS_KEY_ID}"
        secretAccessKey: "\${AWS_SECRET_ACCESS_KEY}"
        endpoint: ${COS_ENDPOINT}
        region: ${COS_REGION}
        insecure: false
        s3ForcePathStyle: true

    limits_config:
      retention_period: 7d

    compactor:
      retention_enabled: true
      delete_request_store: s3
      working_directory: /var/loki/retention

  backend:
    replicas: 1
    persistence:
      enabled: true
      size: 10Gi
      storageClassName: ""
    extraArgs:
      - "-config.expand-env=true"
    extraEnv:
      - name: AWS_ACCESS_KEY_ID
        valueFrom:
          secretKeyRef:
            name: ${LOKI_SECRET_NAME}
            key: s3-access-key-id
      - name: AWS_SECRET_ACCESS_KEY
        valueFrom:
          secretKeyRef:
            name: ${LOKI_SECRET_NAME}
            key: s3-secret-access-key

  read:
    replicas: 1
    persistence:
      enabled: true
      size: 10Gi
      storageClassName: ""

  write:
    replicas: 1
    persistence:
      enabled: true
      size: 10Gi
      storageClassName: ""

mimir:
  enabled: false

minio:
  enabled: false
MCEOF

grep -n "dex:" -A15 mission-control-values.yaml
grep -n "loki:" -A120 mission-control-values.yaml

# ------------------------------------------------------------------------------
# 17. Optional clean Mission Control
# ------------------------------------------------------------------------------

if [ "$CLEAN_MC" = "true" ]; then
  log "Cleaning existing Mission Control deployment"

  helm uninstall "$MC_RELEASE" -n "$MC_NAMESPACE" --debug || true
  kubectl delete namespace "$MC_NAMESPACE" --ignore-not-found
  wait_for_namespace_deleted "$MC_NAMESPACE"

  kubectl create namespace "$MC_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "$MC_NAMESPACE" create secret generic "$LOKI_SECRET_NAME" \
    --from-literal=s3-access-key-id="$COS_ACCESS_KEY_ID" \
    --from-literal=s3-secret-access-key="$COS_SECRET_ACCESS_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic hcd-cos-s3-credentials \
    --namespace "$MC_NAMESPACE" \
    --from-literal=accessKeyId="$COS_ACCESS_KEY_ID" \
    --from-literal=secretAccessKey="$COS_SECRET_ACCESS_KEY" \
    --from-literal=bucket="$COS_BUCKET" \
    --from-literal=endpoint="$COS_ENDPOINT" \
    --from-literal=region="$COS_REGION" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# ------------------------------------------------------------------------------
# 18. Render and validate Helm chart
# ------------------------------------------------------------------------------

log "Rendering Mission Control Helm chart"

HELM_VERSION_ARG=""

if [ -n "${MC_CHART_VERSION:-}" ]; then
  HELM_VERSION_ARG="--version ${MC_CHART_VERSION}"
fi

# shellcheck disable=SC2086
helm template "$MC_RELEASE" \
  oci://registry.replicated.com/mission-control/mission-control \
  --namespace "$MC_NAMESPACE" \
  -f mission-control-values.yaml \
  $HELM_VERSION_ARG \
  --debug > mc-rendered.yaml

grep -n "enablePasswordDB\|staticPasswords" mc-rendered.yaml -A20 -B10 || true
grep -n "object_store\|storage_config\|bucketnames\|s3forcepathstyle\|retention_period\|delete_request_store\|compactor" mc-rendered.yaml | head -120 || true

if ! grep -q "admin@local\|staticPasswords\|dex" mc-rendered.yaml; then
  echo "WARNING: Dex admin password config not obviously found in rendered chart. Continuing anyway."
fi

if ! grep -q "object_store: s3" mc-rendered.yaml; then
  echo "Loki validation failed: object_store: s3 not found in rendered chart."
  exit 1
fi

if ! grep -q "delete_request_store: s3" mc-rendered.yaml; then
  echo "Loki validation failed: delete_request_store: s3 not found in rendered chart."
  exit 1
fi

# ------------------------------------------------------------------------------
# 19. Install or upgrade Mission Control
# ------------------------------------------------------------------------------

log "Installing or upgrading Mission Control"

helm_install_or_upgrade "$MC_RELEASE" "$MC_NAMESPACE" "$MC_CHART" "mission-control-values.yaml" "30m"

helm status "$MC_RELEASE" -n "$MC_NAMESPACE" --debug
kubectl get pods -n "$MC_NAMESPACE"
kubectl get svc -n "$MC_NAMESPACE"

# ------------------------------------------------------------------------------
# 19a. Create LoadBalancer for Mission Control UI
# ------------------------------------------------------------------------------

log "Creating external LoadBalancer service for Mission Control UI"

cat > mc-ui-lb.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: mission-control-ui-lb
  namespace: mission-control
  labels:
    app: mission-control-ui-lb
spec:
  type: LoadBalancer
  selector:
    app: mission-control-ui
  ports:
    - name: https
      port: 8080
      targetPort: 8080
      protocol: TCP
EOF

kubectl apply -f mc-ui-lb.yaml

echo "Waiting for Mission Control UI LoadBalancer endpoint..."

MC_UI_HOST=""
for i in {1..30}; do
  MC_UI_HOST=$(
    kubectl -n "${MC_NAMESPACE}" get svc mission-control-ui-lb \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true
  )

  if [ -z "$MC_UI_HOST" ]; then
    MC_UI_HOST=$(
      kubectl -n "${MC_NAMESPACE}" get svc mission-control-ui-lb \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
    )
  fi

  if [ -n "$MC_UI_HOST" ]; then
    break
  fi

  echo "Waiting for Mission Control UI LoadBalancer... attempt $i/30"
  sleep 10
done

if [ -n "${MC_UI_HOST:-}" ]; then
  echo "Mission Control UI LoadBalancer endpoint: ${MC_UI_HOST}"
  cat > .env.mission-control <<EOF
export MC_UI_HOST="${MC_UI_HOST}"
export MC_UI_PORT="8080"
export MC_ADMIN_USER="${MC_ADMIN_USER}"
export MC_ADMIN_PASSWORD="${MC_ADMIN_PASSWORD}"
EOF
  echo "Mission Control connection details written to .env.mission-control"
else
  echo "WARNING: Mission Control UI LoadBalancer endpoint not assigned yet."
  echo "Check with: kubectl -n ${MC_NAMESPACE} get svc mission-control-ui-lb"
fi

# ------------------------------------------------------------------------------
# 20. Verify Dex config
# ------------------------------------------------------------------------------

log "Verifying Dex config"

kubectl get secret mission-control-ui-dex-config \
  -n "$MC_NAMESPACE" \
  -o jsonpath='{.data.config\.yaml}' | base64 -d || true

echo

# ------------------------------------------------------------------------------
# 21. Optional demo HCD database
# ------------------------------------------------------------------------------

if [ "$CREATE_DEMO_DB" = "true" ]; then
  log "Creating demo HCD database"

  if [ "$CLEAN_DEMO_DB" = "true" ]; then
    kubectl delete missioncontrolcluster "$DEMO_CLUSTER_NAME" \
      -n "$DEMO_NAMESPACE" \
      --ignore-not-found || true

    kubectl delete namespace "$DEMO_NAMESPACE" --ignore-not-found || true
    wait_for_namespace_deleted "$DEMO_NAMESPACE"
  fi

  cat > demo-mc-cluster.yaml <<DBEOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${DEMO_NAMESPACE}
---
apiVersion: v1
kind: Secret
metadata:
  name: demo-superuser
  namespace: ${DEMO_NAMESPACE}
type: Opaque
stringData:
  username: ${DEMO_SUPERUSER_NAME}
  password: ${DEMO_SUPERUSER_PASSWORD}
---
apiVersion: missioncontrol.datastax.com/v1beta2
kind: MissionControlCluster
metadata:
  name: ${DEMO_CLUSTER_NAME}
  namespace: ${DEMO_NAMESPACE}
spec:
  createIssuer: true

  dataApi:
    enabled: false

  encryption:
    internodeEncryption:
      enabled: true
      certs:
        createCerts: true

  k8ssandra:
    auth: true

    cassandra:
      serverType: hcd
      serverVersion: ${DEMO_HCD_VERSION}
      serverImage: ""

      superuserSecretRef:
        name: demo-superuser

      resources:
        requests:
          cpu: 1000m
          memory: 4Gi

      storageConfig:
        cassandraDataVolumeClaimSpec:
          accessModes:
            - ReadWriteOnce
          storageClassName: ${DEMO_STORAGE_CLASS}
          resources:
            requests:
              storage: ${DEMO_STORAGE_SIZE}

      config:
        jvmOptions:
          gc: G1GC
          heapSize: 1Gi
        cassandraYaml: {}
        dseYaml: {}

      datacenters:
        - datacenterName: dc-1
          k8sContext: ""
          size: 1
          stopped: false

          metadata:
            name: demo-dc-1
            pods: {}
            services:
              seedService: {}
              dcService: {}
              allPodsService: {}
              additionalSeedService: {}
              nodePortService: {}

          racks:
            - name: rk-01
              nodeAffinityLabels: {}

          dseWorkloads:
            searchEnabled: false
            graphEnabled: false

          config:
            cassandraYaml: {}
            dseYaml: {}

          networking: {}
          perNodeConfigMapRef: {}
DBEOF

  kubectl apply -f demo-mc-cluster.yaml

  kubectl get missioncontrolcluster -n "$DEMO_NAMESPACE"
  kubectl get k8ssandracluster -n "$DEMO_NAMESPACE" || true
  kubectl get cassdc -n "$DEMO_NAMESPACE" || true
  kubectl get pvc -n "$DEMO_NAMESPACE" || true
  kubectl get svc -n "$DEMO_NAMESPACE" || true
  kubectl get pods -n "$DEMO_NAMESPACE" || true
fi

# ------------------------------------------------------------------------------
# 22. Final validation
# ------------------------------------------------------------------------------

log "Final validation"

ibmcloud target
ibmcloud ks cluster get --cluster "$CLUSTER_NAME"
ibmcloud ks workers --cluster "$CLUSTER_NAME"

kubectl get nodes -o wide
kubectl get pods -n cert-manager
kubectl get pods -n "$MC_NAMESPACE"
helm status "$MC_RELEASE" -n "$MC_NAMESPACE" --debug

if [ "$CREATE_DEMO_DB" = "true" ]; then
  kubectl get missioncontrolcluster -n "$DEMO_NAMESPACE" || true
  kubectl get k8ssandracluster -n "$DEMO_NAMESPACE" || true
  kubectl get cassdc -n "$DEMO_NAMESPACE" || true
  kubectl get pvc -n "$DEMO_NAMESPACE" || true
  kubectl get pods -n "$DEMO_NAMESPACE" || true
fi

if [ "$CREATE_DEMO_DB" = "true" ]; then
  # ================================================================================
  # Expose HCD/Cassandra CQL externally for watsonx.data Infrastructure Manager
  # ================================================================================

echo "================================================================================"
echo "Creating external LoadBalancer service for HCD CQL"
echo "================================================================================"

cat > demo-cql-lb.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  name: demo-cql-lb
  namespace: ${DEMO_NAMESPACE}
  labels:
    app.kubernetes.io/name: demo-cql-lb
    app.kubernetes.io/part-of: hcd-demo
spec:
  type: LoadBalancer
  selector:
    cassandra.datastax.com/cluster: demo
    cassandra.datastax.com/datacenter: demo-dc-1
    cassandra.datastax.com/rack: rk-01
  ports:
    - name: cql
      port: 9042
      targetPort: 9042
      protocol: TCP
EOF

kubectl apply -f demo-cql-lb.yaml

echo "Ensuring IBM Cloud provider ConfigMap exists..."

# Check if ibm-cloud-provider-data ConfigMap exists
if ! kubectl get configmap ibm-cloud-provider-data -n kube-system &>/dev/null; then
  echo "Creating missing ibm-cloud-provider-data ConfigMap..."
  
  # Get cluster ID
  CLUSTER_ID=$(ibmcloud ks cluster get --cluster "${CLUSTER_NAME}" --output json | jq -r '.id' 2>/dev/null || echo "")
  
  if [ -n "$CLUSTER_ID" ]; then
    # Create the ConfigMap
    kubectl create configmap ibm-cloud-provider-data \
      --from-literal=cluster-id="$CLUSTER_ID" \
      -n kube-system
    
    echo "ConfigMap created. Restarting cloud provider..."
    
    # Restart the cloud provider daemonset if it exists
    if kubectl get daemonset ibm-cloud-provider -n kube-system &>/dev/null; then
      kubectl rollout restart daemonset/ibm-cloud-provider -n kube-system
      echo "Waiting for cloud provider to restart..."
      sleep 30
    fi
  else
    echo "WARNING: Could not retrieve cluster ID. LoadBalancer may not provision correctly."
  fi
else
  echo "IBM Cloud provider ConfigMap already exists."
fi

echo "Waiting for external LoadBalancer hostname/IP..."

for i in {1..60}; do
  DEMO_CQL_HOST=$(
    kubectl -n "${DEMO_NAMESPACE}" get svc demo-cql-lb \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true
  )

  if [ -z "$DEMO_CQL_HOST" ]; then
    DEMO_CQL_HOST=$(
      kubectl -n "${DEMO_NAMESPACE}" get svc demo-cql-lb \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
    )
  fi

  if [ -n "$DEMO_CQL_HOST" ]; then
    break
  fi

  echo "Waiting for LoadBalancer endpoint... attempt $i/60"
  sleep 10
done

if [ -z "${DEMO_CQL_HOST:-}" ]; then
  echo "ERROR: LoadBalancer endpoint was not assigned."
  echo "Check with:"
  echo "  kubectl -n ${DEMO_NAMESPACE} describe svc demo-cql-lb"
  exit 1
fi

echo "HCD CQL LoadBalancer endpoint: ${DEMO_CQL_HOST}"

cat > .env.demo-db <<EOF
export DEMO_NAMESPACE="${DEMO_NAMESPACE}"
export DEMO_CQL_HOST="${DEMO_CQL_HOST}"
export DEMO_CQL_PORT="9042"
export DEMO_DB_USERNAME="demo-superuser"
export DEMO_DB_PASSWORD="${DEMO_SUPERUSER_PASSWORD}"
EOF

echo "Demo DB connection details written to .env.demo-db"
fi

cat <<DONE

================================================================================
Setup complete.

Mission Control UI:

  URL: https://${MC_UI_HOST:-<pending>}:8080
  Username: ${MC_ADMIN_USER}
  Password: ${MC_ADMIN_PASSWORD}

  Note: Accept the self-signed certificate warning in your browser.
  
  Alternative (if LoadBalancer pending):
    kubectl -n ${MC_NAMESPACE} port-forward svc/mission-control-ui 8080:8080
    Then open: https://localhost:8080

Demo database superuser:

  Username: ${DEMO_SUPERUSER_NAME}
  Password: ${DEMO_SUPERUSER_PASSWORD}

HCD Database Connection:

  Host: ${DEMO_CQL_HOST:-<not-provisioned>}
  Port: 9042
  Username: ${DEMO_SUPERUSER_NAME}
  Password: ${DEMO_SUPERUSER_PASSWORD}
  
  Connection string:
    ${DEMO_CQL_HOST:-<not-provisioned>}:9042

  Test connection:
    ./scripts/test_hcd_connection.sh

Generated files:

  ${ENV_FILE}
  ${COS_ENV_FILE}
  ${COS_HMAC_ENV_FILE}
  mission-control-values.yaml
  mc-rendered.yaml
  demo-mc-cluster.yaml

Security reminder:

  Do not commit these files to Git:
    - ${COS_ENV_FILE}
    - ${COS_HMAC_ENV_FILE}
    - mission-control-values.yaml

================================================================================

DONE
