#!/usr/bin/env python3
"""
Create a new research note from template.
"""
import os
import sys
import argparse
from datetime import datetime, timezone
from pathlib import Path

def create_note(topic, slug):
    """Create a new research note from template."""
    workspace = os.environ.get('WORKSPACE', '/home/ubuntu/.openclaw/workspace')
    
    now = datetime.now(timezone.utc)
    date_str = now.strftime('%Y-%m-%d')
    time_str = now.strftime('%H%M')
    
    # Validate topic
    valid_topics = ['finops', 'native-apps', 'snowpark', 'scs', 'governance', 'observability']
    if topic not in valid_topics:
        print(f"Error: Invalid topic '{topic}'. Must be one of: {', '.join(valid_topics)}", file=sys.stderr)
        sys.exit(1)
    
    # Paths
    topic_dir = Path(workspace) / 'research' / topic / date_str
    topic_dir.mkdir(parents=True, exist_ok=True)
    
    template_path = Path(workspace) / 'research' / topic / 'TEMPLATE.md'
    
    # Create default template if it doesn't exist
    if not template_path.exists():
        create_default_template(template_path, topic)
    
    # Generate filename
    safe_slug = ''.join(c if c.isalnum() or c in '-_' else '-' for c in slug.lower())
    filename = f"{date_str}_{time_str}_{safe_slug}.md"
    note_path = topic_dir / filename
    
    # Read template and substitute
    template_content = template_path.read_text()
    note_content = template_content.replace('{{DATE}}', date_str).replace('{{TIME}}', time_str)
    
    # Write note
    note_path.write_text(note_content)
    
    print(str(note_path))
    return str(note_path)

def create_default_template(template_path, topic):
    """Create a default template for a topic."""
    template_content = f'''# Research: {topic.title()} - {{{{DATE}}}}

**Time:** {{{{TIME}}}} UTC  
**Topic:** {topic}  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. **Finding 1**: [Statement with citation]
2. **Finding 2**: [Statement with citation]
3. **Finding 3**: [Statement with citation]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| | | | |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Feature 1**: [Brief description]
2. **Feature 2**: [Brief description]
3. **Feature 3**: [Brief description]

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### [Artifact Name]

```sql
-- Example SQL draft
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| | | |

## Links & Citations

1. [Title](URL) - *Brief description of relevance*
2. [Title](URL) - *Brief description of relevance*
3. [Title](URL) - *Brief description of relevance*

## Next Steps / Follow-ups

- [ ] Action item 1
- [ ] Action item 2
'''
    template_path.parent.mkdir(parents=True, exist_ok=True)
    template_path.write_text(template_content)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Create a new research note from template')
    parser.add_argument('--topic', required=True, help='Research topic (finops, native-apps, snowpark, scs, governance, observability)')
    parser.add_argument('--slug', required=True, help='Short slug for the note filename')
    
    args = parser.parse_args()
    create_note(args.topic, args.slug)
