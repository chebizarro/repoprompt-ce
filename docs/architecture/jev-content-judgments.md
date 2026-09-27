# Jev content judgments: privacy and egress contract

This document specifies the opt-in content-judgment consumers in the [implementation plan](../plans/jev-content-judgments-2026-09-22.md). The schema and DTO fields can exist before the consumers are wired; an advertised parameter alone does not send data to Jev. This is a separate contract from [Model Routing](model-routing.md): routing does not receive file text, while content judgments intentionally may.

## Consent and authority

Content judgments are **off for every workspace unless explicitly enabled for that workspace**. The optional schema-v11 `contentJudgmentsByWorkspaceID` map has no global default and no inheritance mode: an absent map, absent entry, or unknown workspace ID resolves off. A supplied `semantic_query` or `relevant_to` in a non-opted-in workspace is accepted but silently ignored; the result remains byte-identical to the existing tool reply, with no semantic metadata and no Jev call. Each consumer reads the gate once at the start of its tool invocation, Context Builder run, composer debounce, or approval enrichment. A toggle flipped during a judgment does not revoke that bounded in-flight call; it applies to the next invocation.

Settings must disclose the TypeSafe transfer and link to TypeSafe's privacy policy before a workspace is enabled. **Masking is not anonymization:** sensitive prose, identifiers, or secrets may remain in even a shortened excerpt. Opt-in is consent to send the bounded text below to TypeSafe, not a guarantee that the text is anonymous. Do not log request or response bodies. Never send credentials, environment variables, physical absolute paths, or content from a different workspace merely to improve a judgment. Jev output is advisory; it never becomes authorization or a reason to block ordinary work.

## Egress inventory

Only the following consumer state is eligible to leave the machine for an opted-in workspace. The common request also carries the pinned `jev-1.13.0` model, fixed versioned question wording and criteria, and Bearer authentication to `POST https://api.typesafe.ai/v1/systemone`.

| Consumer | Text sent to TypeSafe | Local limits and application |
| --- | --- | --- |
| `file_search` | The caller's `semantic_query`; a bounded prefix of result matches as logical/display path, line number, and at most 400 characters of line text per match; opaque match IDs. No physical paths or unreturned files. | At most 255 content matches that fit one 45,000-character state; one Choice ranking question plus one Noul presence question; 2-second budget. A partial prefix rerank leaves the rest in original order. Ordering happens before the existing approximately 48,000-character result cap. `count_only`, zero matches, and one match make no call. |
| `read_file` | The caller's `relevant_to`; text already in the requested/projected read, tagged with window and 1-based line IDs. No second file read. | Only a valid-text read fitting one 45,000-character / approximately 28,000-token state is judged. Windows are at most 128 lines and at most 255 Choice criteria. Presence questions use up to 1.2 seconds, followed by Choice line questions using the remainder of a 2-second total budget (nominally 0.8 seconds). Over-budget reads return the original full read. |
| Context Builder pre-pass (follow-up PR) | The current task prompt and, for selected candidate files only, logical/display path plus the first 40 lines of each file. | At most two batches of 40 files; 3 seconds per batch. Files beyond 80, binary, or empty are unranked; this is not a whole-repository upload. The result is only a `Likely relevant files` hint in the discovery message. |
| Composer skill suggestion (follow-up PR) | Current draft text; at most 30 skill names and descriptions truncated to 160 characters each; only if stage one qualifies, the top candidate's first 700 characters of `SKILL.md` body. | Runs after 600 ms idle, with 1.5 seconds per stage. Slash commands, an already resolved skill, empty drafts, and empty catalogs make no call. No skill is auto-loaded and submission never waits for the suggestion. |
| Approval advisory (follow-up PR) | The pending approval's method/kind, command, reason, and already displayed detail strings. | One Noul question within 1.5 seconds. Never send `proposedExecpolicyAmendmentJSON`, `grantRoot`, or `cwd` beyond text already present in displayed details. The result can only add a “Possibly irreversible” badge; it cannot alter buttons, permission persistence, or the decision path. |

The search and read tools use only the invocation's already-scoped results. For multi-root workspaces the gate is still per-workspace, while paths in Jev state are logical/display paths, not physical paths.

