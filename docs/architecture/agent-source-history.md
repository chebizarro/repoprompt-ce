# Durable Agent chat source history

`agent_manage` operation `get_source_history` is an additive, read-only session-control surface. It uses the same administrative/direct-child authorization policy as `get_log`, **before** hydration, bootstrap, persistence, or cursor resolution. Existing log and handoff projections are unchanged.

The session JSON retains `sourceHistory` independently of the display transcript. Canonical source-item UUIDs identify occurrences; first-capture ordinals do not change. Only user/assistant/assistantInline text is captured. Tools, reasoning, attachments, system rows, attribution metadata, and errors are not exported. Missing rows do not delete captured history. Prefix extensions are stored as UTF-8 append patches, other edits as replacement patches; streaming-state-only changes also receive a revision. Every exposed live head must already have passed required session persistence. Full session writes serialize lineage reconciliation through atomic replacement and deletion fences, preserving longer compatible histories and refusing divergent ones.

New sessions report `complete_since_creation`. Legacy files bootstrap actual retained source rows before normalization and report `retained_at_upgrade`; this **does not** reconstruct already-compacted chat or promise complete pre-upgrade history. A version-10 full session with a missing feed, an unsupported schema, role-changing occurrence, or divergent lineage is an error, not a new history.

## Wire contract

Use the Interlocutor generic command when needed:

```text
/call agent_manage {"op":"get_source_history","session_id":"<UUID>","limit":100,"max_bytes":1048576}
```

- Omit both `cursor` and `after_revision` for a snapshot.
- Supply `after_revision` (nonnegative integer) for changes after a consumed head.
- Continue with the returned opaque `cursor`; do not combine it with `after_revision`.
- `limit` is 1–256. `max_bytes` is 1024–8388608 and counts actual UTF-8 JSON bytes, including escaping and continuation metadata, excluding MCP framing.

Response fields: `version` (1), `session_id`, `feed_id`, `coverage`, `view` (`snapshot`/`changes`), `head_revision`, optional `after_revision`, `records`, optional `next_cursor`, `complete`.

Each record contains `occurrence_id`, `ordinal`, `kind`, **complete exact** `text`, `revision`, and `is_streaming`. Snapshot order is ordinal; changes order is last revision and coalesces an occurrence's edits within the fixed window. A window's head is frozen in the cursor; later capture and app restarts cannot alter those pages because patch history remains durable. Cursors bind session, feed lineage, head, view/lower revision, and position. They are continuation tokens, not authorization. Invalid cursors never restart at the beginning.

`complete` is true exactly when no next cursor exists. A record that does not fit fails; text is not truncated and no cursor is advanced past an omitted record. Empty completed change windows are valid, including head zero.

## Consumer and migration boundaries

Interlocutor v3 consumes source occurrence/revision pairs, not turn ordinals or rendered XML fingerprints. It freezes publication decisions and chunks before delivery, and commits observation progress only after relay acknowledgments or exact, EOSE-complete recovery probes. User messages remain limited to the new-channel initial frozen snapshot; later input is not echoed. Edits to observed assistant occurrences are labelled updated text, while identical text/state-only revisions advance silently.

Legacy delivery history is not erased by this protocol. Migration requires an exact current legacy prefix plus a complete order-preserving bridge into the source snapshot. Pending legacy output first completes under its original tags and ACK/probe rules. A source API upgrade alone cannot prove an already-lost old boundary. Ambiguous migration refuses, retains old bytes, and requires independent source evidence or a separately approved lossy baseline. No automatic reset, whole-history replay, or approval/completion inference is permitted.

Deploy the source application before the new consumer. Unsupported servers produce an explicit compatibility failure, not an XML fallback. Downgrade is not continuity-safe: older applications may remove additive session data, and older Interlocutor versions reject v3 checkpoints. Keep backups and never silently replace a changed/missing feed lineage.
