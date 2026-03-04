#!/usr/bin/env python3
"""Run Parallel Search for Snowflake FinOps topics - March 4, 2026"""
import os
import requests
import json
from datetime import datetime, timezone
import time

API_KEY = os.environ.get("PARALLEL_API_KEY")
HEADERS = {
    "x-api-key": API_KEY,
    "Content-Type": "application/json",
    "parallel-beta": "search-extract-2025-10-10"
}

SEARCH_TOPICS = [
    {
        "queries": ["Snowflake cost optimization auto-suspend warehouse sizing serverless credits"],
        "objective": "Find latest Snowflake cost optimization practices for 2026",
        "topic": "cost-optimization"
    },
    {
        "queries": ["Snowflake Native App Framework best practices application bundle manifest setup provider consumer"],
        "objective": "Discover Native App Framework best practices",
        "topic": "native-app-framework"
    },
    {
        "queries": ["Snowpark Container Services SCS FinOps workloads cost monitoring job scheduling"],
        "objective": "Learn about Snowpark Container Services for cost workloads",
        "topic": "scs-finops"
    },
    {
        "queries": ["Snowflake ORG_USAGE vs ACCOUNT_USAGE billing data warehouse metering cost analysis views"],
        "objective": "Understand ORG_USAGE vs ACCOUNT_USAGE for cost monitoring",
        "topic": "org-vs-account-usage"
    },
    {
        "queries": ["Snowflake materialized view cost metrics aggregation warehouse metering query acceleration"],
        "objective": "Find materialized view cost optimization strategies",
        "topic": "mv-cost-metrics"
    },
    {
        "queries": ["Snowflake Snowpark Python stored procedures cost monitoring table functions UDF"],
        "objective": "Explore Snowpark for FinOps automation",
        "topic": "snowpark-cost-monitoring"
    }
]

def parallel_search(queries, objective):
    """Execute Parallel Search API call"""
    payload = {
        "search_queries": queries,
        "objective": objective
    }
    try:
        resp = requests.post(
            "https://api.parallel.ai/v1beta/search",
            headers=HEADERS,
            json=payload,
            timeout=120
        )
        resp.raise_for_status()
        return resp.json()
    except Exception as e:
        return {"error": str(e)}

def main():
    timestamp = datetime.now(timezone.utc)
    print("="*70)
    print("Snowflake FinOps Deep Research Session - Search Phase")
    print(f"Started: {timestamp.isoformat()}")
    print("="*70)
    
    all_results = []
    all_urls = []
    
    for topic in SEARCH_TOPICS:
        print(f"\n→ Searching: {topic['topic']}")
        result = parallel_search(topic["queries"], topic["objective"])
        all_results.append({
            "topic": topic["topic"],
            "queries": topic["queries"],
            "objective": topic["objective"],
            "results": result
        })
        
        # Collect URLs from results
        if "results" in result:
            for r in result["results"]:
                url = r.get("url")
                if url:
                    all_urls.append({
                        "url": url,
                        "title": r.get("title", "N/A"),
                        "topic": topic["topic"],
                        "publish_date": r.get("publish_date", "N/A")
                    })
        
        time.sleep(0.5)
    
    # Deduplicate and prioritize docs
    seen = set()
    unique_urls = []
    for u in all_urls:
        if u["url"] not in seen and "snowflake" in u["url"].lower():
            seen.add(u["url"])
            unique_urls.append(u)
    
    print(f"\n✓ Found {len(unique_urls)} unique Snowflake-related URLs")
    
    # Prioritize docs.snowflake.com
    docs_urls = [u for u in unique_urls if "docs.snowflake.com" in u["url"]]
    other_urls = [u for u in unique_urls if "docs.snowflake.com" not in u["url"]]
    
    # Take up to 15 priority URLs
    final_urls = docs_urls[:8] + other_urls[:7]
    
    # Save search results
    out_dir = f"/home/ubuntu/.openclaw/workspace/research/finops/{timestamp.strftime('%Y-%m-%d')}"
    os.makedirs(out_dir, exist_ok=True)
    search_out = f"{out_dir}/search_results_{timestamp.strftime('%Y%m%d_%H%M')}.json"
    
    output = {
        "timestamp": timestamp.isoformat(),
        "session": "finops-deep-research",
        "searches": all_results,
        "extract_candidates": final_urls
    }
    
    with open(search_out, "w") as f:
        json.dump(output, f, indent=2)
    
    print(f"\n[PHASE 1] Search results saved to: {search_out}")
    print(f"\nPriority URLs for extraction ({len(final_urls)}):")
    for i, u in enumerate(final_urls, 1):
        print(f"  {i}. [{u['topic']}] {u['url']}")
    
    return final_urls

if __name__ == "__main__":
    main()
