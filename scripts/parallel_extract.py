#!/usr/bin/env python3
"""Parallel Extract API wrapper for deep reading sources."""
import os
import sys
import json
import urllib.request
import urllib.error

API_URL = "https://api.parallel.ai/v1beta/extract"

def extract(url, max_text_length=50000):
    """Extract content using Parallel AI API."""
    api_key = os.environ.get("PARALLEL_API_KEY")
    if not api_key:
        print("Error: PARALLEL_API_KEY not set", file=sys.stderr)
        sys.exit(1)

    headers = {
        "Content-Type": "application/json",
        "x-api-key": api_key,
        "parallel-beta": "search-extract-2025-10-10"
    }

    # Use urls array instead of single url
    payload = json.dumps({
        "urls": [url],
        "max_text_length": max_text_length
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
        print("Usage: python3 parallel_extract.py '<url>' [max_text_length]", file=sys.stderr)
        sys.exit(1)

    url = sys.argv[1]
    max_length = int(sys.argv[2]) if len(sys.argv) > 2 else 50000

    result = extract(url, max_length)
    print(json.dumps(result, indent=2))
