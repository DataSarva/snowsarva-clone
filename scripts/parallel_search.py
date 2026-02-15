#!/usr/bin/env python3
"""Parallel Search API wrapper for discovering sources."""
import os
import sys
import json
import urllib.request
import urllib.error

API_URL = "https://api.parallel.ai/v1beta/search"

def search(query, max_results=10):
    """Search using Parallel AI API."""
    api_key = os.environ.get("PARALLEL_API_KEY")
    if not api_key:
        print("Error: PARALLEL_API_KEY not set", file=sys.stderr)
        sys.exit(1)

    headers = {
        "Content-Type": "application/json",
        "x-api-key": api_key,
        "parallel-beta": "search-extract-2025-10-10"
    }

    # Use search_queries instead of query
    payload = json.dumps({
        "search_queries": [query],
        "max_results": max_results
    }).encode("utf-8")

    req = urllib.request.Request(
        API_URL,
        data=payload,
        headers=headers,
        method="POST"
    )

    try:
        with urllib.request.urlopen(req, timeout=120) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        print(f"HTTP Error: {e.code} - {e.read().decode()}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 parallel_search.py '<query>' [max_results]", file=sys.stderr)
        sys.exit(1)

    query = sys.argv[1]
    max_results = int(sys.argv[2]) if len(sys.argv) > 2 else 10

    result = search(query, max_results)
    print(json.dumps(result, indent=2))
