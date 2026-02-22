#!/usr/bin/env python3
import os
import json
import requests
import sys
import time

api_key = os.environ.get('PARALLEL_API_KEY')
if not api_key:
    print("Error: PARALLEL_API_KEY not set", file=sys.stderr)
    sys.exit(1)

headers = {
    'Content-Type': 'application/json',
    'x-api-key': api_key,
    'parallel-beta': 'search-extract-2025-10-10'
}

urls = [
    "https://www.flexera.com/blog/finops/snowpark-container-services/",
    "https://docs.snowflake.com/en/developer-guide/snowpark-container-services/accounts-orgs-usage-views",
    "https://docs.snowflake.com/en/developer-guide/snowpark-container-services/monitoring-services",
    "https://docs.snowflake.com/en/developer-guide/native-apps/container-cost-governance"
]

payload = {'urls': urls}
response = requests.post(
    'https://api.parallel.ai/v1beta/extract',
    headers=headers,
    json=payload,
    timeout=120
)

if response.status_code != 200:
    print(f"Error: {response.status_code} - {response.text}", file=sys.stderr)
    sys.exit(1)

results = response.json()
output_file = f"/home/ubuntu/.openclaw/workspace/research/extract_current_{int(time.time())}.json"
with open(output_file, 'w') as f:
    json.dump(results, f, indent=2)
print(f"Extract results saved to: {output_file}")
