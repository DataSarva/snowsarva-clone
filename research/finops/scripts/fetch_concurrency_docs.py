#!/usr/bin/env python3
"""Fetch Snowflake concurrency and queuing docs directly"""
import requests
from datetime import datetime
import json

DOCS_URLS = [
    "https://docs.snowflake.com/en/user-guide/warehouses-overview",
    "https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_load_history",
    "https://docs.snowflake.com/en/user-guide/warehouses-multicluster",
    "https://docs.snowflake.com/en/user-guide/scaling-policies",
    "https://docs.snowflake.com/en/user-guide/warehouses-considerations"
]

def fetch_markdown(url):
    """Fetch content via docs API"""
    try:
        resp = requests.get(url, timeout=60, headers={"User-Agent": "Mozilla/5.0"})
        resp.raise_for_status()
        return resp.text
    except Exception as e:
        return {"error": str(e)}

results = []
for url in DOCS_URLS:
    print(f"Fetching: {url}")
    content = fetch_markdown(url)
    results.append({
        "url": url,
        "fetched_at": datetime.utcnow().isoformat(),
        "content_length": len(content) if isinstance(content, str) else 0,
        "content": content[:5000] if isinstance(content, str) else content
    })
    print(f"  -> Content length: {len(content) if isinstance(content, str) else 'ERROR'}")

output_path = "/home/ubuntu/.openclaw/workspace/research/finops/2026-02-24/research_raw_concurrency_docs.json"
with open(output_path, "w") as f:
    json.dump(results, f, indent=2, default=str)
print(f"\nSaved to: {output_path}")
