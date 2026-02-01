#!/usr/bin/env python3
"""Create a new research note file from the per-topic template.

Usage:
  python3 new_research_note.py --topic finops --slug cost-attribution-mart

Writes:
  <workspace>/research/<topic>/<YYYY-MM-DD>/<YYYY-MM-DD_HHMM>_<slug>.md

It copies from:
  <workspace>/research/<topic>/TEMPLATE.md
and stamps the UTC timestamp.

Notes:
- Keeps this deterministic so cron/sub-agents reliably create notes.
- Does NOT attempt to fill the content; it scaffolds the file.
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
from pathlib import Path
import re

TOPICS = {"finops", "native-apps", "snowpark", "scs", "governance", "observability"}


def _slugify(s: str) -> str:
    s = s.strip().lower()
    s = re.sub(r"[^a-z0-9]+", "-", s)
    s = re.sub(r"-+", "-", s).strip("-")
    if not s:
        raise SystemExit("slug is empty after normalization")
    return s[:80]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--topic", required=True, choices=sorted(TOPICS))
    ap.add_argument("--slug", required=True, help="short kebab-case label (will be normalized)")
    ap.add_argument(
        "--workspace",
        default=os.environ.get("OPENCLAW_WORKSPACE", "/home/ubuntu/.openclaw/workspace"),
        help="OpenClaw workspace path (default: /home/ubuntu/.openclaw/workspace)",
    )
    args = ap.parse_args()

    workspace = Path(args.workspace)
    topic = args.topic
    slug = _slugify(args.slug)

    now = dt.datetime.now(dt.timezone.utc)
    day = now.strftime("%Y-%m-%d")
    hhmm = now.strftime("%Y-%m-%d_%H%M")

    template = workspace / "research" / topic / "TEMPLATE.md"
    if not template.exists():
        raise SystemExit(f"template not found: {template}")

    out_dir = workspace / "research" / topic / day
    out_dir.mkdir(parents=True, exist_ok=True)

    out_path = out_dir / f"{hhmm}_{slug}.md"
    if out_path.exists():
        raise SystemExit(f"refusing to overwrite existing file: {out_path}")

    content = template.read_text(encoding="utf-8")
    content = content.replace("<YYYY-MM-DD HH:MM>", now.strftime("%Y-%m-%d %H:%M"))
    content = content.replace("<YYYY-MM-DD HH:MM>", now.strftime("%Y-%m-%d %H:%M"))

    out_path.write_text(content, encoding="utf-8")
    print(str(out_path))


if __name__ == "__main__":
    main()
