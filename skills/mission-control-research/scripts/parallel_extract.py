#!/usr/bin/env python3
"""Parallel Extract API helper.

Env:
  PARALLEL_API_KEY (required)

Usage:
  python3 parallel_extract.py \
    --url https://docs.snowflake.com/en/developer-guide/native-apps/event-manage-provider \
    --objective "What are provider event sharing requirements?" \
    --excerpts

Docs (per Akhil):
  POST https://api.parallel.ai/v1beta/extract
  Headers: Content-Type: application/json; x-api-key; parallel-beta: search-extract-2025-10-10
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request

DEFAULT_URL = "https://api.parallel.ai/v1beta/extract"
BETA_HEADER = "search-extract-2025-10-10"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", action="append", dest="urls", required=True, help="url to extract (repeatable)")
    ap.add_argument("--objective", required=True)
    ap.add_argument("--excerpts", action="store_true", default=True)
    ap.add_argument("--full-content", action="store_true", default=False)
    ap.add_argument("--endpoint", default=DEFAULT_URL)
    ap.add_argument("--truncate", type=int, default=0)
    args = ap.parse_args()

    api_key = os.environ.get("PARALLEL_API_KEY")
    if not api_key:
        print("PARALLEL_API_KEY is not set", file=sys.stderr)
        sys.exit(2)

    payload = {
        "urls": args.urls,
        "objective": args.objective,
        "excerpts": bool(args.excerpts),
        "full_content": bool(args.full_content),
    }

    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        args.endpoint,
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
