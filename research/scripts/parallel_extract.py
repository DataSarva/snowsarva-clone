#!/usr/bin/env python3
"""
Parallel Extract API client for deep reading sources.
"""
import os
import sys
import json
import urllib.request
import urllib.error

def extract(urls, prompt=None):
    """Extract content from URLs using Parallel AI API."""
    api_key = os.environ.get('PARALLEL_API_KEY')
    if not api_key:
        print("Error: PARALLEL_API_KEY not set", file=sys.stderr)
        sys.exit(1)
    
    api_url = "https://api.parallel.ai/v1beta/extract"
    headers = {
        "Content-Type": "application/json",
        "x-api-key": api_key,
        "parallel-beta": "search-extract-2025-10-10"
    }
    
    if isinstance(urls, str):
        urls = [urls]
    
    data = {
        "urls": urls
    }
    
    if prompt:
        data["prompt"] = prompt
    
    req = urllib.request.Request(
        api_url,
        data=json.dumps(data).encode('utf-8'),
        headers=headers,
        method='POST'
    )
    
    try:
        with urllib.request.urlopen(req, timeout=120) as response:
            return json.loads(response.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        print(f"HTTP Error {e.code}: {e.read().decode('utf-8')}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 parallel_extract.py '<url1>' ['<url2>' ...]", file=sys.stderr)
        sys.exit(1)
    
    urls = sys.argv[1:]
    results = extract(urls)
    print(json.dumps(results, indent=2))
