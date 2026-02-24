#!/usr/bin/env python3
"""
Warehouse Auto-Suspend/Resume Deep Research v1.0
Runs Parallel API searches and extracts for Snowflake warehouse idle/billing behavior.
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

# Targeted queries for auto-suspend/resume research
SEARCH_QUERIES = [
    {
        "query": "Snowflake warehouse auto-suspend minimum idle time TIMEOUT billing credits",
        "topic": "auto-suspend-basics"
    },
    {
        "query": "Snowflake warehouse suspend behavior cluster shutdown credit consumption idle",
        "topic": "suspend-behavior"
    },
    {
        "query": "Snowflake warehouse resume behavior cold start latency cluster startup",
        "topic": "resume-behavior"
    },
    {
        "query": "Snowflake warehouse WAREHOUSE_METERING_HISTORY identify idle vs active time",
        "topic": "metering-view"
    },
    {
        "query": "Snowflake warehouse resource monitor auto-suspend suspend immediate vs at end",
        "topic": "resource-monitors"
    },
    {
        "query": "Snowflake warehouse DATA_TRANSFER_HISTORY vs WAREHOUSE_METERING_HISTORY credits",
        "topic": "credit-tracking"
    }
]

def parallel_search(query_data, limit=8):
    """Execute Parallel Search API call"""
    payload = {
        "query": query_data["query"],
        "limit": limit
    }
    try:
        resp = requests.post(
            "https://api.parallel.ai/v1beta/search",
            headers=HEADERS,
            json=payload,
            timeout=60
        )
        resp.raise_for_status()
        return {
            "topic": query_data["topic"],
            "query": query_data["query"],
            "results": resp.json()
        }
    except Exception as e:
        return {
            "topic": query_data["topic"],
            "query": query_data["query"],
            "error": str(e)
        }

def parallel_extract(url):
    """Extract detailed content from a specific URL"""
    payload = {
        "urls": [url],
        "include_graph_data": True
    }
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
    print("Warehouse Auto-Suspend/Resume Research Session")
    print(f"Started: {datetime.utcnow().isoformat()}")
    print("="*60)
    
    all_results = []
    all_urls = []
    
    # Run searches
    print("\n[PHASE 1] Running Parallel Searches...")
    for q in SEARCH_QUERIES:
        print(f"\n→ {q['topic']}: {q['query'][:50]}...")
        result = parallel_search(q)
        all_results.append(result)
        
        # Collect URLs for extraction
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
        time.sleep(0.5)  # Rate limiting
    
    # Deduplicate URLs
    seen = set()
    unique_urls = []
    for u in all_urls:
        if u["url"] not in seen and "snowflake" in u["url"].lower():
            seen.add(u["url"])
            unique_urls.append(u)
    
    print(f"\n✓ Found {len(unique_urls)} unique Snowflake-related URLs")
    
    # Extract from top URLs (prioritize docs.snowflake.com)
    docs_urls = [u for u in unique_urls if "docs.snowflake.com" in u["url"]]
    other_urls = [u for u in unique_urls if "docs.snowflake.com" not in u["url"]]
    
    top_urls = (docs_urls[:5] + other_urls[:3])[:8]
    
    print(f"\n[PHASE 2] Extracting content from {len(top_urls)} priority URLs...")
    extracts = []
    for u in top_urls:
        print(f"→ {u['url'][:60]}...")
        extract = parallel_extract(u["url"])
        extracts.append({
            "source": u,
            "extract": extract
        })
        time.sleep(0.5)
    
    # Output structured results
    output = {
        "timestamp": datetime.utcnow().isoformat(),
        "session": "warehouse-auto-suspend-research",
        "searches": all_results,
        "extracts": extracts
    }
    
    output_path = "/home/ubuntu/.openclaw/workspace/research/finops/2026-02-24/research_raw_warehouse_suspend.json"
    with open(output_path, "w") as f:
        json.dump(output, f, indent=2)
    
    print(f"\n[PHASE 3] Raw results saved to: {output_path}")
    
    # Print summary for report generation
    print("\n" + "="*60)
    print("URL SUMMARY (for citations)")
    print("="*60)
    for i, u in enumerate(top_urls, 1):
        print(f"{i}. {u['url']}")
        print(f"   Title: {u['title']}")
        print()
    
    return output

if __name__ == "__main__":
    main()
