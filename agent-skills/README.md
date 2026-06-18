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
