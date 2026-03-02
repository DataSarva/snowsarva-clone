#!/usr/bin/env python3
"""Warehouse Sizing Deep Research v1.0
Runs Parallel API searches and extracts for Snowflake warehouse sizing and cost optimization.
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

# Targeted queries for warehouse sizing research
SEARCH_QUERIES = [
    {
        "query": "Snowflake warehouse sizing XS XSmall Small Medium Large Xlarge 2X 3X 4X 5X 6X credits per hour",
        "topic": "warehouse-size-credits"
    },
    {
        "query": "Snowflake warehouse size vs query performance right-sizing best practices optimization",
        "topic": "right-sizing-strategy"
    },
    {
        "query": "Snowflake warehouse SUSPEND_TIMEOUT AUTO_SUSPEND sizing recommendation cost optimization",
        "topic": "suspend-timeout-sizing"
    },
    {
        "query": "Snowflake warehouse elastic scaling resize operations dynamic sizing credit cost",
        "topic": "elastic-scaling"
    },
    {
        "query": "Snowflake WAREHOUSE_METERING_HISTORY query credits consumed warehouse size analysis",
        "topic": "metering-analysis"
    },
    {
        "query": "Snowflake warehouse size query acceleration caching cost per query benchmark",
        "topic": "cost-per-query"
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
    print("="*70)
    print("Warehouse Sizing Deep Research Session")
    print(f"Started: {datetime.utcnow().isoformat()}")
    print("="*70)
    
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
                            "snippet": r.get("snippet", "")[:200],
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
    
    # Extract from top URLs (prioritize docs.snowflake.com)
    docs_urls = [u for u in unique_urls if "docs.snowflake.com" in u["url"]]
    other_urls = [u for u in unique_urls if "docs.snowflake.com" not in u["url"]]
    top_urls = (docs_urls[:6] + other_urls[:3])[:9]
    
    print(f"\n[PHASE 2] Extracting content from {len(top_urls)} priority URLs...")
    extracts = []
    for u in top_urls:
        print(f"→ {u['url'][:70]}...")
        extract = parallel_extract(u["url"])
        extracts.append({
            "source": u,
            "extract": extract
        })
        time.sleep(0.5)
    
    # Output structured results
    output = {
        "timestamp": datetime.utcnow().isoformat(),
        "session": "warehouse-sizing-research",
        "searches": all_results,
        "extracts": extracts
    }
    
    out_dir = "/home/ubuntu/.openclaw/workspace/research/finops/2026-03-02"
    os.makedirs(out_dir, exist_ok=True)
    output_path = f"{out_dir}/research_raw_warehouse_sizing.json"
    with open(output_path, "w") as f:
        json.dump(output, f, indent=2)
    
    print(f"\n[PHASE 3] Raw results saved to: {output_path}")
    
    # Print summary for report generation
    print("\n" + "="*70)
    print("URL SUMMARY (for citations)")
    print("="*70)
    for i, u in enumerate(top_urls, 1):
        print(f"{i}. {u['url']}")
        print(f"   Title: {u['title']}")
        print()
    
    # Print key findings snippets
    print("\n" + "="*70)
    print("KEY EXCERPTS (for synthesis)")
    print("="*70)
    for e in extracts:
        if "extract" in e and "data" in e["extract"]:
            data = e["extract"]["data"]
            if "results" in data and len(data["results"]) > 0:
                result = data["results"][0]
                if "extracted_data" in result:
                    content = result["extracted_data"]
                    # Get first substantial paragraph
                    if "text" in content:
                        text = content["text"][:400]
                        print(f"\nFrom: {e['source']['url'][:60]}...")
                        print(f"  {text}...")
    
    return output

if __name__ == "__main__":
    main()
