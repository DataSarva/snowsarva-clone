#!/usr/bin/env python3
"""Create a new research note with proper structure."""
import os
import sys
from datetime import datetime, timezone

TOPICS = ["finops", "native-apps", "snowpark", "scs", "governance", "observability"]

def create_research_note(topic, slug):
    """Create a new research note file."""
    if topic not in TOPICS:
        print(f"Error: Unknown topic '{topic}'. Valid topics: {', '.join(TOPICS)}", file=sys.stderr)
        sys.exit(1)

    now = datetime.now(timezone.utc)
    date_str = now.strftime("%Y-%m-%d")
    time_str = now.strftime("%H%M")
    timestamp = now.strftime("%Y-%m-%dT%H:%M:%S")

    base_dir = os.environ.get("WORKSPACE", "/home/ubuntu/.openclaw/workspace")
    topic_dir = os.path.join(base_dir, "research", topic, date_str)
    os.makedirs(topic_dir, exist_ok=True)

    filename = f"{date_str}_{time_str}_{slug}.md"
    filepath = os.path.join(topic_dir, filename)

    # Check if template exists
    template_path = os.path.join(base_dir, "research", topic, "TEMPLATE.md")
    if os.path.exists(template_path):
        with open(template_path, "r") as f:
            content = f.read()
        content = content.replace("{{DATE}}", date_str)
        content = content.replace("{{TIME}}", time_str)
        content = content.replace("{{TIMESTAMP}}", timestamp)
    else:
        content = f"# Research: {topic} - {date_str}\n\n**Time:** {timestamp} UTC\n**Topic:** {topic}\n\n---\n\n"

    with open(filepath, "w") as f:
        f.write(content)

    print(filepath)
    return filepath

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python3 new_research_note.py --topic <topic> --slug <slug>", file=sys.stderr)
        print(f"Valid topics: {', '.join(TOPICS)}", file=sys.stderr)
        sys.exit(1)

    # Parse args
    topic = None
    slug = None
    for i in range(1, len(sys.argv)):
        if sys.argv[i] == "--topic" and i + 1 < len(sys.argv):
            topic = sys.argv[i + 1]
        elif sys.argv[i] == "--slug" and i + 1 < len(sys.argv):
            slug = sys.argv[i + 1]

    if not topic or not slug:
        print("Error: --topic and --slug are required", file=sys.stderr)
        sys.exit(1)

    create_research_note(topic, slug)
