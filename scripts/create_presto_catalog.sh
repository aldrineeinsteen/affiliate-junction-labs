#!/bin/bash
# Create Presto catalog for Iceberg in watsonx.data
# This script configures the Presto catalog for the affiliate junction demo

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

# Check required environment variables
if [ -z "$PRESTO_HOST" ]; then
    log_error "PRESTO_HOST environment variable is not set"
    exit 1
fi

if [ -z "$PRESTO_USERNAME" ]; then
    log_error "PRESTO_USERNAME environment variable is not set"
    exit 1
fi

if [ -z "$PRESTO_PASSWORD" ]; then
    log_error "PRESTO_PASSWORD environment variable is not set"
    exit 1
fi

PRESTO_PORT=${PRESTO_PORT:-8443}
CATALOG_NAME=${CATALOG_NAME:-iceberg_data}
SCHEMA_NAME=${SCHEMA_NAME:-affiliate_junction}

log_info "Creating Presto catalog configuration..."
log_info "  Host: $PRESTO_HOST"
log_info "  Port: $PRESTO_PORT"
log_info "  Catalog: $CATALOG_NAME"
log_info "  Schema: $SCHEMA_NAME"

# Create catalog properties
CATALOG_PROPERTIES=$(cat <<EOF
connector.name=iceberg
iceberg.catalog.type=hive_metastore
hive.metastore.uri=thrift://hive-metastore:9083
iceberg.file-format=PARQUET
iceberg.compression-codec=SNAPPY
EOF
)

log_info "Catalog properties:"
echo "$CATALOG_PROPERTIES"

# Note: In watsonx.data, catalogs are typically created via the web UI or API
# This script provides the configuration that should be used

log_info ""
log_info "To create the catalog in watsonx.data:"
log_info "1. Access the watsonx.data web console"
log_info "2. Navigate to Infrastructure > Catalogs"
log_info "3. Click 'Add catalog'"
log_info "4. Select 'Apache Iceberg' as the catalog type"
log_info "5. Use the following configuration:"
log_info "   - Catalog name: $CATALOG_NAME"
log_info "   - Metastore: Use existing Hive metastore"
log_info "   - File format: Parquet"
log_info "   - Compression: Snappy"
log_info ""
log_info "After creating the catalog, create the schema:"
log_info "   CREATE SCHEMA IF NOT EXISTS ${CATALOG_NAME}.${SCHEMA_NAME}"
log_info "   WITH (location = 's3a://iceberg-bucket/${SCHEMA_NAME}/')"

log_info ""
log_info "Catalog configuration complete!"

# Made with Bob
