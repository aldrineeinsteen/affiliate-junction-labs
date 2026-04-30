# Advance Mode Rules (Non-Obvious Only)

## Database Connection Patterns
- **Services MUST import from `affiliate_common`**: `from affiliate_common import CassandraConnection, PrestoConnection`
- **Web UI MUST import from `web/`**: `from web.cassandra_wrapper import cassandra_wrapper` and `from web.presto_wrapper import presto_wrapper`
- **Never mix these imports** - services and web UI use different connection classes despite similar interfaces

## Batch Query Metrics Capture
- Cassandra batch statements require `representative_query` parameter for proper metrics:
  ```python
  cassandra_connection.execute_query(
      query=batch,  # BatchStatement object
      representative_query="INSERT INTO table (col1, col2) VALUES (?, ?)",
      query_description="Batch insert description"
  )
  ```
- Without `representative_query`, metrics only show batch metadata, not the actual query pattern

## Query Deduplication System
- All queries automatically deduplicated via `normalize_query_for_deduplication()`
- Similar queries (same structure, different values) increment `repeat_count` instead of creating new metrics
- Don't manually track query repetitions - the connection classes handle this

## Services Manager Pattern
- Every service MUST call `services_manager.update_query_metrics(cassandra_metrics, presto_metrics)` to persist metrics
- Metrics automatically limited to 50 most recent queries
- Timeseries stats automatically limited to 90 datapoints
- Call `connection.clear_query_metrics()` after persisting to prevent memory buildup

## Environment Variable Usage
- HCD host is `172.17.0.1` (Docker bridge network) - NOT `localhost` or `127.0.0.1`
- Presto host is `ibm-lh-presto-svc` (hostname in /etc/hosts) - NOT an IP address
- Presto SSL cert path is hardcoded: `/certs/presto.crt` in `database_connections.py` line 499

## Schema Execution Timing
- Schemas executed by services on first run, NOT by setup.sh
- `SchemaExecutor` checks if tables exist before creating
- HCD tables have 6-minute TTL (defined in `hcd_schema.cql`)
- Presto tables are hourly partitioned (defined in `presto_schema.sql`)

## Service Startup Order
- Start `generate_traffic` and `hcd_to_presto` first
- Wait 60 seconds for Presto DDL to complete
- Then start `presto_to_hcd`, `presto_insights`, `presto_cleanup`
- This order is enforced in `setup.sh` lines 29-31

## Query Description Best Practice
- Always provide `query_description` parameter - it appears in web UI query panel
- Descriptions should explain business purpose, not technical details
- Example: "Get top publishers by revenue" not "SELECT with GROUP BY"