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
# The script is executable: call it by path, or define a shell FUNCTION (not a variable):
J() { python3 "$(ls .agents/skills/rpce-jev/scripts/jev.py ~/.agents/skills/rpce-jev/scripts/jev.py 2>/dev/null | head -1)" "$@"; }
```

Do not run `doctor` routinely; it is a connectivity check for when a call fails with an auth or network error. In zsh, `J="python3 …/jev.py"; $J …` fails with exit 127 because zsh does not word-split variables — use the function above or the script path directly.

`TYPESAFE_BASE_URL` and `TYPESAFE_DEFAULT_MODEL` (default `jev-latest`) are honored. Never paste the key into prompts, transcripts, or commits; `preflight.sh` secret scanning applies.

## Commands

All commands accept `--json` (before or after the subcommand) and otherwise end with a `# jev usage:` line (requests, input tokens, cost). `$J` below is the `J` shell function from Setup (workspace copy preferred, global copy otherwise).

| Need | Command | What comes back |
| --- | --- | --- |
| Which lines of a long file matter | `$J find-lines --query "where is the MCP strict-mode flag applied" --file Sources/.../Controller.swift` | presence label, top lines, and ready `read_file start_line/limit` ranges |
| Trim a noisy search | `rg -n "mcpStrictMode" Sources \| $J filter-search --query "where the flag is read from settings"` | hits grouped by path with kept line numbers; presence label |
| Choose files for the selection | `$J rank-files --task "..." Sources/A.swift Sources/B.swift` or `find ... \| $J rank-files --task "..." --from-stdin` | 0-3 relevance score per file and a `manage_selection add` line |
| Should a skill be loaded | `$J pick-skill --prompt "<user request>"` | one `/skill` recommendation or "no skill" |
| Verify a probe's claim | `$J verify-claim --claim "buildArguments appends --strict-mcp-config" --file Sources/.../Controller.swift --lines 1990-2010` | `supported` probability plus `elsewhere` (wrong lines cited) |
| Anything else | `$J ask --state-file s.json --questions-file q.json` | raw API answer |
| Is it being used / saving anything | `$J ledger --since 7d` (no API call) | calls by command, Jev cost, lines judged vs. returned, hook nudges, recent failures |

`find-lines` also takes `--file -` (stdin) and `--start/--end` to scope a range; `filter-search` accepts any grep-style `path:line:text` input (`rg -n`, `grep -n`) or, failing that, ranks arbitrary lines.

## Workflow rules

1. **Before `read_file` on a file over ~150 lines**, run `find-lines` with the actual question you need answered, then read only the returned ranges. If presence is `absent`, do not read the file; search elsewhere. Files under ~150 lines: just read them — a judgment costs a turn and saves nothing.
2. **A `find-lines` result replaces the full read; it does not precede one.** Do not fall back to reading the whole file afterwards unless the returned ranges demonstrably did not answer the question (presence `partial`, or the hits were the wrong symbol) — then widen with `--start/--end`, re-query with better wording, or read the file and say in your reply why the judgment was insufficient. Reading the whole file after a judgment is the single largest source of waste measured in the field.
3. **Before consuming a search with over ~15 hits**, pipe it through `filter-search`. Read only kept paths/lines.
4. **When building a selection from many candidates** (tree walk, `file_search` path results, codemap), use `rank-files` and add only files scoring >= 1.5; consider `get_code_structure` instead of full reads for files scoring 1.5-2.4.
5. **When an explore probe returns `file:line` claims**, run `verify-claim` on load-bearing ones instead of re-reading whole files. `unclear` or `unsupported` means read the span yourself.
6. **Batch, don't loop.** One request over one state is charged once regardless of question count. Prefer `ask` with several questions over several single-question calls. Chunk state under 28k tokens (the script does this for you).
7. **Keep policy in code, judgments in Jev.** Thresholds in the script are cookbook defaults; tune per repository with real cases before trusting them for anything destructive. Jev output is advisory for approvals, deletions, and pushes.

## Interpreting outputs

- `presence` is a Noul: probability that *any* candidate answers the query. >= 0.7 answered, 0.35-0.7 partial, < 0.35 absent. Near 0.5 means "coin flip", not "medium relevance".
- `p` is a Choice probability; it only compares candidates inside one window. `score = presence * p` is the cross-window ranking heuristic.
- `rank-files` scores are rubric positions 0-3 (unrelated / tangential / useful context / central) with a separate `confidence` that measures distribution sharpness, not correctness.
- Typed output guarantees the shape, not the truth. Validate on this repository's data.

## Limits

- Text only; English performs best. 32k-token ceiling per request (state + longest question); Choice max 255 options; Score 2-10 levels.
- Retries with backoff on 429/529/5xx; exits 2 with `jev: ...` on failure. Do not fall back to reading everything silently; report the failure and decide.
- The skill does not change RepoPrompt CE source. Savings depend on following the workflow rules above.

## Automatic pickup

- **Codex** (RepoPrompt CE Agent Mode) lists installed skills in its system message, so it discovers `rpce-jev` from `~/.agents/skills` on its own.
- **Claude Code and the RepoPrompt CE Claude provider** only load a skill on `/rpce-jev` or a description match. For automatic pickup run `jev.py install-claude-hooks` once; it merges two command hooks into `~/.claude/settings.json` (backup written alongside, `--uninstall` reverses it):
  - `SessionStart` prints a two-sentence reminder into context.
  - `PreToolUse` on `Read` / `read_file` denies, **once per file per session**, a read of a file over `JEV_HOOK_MIN_LINES` (150) lines that has no range, with the exact `find-lines` command to run instead. Repeating the same read is allowed and recorded, so the ledger shows how often the nudge was overridden. `JEV_HOOK_DISABLE=1` turns it off. Hooks make no API calls and fail open.

## Measuring savings

Every invocation and hook event appends one line to `~/.local/state/rpce-jev/ledger.jsonl` (override with `JEV_LEDGER_PATH` / `JEV_STATE_DIR`; disable with `JEV_LEDGER=0`). The ledger is bounded: at `JEV_LEDGER_MAX_BYTES` (8 MiB, roughly a year of heavy use) it rotates to `ledger.1.jsonl` and one rotation is kept. Records carry command, outcome, Jev requests/tokens/cost, harness (claude/codex), repo, and for `find-lines` the file length versus lines returned — so `jev.py ledger --since 7d` answers "is it used, what did it cost, what fraction of judged lines reached the agent, how often was the hook nudge overridden" without transcript archaeology. Use `--json` for dashboards and `--tail N` for raw records.

## Handoff

Report: which commands were used, presence/score outcomes that changed what you read, any threshold that misfired, and the usage totals.
