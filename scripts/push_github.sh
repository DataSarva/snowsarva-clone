#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/home/ubuntu/.openclaw/workspace"
REMOTE_URL="https://github.com/DataSarva/snowsarva-clone.git"

cd "$REPO_DIR"

# Ensure git repo exists
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Not a git repo: $REPO_DIR" >&2
  exit 1
fi

# If no changes, do nothing
if [[ -z "$(git status --porcelain)" ]]; then
  exit 0
fi

# Commit changes with a timestamped message
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

git add -A
# Allow empty? No; we already checked status.
git commit -m "auto: research sync ${TS}" >/dev/null

# Configure remote without leaking token in logs
TOKEN=${GITHUB_TOKEN:-}
if [[ -z "$TOKEN" ]]; then
  echo "GITHUB_TOKEN not set" >&2
  exit 2
fi

# Temporarily set a token-authenticated remote URL
AUTH_URL="https://x-access-token:${TOKEN}@github.com/DataSarva/snowsarva-clone.git"

# Create origin if missing
if ! git remote get-url origin >/dev/null 2>&1; then
  git remote add origin "$REMOTE_URL" >/dev/null
fi

# Set auth url, push, then revert to clean url
OLD_URL=$(git remote get-url origin)
git remote set-url origin "$AUTH_URL"

# Push to main (create/switch branch if needed)
BRANCH=$(git branch --show-current)
if [[ -z "$BRANCH" ]]; then
  BRANCH=main
fi
if [[ "$BRANCH" != "main" ]]; then
  git branch -M main >/dev/null
fi

git push -u origin main >/dev/null

# Restore clean remote URL (no token stored)
git remote set-url origin "$REMOTE_URL"

# Safety: also restore previous if it was non-standard
# (optional; keep clean remote)
exit 0
