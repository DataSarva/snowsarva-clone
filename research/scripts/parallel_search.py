#!/usr/bin/env python3
"""
Parallel Search API client for discovering sources.
"""
import os
import sys
import json
import urllib.request
import urllib.error

def search(query, num_results=5):
    """Search using Parallel AI API."""
    api_key = os.environ.get('PARALLEL_API_KEY')
    if not api_key:
        print("Error: PARALLEL_API_KEY not set", file=sys.stderr)
        sys.exit(1)
    
    url = "https://api.parallel.ai/v1beta/search"
    headers = {
        "Content-Type": "application/json",
        "x-api-key": api_key,
        "parallel-beta": "search-extract-2025-10-10"
    }
    
    data = {
        "query": query,
        "num_results": num_results
    }
    
    req = urllib.request.Request(
        url,
        data=json.dumps(data).encode('utf-8'),
        headers=headers,
        method='POST'
    )
    
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            return json.loads(response.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        print(f"HTTP Error {e.code}: {e.read().decode('utf-8')}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 parallel_search.py '<query>' [num_results]", file=sys.stderr)
        sys.exit(1)
    
    query = sys.argv[1]
    num_results = int(sys.argv[2]) if len(sys.argv) > 2 else 5
    
    results = search(query, num_results)
    print(json.dumps(results, indent=2))
