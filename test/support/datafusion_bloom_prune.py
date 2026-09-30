"""Runs a query with DataFusion (arrow-rs) with bloom filter pruning enabled and reports, as JSON,
the result count and the row group bloom filter pruning metric from EXPLAIN ANALYZE.

Usage: datafusion_bloom_prune.py FILE "select count(*) as c from t where ..."
"""
import json
import re
import sys

from datafusion import SessionConfig, SessionContext

path, sql = sys.argv[1], sys.argv[2]
config = (
    SessionConfig()
    .set("datafusion.execution.parquet.bloom_filter_on_read", "true")
    .set("datafusion.execution.parquet.pushdown_filters", "false")
)
ctx = SessionContext(config)
ctx.register_parquet("t", path)
count = ctx.sql(sql).collect()[0].column(0)[0].as_py()
plan = ctx.sql("EXPLAIN ANALYZE " + sql).collect()
text = "\n".join(str(v) for batch in plan for v in batch.column(1).to_pylist())

m = re.search(r"row_groups_pruned_bloom_filter=(\d+) total → (\d+) matched", text)
if not m:
    sys.exit("no row_groups_pruned_bloom_filter metric in plan:\n" + text)
print(json.dumps({
    "count": count,
    "bloom_filter_row_groups_total": int(m.group(1)),
    "bloom_filter_row_groups_matched": int(m.group(2)),
}))
