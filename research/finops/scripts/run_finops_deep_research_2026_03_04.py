#!/usr/bin/env python3
"""
Snowflake FinOps Deep Research - March 4, 2026
Targets: cost optimization, Native App Framework, SCS for FinOps, 
         ORG_USAGE vs ACCOUNT_USAGE, materialized views for cost metrics
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
        "query": "Snowflake cost optimization auto-suspend warehouse sizing serverless credits optimization 2026",
        "topic": "cost-optimization"
    },
    {
        "query": "Snowflake Native App Framework best practices application bundle manifest setup provider consumer 2026",
        "topic": "native-app-framework"
    },
    {
        "query": "Snowpark Container Services SCS FinOps workloads cost monitoring job scheduling",
        "topic": "scs-finops"
    },
    {
        "query": "Snowflake ORG_USAGE vs ACCOUNT_USAGE billing data warehouse access cost analysis views",
        "topic": "org-vs-account-usage"
    },
    {
        "query": "Snowflake materialized view cost metrics aggregation WAREHOUSE_METERING_HISTORY optimization",
        "topic": "mv-cost-metrics"
    },
    {
        "query": "Snowflake Snowpark Python stored procedures cost monitoring table functions",
        "topic": "snowpark-cost-monitoring"
    },
    {
        "query": "Snowflake REST API billing usage warehouses accounts organizations",
        "topic": "billing-api"
    }
]

def parallel_search(query_data, limit=10):
    """Execute Parallel Search API call"""
    payload = {
        "query": query_data["query"],
        "limit": limit,
        "freshness": "pm"  # Past month for recent updates
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
        "include_graph_data": True,
        "format": "markdown"
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
    timestamp = datetime.utcnow()
    print("="*70)
    print("Snowflake FinOps Deep Research Session")
    print(f"Started: {timestamp.isoformat()}")
    print("="*70)
    print("\nTopics:")
    for q in SEARCH_QUERIES:
        print(f"  • {q['topic']}")
    
    all_results = []
    all_urls = []
    
    # Phase 1: Search
    print("\n[PHASE 1] Running Parallel Searches...")
    for q in SEARCH_QUERIES:
        print(f"\n→ {q['topic']}: {q['query'][:60]}...")
        result = parallel_search(q, limit=8)
        all_results.append(result)
        
        # Collect URLs
        if "results" in result and "data" in result["results"]:
            data = result["results"]["data"]
            if "results" in data:
                for r in data["results"]:
                    if isinstance(r, dict) and "url" in r:
                        all_urls.append({
                            "url": r["url"],
                            "title": r.get("title", "N/A"),
                            "snippet": r.get("snippet", "")[:250],
                            "publish_date": r.get("publish_date", "N/A"),
                            "topic": q["topic"]
                        })
        time.sleep(0.3)
    
    # Deduplicate and filter
    seen = set()
    unique_urls = []
    for u in all_urls:
        if u["url"] not in seen and ("snowflake" in u["url"].lower() or "snowpark" in u["url"].lower()):
            seen.add(u["url"])
            unique_urls.append(u)
    
    print(f"\n✓ Found {len(unique_urls)} unique Snowflake-related URLs")
    
    # Prioritize URLs
    docs_urls = [u for u in unique_urls if "docs.snowflake.com" in u["url"]]
    other_urls = [u for u in unique_urls if "docs.snowflake.com" not in u["url"]]
    
    # Pick top 5 per topic prioritizing docs
    top_urls = []
    for topic in [q["topic"] for q in SEARCH_QUERIES]:
        topic_docs = [u for u in docs_urls if u["topic"] == topic][:2]
        topic_other = [u for u in other_urls if u["topic"] == topic][:1]
        top_urls.extend(topic_docs + topic_other)
    
    # Deduplicate final list
    final_urls = []
    seen_final = set()
    for u in top_urls:
        if u["url"] not in seen_final:
            seen_final.add(u["url"])
            final_urls.append(u)
    
    # Limit to top 12
    final_urls = final_urls[:12]
    
    print(f"\n[PHASE 2] Extracting content from {len(final_urls)} priority URLs...")
    extracts = []
    for u in final_urls:
        print(f"→ {u['url'][:70]}...")
        extract = parallel_extract(u["url"])
        extracts.append({
            "source": u,
            "extract": extract
        })
        time.sleep(0.5)
    
    # Save raw results
    output = {
        "timestamp": timestamp.isoformat(),
        "session": "finops-deep-research-2026-03-04",
        "searches": all_results,
        "extracts": extracts
    }
    
    out_dir = f"/home/ubuntu/.openclaw/workspace/research/finops/{timestamp.strftime('%Y-%m-%d')}"
    os.makedirs(out_dir, exist_ok=True)
    
    search_out = f"{out_dir}/search_results_{timestamp.strftime('%Y%m%d_%H%M')}.json"
    with open(search_out, "w") as f:
        json.dump(output, f, indent=2)
    
    print(f"\n[PHASE 3] Raw results saved to: {search_out}")
    
    # Print URL summary for synthesis
    print("\n" + "="*70)
    print("URL SUMMARY (for citations)")
    print("="*70)
    for i, u in enumerate(final_urls, 1):
        print(f"\n{i}. [{u['topic']}] {u['url']}")
        print(f"   Title: {u['title']}")
    
    return output, final_urls

if __name__ == "__main__":
    main()
