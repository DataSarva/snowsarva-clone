#!/usr/bin/env python3
"""Search for Snowflake budget/forecasting/cost alerts sources using Parallel API v2."""
import json
import requests
import os
from datetime import datetime, timezone

def parallel_search(query, max_results=10):
    """Call Parallel Search API with correct payload."""
    url = "https://api.parallel.ai/v1beta/search"
    headers = {
        "Content-Type": "application/json",
        "x-api-key": os.environ.get("PARALLEL_API_KEY", ""),
        "parallel-beta": "search-extract-2025-10-10"
    }
    payload = {
        "objective": query,  # Required field
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

def parallel_chat(messages, model="sonnet", temperature=0.3):
    """Call Parallel Chat Completions for synthesis."""
    url = "https://api.parallel.ai/v1beta/chat/completions"
    headers = {
        "Content-Type": "application/json",
        "x-api-key": os.environ.get("PARALLEL_API_KEY", ""),
        "parallel-beta": "search-extract-2025-10-10"
    }
    payload = {
        "model": model,
        "messages": messages,
        "temperature": temperature,
        "max_tokens": 4000
    }
    resp = requests.post(url, headers=headers, json=payload, timeout=120)
    resp.raise_for_status()
    return resp.json()

if __name__ == "__main__":
    # Focused search on budget/forecasting topics
    queries = [
        "Snowflake resource monitors budget limits API documentation",
        "Snowflake cost forecasting alerts notifications setup",
        "Snowflake ORGANIZATION_USAGE views for budget tracking"
    ]
    
    timestamp = int(datetime.now(timezone.utc).timestamp())
    all_search_results = []
    
    for query in queries:
        print(f"\nSearching: {query}")
        try:
            result = parallel_search(query, max_results=8)
            result["query"] = query
            result["search_timestamp"] = timestamp
            all_search_results.append(result)
            found = len(result.get("results", []))
            print(f"  ✓ Found {found} results")
        except Exception as e:
            print(f"  ✗ Error: {e}")
    
    # Save search results
    search_path = f"search_budget_forecast_{timestamp}.json"
    with open(search_path, "w") as f:
        json.dump(all_search_results, f, indent=2)
    print(f"\n✓ Saved search results to: {search_path}")
    
    # Collect URLs for extraction (top 7 unique URLs with highest relevance)
    url_scores = {}
    for result in all_search_results:
        for item in result.get("results", []):
            url = item.get("url", "")
            score = item.get("score", 0)
            if url and url not in url_scores:
                url_scores[url] = {
                    "score": score,
                    "title": item.get("title", ""),
                    "snippet": item.get("snippet", "")
                }
    
    # Sort by score and take top 7
    sorted_urls = sorted(url_scores.items(), key=lambda x: x[1]["score"], reverse=True)
    urls_to_extract = [url for url, _ in sorted_urls[:7]]
    
    print(f"\nExtracting {len(urls_to_extract)} URLs:")
    for url, info in sorted_urls[:7]:
        print(f"  • {info['title'][:60]}... ({info['score']:.2f})")
    
    extract_data = None
    if urls_to_extract:
        try:
            extract_result = parallel_extract(urls_to_extract)
            extract_path = f"extract_budget_forecast_{timestamp}.json"
            with open(extract_path, "w") as f:
                json.dump(extract_result, f, indent=2)
            print(f"\n✓ Saved extract results to: {extract_path}")
            extract_data = extract_result
        except Exception as e:
            print(f"✗ Extraction error: {e}")
    
    # Print summary for synthesis
    print("\n" + "="*60)
    print("SEARCH SUMMARY")
    print("="*60)
    print(f"Total searches: {len(all_search_results)}")
    total_results = sum(len(r.get("results", [])) for r in all_search_results)
    print(f"Total results: {total_results}")
    print(f"Unique URLs extracted: {len(urls_to_extract)}")
    print("\nTop Sources:")
    for i, (url, info) in enumerate(sorted_urls[:5], 1):
        print(f"  {i}. {info['title']}: {url}")