## Versioned local policy

Every wording, threshold, or chunking change advances the affected policy version; DTO metadata, the DEBUG ledger, and applicable session audit rows carry that version.

| Consumer | Policy version | Initial threshold or output rule |
| --- | --- | --- |
| Search | `jev-1.13.0-rpce-content-file-search-v1` | Stable probability sort of judged matches; partial or unjudged matches retain linear order. Presence is reported, not used to suppress results. |
| Read | `jev-1.13.0-rpce-content-read-file-v1` | Presence ≥0.70 keeps a window, optionally trimmed to best line ±32; 0.35–<0.70 keeps best line ±16 or the whole window without Choice; <0.35 drops it. Invalid presence counts below 0.35. No qualifying window returns the full read. |
| Context Builder | `jev-1.13.0-rpce-content-context-builder-v1` | Weighted score ≥2.5 lists at most 10 central files; 1.5–<2.5 lists at most 15 useful-context files. |
| Skill suggestion | `jev-1.13.0-rpce-content-skill-suggestion-v1` | Stage-one gate ≥0.30, non-`none` Choice probability ≥0.40, and stage-two fit ≥0.30. |
| Approval advisory | `jev-1.13.0-rpce-content-approval-advisory-v1` | Irreversibility Noul ≥0.70 attaches only the badge, guarded by the same pending request ID and waiting state. |

The shared batch rejects an empty state, a state above the caller's 45,000-character budget, more than 255 Choice criteria, or a Score question outside 2–10 levels. The service also has a **per-process sliding five-minute egress ceiling of 60 requests or 2,000,000 submitted state characters**. Crossing either limit makes no network call and fails open locally; it is not a remote quota or a promise of billing cost.

## Fail-open and observable results

Credential absence, invalidation, network errors, rate limits, overload, decoding errors, cancellation, local rate limiting, and whole-call timeout retain the old result path: linear search order, full read, no Context Builder section, no skill chip, or no approval badge. There is no RepoPrompt-layer retry or interactive key prompt from a tool. A read whose presence call succeeds but Choice times out may keep whole qualifying windows; if presence fails or no window qualifies it returns the full read. Valid partial answers may rank or keep what was judged while leaving the rest in its original or unranked state. A windowed read includes ordered, merged 1-based `line_ranges`, original `total_lines`, and an elision marker between disjoint ranges; `first_line`/`last_line` describe the overall selected span and must satisfy the existing read-file line-metadata validator.

Tool DTO metadata is optional and omitted when disabled. Search reports `semantic_rerank` with applied/reason, presence, Jev input tokens, judged/reordered match counts, prioritized characters, and policy version. Read reports `semantic_filter` with applied/reason, Jev input tokens, considered/kept window counts, and policy version, plus `relevant_to` and `line_ranges` when filtered. Read-side estimated bytes avoided are original UTF-8 content bytes minus returned UTF-8 content bytes; search does not invent a bytes-saved figure from a reorder.

The DEBUG-only JSONL ledger, when explicitly enabled, records **metadata, never file text**: timestamp, consumer, outcome, input/output token counts, latency, optional read bytes-avoided estimate, question count, and policy version. It is written with `0600` permissions and should be reviewed before sharing. Release builds do not emit the ledger; shipping observations are DTO metadata and Agent Mode audit rows. The latter are bounded to 128 per session and contain only consumer, policy version, decision, optional chosen skill name or `possiblyIrreversible` key, probability, input tokens, latency, and whether a chip/badge was applied—never prompts, file text, commands, or response bodies. Tool consumers have no owning Agent Mode turn and do not write a session audit row.

## Deferred design work

The Jev client and credential service stay in `Features/AgentMode/Routing/Backends/Jev/`, following the existing Auto effort consumer. A later, separately reviewed lift to `Infrastructure/AI/` may become worthwhile once three or more feature areas consume them; this change does not move or duplicate those owners.

Search uses one budget-fitted prefix rather than semantic-find multi-window composition. Cross-window presence/ranking for very large search result sets, as well as multi-request chunking for over-budget reads, is future work only; it would need new egress and policy-version review.
