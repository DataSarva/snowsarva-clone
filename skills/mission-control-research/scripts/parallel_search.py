#!/usr/bin/env python3
"""Parallel Search Extract API helper.

Env:
  PARALLEL_API_KEY (required)

Usage:
  python3 parallel_search.py \
    --objective "Find Snowflake Native Apps updates" \
    --query "Snowflake Native Apps release notes" \
    --query "Snowpark Container Services costs" \
    --max-results 5 \
    --max-chars 3000

Output:
  Prints JSON response (or a truncated version).

Docs (per Akhil):
  POST https://api.parallel.ai/v1beta/search
  Headers: Content-Type: application/json; x-api-key; parallel-beta: search-extract-2025-10-10
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request

DEFAULT_URL = "https://api.parallel.ai/v1beta/search"
BETA_HEADER = "search-extract-2025-10-10"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--objective", required=True)
    ap.add_argument("--query", action="append", dest="queries", required=True)
    ap.add_argument("--max-results", type=int, default=10)
    ap.add_argument("--max-chars", type=int, default=8000, help="max excerpt chars per result")
    ap.add_argument("--url", default=DEFAULT_URL)
    ap.add_argument("--truncate", type=int, default=0, help="truncate printed output chars")
    args = ap.parse_args()

    api_key = os.environ.get("PARALLEL_API_KEY")
    if not api_key:
        print("PARALLEL_API_KEY is not set", file=sys.stderr)
        sys.exit(2)

    payload = {
        "objective": args.objective,
        "search_queries": args.queries,
        "max_results": args.max_results,
        "excerpts": {"max_chars_per_result": args.max_chars},
    }

    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        args.url,
        data=data,
        headers={
            "content-type": "application/json",
            "x-api-key": api_key,
            "parallel-beta": BETA_HEADER,
        },
        method="POST",
    )

    with urllib.request.urlopen(req, timeout=60) as resp:
        raw = resp.read().decode("utf-8", errors="replace")

    if args.truncate and len(raw) > args.truncate:
        raw = raw[: args.truncate] + "\n[truncated]\n"

    print(raw)


if __name__ == "__main__":
    main()
