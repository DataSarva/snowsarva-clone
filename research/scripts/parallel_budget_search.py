#!/usr/bin/env python3
"""Search for Snowflake budget/forecasting/cost alerts sources using Parallel API."""
import json
import requests
import os
from datetime import datetime

def parallel_search(query, max_results=10):
    """Call Parallel Search API."""
    url = "https://api.parallel.ai/v1beta/search"
    headers = {
        "Content-Type": "application/json",
        "x-api-key": os.environ.get("PARALLEL_API_KEY", ""),
        "parallel-beta": "search-extract-2025-10-10"
    }
    payload = {
        "query": query,
        "max_results": max_results,
        "include_content": True
    }
    resp = requests.post(url, headers=headers, json=payload, timeout=60)
    resp.raise_for_status()
    return resp.json()

def parallel_extract(urls):
    """Call Parallel Extract API for deep reads."""
    url = "https://api.parallel.ai/v1beta/extract"
    headers = {
        "Content-Type": "application/json",
        "x-api-key": os.environ.get("PARALLEL_API_KEY", ""),
        "parallel-beta": "search-extract-2025-10-10"
    }
    payload = {
        "urls": urls,
        "include_content": True,
        "max_length": 20000
    }
    resp = requests.post(url, headers=headers, json=payload, timeout=120)
    resp.raise_for_status()
    return resp.json()

if __name__ == "__main__":
    # Multi-query search for budget/forecasting topics
    queries = [
        "Snowflake resource monitors budget limits API",
        "Snowflake cost forecasting alerts notifications",
        "Snowflake FinOps spend management chargeback allocation"
    ]
    
    timestamp = int(datetime.utcnow().timestamp())
    all_results = []
    
    for query in queries:
        print(f"Searching: {query}")
        try:
            result = parallel_search(query, max_results=8)
            result["query"] = query
            result["search_timestamp"] = timestamp
            all_results.append(result)
            print(f"  Found {len(result.get('results', []))} results")
        except Exception as e:
            print(f"  Error: {e}")
    
    # Save search results
    search_path = f"search_budget_forecast_{timestamp}.json"
    with open(search_path, "w") as f:
        json.dump(all_results, f, indent=2)
    print(f"\nSaved search results to: {search_path}")
    
    # Collect URLs for extraction (top 6 unique URLs)
    urls_to_extract = []
    seen = set()
    for result in all_results:
        for item in result.get("results", []):
            url = item.get("url", "")
            if url and url not in seen:
                urls_to_extract.append(url)
                seen.add(url)
                if len(urls_to_extract) >= 6:
                    break
        if len(urls_to_extract) >= 6:
            break
    
    print(f"\nExtracting {len(urls_to_extract)} URLs...")
    for url in urls_to_extract:
        print(f"  - {url}")
    
    if urls_to_extract:
        try:
            extract_result = parallel_extract(urls_to_extract)
            extract_path = f"extract_budget_forecast_{timestamp}.json"
            with open(extract_path, "w") as f:
                json.dump(extract_result, f, indent=2)
            print(f"\nSaved extract results to: {extract_path}")
        except Exception as e:
            print(f"Extraction error: {e}")
