#!/usr/bin/env python3
import os
import requests
import json

API_KEY = os.environ.get("PARALLEL_API_KEY")
HEADERS = {
    "x-api-key": API_KEY,
    "Content-Type": "application/json",
    "parallel-beta": "search-extract-2025-10-10"
}

queries = [
    "Snowflake warehouse auto-suspend auto-resume configuration optimization",
    "Snowflake WAREHOUSE_METERING_HISTORY suspend resume credits billing",
    "Snowflake warehouse auto_suspend_seconds minimum idle time behavior",
    "Snowflake warehouse resume time cold start latency",
    "Snowflake warehouse billing idle time credits consumed"
]

for query in queries:
    print(f"\n=== Query: {query} ===")
    payload = {
        "query": query,
        "limit": 10
    }
    try:
        resp = requests.post(
            "https://api.parallel.ai/v1beta/search",
            headers=HEADERS,
            json=payload,
            timeout=60
        )
        resp.raise_for_status()
        data = resp.json()
        
        results = data.get("data", {}).get("results", [])
        for r in results:
            if isinstance(r, dict):
                print(f"- URL: {r.get('url', 'n/a')}")
                print(f"  Title: {r.get('title', 'n/a')}")
                if "snippet" in r:
                    print(f"  Snippet: {r.get('snippet', '')[:200]}...")
            else:
                print(f"  Result: {r}")
    except Exception as e:
        print(f"Error: {e}")
