# Jev question recipes used by `scripts/jev.py`

Source of truth for the API is <https://docs.typesafe.ai/api.md>; primitives are documented at `/primitives/choice.md`, `/primitives/noul.md`, `/primitives/score.md`. This file records the exact shapes the script sends so thresholds and wording can be tuned without reading the code.

Request envelope (all commands):

```json
{ "state": <string | object>, "model": "jev-latest", "questions": { "<id>": { "type": "...", "instructions": "...", "criteria": ... } } }
```

Response: `answers.<id>` with `noul` (0-1), or `choice` + `probabilities` + `confidence`, or `score` (0..levels-1) + `probabilities` + `legend` + `confidence`; `usage.input_tokens`.

Limits: 32k tokens per request for state + longest question (script budgets 28k for state); Choice <= 255 options; Score 2-10 levels; text only.

## find-lines / filter-search (semantic_find cookbook)

State:

```json
{ "query": "<question>", "document": "L00042|<line text>\nL00043|..." }
```

Questions per window (<= 255 non-empty lines, <= 28k tokens):

- `best` (choice): "Each line of `document` is prefixed with an id and `|`. Which line most directly answers, implements, or is most relevant to `query`? Choose the id." Criteria: `{ "L00042": null, ... }` (ids are self-describing; the text is in state).
- `present` (noul): "Does any line of `document` address `query`?" with `true` = "At least one line states, implements, or directly implies an answer" / `false` = "No line addresses the query; the closest lines are only loosely related."

Composition: `score = present * p(line)`. Choice probabilities sum to 1 inside a window, so across windows they are not comparable; presence-weighting is the cross-window heuristic. The cookbook's alternative for long documents is a two-pass Choice (pick the window, then rank inside it); switch to that if presence-weighting misranks on your files.

Default thresholds (cookbook values, tune on real cases): presence >= 0.70 answered, 0.35-0.70 partial, < 0.35 absent; per-line keep `score >= 0.02`, top 8 (find-lines) / 12 (filter-search); read ranges add 6 lines of context and merge overlaps.

`filter-search` uses the same questions with subject "hit" over `path:line: text` candidates and the presence criteria "at least one hit is the code the query is looking for" / "every hit is a false positive or unrelated mention".

## rank-files (composite-scoring pattern; Score is comparable across requests)

State:

```json
{ "task": "<task description>", "files": { "f001": { "path": "Sources/X.swift", "excerpt": "<signature lines or head>" }, ... } }
```

One Score question per file (state is charged once per request; output tokens are free):

- instructions: "How relevant is the file `files.f001` (path `files.f001.path`, excerpt in `files.f001.excerpt`) to completing `task`? Judge from the excerpt and the path; the excerpt may be only signatures."
- criteria (ordered levels 0-3):
  0. Unrelated: the file does not touch the task's concepts, symbols, or data flow.
  1. Tangential: shares vocabulary or is a distant dependency; reading it would not change how the task is done.
  2. Useful context: defines a type, protocol, or helper the task must use correctly; likely read, unlikely edited.
  3. Central: the task almost certainly requires reading and probably editing this file.

`score` is the probability-weighted level. Default keep >= 1.5; suggest `get_code_structure` for 1.5-2.4 and full read for >= 2.5. Excerpt modes: `signatures` (regex over func/class/struct/def/fn/... lines, falls back to head), `head`, `full`. Batches of 40 files or 28k tokens.

## pick-skill (skill_suggestion cookbook, two stages)

Stage 1 state: `{ "request": "<prompt>", "skills": { "<name>": "<description, truncated to 160 chars>" } }`

- `which` (choice over skill names + `none`): "Which entry in `skills` is the documented procedure the agent should load to handle `request`? Choose `none` if no listed skill applies."
- `acts` (noul): request requires acting on repo/tooling/system rather than only explaining.
- `procedure` (noul): a documented, repository-specific procedure would materially improve handling.
- `prose` (noul): a direct prose answer fully satisfies the request.
- gate = mean(acts, procedure, 1 - prose); proceed only if gate >= 0.30.

Stage 2 state: `{ "request", "candidates": { "<name>": { "description", "excerpt": "<first 700 chars of SKILL.md body>" } } }` for the top 3.

- `rerank` (choice over candidates + `none`).
- `fit_<name>` (noul each): "Does the candidate specifically cover the kind of work described in `request`, such that following it would be appropriate?"
- Recommend the candidate with the highest `fit` if `fit >= 0.30`; otherwise no skill.

Discovery mirrors `AgentSkillCatalog`: `./.agents/skills`, `./.claude/skills`, `~/.agents/skills`, `~/.claude/skills`, plus `--skills-dir`; earlier roots win on name collisions.

## verify-claim (citation_check cookbook)

State: `{ "claim": "<claim>", "source": { "path", "lines": "a-b", "text": "<n|line ...>" } }`

- `supported` (noul): "Does `source.text` (line-numbered) directly support `claim` as stated?" true = "cited lines contain the code or statement the claim describes, with matching names, behavior, and location"; false = "cited lines do not show it, show something materially different, or the claim adds details the source does not contain."
- `elsewhere` (noul): plausible the claim is true but supported outside the cited span.

Verdicts: supported >= 0.70, unsupported <= 0.30, otherwise unclear. High `elsewhere` with low `supported` usually means a wrong line citation rather than a false claim.

## Live calibration (jev-1.13.0, 2026-09-22, this repository)

- Token estimate: tagged Swift source measured ~1.5 chars/token (JSON escaping + indentation), so the script budgets with 1.6 chars/token; a 2,526-line file was 10 windows / 72k input tokens / $0.003 / 3.3 s.
- `find-lines` for "where is --strict-mcp-config appended" ranked the exact line at p=0.98 with window presence 0.97 vs <= 0.06 for the other nine windows; an off-topic query on a 22-line file gave presence 0.02.
- `filter-search` over 50 `rg -n mcpStrictMode` hits kept 2 files / 5 lines and they were the right ones; presence 0.67 read as "partial", so the partial band is doing useful work.
- `pick-skill` chose `rpce-contribution-check` (fit 0.94) for a commit-validation prompt and returned no skill (gate 0.12, none_p 0.66) for a trivia question.
- `verify-claim`: true claim 0.83 supported; fabricated claim 0.02 supported / 0.44 elsewhere.

## Tuning notes

- Keep one condition per Noul; phrase for the affirmative.
- Include a `none` / no-match option whenever nothing may fit.
- Choice/Score `confidence` measures distribution concentration, not correctness; a Noul near 0.5 is a coin flip.
- Record misfires (query, file, expected vs. observed) and adjust wording or thresholds in `jev.py`; re-run the same inputs to confirm.
