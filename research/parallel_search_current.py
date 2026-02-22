#!/usr/bin/env python3
"""Parallel API search script for continuous research."""
import os
import json
import requests
import sys
import time

def parallel_search(objective, topn=10):
    """Search using Parallel API."""
    api_key = os.environ.get('PARALLEL_API_KEY')
    if not api_key:
        print("Error: PARALLEL_API_KEY not set", file=sys.stderr)
        sys.exit(1)
    
    headers = {
        'Content-Type': 'application/json',
        'x-api-key': api_key,
        'parallel-beta': 'search-extract-2025-10-10'
    }
    
    payload = {
        'objective': objective,
        'topn': topn
    }
    
    response = requests.post(
        'https://api.parallel.ai/v1beta/search',
        headers=headers,
        json=payload,
        timeout=60
    )
    
    if response.status_code != 200:
        print(f"Error: {response.status_code} - {response.text}", file=sys.stderr)
        sys.exit(1)
    
    return response.json()

def parallel_extract(urls):
    """Extract content from URLs using Parallel API."""
    api_key = os.environ.get('PARALLEL_API_KEY')
    if not api_key:
        print("Error: PARALLEL_API_KEY not set", file=sys.stderr)
        sys.exit(1)
    
    headers = {
        'Content-Type': 'application/json',
        'x-api-key': api_key,
        'parallel-beta': 'search-extract-2025-10-10'
    }
    
    payload = {
        'urls': urls
    }
    
    response = requests.post(
        'https://api.parallel.ai/v1beta/extract',
        headers=headers,
        json=payload,
        timeout=120
    )
    
    if response.status_code != 200:
        print(f"Error: {response.status_code} - {response.text}", file=sys.stderr)
        sys.exit(1)
    
    return response.json()

if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--query', required=True)
    parser.add_argument('--topn', type=int, default=10)
    parser.add_argument('--extract', action='store_true')
    args = parser.parse_args()
    
    # Search
    print(f"Searching: {args.query}")
    results = parallel_search(args.query, args.topn)
    
    output_file = f"/home/ubuntu/.openclaw/workspace/research/search_current_{int(time.time())}.json"
    with open(output_file, 'w') as f:
        json.dump(results, f, indent=2)
    print(f"Search results saved to: {output_file}")
    
    # Extract if requested
    if args.extract and 'results' in results:
        urls = [r.get('url') for r in results['results'] if r.get('url')]
        if urls:
            print(f"Extracting from {len(urls[:5])} URLs...")
            extracts = parallel_extract(urls[:5])
            extract_file = f"/home/ubuntu/.openclaw/workspace/research/extract_current_{int(time.time())}.json"
            with open(extract_file, 'w') as f:
                json.dump(extracts, f, indent=2)
            print(f"Extract results saved to: {extract_file}")
