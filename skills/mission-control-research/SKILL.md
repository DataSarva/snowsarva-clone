---
name: mission-control-research
description: Create structured, timestamped research notes for Snow’s 24/7 Snowflake FinOps + Native Apps work. Use whenever Snow is doing research/exploration, reading docs/release notes, synthesizing best practices, or planning features/architecture for the Snowflake FinOps Native App. Produces durable artifacts under /research/<topic>/<YYYY-MM-DD>/... and keeps assumptions/risks explicit.
metadata: {"openclaw":{"always":true}}
---

# Mission Control Research

## Goal
Turn “research” into **durable, searchable artifacts** so the system has continuity and we can build from facts (not vibes).

## Required output (every research session)
When you do any non-trivial research, you MUST produce a new note file:

`{workspace}/research/<topic>/<YYYY-MM-DD>/<YYYY-MM-DD_HHMM>_<slug>.md`

Topics (pick one primary):
- `finops`
- `native-apps`
- `snowpark`
- `scs`
- `governance`
- `observability`

Use the matching template at:
`{workspace}/research/<topic>/TEMPLATE.md`

## Workflow (do this, every time)
1) **Choose the topic** (single primary lane).
2) **Create the note file** (preferred: deterministic script):
   - Run: `python3 {baseDir}/scripts/new_research_note.py --topic <topic> --slug <short-slug>`
   - It prints the created path. Write your content there.
3) **Fill the template with real content**:
   - “Accurate takeaways”: plain statements that can be validated.
   - “Snowflake objects & data sources”: name concrete views/tables and whether they are ACCOUNT_USAGE vs ORG_USAGE vs INFORMATION_SCHEMA; mark unknowns.
   - “MVP features unlocked”: 1–3 PR-sized ideas that can be shipped.
   - “Risks / assumptions”: list what could be wrong or environment-dependent.
   - “Links”: cite sources.
4) **Update running memory** (lightweight): append 1–2 bullets to `memory/YYYY-MM-DD.md`.
5) **Optionally update SKILLS.md** if you learned a new stable capability/constraint that should change how we work.

## Quality bar (accuracy)
- Prefer Snowflake docs + authoritative sources.
- If unsure, write it as an assumption or a question.
- Avoid broad claims without a cited link or a clearly labeled inference.

## Bundled resources
### scripts/
- `new_research_note.py` scaffolds new research notes from templates with timestamped paths.
