#!/usr/bin/env python3
""" Warehouse Concurrency & Queueing Deep Research v1.0
Runs Parallel API searches for Snowflake warehouse concurrency, queuing, and multi-cluster scaling behavior.
"""
import os
import requests
import json
from datetime import datetime
import time

API_KEY = os.environ.get("PARALLEL_API_KEY")
HEADERS = {
    "x-api-key": API_KEY,
    "Content-Type": "application/json",
    "parallel-beta": "search-extract-2025-10-10"
}

SEARCH_QUERIES = [
    {
        "query": "Snowflake warehouse concurrency query queuing behavior queue depth",
        "topic": "concurrency-queuing"
    },
    {
        "query": "Snowflake multi-cluster warehouse queue scaling policy max_concurrency_level",
        "topic": "mcc-queue-scaling"
    },
    {
        "query": "Snowflake warehouse STATEMENT_QUEUE_TIME statistics query wait time",
        "topic": "queue-time-metrics"
    },
    {
        "query": "Snowflake warehouse WAREHOUSE_LOAD_HISTORY QUEUED_OVER_TIME queued queries",
        "topic": "warehouse-load"
    },
    {
        "query": "Snowflake warehouse statement timeout queue timeout concurrency scaling",
        "topic": "timeout-governance"
    },
    {
        "query": "Snowflake QUERY_ACCELERATION concurrency queue behavior",
        "topic": "qas-concurrency"
    }
]

def parallel_search(query_data, limit=8):
    payload = {"query": query_data["query"], "limit": limit}
    try:
        resp = requests.post(
            "https://api.parallel.ai/v1beta/search",
            headers=HEADERS,
            json=payload,
            timeout=60
        )
        resp.raise_for_status()
        return {"topic": query_data["topic"], "query": query_data["query"], "results": resp.json()}
    except Exception as e:
        return {"topic": query_data["topic"], "query": query_data["query"], "error": str(e)}

def parallel_extract(url):
    payload = {"urls": [url], "include_graph_data": True}
    try:
        resp = requests.post(
            "https://api.parallel.ai/v1beta/extract",
            headers=HEADERS,
            json=payload,
            timeout=60
        )
        resp.raise_for_status()
        return resp.json()
    except Exception as e:
        return {"error": str(e), "url": url}

def main():
    print("="*60)
    print("Warehouse Concurrency & Queueing Research Session")
    print(f"Started: {datetime.utcnow().isoformat()}")
    print("="*60)
    
    all_results = []
    all_urls = []
    
    print("\n[PHASE 1] Running Parallel Searches...")
    for q in SEARCH_QUERIES:
        print(f"\n→ {q['topic']}: {q['query'][:50]}...")
        result = parallel_search(q)
        all_results.append(result)
        
        if "results" in result and "data" in result["results"]:
            data = result["results"]["data"]
            if "results" in data:
                for r in data["results"]:
                    if isinstance(r, dict) and "url" in r:
                        all_urls.append({
                            "url": r["url"],
                            "title": r.get("title", "N/A"),
                            "snippet": r.get("snippet", "")[:150],
                            "topic": q["topic"]
                        })
        time.sleep(0.5)
    
    # Deduplicate URLs
    seen = set()
    unique_urls = []
    for u in all_urls:
        if u["url"] not in seen and "snowflake" in u["url"].lower():
            seen.add(u["url"])
            unique_urls.append(u)
    
    print(f"\n✓ Found {len(unique_urls)} unique Snowflake-related URLs")
    
    # Extract from priority URLs
    docs_urls = [u for u in unique_urls if "docs.snowflake.com" in u["url"]]
    other_urls = [u for u in unique_urls if "docs.snowflake.com" not in u["url"]]
    top_urls = (docs_urls[:5] + other_urls[:3])[:8]
    
    print(f"\n[PHASE 2] Extracting content from {len(top_urls)} priority URLs...")
    extracts = []
    for u in top_urls:
        print(f"→ {u['url'][:60]}...")
        extract = parallel_extract(u["url"])
        extracts.append({"source": u, "extract": extract})
        time.sleep(0.5)
    
    output = {
        "timestamp": datetime.utcnow().isoformat(),
        "session": "warehouse-concurrency-queueing-research",
        "searches": all_results,
        "extracts": extracts
    }
    
    import os
    os.makedirs("/home/ubuntu/.openclaw/workspace/research/finops/2026-02-24", exist_ok=True)
    output_path = "/home/ubuntu/.openclaw/workspace/research/finops/2026-02-24/research_raw_concurrency_queue.json"
    with open(output_path, "w") as f:
        json.dump(output, f, indent=2)
    
    print(f"\n[PHASE 3] Raw results saved to: {output_path}")
    
    print("\n" + "="*60)
    print("URL SUMMARY (for citations)")
    print("="*60)
    for i, u in enumerate(top_urls, 1):
        print(f"{i}. {u['url']}")
        print(f"   Title: {u['title']}")
        
    return output

if __name__ == "__main__":
    main()
