#!/usr/bin/env bash
#
# convert-skills.sh — generate a portable copy of the Claude `skills/` tree that
# works as-is with OpenAI Codex (~/.agents/skills/), Google Antigravity (workspace
# skills/), Cursor, and any other agent that adopts the SKILL.md format.
#
# The SKILL.md format (name + description frontmatter + reference files) is already
# identical across these tools, so the only work is scrubbing Claude-specific
# references from the prose. This script is idempotent.
#
# Usage:  scripts/convert-skills.sh [SRC_DIR] [OUT_DIR]
#   SRC_DIR  default: skills
#   OUT_DIR  default: agent-skills
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$ROOT/skills}"
OUT="${2:-$ROOT/agent-skills}"

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: source skills dir not found: $SRC" >&2
  exit 1
fi

echo "Converting skills"
echo "  from: $SRC"
echo "  to:   $OUT"

rm -rf "$OUT"
mkdir -p "$OUT"

# Walk every markdown file, scrub Claude-specific references, preserve structure.
count=0
while IFS= read -r -d '' f; do
  rel="${f#"$SRC"/}"
  dest="$OUT/$rel"
  mkdir -p "$(dirname "$dest")"
  # Scrubs (order matters; specific before general). Replacements start with a
  # consonant so a preceding indefinite article ("a Claude Code ...") stays
  # grammatical. NOTE: avoid \b — BSD/macOS sed does not support it.
  #   [[wikilink]]        -> wikilink                 (Claude auto-memory cross-links)
  #   Claude-in-Chrome    -> automated browser tools  (Claude browser MCP)
  #   Claude Code         -> coding agent             (the CLI product)
  #   Claude              -> the agent                (catch-all safety net)
  sed -E \
    -e 's/\[\[([^]]*)\]\]/\1/g' \
    -e 's/Claude-in-Chrome/automated browser tools/g' \
    -e 's/Claude Code/coding agent/g' \
    -e 's/Claude/the agent/g' \
    "$f" > "$dest"
  count=$((count + 1))
done < <(find "$SRC" -type f -name '*.md' -print0)

# Copy any non-markdown assets (scripts, references) verbatim.
while IFS= read -r -d '' f; do
  rel="${f#"$SRC"/}"
  dest="$OUT/$rel"
  mkdir -p "$(dirname "$dest")"
  cp "$f" "$dest"
done < <(find "$SRC" -type f ! -name '*.md' -print0)

# Drop a short README into the portable tree.
cat > "$OUT/README.md" <<'EOF'
# agent-skills — portable skills for Codex / Antigravity / Cursor

Generated from `../skills/` by `../scripts/convert-skills.sh`. Same `SKILL.md`
format Claude uses (name + description frontmatter + reference files); the only
difference is that Claude-specific references have been scrubbed.

## Install

**OpenAI Codex** — copy each skill folder into your global skills dir:
```bash
mkdir -p ~/.agents/skills
cp -R salesforce-* ~/.agents/skills/
```
Codex auto-loads a skill when your task matches its `description` (implicit), or
you can name it in your prompt (explicit). See
https://developers.openai.com/codex/skills

**Google Antigravity** — copy the folders into a `skills/` directory in your
workspace (or your `.agents/` directory). Antigravity loads a skill by
description match. See
https://codelabs.developers.google.com/getting-started-with-antigravity-skills

**Cursor / other AGENTS.md tools** — point them at this directory, or rely on the
root `AGENTS.md` for always-on context.

## Note

These skills are DX-first: they describe the `sf` CLI, metadata, and MCP paths
and avoid UI automation. They are product-agnostic and reusable for any
Salesforce build, not just this repo.
EOF

echo "Done: $count markdown skill file(s) converted into $OUT"
