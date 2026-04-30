# Ask Mode Documentation Rules (Non-Obvious Only)

## Project Structure Context
- `affiliate_common/` contains shared database connection classes used by backend services
- `web/` contains separate wrapper classes for the FastAPI web UI (NOT the same as affiliate_common)
- Services are Python scripts in project root (e.g., `generate_traffic.py`, `hcd_to_presto.py`)
- Systemd unit files (*.service) define how services run - they use `.venv/bin/python` from project directory

## Hidden Documentation Locations
- `DEVELOPER.md` contains comprehensive query execution patterns and metrics examples
- `DEMO_SCRIPT.md` has presentation flow and talking points
- `CREDENTIALS.md` likely contains access credentials (not in repo listing)
- Service-specific documentation is in docstrings, not separate files

## Non-Standard Naming
- "HCD" means "Hyperconverged Database" (Cassandra) - not obvious from name
- "Presto" refers to both the query engine and Iceberg storage layer
- "Services" table in HCD stores service metadata, NOT service definitions
- "Query panel" in web UI is the sliding panel showing real-time query execution

## Architecture Gotchas
- Dual-write pattern: Data written to HCD first, then ETL'd to Presto (not simultaneous)
- 6-minute TTL on HCD tables means data automatically expires (not permanent storage)
- Presto tables are hourly partitioned by `bucket_date` column (critical for query performance)
- Web UI queries go through wrappers, service queries go through shared connections

## Environment Configuration
- `.env` file must be created from `env-sample` - not auto-generated
- HCD host `172.17.0.1` is Docker bridge network IP (counterintuitive for single-host setup)
- Presto host `ibm-lh-presto-svc` is a hostname in /etc/hosts, not a service discovery mechanism
- SSL cert path `/certs/presto.crt` is hardcoded in connection class (not configurable)

## Service Dependencies
- Services must start in specific order: traffic generator and ETL first, then analytics services
- 60-second wait between service groups is for Presto DDL completion (not arbitrary)
- Schema execution happens on first service run, not during setup
- Services auto-restart on failure but don't recreate schemas