#!/usr/bin/env python3
"""Parallel Search/Chat helper.

Uses Parallel's OpenAI-compatible chat completions endpoint.

Env:
  PARALLEL_API_KEY  (required)

Examples:
  python3 parallel_chat.py "What are Snowflake Event Tables?" \
    --system "You are a researcher. Cite sources." \
    --model "basic" \
    --max-chars 6000

Notes:
- Endpoint inferred from Akhil-provided docs: https://search-mcp.parallel.ai/v1beta/chat/completions
- Many OpenAI params are ignored by Parallel per their docs; we keep the request minimal.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import textwrap
import urllib.request

DEFAULT_URL = "https://api.parallel.ai/chat/completions"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("query", help="user query")
    ap.add_argument("--system", default="", help="optional system message")
    ap.add_argument("--model", default="research", help="model name (recommend: research; avoid speed for synthesis)")
    ap.add_argument("--url", default=DEFAULT_URL, help="override endpoint")
    ap.add_argument("--max-chars", type=int, default=12000, help="truncate output for terminals")
    args = ap.parse_args()

    api_key = os.environ.get("PARALLEL_API_KEY")
    if not api_key:
        print("PARALLEL_API_KEY is not set", file=sys.stderr)
        sys.exit(2)

    messages = []
    if args.system.strip():
        messages.append({"role": "system", "content": args.system.strip()})
    messages.append({"role": "user", "content": args.query})

    payload = {
        "model": args.model,
        "stream": False,
        "messages": messages,
    }

    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        args.url,
        data=data,
        headers={
            "content-type": "application/json",
            "authorization": f"Bearer {api_key}",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
    except Exception as e:
        print(f"request failed: {e}", file=sys.stderr)
        sys.exit(1)

    # Try to extract the assistant text, fallback to raw json.
    try:
        obj = json.loads(raw)
        text = obj["choices"][0]["message"]["content"]
    except Exception:
        text = raw

    if args.max_chars and len(text) > args.max_chars:
        text = text[: args.max_chars] + "\n\n[truncated]"

    print(text)


if __name__ == "__main__":
    main()
