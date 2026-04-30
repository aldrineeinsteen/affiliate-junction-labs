# AGENTS.md

This file provides guidance to agents when working with code in this repository.

## Project Overview
Python-based affiliate marketing demo showcasing watsonx.data federated queries across HCD (Cassandra) and Presto/Iceberg. FastAPI web UI with systemd-managed backend services.

## Critical Non-Obvious Patterns

### Database Connection Architecture
- **MUST use shared connection classes**: `CassandraConnection` and `PrestoConnection` from `affiliate_common/database_connections.py` for services
- **Web UI uses separate wrappers**: `cassandra_wrapper` and `presto_wrapper` from `web/` directory (NOT the shared classes)
- **Query metrics are automatically captured**: All queries through these classes record timing, parameters, and results
- **Metrics deduplication**: Similar queries are automatically deduplicated using `normalize_query_for_deduplication()` - repeat_count tracks occurrences

### Batch Operations Pattern (HCD/Cassandra)
- Batch statements MUST pass `representative_query` parameter to `execute_query()` for proper metrics capture
- Example: `cassandra_connection.execute_query(query=batch, representative_query="INSERT INTO...", query_description="...")`
- Without `representative_query`, batch metrics will only show batch metadata, not the actual query pattern

### Services Manager Integration
- All services MUST use `ServicesManager` from `affiliate_common/services_manager.py`
- Services store stats and query metrics in HCD `services` table for web UI monitoring
- Call `services_manager.update_query_metrics(cassandra_metrics, presto_metrics)` to persist metrics
- Timeseries data automatically limited to 90 datapoints, query metrics to 50 most recent

### Query Execution Methods
**Services (affiliate_common):**
- `execute_query(query, parameters, max_retries, query_description)` - with automatic retry and metrics

**Web UI (web/):**
- `execute_query_simple()` - basic execution with metrics
- `execute_query()` - includes retry logic
- `execute_query_with_retry()` - explicit retry control

### Environment Configuration
- All services and web UI load from `.env` file (copy from `env-sample`)
- HCD connection: `HCD_HOST=172.17.0.1` (Docker bridge network, NOT localhost)
- Presto connection: `PRESTO_HOST=ibm-lh-presto-svc` (hostname in /etc/hosts, NOT IP)
- Presto uses SSL with cert at `/certs/presto.crt` (hardcoded in connection)

### Service Management
- Services are systemd units (*.service files)
- Start order matters: `generate_traffic` and `hcd_to_presto` first, wait 60s for Presto DDL, then others
- Services run Python scripts with `.venv/bin/python` from project directory
- Logs via `journalctl -u <service_name> -f`

### Schema Management
- `SchemaExecutor` from `affiliate_common/schema_executor.py` handles DDL
- HCD schema: `hcd_schema.cql` (6-minute TTL on tables)
- Presto schema: `presto_schema.sql` (hourly partitioned Iceberg tables)
- Schemas executed on first service start, not in setup.sh

### Data Flow Pattern
- **Dual-write architecture**: Real-time data in HCD (6-min TTL), historical in Presto/Iceberg
- `generate_traffic.py` writes to HCD only
- `hcd_to_presto.py` ETL transfers HCD → Presto every minute using Spark
- `presto_to_hcd.py` writes aggregated data back to HCD for fast web queries
- `presto_insights.py` and `presto_cleanup.py` maintain Presto data

### Web UI Query Transparency
- Query panel shows all HCD and Presto queries in real-time
- Queries formatted with `sqlparse` for readability
- Separate counters for HCD vs Presto operations
- Query history persists across page loads (stored in wrapper classes)

## Commands

### Setup
```bash
./setup.sh  # Installs deps, creates .venv, configures systemd services in a single VM
./setup 2.sh  # Is the updated script for setting up the K8s based deployment on IBM Cloud
```

### Service Management
```bash
# View logs
journalctl -u generate_traffic -f
journalctl -u hcd_to_presto -f
journalctl -u uvicorn -f

# Restart services
sudo systemctl restart generate_traffic
sudo systemctl restart hcd_to_presto
sudo systemctl restart uvicorn

# Check status
sudo systemctl status generate_traffic
```

### Development
```bash
# Activate venv (auto-added to .bashrc by setup.sh)
source .venv/bin/activate

# Run web UI manually (for development)
uvicorn web.main:app --reload --host 0.0.0.0 --port 10000

# Access HCD CQL console
./hcd-1.2.3/bin/hcd cqlsh 172.17.0.1 -u cassandra -p cassandra
```

### Testing
No automated tests. Manual testing via web UI at http://localhost:10000 (login: watsonx/watsonx.data)

## Code Style
- Python 3.11 with type hints where beneficial
- Logging via standard library (INFO level for services, DEBUG for detailed query info)
- Environment variables via python-dotenv
- Error handling: Services retry database operations (max_retries=3), log errors, continue running
- Query descriptions: Always provide `query_description` parameter for metrics clarity