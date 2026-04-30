# Plan Mode Architecture Rules (Non-Obvious Only)

## Dual-Write Architecture Constraints
- Real-time data MUST go to HCD first (6-minute TTL), then ETL to Presto
- Cannot write directly to Presto from traffic generator - Spark ETL is required
- HCD → Presto transfer happens every minute via `hcd_to_presto.py` using Spark
- Presto → HCD aggregation writes back for fast web queries (counterintuitive reverse flow)

## Connection Class Separation
- Services and web UI use different connection classes by design (not a mistake)
- `affiliate_common/database_connections.py` for services (with ServicesManager integration)
- `web/cassandra_wrapper.py` and `web/presto_wrapper.py` for web UI (request-scoped metrics)
- Cannot unify these - they have different lifecycle and metrics requirements

## Query Metrics System Architecture
- Metrics captured at connection level, not application level
- Automatic deduplication prevents metric explosion from repeated queries
- Services persist metrics to HCD `services` table for web UI consumption
- Web UI reads service metrics from HCD, doesn't generate its own service metrics
- Metrics limited to 50 queries and 90 timeseries datapoints to prevent table bloat

## Schema Management Pattern
- Schemas NOT executed by setup.sh (counterintuitive)
- Each service executes its own schema on first run via `SchemaExecutor`
- `SchemaExecutor` checks table existence before creating (idempotent)
- HCD and Presto schemas are separate files with different characteristics
- Cannot change schema without service restart (no hot reload)

## Service Orchestration Dependencies
- `generate_traffic` must start before `hcd_to_presto` (data source dependency)
- `hcd_to_presto` must complete Presto DDL before other Presto services start
- 60-second wait is for Iceberg table creation, not arbitrary delay
- `presto_to_hcd`, `presto_insights`, `presto_cleanup` depend on Presto tables existing
- Service restart order matters - cannot restart services independently

## Performance Bottlenecks
- HCD 6-minute TTL means queries must be partition-aware (no full scans)
- Presto queries MUST filter on `bucket_date` partition column for performance
- Batch operations in HCD limited to ~10,000 records (driver limitation)
- Query deduplication reduces metrics overhead but hides individual query patterns
- Web UI query panel can become slow with >100 queries (client-side rendering)

## Hidden Coupling
- Web UI depends on services table in HCD for monitoring data
- Services table schema must match `ServicesManager` expectations
- Query metrics JSON structure is tightly coupled between connections and web UI
- Environment variables shared between services and web UI (single .env file)
- Presto SSL cert path hardcoded in connection class (not in environment)