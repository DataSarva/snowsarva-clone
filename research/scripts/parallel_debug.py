#!/usr/bin/env python3
"""Debug Parallel API with simpler requests."""
import json
import requests
import os

def test_parallel_search():
    url = "https://api.parallel.ai/v1beta/search"
    headers = {
        "Content-Type": "application/json",
        "x-api-key": os.environ.get("PARALLEL_API_KEY", ""),
        "parallel-beta": "search-extract-2025-10-10"
    }
    
    # Minimal payload test
    payload = {
        "query": "Snowflake resource monitors",
        "max_results": 5
    }
    
    print(f"Headers: {headers}")
    print(f"Payload: {json.dumps(payload, indent=2)}")
    
    try:
        resp = requests.post(url, headers=headers, json=payload, timeout=30)
        print(f"Status: {resp.status_code}")
        print(f"Response: {resp.text[:500]}")
    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    test_parallel_search()
