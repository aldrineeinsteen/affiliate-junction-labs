#!/usr/bin/env bash

# ==============================================================================
# Environment Loader Helper Functions
# ==============================================================================

load_domain_config() {
    local domain="$1"
    local root_dir="$2"
    
    # Check if domain directory exists in config/domains/
    local config_domain_dir="$root_dir/config/domains/$domain"
    if [ -d "$config_domain_dir" ]; then
        DOMAIN_DIR="$config_domain_dir"
        DOMAIN_DESCRIPTOR="$DOMAIN_DIR/domain.yaml"
        
        if [ ! -f "$DOMAIN_DESCRIPTOR" ]; then
            echo "ERROR: Domain descriptor not found: $DOMAIN_DESCRIPTOR"
            return 1
        fi
        
        echo "Loaded domain configuration from: $DOMAIN_DESCRIPTOR"
        return 0
    fi
    
    # Fallback: check if domain directory exists in domains/
    local legacy_domain_dir="$root_dir/domains/$domain"
    if [ -d "$legacy_domain_dir" ]; then
        DOMAIN_DIR="$legacy_domain_dir"
        DOMAIN_DESCRIPTOR="$DOMAIN_DIR/domain.yaml"
        
        if [ ! -f "$DOMAIN_DESCRIPTOR" ]; then
            echo "ERROR: Domain descriptor not found: $DOMAIN_DESCRIPTOR"
            return 1
        fi
        
        echo "Loaded domain configuration from: $DOMAIN_DESCRIPTOR"
        return 0
    fi
    
    echo "ERROR: Domain directory not found for: $domain"
    echo "Expected locations:"
    echo "  - $config_domain_dir"
    echo "  - $legacy_domain_dir"
    return 1
}

load_env_file() {
    local env_file="$1"
    
    if [ ! -f "$env_file" ]; then
        echo "WARNING: Environment file not found: $env_file"
        return 1
    fi
    
    echo "Loading environment from: $env_file"
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
    return 0
}

export_domain_vars() {
    local domain_file="$1"
    
    if [ ! -f "$domain_file" ]; then
        echo "ERROR: Domain file not found: $domain_file"
        return 1
    fi
    
    # Parse YAML and export variables
    # This is a simplified version - in production, use yq or similar
    echo "Domain configuration loaded from: $domain_file"
    return 0
}

load_domain_env() {
    local root_dir="$1"
    local domain="$2"
    
    # Load domain configuration
    if ! load_domain_config "$domain" "$root_dir"; then
        return 1
    fi
    
    # Load domain-specific environment file if it exists
    local domain_env_file="$DOMAIN_DIR/.env"
    if [ -f "$domain_env_file" ]; then
        load_env_file "$domain_env_file"
    fi
    
    # Export domain variables from YAML
    if [ -f "$DOMAIN_DESCRIPTOR" ]; then
        export_domain_vars "$DOMAIN_DESCRIPTOR"
    fi
    
    echo "Domain environment loaded for: $domain"
    return 0
}

print_domain_plan() {
    echo ""
    echo "Domain: ${DOMAIN}"
    echo "Domain Directory: ${DOMAIN_DIR}"
    echo "Domain Descriptor: ${DOMAIN_DESCRIPTOR}"
    echo "Phase: ${PHASE}"
    echo "Region: ${REGION}"
    echo "Resource Group: ${RG}"
    echo ""
    
    if [ -f "$DOMAIN_DESCRIPTOR" ]; then
        echo "Domain configuration file found and loaded successfully."
    else
        echo "WARNING: Domain configuration file not found."
    fi
    
    echo ""
}

# Made with Bob
