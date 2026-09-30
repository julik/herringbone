"""Runs a query with DataFusion (arrow-rs) with page index pruning enabled and reports, as JSON,
the result count and the page index pruning metrics from EXPLAIN ANALYZE.

Usage: datafusion_prune.py FILE "select count(*) as c from t where ..."
"""
import json
import re
import sys

from datafusion import SessionConfig, SessionContext

path, sql = sys.argv[1], sys.argv[2]
config = (
    SessionConfig()
    .set("datafusion.execution.parquet.enable_page_index", "true")
    .set("datafusion.execution.parquet.pushdown_filters", "false")
)
ctx = SessionContext(config)
ctx.register_parquet("t", path)
count = ctx.sql(sql).collect()[0].column(0)[0].as_py()
plan = ctx.sql("EXPLAIN ANALYZE " + sql).collect()
text = "\n".join(str(v) for batch in plan for v in batch.column(1).to_pylist())


def number(s):
    s = s.strip()
    mult = {"K": 1_000, "M": 1_000_000}.get(s[-1], 1)
    return int(round(float(s.rstrip("KM ").strip()) * mult))


m = re.search(r"page_index_rows_pruned=([\d.]+\s*[KM]?) total → ([\d.]+\s*[KM]?) matched", text)
if not m:
    sys.exit("no page_index_rows_pruned metric in plan:\n" + text)
print(json.dumps({
    "count": count,
    "page_index_rows_total": number(m.group(1)),
    "page_index_rows_matched": number(m.group(2)),
}))
