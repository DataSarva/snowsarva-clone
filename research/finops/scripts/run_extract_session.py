#!/usr/bin/env python3
"""Extract detailed content from priority URLs using Parallel API"""
import os
import requests
import json
from datetime import datetime, timezone
import time

API_KEY = os.environ.get("PARALLEL_API_KEY")
HEADERS = {
    "x-api-key": API_KEY,
    "Content-Type": "application/json",
    "parallel-beta": "search-extract-2025-10-10"
}

# Priority URLs from the search results
PRIORITY_URLS = [
    "https://docs.snowflake.com/en/user-guide/cost-optimize",
    "https://docs.snowflake.com/en/user-guide/cost-management-overview",
    "https://docs.snowflake.com/en/developer-guide/native-apps/native-apps-workflow",
    "https://www.flexera.com/blog/finops/reduce-snowflake-costs/",
    "https://dataengineerhub.blog/articles/snowflake-cost-optimization-techniques-2026",
    "https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/",
]

def parallel_extract(url):
    """Extract detailed content from a URL"""
    payload = {
        "urls": [url]
    }
    try:
        resp = requests.post(
            "https://api.parallel.ai/v1beta/extract",
            headers=HEADERS,
            json=payload,
            timeout=90
        )
        resp.raise_for_status()
        return resp.json()
    except Exception as e:
        return {"error": str(e), "url": url}

def main():
    timestamp = datetime.now(timezone.utc)
    print("="*70)
    print("Snowflake FinOps Deep Research Session - Extract Phase")
    print(f"Started: {timestamp.isoformat()}")
    print("="*70)
    
    extracts = []
    for url in PRIORITY_URLS:
        print(f"\n→ Extracting: {url}")
        result = parallel_extract(url)
        extracts.append({
            "url": url,
            "extract": result
        })
        time.sleep(1)  # Be polite to API
    
    # Save extract results
    out_dir = f"/home/ubuntu/.openclaw/workspace/research/finops/{timestamp.strftime('%Y-%m-%d')}"
    os.makedirs(out_dir, exist_ok=True)
    extract_out = f"{out_dir}/extracted_content_{timestamp.strftime('%Y%m%d_%H%M')}.json"
    
    output = {
        "timestamp": timestamp.isoformat(),
        "session": "finops-deep-research-extract",
        "extracts": extracts
    }
    
    with open(extract_out, "w") as f:
        json.dump(output, f, indent=2)
    
    print(f"\n[PHASE 2] Extract results saved to: {extract_out}")
    print(f"Extracted {len(extracts)} URLs")
    
    return extracts

if __name__ == "__main__":
    main()
