#!/bin/bash
# Test Presto/watsonx.data connection
# This script validates connectivity to the Presto query engine

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Check if running in Kubernetes
if [ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
    log_info "Running in Kubernetes environment"
    IS_K8S=true
else
    log_info "Running in local environment"
    IS_K8S=false
fi

# Load environment variables
if [ "$IS_K8S" = false ] && [ -f .env ]; then
    log_info "Loading environment variables from .env"
    export $(cat .env | grep -v '^#' | xargs)
fi

# Set defaults
PRESTO_HOST=${PRESTO_HOST:-"presto-service"}
PRESTO_PORT=${PRESTO_PORT:-8443}
PRESTO_USERNAME=${PRESTO_USERNAME:-"ibmlhadmin"}
PRESTO_CATALOG=${PRESTO_CATALOG:-"iceberg_data"}
PRESTO_SCHEMA=${PRESTO_SCHEMA:-"affiliate_junction"}

log_info "Testing Presto connection..."
log_info "  Host: $PRESTO_HOST"
log_info "  Port: $PRESTO_PORT"
log_info "  Username: $PRESTO_USERNAME"
log_info "  Catalog: $PRESTO_CATALOG"
log_info "  Schema: $PRESTO_SCHEMA"

# Test 1: Check if host is reachable
log_info ""
log_info "Test 1: Checking host reachability..."
if command -v nc &> /dev/null; then
    if nc -z -w5 "$PRESTO_HOST" "$PRESTO_PORT" 2>/dev/null; then
        log_success "Host $PRESTO_HOST:$PRESTO_PORT is reachable"
    else
        log_error "Cannot reach $PRESTO_HOST:$PRESTO_PORT"
        exit 1
    fi
else
    log_warn "netcat (nc) not available, skipping reachability test"
fi

# Test 2: Test connection using Python
log_info ""
log_info "Test 2: Testing database connection..."

python3 << 'EOF'
import os
import sys
import prestodb

try:
    # Get connection parameters
    host = os.getenv('PRESTO_HOST', 'presto-service')
    port = int(os.getenv('PRESTO_PORT', '8443'))
    username = os.getenv('PRESTO_USERNAME', 'ibmlhadmin')
    password = os.getenv('PRESTO_PASSWORD', '')
    catalog = os.getenv('PRESTO_CATALOG', 'iceberg_data')
    schema = os.getenv('PRESTO_SCHEMA', 'affiliate_junction')
    
    print(f"Connecting to {host}:{port}...")
    
    # Create connection
    conn = prestodb.dbapi.connect(
        host=host,
        port=port,
        user=username,
        catalog=catalog,
        schema=schema,
        http_scheme='https',
        auth=prestodb.auth.BasicAuthentication(username, password)
    )
    
    cursor = conn.cursor()
    print("✓ Successfully connected to Presto")
    
    # Test 1: Show catalogs
    try:
        cursor.execute("SHOW CATALOGS")
        catalogs = [row[0] for row in cursor.fetchall()]
        print(f"✓ Found {len(catalogs)} catalogs:")
        for cat in sorted(catalogs):
            marker = "→" if cat == catalog else " "
            print(f"  {marker} {cat}")
    except Exception as e:
        print(f"⚠ Could not list catalogs: {e}")
    
    # Test 2: Show schemas in catalog
    try:
        cursor.execute(f"SHOW SCHEMAS FROM {catalog}")
        schemas = [row[0] for row in cursor.fetchall()]
        print(f"\n✓ Found {len(schemas)} schemas in '{catalog}':")
        for sch in sorted(schemas):
            marker = "→" if sch == schema else " "
            print(f"  {marker} {sch}")
    except Exception as e:
        print(f"⚠ Could not list schemas: {e}")
    
    # Test 3: Show tables in schema
    try:
        cursor.execute(f"SHOW TABLES FROM {catalog}.{schema}")
        tables = [row[0] for row in cursor.fetchall()]
        
        if tables:
            print(f"\n✓ Found {len(tables)} tables in '{catalog}.{schema}':")
            for table in sorted(tables):
                print(f"  - {table}")
        else:
            print(f"\n⚠ No tables found in '{catalog}.{schema}'")
            print("  This is normal for a new deployment")
    except Exception as e:
        print(f"⚠ Could not list tables: {e}")
        print("  Schema may not exist yet - this is normal for new deployments")
    
    # Test 4: Simple query
    try:
        cursor.execute("SELECT 1 as test")
        result = cursor.fetchone()
        if result and result[0] == 1:
            print("\n✓ Query execution test passed")
        else:
            print("\n✗ Query execution test failed")
            sys.exit(1)
    except Exception as e:
        print(f"\n✗ Query execution failed: {e}")
        sys.exit(1)
    
    # Close connection
    cursor.close()
    conn.close()
    
    print("\n✓ All Presto connection tests passed!")
    sys.exit(0)
    
except Exception as e:
    print(f"✗ Connection failed: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
EOF

if [ $? -eq 0 ]; then
    log_success "Presto connection test completed successfully!"
    exit 0
else
    log_error "Presto connection test failed!"
    exit 1
fi

# Made with Bob
