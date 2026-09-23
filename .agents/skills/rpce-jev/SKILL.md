---
name: rpce-jev
description: Cut agent context-window usage in RepoPrompt CE by delegating relevance judgments to TypeSafe's Jev model via scripts/jev.py. Use before reading a file longer than ~150 lines, before consuming a search with more than ~15 hits, when choosing which candidate files to add to the selection, when deciding whether a skill applies to a prompt, or when spot-checking a file:line claim from an explore probe. Do not use to generate code or text, to replace the Oracle or context_builder for reasoning, or for files that must be read in full anyway.
---

# RepoPrompt CE + Jev (TypeSafe System One)

Jev answers typed questions (choice / yes-no probability / rubric score) over text in ~100 ms at $0.042 per million input tokens and never generates text. The point of this skill is simple: **let Jev read the bulk text and give the agent only ids, line ranges, and probabilities.** Each avoided `read_file` or search dump is a direct token saving in the frontier model's context.

Script: `scripts/jev.py` beside this SKILL.md (Python 3.9+, stdlib only) — `.agents/skills/rpce-jev/scripts/jev.py` when installed in a workspace, `~/.agents/skills/rpce-jev/scripts/jev.py` when installed globally. Recipes and thresholds: `references/question-recipes.md`.

## Setup

```bash
export TYPESAFE_API_KEY=...          # or ~/.jev-key / ~/.config/typesafe/api_key (chmod 600)
# or: security add-generic-password -s TYPESAFE_API_KEY -a "$USER" -w
J() { python3 "$(ls .agents/skills/rpce-jev/scripts/jev.py ~/.agents/skills/rpce-jev/scripts/jev.py 2>/dev/null | head -1)" "$@"; }
J doctor
```

`TYPESAFE_BASE_URL` and `TYPESAFE_DEFAULT_MODEL` (default `jev-latest`) are honored. Never paste the key into prompts, transcripts, or commits; `preflight.sh` secret scanning applies.

## Commands

All commands accept `--json` and end with a `# jev usage:` line (requests, input tokens, cost). `$J` below is the `J` shell function from Setup (workspace copy preferred, global copy otherwise).

| Need | Command | What comes back |
| --- | --- | --- |
| Which lines of a long file matter | `$J find-lines --query "where is the MCP strict-mode flag applied" --file Sources/.../Controller.swift` | presence label, top lines, and ready `read_file start_line/limit` ranges |
| Trim a noisy search | `rg -n "mcpStrictMode" Sources \| $J filter-search --query "where the flag is read from settings"` | hits grouped by path with kept line numbers; presence label |
| Choose files for the selection | `$J rank-files --task "..." Sources/A.swift Sources/B.swift` or `find ... \| $J rank-files --task "..." --from-stdin` | 0-3 relevance score per file and a `manage_selection add` line |
| Should a skill be loaded | `$J pick-skill --prompt "<user request>"` | one `/skill` recommendation or "no skill" |
| Verify a probe's claim | `$J verify-claim --claim "buildArguments appends --strict-mcp-config" --file Sources/.../Controller.swift --lines 1990-2010` | `supported` probability plus `elsewhere` (wrong lines cited) |
| Anything else | `$J ask --state-file s.json --questions-file q.json` | raw API answer |

`find-lines` also takes `--file -` (stdin) and `--start/--end` to scope a range; `filter-search` accepts any grep-style `path:line:text` input (`rg -n`, `grep -n`) or, failing that, ranks arbitrary lines.

## Workflow rules

1. **Before `read_file` on a file over ~150 lines**, run `find-lines` with the actual question you need answered, then read only the returned ranges. If presence is `absent`, do not read the file; search elsewhere.
2. **Before consuming a search with over ~15 hits**, pipe it through `filter-search`. Read only kept paths/lines.
3. **When building a selection from many candidates** (tree walk, `file_search` path results, codemap), use `rank-files` and add only files scoring >= 1.5; consider `get_code_structure` instead of full reads for files scoring 1.5-2.4.
4. **When an explore probe returns `file:line` claims**, run `verify-claim` on load-bearing ones instead of re-reading whole files. `unclear` or `unsupported` means read the span yourself.
5. **Batch, don't loop.** One request over one state is charged once regardless of question count. Prefer `ask` with several questions over several single-question calls. Chunk state under 28k tokens (the script does this for you).
6. **Keep policy in code, judgments in Jev.** Thresholds in the script are cookbook defaults; tune per repository with real cases before trusting them for anything destructive. Jev output is advisory for approvals, deletions, and pushes.

## Interpreting outputs

- `presence` is a Noul: probability that *any* candidate answers the query. >= 0.7 answered, 0.35-0.7 partial, < 0.35 absent. Near 0.5 means "coin flip", not "medium relevance".
- `p` is a Choice probability; it only compares candidates inside one window. `score = presence * p` is the cross-window ranking heuristic.
- `rank-files` scores are rubric positions 0-3 (unrelated / tangential / useful context / central) with a separate `confidence` that measures distribution sharpness, not correctness.
- Typed output guarantees the shape, not the truth. Validate on this repository's data.

## Limits

- Text only; English performs best. 32k-token ceiling per request (state + longest question); Choice max 255 options; Score 2-10 levels.
- Retries with backoff on 429/529/5xx; exits 2 with `jev: ...` on failure. Do not fall back to reading everything silently; report the failure and decide.
- The skill does not change RepoPrompt CE source. Savings depend on following the workflow rules above.

## Measuring savings

Track the `# jev usage:` lines against what you avoided: lines not read (`read_file` ranges vs. file length) and hits not consumed. Record per-session totals in the handoff when the task was context-heavy so follow-up decisions (hooks, MCP server, `file_search` reranking in source) rest on numbers.

## Handoff

Report: which commands were used, presence/score outcomes that changed what you read, any threshold that misfired, and the usage totals.
