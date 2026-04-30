"""
Configuration loader for Kubernetes and local environments.

Supports loading configuration from:
1. Kubernetes ConfigMap (mounted as /config/config.yaml)
2. Local YAML file (config/config.yaml)
3. Environment variables (for secrets)
4. .env file (for local development)
"""

import os
import yaml
import logging
from pathlib import Path
from typing import Dict, Any, Optional

logger = logging.getLogger(__name__)


class ConfigLoader:
    """Load configuration from Kubernetes ConfigMap or local files."""
    
    def __init__(self, config_path: Optional[str] = None):
        """
        Initialize configuration loader.
        
        Args:
            config_path: Optional path to config file. If not provided, will try:
                1. CONFIG_PATH environment variable
                2. /config/config.yaml (Kubernetes ConfigMap mount)
                3. config/config.yaml (local development)
        """
        self.config_path = self._resolve_config_path(config_path)
        self.config: Dict[str, Any] = {}
        self._load_config()
        
    def _resolve_config_path(self, config_path: Optional[str]) -> Path:
        """Resolve the configuration file path."""
        if config_path:
            return Path(config_path)
        
        # Try environment variable
        env_path = os.getenv('CONFIG_PATH')
        if env_path:
            return Path(env_path)
        
        # Try Kubernetes ConfigMap mount
        k8s_path = Path('/config/config.yaml')
        if k8s_path.exists():
            logger.info(f"Using Kubernetes ConfigMap: {k8s_path}")
            return k8s_path
        
        # Fall back to local config
        local_path = Path('config/config.yaml')
        if local_path.exists():
            logger.info(f"Using local config: {local_path}")
            return local_path
        
        # Try example file
        example_path = Path('config/config.yaml.example')
        if example_path.exists():
            logger.warning(f"Using example config: {example_path}")
            return example_path
        
        raise FileNotFoundError(
            "No configuration file found. Tried:\n"
            "  - CONFIG_PATH environment variable\n"
            "  - /config/config.yaml (Kubernetes)\n"
            "  - config/config.yaml (local)\n"
            "  - config/config.yaml.example"
        )
    
    def _load_config(self):
        """Load configuration from YAML file."""
        try:
            with open(self.config_path, 'r') as f:
                self.config = yaml.safe_load(f)
            logger.info(f"Configuration loaded from {self.config_path}")
        except Exception as e:
            logger.error(f"Failed to load configuration from {self.config_path}: {e}")
            raise
    
    def get(self, key: str, default: Any = None) -> Any:
        """
        Get configuration value by dot-notation key.
        
        Args:
            key: Dot-notation key (e.g., 'databases.hcd.port')
            default: Default value if key not found
            
        Returns:
            Configuration value or default
        """
        keys = key.split('.')
        value = self.config
        
        for k in keys:
            if isinstance(value, dict):
                value = value.get(k)
                if value is None:
                    return default
            else:
                return default
        
        return value
    
    def get_database_config(self, db_type: str) -> Dict[str, Any]:
        """
        Get database configuration.
        
        Args:
            db_type: Database type ('hcd' or 'presto')
            
        Returns:
            Database configuration dictionary
        """
        db_config = self.get(f'databases.{db_type}', {})
        
        # Add credentials from environment variables
        if db_type == 'hcd':
            db_config['username'] = os.getenv('HCD_USERNAME', 'cassandra')
            db_config['password'] = os.getenv('HCD_PASSWORD', '')
        elif db_type == 'presto':
            db_config['username'] = os.getenv('PRESTO_USERNAME', 'ibmlhadmin')
            db_config['password'] = os.getenv('PRESTO_PASSWORD', '')
        
        return db_config
    
    def get_application_config(self) -> Dict[str, Any]:
        """Get application configuration."""
        return self.get('application', {})
    
    def get_web_config(self) -> Dict[str, Any]:
        """Get web UI configuration."""
        web_config = self.get('web', {})
        # Add auth password from environment
        web_config['auth_passwd'] = os.getenv('WEB_AUTH_PASSWD', 'watsonx.data')
        return web_config
    
    def get_schedules(self) -> Dict[str, str]:
        """Get CronJob schedules."""
        return self.get('schedules', {})
    
    def is_kubernetes(self) -> bool:
        """Check if running in Kubernetes environment."""
        return (
            os.path.exists('/var/run/secrets/kubernetes.io/serviceaccount') or
            os.getenv('KUBERNETES_SERVICE_HOST') is not None
        )
    
    def get_service_endpoint(self, service_type: str) -> str:
        """
        Get service endpoint (hostname or IP).
        
        In Kubernetes, returns service name for DNS resolution.
        In local environment, returns configured host.
        
        Args:
            service_type: Service type ('hcd' or 'presto')
            
        Returns:
            Service endpoint
        """
        if self.is_kubernetes():
            # Use Kubernetes service name for DNS resolution
            service_name = self.get(f'databases.{service_type}.service_name')
            namespace = self.get('domain.namespace', 'affiliate-junction')
            # Return FQDN for cross-namespace access
            return f"{service_name}.{namespace}.svc.cluster.local"
        else:
            # Use configured host for local development
            if service_type == 'hcd':
                return os.getenv('HCD_HOST', '172.17.0.1')
            elif service_type == 'presto':
                return os.getenv('PRESTO_HOST', 'ibm-lh-presto-svc')
        
        return 'localhost'


# Global configuration instance
_config_instance: Optional[ConfigLoader] = None


def get_config(config_path: Optional[str] = None) -> ConfigLoader:
    """
    Get global configuration instance (singleton pattern).
    
    Args:
        config_path: Optional path to config file
        
    Returns:
        ConfigLoader instance
    """
    global _config_instance
    
    if _config_instance is None:
        _config_instance = ConfigLoader(config_path)
    
    return _config_instance


def reload_config(config_path: Optional[str] = None):
    """
    Reload configuration (useful for testing or config updates).
    
    Args:
        config_path: Optional path to config file
    """
    global _config_instance
    _config_instance = ConfigLoader(config_path)

# Made with Bob
