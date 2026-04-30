#!/bin/bash
# Test HCD (Cassandra) connection
# This script validates connectivity to the HCD database

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
HCD_HOST=${HCD_HOST:-"hcd-service"}
HCD_PORT=${HCD_PORT:-9042}
HCD_USERNAME=${HCD_USERNAME:-"cassandra"}
HCD_KEYSPACE=${HCD_KEYSPACE:-"affiliate_junction"}

log_info "Testing HCD connection..."
log_info "  Host: $HCD_HOST"
log_info "  Port: $HCD_PORT"
log_info "  Username: $HCD_USERNAME"
log_info "  Keyspace: $HCD_KEYSPACE"

# Test 1: Check if host is reachable
log_info ""
log_info "Test 1: Checking host reachability..."
if command -v nc &> /dev/null; then
    if nc -z -w5 "$HCD_HOST" "$HCD_PORT" 2>/dev/null; then
        log_success "Host $HCD_HOST:$HCD_PORT is reachable"
    else
        log_error "Cannot reach $HCD_HOST:$HCD_PORT"
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
from cassandra.cluster import Cluster
from cassandra.auth import PlainTextAuthProvider

try:
    # Get connection parameters
    host = os.getenv('HCD_HOST', 'hcd-service')
    port = int(os.getenv('HCD_PORT', '9042'))
    username = os.getenv('HCD_USERNAME', 'cassandra')
    password = os.getenv('HCD_PASSWORD', '')
    keyspace = os.getenv('HCD_KEYSPACE', 'affiliate_junction')
    
    print(f"Connecting to {host}:{port}...")
    
    # Create auth provider
    auth_provider = PlainTextAuthProvider(username=username, password=password)
    
    # Connect to cluster
    cluster = Cluster(
        contact_points=[host],
        port=port,
        auth_provider=auth_provider,
        connect_timeout=10
    )
    
    session = cluster.connect()
    print("✓ Successfully connected to HCD")
    
    # Test keyspace access
    try:
        session.set_keyspace(keyspace)
        print(f"✓ Successfully accessed keyspace '{keyspace}'")
        
        # List tables
        query = f"""
        SELECT table_name 
        FROM system_schema.tables 
        WHERE keyspace_name = '{keyspace}'
        """
        result = session.execute(query)
        tables = [row.table_name for row in result]
        
        if tables:
            print(f"✓ Found {len(tables)} tables in keyspace:")
            for table in sorted(tables):
                print(f"  - {table}")
        else:
            print(f"⚠ No tables found in keyspace '{keyspace}'")
            
    except Exception as e:
        print(f"✗ Error accessing keyspace '{keyspace}': {e}")
        sys.exit(1)
    
    # Close connection
    cluster.shutdown()
    print("\n✓ All HCD connection tests passed!")
    sys.exit(0)
    
except Exception as e:
    print(f"✗ Connection failed: {e}")
    sys.exit(1)
EOF

if [ $? -eq 0 ]; then
    log_success "HCD connection test completed successfully!"
    exit 0
else
    log_error "HCD connection test failed!"
    exit 1
fi

# Made with Bob
