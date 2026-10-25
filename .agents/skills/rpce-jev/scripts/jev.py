#!/usr/bin/env python3
"""jev.py - TypeSafe/Jev judgment helper for RepoPrompt CE agents.

Principle: Jev reads the bulk text; the agent receives only ids, line ranges,
and probabilities. Every subcommand ends with a `# jev usage:` line so savings
can be measured against the tokens the agent would otherwise have read.

Stdlib only. Requires TYPESAFE_API_KEY (env, ~/.jev-key, ~/.config/typesafe/api_key,
or the macOS Keychain generic password service "TYPESAFE_API_KEY").

Subcommands:
  find-lines     rank lines of one file (or stdin) against a query
  filter-search  rerank grep-style `path:line:text` hits and group by path
  rank-files     score candidate files for relevance to a task (0-3 rubric)
  pick-skill     suggest one installed skill for a prompt, or none
  verify-claim   probability that a source span supports a claim
  ask            raw System One request from JSON files
  doctor         check credentials and connectivity
  ledger         summarize the local usage ledger (no API call)
  hook           Claude Code hook entry points (session-start, pre-read)
  install-claude-hooks  wire the hooks into ~/.claude/settings.json

Every invocation appends one line to a bounded local ledger
(~/.local/state/rpce-jev/ledger.jsonl, rotated at JEV_LEDGER_MAX_BYTES with one
backup) so usage and savings can be read with `jev.py ledger` instead of mined
from transcripts. Set JEV_LEDGER=0 to disable.
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import platform
import re
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable

DEFAULT_BASE_URL = "https://api.typesafe.ai"
DEFAULT_MODEL = "jev-latest"
ENDPOINT = "/v1/systemone"
MAX_CHOICE_OPTIONS = 255
# Docs: 32k tokens for state + longest question; leave headroom for questions.
STATE_TOKEN_BUDGET = 28_000
# Measured live on tagged Swift source (JSON-escaped, indented): ~1.5 chars/token.
CHARS_PER_TOKEN = 1.6
PRICE_PER_MILLION_INPUT_TOKENS = 0.042
KEY_FILES = (Path.home() / ".jev-key", Path.home() / ".config" / "typesafe" / "api_key")
SKILL_ROOTS = (".agents/skills", ".claude/skills")


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, "") or default)
    except ValueError:
        return default


STATE_DIR = Path(os.environ.get("JEV_STATE_DIR") or (Path.home() / ".local" / "state" / "rpce-jev"))
LEDGER_PATH = Path(os.environ.get("JEV_LEDGER_PATH") or (STATE_DIR / "ledger.jsonl"))
LEDGER_MAX_BYTES = _env_int("JEV_LEDGER_MAX_BYTES", 8 * 1024 * 1024)  # one rotation kept => <= 2x this on disk
NUDGE_STATE_PATH = STATE_DIR / "nudges.json"
HOOK_MIN_LINES = _env_int("JEV_HOOK_MIN_LINES", 150)
HOOK_MAX_COUNT_BYTES = 4 * 1024 * 1024  # above this, assume "long" without counting lines
HOOK_SKIP_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".pdf", ".ipynb", ".zip", ".gz", ".tar", ".bin", ".dylib", ".so", ".o", ".a", ".wasm", ".sqlite", ".db"}
SCRIPT_PATH = Path(__file__).resolve()


class JevError(RuntimeError):
    pass


# --------------------------------------------------------------------------- client


def resolve_api_key() -> str:
    key = os.environ.get("TYPESAFE_API_KEY", "").strip()
    if key:
        return key
    for key_file in KEY_FILES:
        if key_file.is_file():
            key = parse_key_file(key_file.read_text(encoding="utf-8"))
            if key:
                return key
    if platform.system() == "Darwin":
        try:
            out = subprocess.run(
                ["security", "find-generic-password", "-s", "TYPESAFE_API_KEY", "-w"],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
            if out.returncode == 0 and out.stdout.strip():
                return out.stdout.strip()
        except (OSError, subprocess.SubprocessError):
            pass
    raise JevError(
        "No TypeSafe API key. Set TYPESAFE_API_KEY, write it to "
        f"{KEY_FILES[0]} or {KEY_FILES[1]} (chmod 600), or add a Keychain item: "
        "security add-generic-password -s TYPESAFE_API_KEY -a \"$USER\" -w"
    )


def parse_key_file(text: str) -> str:
    """Accept a bare key or dotenv-style lines such as `export TYPESAFE_API_KEY=...`."""
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].strip()
        name, sep, value = line.partition("=")
        if sep and name.strip().upper() in ("TYPESAFE_API_KEY", "JEV_API_KEY"):
            return value.strip().strip("\"'")
        if not sep:
            return line
    return ""


def estimate_tokens(text: str) -> int:
    return max(1, int(len(text) / CHARS_PER_TOKEN))


class JevClient:
    def __init__(self, api_key: str, base_url: str, model: str, timeout: float = 30.0, max_attempts: int = 4):
        self.api_key = api_key
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.timeout = timeout
        self.max_attempts = max_attempts
        self.requests = 0
        self.input_tokens = 0
        self.output_tokens = 0
        self.elapsed = 0.0

    def ask(self, state: Any, questions: dict[str, dict[str, Any]]) -> dict[str, Any]:
        payload = {"state": state, "model": self.model, "questions": questions}
        body = json.dumps(payload).encode("utf-8")
        url = self.base_url + ENDPOINT
        delay = 1.0
        for attempt in range(1, self.max_attempts + 1):
            request = urllib.request.Request(
                url,
                data=body,
                method="POST",
                headers={
                    "Authorization": f"Bearer {self.api_key}",
                    "Content-Type": "application/json",
                    "User-Agent": "rpce-jev/1.0",
                },
            )
            started = time.monotonic()
            try:
                with urllib.request.urlopen(request, timeout=self.timeout) as response:
                    data = json.loads(response.read().decode("utf-8"))
            except urllib.error.HTTPError as error:
                text = error.read().decode("utf-8", errors="replace")
                retryable = error.code in (429, 529) or error.code >= 500
                if retryable and attempt < self.max_attempts:
                    time.sleep(delay)
                    delay *= 2
                    continue
                raise JevError(f"HTTP {error.code} from {url}: {text[:600]}") from None
            except (urllib.error.URLError, TimeoutError, OSError) as error:
                if attempt < self.max_attempts:
                    time.sleep(delay)
                    delay *= 2
                    continue
                raise JevError(f"Network error talking to {url}: {error}") from None
            self.elapsed += time.monotonic() - started
            usage = data.get("usage") or {}
            self.requests += 1
            self.input_tokens += int(usage.get("input_tokens") or 0)
            self.output_tokens += int(usage.get("output_tokens") or 0)
            if "answers" not in data:
                raise JevError(f"Unexpected response shape: {json.dumps(data)[:600]}")
            return data
        raise JevError("Exhausted retries")

    def usage_line(self) -> str:
        cost = self.input_tokens / 1_000_000 * PRICE_PER_MILLION_INPUT_TOKENS
        return (
            f"# jev usage: requests={self.requests} input_tokens={self.input_tokens} "
            f"cost_usd={cost:.6f} model={self.model} elapsed_s={self.elapsed:.2f}"
        )

    def usage_dict(self) -> dict[str, Any]:
        return {
            "requests": self.requests,
            "input_tokens": self.input_tokens,
            "output_tokens": self.output_tokens,
            "cost_usd": round(self.input_tokens / 1_000_000 * PRICE_PER_MILLION_INPUT_TOKENS, 6),
            "model": self.model,
            "elapsed_s": round(self.elapsed, 3),
        }


# --------------------------------------------------------------------------- helpers


def read_text(path: str) -> str:
    if path == "-":
        return sys.stdin.read()
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError:
        raise JevError(missing_file_message(path)) from None
    except IsADirectoryError:
        raise JevError(f"{path} is a directory, not a file") from None
    except OSError as error:
        raise JevError(f"cannot read {path}: {error.strerror or error}") from None


def missing_file_message(path: str) -> str:
    """Explain a missing path and suggest nearby files so the caller can self-correct."""
    target = Path(path)
    parent = target.parent if str(target.parent) else Path(".")
    msg = f"file not found: {path} (cwd: {Path.cwd()})"
    if not parent.is_dir():
        return msg + f"; directory {parent} does not exist"
    try:
        names = sorted(p.name for p in parent.iterdir() if p.is_file())
    except OSError:
        return msg
    stem = target.stem.lower()
    close = difflib.get_close_matches(target.name, names, n=5, cutoff=0.5)
    contains = [n for n in names if stem and stem in n.lower() and n not in close]
    suggestions = (close + contains)[:5]
    if suggestions:
        msg += "; did you mean: " + ", ".join(str(parent / n) for n in suggestions)
    return msg


def chunk_candidates(
    candidates: list[tuple[str, str]],
    max_options: int = MAX_CHOICE_OPTIONS,
    token_budget: int = STATE_TOKEN_BUDGET,
) -> list[list[tuple[str, str]]]:
    """Split (id, text) candidates into windows that respect option and token caps."""
    windows: list[list[tuple[str, str]]] = []
    current: list[tuple[str, str]] = []
    current_tokens = 0
    for candidate_id, text in candidates:
        tokens = estimate_tokens(f"{candidate_id}|{text}\n")
        if current and (len(current) >= max_options or current_tokens + tokens > token_budget):
            windows.append(current)
            current, current_tokens = [], 0
        current.append((candidate_id, text))
        current_tokens += tokens
    if current:
        windows.append(current)
    return windows


def rank_candidates(
    client: JevClient,
    query: str,
    candidates: list[tuple[str, str]],
    presence_true: str,
    presence_false: str,
    subject: str = "line",
) -> tuple[dict[str, dict[str, float]], list[float]]:
    """Choice + presence Noul per window (semantic_find cookbook).

    Returns ({id: {p, presence, score}}, [presence per window]). Choice
    probabilities only compare within a window, so the cross-window score is
    presence * p; treat it as a ranking heuristic, not a calibrated probability.
    """
    results: dict[str, dict[str, float]] = {}
    presences: list[float] = []
    for window in chunk_candidates(candidates):
        document = "\n".join(f"{cid}|{text}" for cid, text in window)
        state = {"query": query, "document": document}
        questions = {
            "best": {
                "type": "choice",
                "instructions": (
                    f"Each {subject} of `document` is prefixed with an id and `|`. "
                    f"Which {subject} most directly answers, implements, or is most relevant to `query`? "
                    "Choose the id."
                ),
                "criteria": {cid: None for cid, _ in window},
            },
            "present": {
                "type": "noul",
                "instructions": f"Does any {subject} of `document` address `query`?",
                "criteria": {"true": presence_true, "false": presence_false},
            },
        }
        answers = client.ask(state, questions)["answers"]
        probabilities = answers["best"].get("probabilities") or {}
        presence = float(answers["present"].get("noul") or 0.0)
        presences.append(presence)
        for cid, _ in window:
            p = float(probabilities.get(cid) or 0.0)
            results[cid] = {"p": p, "presence": presence, "score": presence * p}
    return results, presences


def presence_label(value: float, high: float, low: float) -> str:
    if value >= high:
        return "answered"
    if value >= low:
        return "partial"
    return "absent"


def merge_ranges(line_numbers: Iterable[int], context: int, max_line: int) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    for line in sorted(set(line_numbers)):
        start, end = max(1, line - context), min(max_line, line + context)
        if ranges and start <= ranges[-1][1] + 1:
            ranges[-1] = (ranges[-1][0], max(ranges[-1][1], end))
        else:
            ranges.append((start, end))
    return ranges


def emit(
    args: argparse.Namespace,
    client: JevClient,
    payload: dict[str, Any],
    text_lines: list[str],
    detail: dict[str, Any] | None = None,
) -> None:
    args.ledger_detail = detail
    if args.json:
        payload["usage"] = client.usage_dict()
        print(json.dumps(payload, indent=2))
    else:
        for line in text_lines:
            print(line)
        print(client.usage_line())


# --------------------------------------------------------------------------- find-lines


def cmd_find_lines(args: argparse.Namespace, client: JevClient) -> None:
    text = read_text(args.file)
    lines = text.splitlines()
    total = len(lines)
    lo = max(1, args.start or 1)
    hi = min(total, args.end or total)
    candidates = [(f"L{n:05d}", lines[n - 1].rstrip()) for n in range(lo, hi + 1) if lines[n - 1].strip()]
    if not candidates:
        raise JevError("No non-empty lines to rank")
    results, presences = rank_candidates(
        client,
        args.query,
        candidates,
        presence_true="At least one line states, implements, or directly implies an answer to the query.",
        presence_false="No line addresses the query; the closest lines are only loosely related.",
    )
    ranked = sorted(results.items(), key=lambda item: item[1]["score"], reverse=True)
    top = [(cid, r) for cid, r in ranked[: args.top] if r["score"] >= args.threshold]
    if not top and ranked:
        top = [ranked[0]]
    overall = max(presences) if presences else 0.0
    label = presence_label(overall, args.presence_threshold, args.partial_threshold)
    hits = [{"line": int(cid[1:]), **r} for cid, r in top]
    ranges = merge_ranges((h["line"] for h in hits), args.context, total)

    name = args.file if args.file != "-" else "<stdin>"
    out = [f"{name}: {total} lines, {len(candidates)} candidates, {len(presences)} window(s)"]
    out.append(f"presence={overall:.2f} ({label}) windows=" + ",".join(f"{p:.2f}" for p in presences))
    for i, h in enumerate(hits, 1):
        out.append(f"{i:2d}. {name}:{h['line']}  score={h['score']:.3f} p={h['p']:.3f}  {lines[h['line'] - 1].strip()[:100]}")
    if label != "absent":
        out.append("read only:")
        for start, end in ranges:
            out.append(f"  read_file path={name} start_line={start} limit={end - start + 1}")
    else:
        out.append("suggestion: query is likely not answered in this file; search elsewhere before reading it.")
    returned = sum(end - start + 1 for start, end in ranges) if label != "absent" else 0
    emit(
        args,
        client,
        {"file": name, "total_lines": total, "presence": overall, "presence_label": label, "windows": presences, "hits": hits, "ranges": ranges},
        out,
        detail={
            "file": name,
            "lines_total": total,
            "lines_judged": len(candidates),
            "lines_returned": returned,
            "ranges": len(ranges) if label != "absent" else 0,
            "presence": round(overall, 3),
            "label": label,
            "windows": len(presences),
        },
    )


# --------------------------------------------------------------------------- filter-search

GREP_LINE = re.compile(r"^(?P<path>[^:\n]+?):(?P<line>\d+)[:-](?P<text>.*)$")


def cmd_filter_search(args: argparse.Namespace, client: JevClient) -> None:
    raw = [ln for ln in read_text(args.input).splitlines() if ln.strip()]
    if not raw:
        raise JevError("No input lines")
    parsed = [GREP_LINE.match(ln) for ln in raw]
    grep_mode = sum(1 for m in parsed if m) >= max(1, len(raw) // 2)
    candidates: list[tuple[str, str]] = []
    meta: dict[str, dict[str, Any]] = {}
    for i, ln in enumerate(raw, 1):
        cid = f"H{i:04d}"
        m = parsed[i - 1] if grep_mode else None
        if m:
            meta[cid] = {"path": m["path"], "line": int(m["line"]), "text": m["text"].strip()}
            candidates.append((cid, f"{m['path']}:{m['line']}: {m['text'].strip()}"[: args.max_chars]))
        elif not grep_mode:
            meta[cid] = {"path": None, "line": None, "text": ln.strip()}
            candidates.append((cid, ln.strip()[: args.max_chars]))
    results, presences = rank_candidates(
        client,
        args.query,
        candidates,
        presence_true="At least one hit is the code or text the query is looking for.",
        presence_false="Every hit is a false positive, an unrelated mention, or only superficially related.",
        subject="hit",
    )
    overall = max(presences) if presences else 0.0
    label = presence_label(overall, args.presence_threshold, args.partial_threshold)
    ranked = sorted(results.items(), key=lambda item: item[1]["score"], reverse=True)
    kept = [(cid, r) for cid, r in ranked[: args.top] if r["score"] >= args.threshold] or ranked[:1]

    out = [f"{len(raw)} hits, {len(presences)} window(s); presence={overall:.2f} ({label})"]
    hits = []
    if grep_mode:
        by_path: dict[str, dict[str, Any]] = {}
        for cid, r in kept:
            m = meta[cid]
            entry = by_path.setdefault(m["path"], {"path": m["path"], "score": 0.0, "lines": []})
            entry["score"] = max(entry["score"], r["score"])
            entry["lines"].append(m["line"])
        for entry in sorted(by_path.values(), key=lambda e: e["score"], reverse=True):
            entry["lines"].sort()
            hits.append(entry)
            out.append(f"  {entry['path']}  score={entry['score']:.3f}  lines={','.join(map(str, entry['lines']))}")
    else:
        for cid, r in kept:
            hits.append({"id": cid, "text": meta[cid]["text"], **r})
            out.append(f"  score={r['score']:.3f}  {meta[cid]['text'][:120]}")
    dropped = len(raw) - sum(len(h.get("lines", [1])) for h in hits)
    out.append(f"dropped {max(0, dropped)} lower-ranked hits; read the kept ranges with read_file start_line/limit.")
    kept_lines = sum(len(h.get("lines", [1])) for h in hits)
    emit(
        args,
        client,
        {"grep_mode": grep_mode, "presence": overall, "presence_label": label, "hits": hits},
        out,
        detail={"hits_in": len(raw), "hits_kept": kept_lines, "paths_kept": len(hits) if grep_mode else None, "presence": round(overall, 3), "label": label},
    )


# --------------------------------------------------------------------------- rank-files

SIGNATURE_LINE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|private|internal|fileprivate|open|static|final|override|async|export|default|pub|unsafe|abstract)\s+)*"
    r"(?:func|class|struct|enum|protocol|extension|actor|typealias|init|var|let|def|fn|impl|trait|type|interface|"
    r"function|const|mod|package|import)\b"
)
RELEVANCE_LEVELS = [
    "Unrelated: the file does not touch the task's concepts, symbols, or data flow.",
    "Tangential: shares vocabulary or is a distant dependency; reading it would not change how the task is done.",
    "Useful context: defines a type, protocol, or helper the task must use correctly; likely read, unlikely edited.",
    "Central: the task almost certainly requires reading and probably editing this file.",
]


def file_excerpt(path: Path, mode: str, max_lines: int) -> str:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as error:
        return f"<unreadable: {error}>"
    lines = text.splitlines()
    if mode == "full":
        chosen = lines
    elif mode == "head":
        chosen = lines[:max_lines]
    else:
        chosen = [ln.rstrip() for ln in lines if SIGNATURE_LINE.match(ln)]
        if len(chosen) < 3:
            chosen = lines[:max_lines]
    chosen = chosen[:max_lines]
    return "\n".join(ln[:200] for ln in chosen)


def cmd_rank_files(args: argparse.Namespace, client: JevClient) -> None:
    paths = list(args.paths)
    if args.from_stdin:
        paths.extend(ln.strip() for ln in sys.stdin.read().splitlines() if ln.strip())
    paths = [p for p in dict.fromkeys(paths) if Path(p).is_file()]
    if not paths:
        raise JevError("No readable files given")
    entries = [(p, file_excerpt(Path(p), args.mode, args.max_lines)) for p in paths]
    # Score questions are comparable across requests, so chunk purely by token budget.
    batches: list[list[tuple[str, str]]] = []
    current: list[tuple[str, str]] = []
    tokens = 0
    for path, excerpt in entries:
        t = estimate_tokens(excerpt) + estimate_tokens(path) + 40
        if current and (tokens + t > STATE_TOKEN_BUDGET or len(current) >= args.batch_size):
            batches.append(current)
            current, tokens = [], 0
        current.append((path, excerpt))
        tokens += t
    if current:
        batches.append(current)

    scored: list[dict[str, Any]] = []
    for batch in batches:
        ids = {f"f{i:03d}": (path, excerpt) for i, (path, excerpt) in enumerate(batch, 1)}
        state = {"task": args.task, "files": {fid: {"path": p, "excerpt": e} for fid, (p, e) in ids.items()}}
        questions = {
            fid: {
                "type": "score",
                "instructions": (
                    f"How relevant is the file `files.{fid}` (path `files.{fid}.path`, excerpt in `files.{fid}.excerpt`) "
                    "to completing `task`? Judge from the excerpt and the path; the excerpt may be only signatures."
                ),
                "criteria": RELEVANCE_LEVELS,
            }
            for fid in ids
        }
        answers = client.ask(state, questions)["answers"]
        for fid, (path, _) in ids.items():
            a = answers.get(fid) or {}
            scored.append({"path": path, "score": float(a.get("score") or 0.0), "confidence": float(a.get("confidence") or 0.0)})
    scored.sort(key=lambda s: s["score"], reverse=True)
    kept = [s for s in scored if s["score"] >= args.threshold][: args.top]
    out = [f"{len(paths)} files scored (0-3 rubric), {len(batches)} request(s)"]
    for i, s in enumerate(kept, 1):
        out.append(f"{i:2d}. {s['path']}  score={s['score']:.2f} conf={s['confidence']:.2f}")
    if kept:
        out.append("selection: manage_selection add " + " ".join(s["path"] for s in kept))
    out.append(f"below threshold {args.threshold}: {len(scored) - len(kept)} file(s)")
    emit(args, client, {"files": scored, "kept": kept, "threshold": args.threshold}, out, detail={"files": len(paths), "kept": len(kept), "batches": len(batches)})


# --------------------------------------------------------------------------- pick-skill

FRONTMATTER = re.compile(r"^---\s*\n(.*?)\n---\s*\n(.*)$", re.DOTALL)


def discover_skills(extra_dirs: list[str]) -> list[dict[str, str]]:
    roots: list[Path] = []
    for base in (Path.cwd(), Path.home()):
        for rel in SKILL_ROOTS:
            roots.append(base / rel)
    roots.extend(Path(d) for d in extra_dirs)
    skills: dict[str, dict[str, str]] = {}
    for root in roots:
        if not root.is_dir():
            continue
        for skill_file in sorted(root.glob("*/SKILL.md")):
            try:
                text = skill_file.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            m = FRONTMATTER.match(text)
            body = text
            name = skill_file.parent.name
            description = ""
            if m:
                body = m.group(2)
                for line in m.group(1).splitlines():
                    key, _, value = line.partition(":")
                    key, value = key.strip().lower(), value.strip().strip("\"'")
                    if key == "name" and value:
                        name = value
                    elif key == "description":
                        description = value
            if name.lower() in skills:
                continue  # earlier roots take precedence, matching AgentSkillCatalog ordering
            skills[name.lower()] = {"name": name, "description": description or "(no description)", "body": body.strip()[:700], "path": str(skill_file)}
    return list(skills.values())


def cmd_pick_skill(args: argparse.Namespace, client: JevClient) -> None:
    skills = discover_skills(args.skills_dir)
    if not skills:
        raise JevError("No skills found under .agents/skills, .claude/skills, or ~/.agents/skills, ~/.claude/skills")
    by_name = {s["name"]: s for s in skills}
    catalog = {s["name"]: s["description"][: args.max_chars] for s in skills}
    state = {"request": args.prompt, "skills": catalog}
    questions = {
        "which": {
            "type": "choice",
            "instructions": "Which entry in `skills` (name -> description) is the documented procedure the agent should load to handle `request`? Choose `none` if no listed skill applies.",
            "criteria": {**{name: None for name in catalog}, "none": "No listed skill is a good fit; the agent should proceed without loading one."},
        },
        "acts": {"type": "noul", "instructions": "Does `request` require the agent to act on the repository, tooling, or system (edit, run, validate, release), rather than only explain?"},
        "procedure": {"type": "noul", "instructions": "Would a documented, repository-specific procedure or checklist materially improve how `request` is handled?"},
        "prose": {"type": "noul", "instructions": "Can `request` be fully satisfied with a direct prose answer, with no tool use or procedure?"},
    }
    answers = client.ask(state, questions)["answers"]
    probs = answers["which"].get("probabilities") or {}
    gate = (float(answers["acts"]["noul"]) + float(answers["procedure"]["noul"]) + (1 - float(answers["prose"]["noul"]))) / 3
    none_p = float(probs.get("none") or 0.0)
    shortlist = sorted(((n, p) for n, p in probs.items() if n != "none"), key=lambda x: x[1], reverse=True)[: args.shortlist]

    verified: list[dict[str, Any]] = []
    if shortlist and gate >= args.gate:
        state2 = {
            "request": args.prompt,
            "candidates": {n: {"description": by_name[n]["description"], "excerpt": by_name[n]["body"]} for n, _ in shortlist},
        }
        questions2: dict[str, dict[str, Any]] = {
            "rerank": {
                "type": "choice",
                "instructions": "Considering full descriptions and excerpts in `candidates`, which candidate best matches `request`? Choose `none` if none specifically applies.",
                "criteria": {**{n: None for n, _ in shortlist}, "none": "None of the candidates specifically covers this request."},
            }
        }
        for n, _ in shortlist:
            questions2[f"fit_{n}"] = {
                "type": "noul",
                "instructions": f"Does the candidate `candidates.{n}` specifically cover the kind of work described in `request`, such that following it would be appropriate?",
            }
        answers2 = client.ask(state2, questions2)["answers"]
        rerank = answers2["rerank"].get("probabilities") or {}
        for n, p1 in shortlist:
            verified.append({"name": n, "stage1_p": p1, "stage2_p": float(rerank.get(n) or 0.0), "fit": float(answers2[f"fit_{n}"]["noul"]), "path": by_name[n]["path"]})
        verified.sort(key=lambda v: (v["fit"], v["stage2_p"]), reverse=True)

    best = verified[0] if verified and verified[0]["fit"] >= args.fit else None
    out = [f"{len(skills)} skills considered; gate={gate:.2f} (threshold {args.gate}); none_p={none_p:.2f}"]
    for v in verified:
        out.append(f"  {v['name']}: fit={v['fit']:.2f} rerank={v['stage2_p']:.2f} stage1={v['stage1_p']:.2f}")
    if best:
        out.append(f"recommend: /{best['name']}  ({best['path']})")
    else:
        out.append("recommend: no skill; proceed without loading one.")
    emit(
        args,
        client,
        {"gate": gate, "none_p": none_p, "candidates": verified, "recommendation": best["name"] if best else None},
        out,
        detail={"skills": len(skills), "gate": round(gate, 3), "recommendation": best["name"] if best else None},
    )


# --------------------------------------------------------------------------- verify-claim


def cmd_verify_claim(args: argparse.Namespace, client: JevClient) -> None:
    lines = read_text(args.file).splitlines()
    lo, hi = 1, len(lines)
    if args.lines:
        a, _, b = args.lines.partition("-")
        lo = max(1, int(a))
        hi = min(len(lines), int(b) if b else lo)
    excerpt = "\n".join(f"{n}|{lines[n - 1]}" for n in range(lo, hi + 1))
    if estimate_tokens(excerpt) > STATE_TOKEN_BUDGET:
        raise JevError("Span too large for one request; narrow --lines")
    state = {"claim": args.claim, "source": {"path": args.file, "lines": f"{lo}-{hi}", "text": excerpt}}
    questions = {
        "supported": {
            "type": "noul",
            "instructions": "Does `source.text` (line-numbered) directly support `claim` as stated?",
            "criteria": {
                "true": "The cited lines contain the code or statement the claim describes, with matching names, behavior, and location.",
                "false": "The cited lines do not show it, show something materially different, or the claim adds details the source does not contain.",
            },
        },
        "elsewhere": {
            "type": "noul",
            "instructions": "Is it plausible that `claim` is true but the supporting code lives outside `source.text` (wrong lines cited)?",
        },
    }
    answers = client.ask(state, questions)["answers"]
    supported = float(answers["supported"]["noul"])
    elsewhere = float(answers["elsewhere"]["noul"])
    verdict = "supported" if supported >= args.high else "unsupported" if supported <= args.low else "unclear"
    out = [f"{args.file}:{lo}-{hi}  supported={supported:.2f} elsewhere={elsewhere:.2f}  verdict={verdict}"]
    if verdict != "supported":
        out.append("next: read the span yourself or run find-lines with the claim as the query.")
    emit(
        args,
        client,
        {"supported": supported, "elsewhere": elsewhere, "verdict": verdict, "lines": [lo, hi]},
        out,
        detail={"file": args.file, "lines": [lo, hi], "supported": round(supported, 3), "verdict": verdict},
    )


# --------------------------------------------------------------------------- ask / doctor


def cmd_ask(args: argparse.Namespace, client: JevClient) -> None:
    state: Any = read_text(args.state_file) if args.state_file else args.state
    if args.state_file and args.state_file.endswith(".json"):
        state = json.loads(state)
    questions = json.loads(read_text(args.questions_file))
    data = client.ask(state, questions)
    print(json.dumps(data, indent=2))
    print(client.usage_line())


def cmd_doctor(args: argparse.Namespace, client: JevClient) -> None:
    data = client.ask("ping", {"ok": {"type": "noul", "instructions": "Is the state the word ping?"}})
    print(f"ok model={data.get('model')} base_url={client.base_url} noul={data['answers']['ok']['noul']:.2f}")
    print(client.usage_line())


# --------------------------------------------------------------------------- ledger


def ledger_enabled() -> bool:
    return os.environ.get("JEV_LEDGER", "1").strip().lower() not in ("0", "false", "off", "no")


def detect_harness() -> str:
    if os.environ.get("CLAUDECODE") or os.environ.get("CLAUDE_CODE_ENTRYPOINT"):
        return "claude"
    if any(k.startswith("CODEX_") for k in os.environ):
        return "codex"
    return "unknown"


def repo_name(cwd: Path) -> str:
    for candidate in (cwd, *cwd.parents):
        if (candidate / ".git").exists():
            return candidate.name
    return cwd.name


def ledger_append(record: dict[str, Any]) -> None:
    """Append one JSON line; rotate once at LEDGER_MAX_BYTES. Never raises."""
    if not ledger_enabled():
        return
    try:
        LEDGER_PATH.parent.mkdir(parents=True, exist_ok=True)
        try:
            if LEDGER_PATH.stat().st_size >= LEDGER_MAX_BYTES:
                LEDGER_PATH.replace(LEDGER_PATH.with_name(LEDGER_PATH.stem + ".1" + LEDGER_PATH.suffix))
        except FileNotFoundError:
            pass
        record.setdefault("ts", datetime.now(timezone.utc).isoformat(timespec="seconds"))
        with LEDGER_PATH.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, separators=(",", ":"), default=str) + "\n")
    except (OSError, TypeError, ValueError):
        pass


def ledger_invocation(args: argparse.Namespace, client: JevClient | None, ok: bool, error: str | None, started: float) -> None:
    cwd = Path.cwd()
    record: dict[str, Any] = {
        "kind": "call",
        "cmd": args.command,
        "ok": ok,
        "harness": detect_harness(),
        "repo": repo_name(cwd),
        "cwd": str(cwd),
        "wall_s": round(time.monotonic() - started, 2),
    }
    if client is not None:
        record.update(client.usage_dict())
    if error:
        record["error"] = error[:300]
    detail = getattr(args, "ledger_detail", None)
    if detail:
        record["detail"] = detail
    ledger_append(record)


def ledger_records() -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    rotated = LEDGER_PATH.with_name(LEDGER_PATH.stem + ".1" + LEDGER_PATH.suffix)
    for path in (rotated, LEDGER_PATH):
        if not path.is_file():
            continue
        with path.open(encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    return records


def parse_since(text: str | None) -> datetime | None:
    if not text:
        return None
    m = re.fullmatch(r"(\d+)([hdw])", text.strip())
    if m:
        n, unit = int(m.group(1)), m.group(2)
        delta = {"h": timedelta(hours=n), "d": timedelta(days=n), "w": timedelta(weeks=n)}[unit]
        return datetime.now(timezone.utc) - delta
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        raise JevError(f"--since must be like 7d, 24h, 2w, or an ISO date; got {text!r}") from None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def cmd_ledger(args: argparse.Namespace, client: JevClient | None) -> None:
    since = parse_since(args.since)
    records = ledger_records()
    if since:
        records = [r for r in records if r.get("ts") and datetime.fromisoformat(r["ts"]) >= since]
    if args.tail:
        for r in records[-args.tail :]:
            print(json.dumps(r, separators=(",", ":")))
        return
    calls = [r for r in records if r.get("kind") == "call"]
    hooks = [r for r in records if r.get("kind") == "hook"]
    by_cmd: dict[str, dict[str, Any]] = {}
    for r in calls:
        slot = by_cmd.setdefault(r.get("cmd", "?"), {"ok": 0, "fail": 0, "requests": 0, "input_tokens": 0, "cost_usd": 0.0})
        slot["ok" if r.get("ok") else "fail"] += 1
        slot["requests"] += int(r.get("requests") or 0)
        slot["input_tokens"] += int(r.get("input_tokens") or 0)
        slot["cost_usd"] += float(r.get("cost_usd") or 0.0)
    fl = [r["detail"] for r in calls if r.get("cmd") == "find-lines" and r.get("ok") and r.get("detail")]
    judged = sum(int(d.get("lines_total") or 0) for d in fl)
    returned = sum(int(d.get("lines_returned") or 0) for d in fl)
    absent = sum(1 for d in fl if d.get("label") == "absent")
    small = sum(1 for d in fl if int(d.get("lines_total") or 0) < HOOK_MIN_LINES)
    fs = [r["detail"] for r in calls if r.get("cmd") == "filter-search" and r.get("ok") and r.get("detail")]
    hits_in = sum(int(d.get("hits_in") or 0) for d in fs)
    hits_kept = sum(int(d.get("hits_kept") or 0) for d in fs)
    harness = {}
    for r in calls:
        harness[r.get("harness", "?")] = harness.get(r.get("harness", "?"), 0) + 1
    repos = {}
    for r in calls:
        repos[r.get("repo", "?")] = repos.get(r.get("repo", "?"), 0) + 1
    hook_events = {}
    for r in hooks:
        hook_events[r.get("event", "?")] = hook_events.get(r.get("event", "?"), 0) + 1
    failures = [r for r in calls if not r.get("ok")][-5:]
    total_cost = sum(v["cost_usd"] for v in by_cmd.values())
    total_tokens = sum(v["input_tokens"] for v in by_cmd.values())
    summary = {
        "ledger": str(LEDGER_PATH),
        "ledger_bytes": LEDGER_PATH.stat().st_size if LEDGER_PATH.is_file() else 0,
        "since": since.isoformat(timespec="seconds") if since else None,
        "first": records[0].get("ts") if records else None,
        "last": records[-1].get("ts") if records else None,
        "calls": len(calls),
        "by_cmd": {k: {**v, "cost_usd": round(v["cost_usd"], 4)} for k, v in sorted(by_cmd.items(), key=lambda kv: -kv[1]["ok"] - kv[1]["fail"])},
        "jev_requests": sum(v["requests"] for v in by_cmd.values()),
        "jev_input_tokens": total_tokens,
        "jev_cost_usd": round(total_cost, 4),
        "find_lines": {
            "files": len(fl),
            "lines_judged": judged,
            "lines_returned": returned,
            "coverage_pct": round(100.0 * returned / judged, 1) if judged else None,
            "absent": absent,
            "under_min_lines": small,
        },
        "filter_search": {"calls": len(fs), "hits_in": hits_in, "hits_kept": hits_kept},
        "by_harness": harness,
        "by_repo": dict(sorted(repos.items(), key=lambda kv: -kv[1])[:8]),
        "hooks": hook_events,
        "recent_failures": [{"ts": r.get("ts"), "cmd": r.get("cmd"), "error": (r.get("error") or "")[:160]} for r in failures],
    }
    if args.json:
        print(json.dumps(summary, indent=2))
        return
    print(f"ledger: {summary['ledger']} ({summary['ledger_bytes'] / 1024:.0f} KiB; rotates at {LEDGER_MAX_BYTES // (1024 * 1024)} MiB, one backup kept)")
    print(f"window: {summary['first'] or '-'} .. {summary['last'] or '-'}" + (f"  (since {summary['since']})" if since else ""))
    print(f"calls: {len(calls)}   jev requests={summary['jev_requests']} input_tokens={total_tokens:,} cost=${total_cost:.4f}")
    for cmd, v in summary["by_cmd"].items():
        print(f"  {cmd:14s} ok={v['ok']:5d} fail={v['fail']:4d}  tokens={v['input_tokens']:>10,}  ${v['cost_usd']:.4f}")
    f = summary["find_lines"]
    if f["files"]:
        print(
            f"find-lines: {f['files']} files, {f['lines_judged']:,} lines judged -> {f['lines_returned']:,} returned "
            f"({f['coverage_pct']}% coverage); absent={f['absent']}; under {HOOK_MIN_LINES} lines={f['under_min_lines']}"
        )
    if summary["filter_search"]["calls"]:
        print(f"filter-search: {hits_in:,} hits in -> {hits_kept:,} kept over {len(fs)} calls")
    print(f"by harness: {harness}   by repo: {summary['by_repo']}")
    if hook_events:
        nudged = hook_events.get("read_nudge", 0)
        repeated = hook_events.get("read_full_after_nudge", 0)
        print(f"hooks: {hook_events}" + (f"   full-read-anyway after nudge: {repeated}/{nudged}" if nudged else ""))
    for r in failures:
        print(f"  fail {r.get('ts')} [{r.get('cmd')}] {(r.get('error') or '')[:140]}")


# --------------------------------------------------------------------------- Claude Code hooks


def nudge_state_load() -> dict[str, list[str]]:
    try:
        data = json.loads(NUDGE_STATE_PATH.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def nudge_state_save(state: dict[str, list[str]]) -> None:
    # Bounded: keep the 40 most recent sessions, 200 paths each.
    trimmed = {k: v[-200:] for k, v in list(state.items())[-40:]}
    try:
        NUDGE_STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        NUDGE_STATE_PATH.write_text(json.dumps(trimmed, separators=(",", ":")), encoding="utf-8")
    except OSError:
        pass


def hook_session_start(event: dict[str, Any]) -> None:
    ledger_append({"kind": "hook", "event": "session_start", "session": event.get("session_id"), "source": event.get("source"), "harness": "claude", "repo": repo_name(Path(event.get("cwd") or Path.cwd()))})
    print(
        "rpce-jev: Jev relevance judgments are available via "
        f"`python3 {SCRIPT_PATH}` (skill /rpce-jev). Before reading a file over {HOOK_MIN_LINES} lines, run "
        "`find-lines --query \"<question>\" --file <path>` and read only the returned ranges; pipe searches with more than ~15 hits "
        "through `filter-search`. A PreToolUse hook nudges once per file when a long file is read without a range."
    )


def hook_pre_read(event: dict[str, Any]) -> None:
    if os.environ.get("JEV_HOOK_DISABLE", "").strip().lower() in ("1", "true", "yes"):
        return
    tool_input = event.get("tool_input") or {}
    path = tool_input.get("file_path") or tool_input.get("path")
    if not isinstance(path, str) or not path:
        return
    if any(tool_input.get(k) not in (None, "", 0) for k in ("offset", "limit", "start_line", "end_line")):
        return
    target = Path(path).expanduser()
    if not target.is_absolute():
        target = Path(event.get("cwd") or Path.cwd()) / target
    if not target.is_file() or target.suffix.lower() in HOOK_SKIP_SUFFIXES:
        return
    size = target.stat().st_size
    lines: int | None
    if size > HOOK_MAX_COUNT_BYTES:
        lines = None
    else:
        lines = target.read_bytes().count(b"\n") + 1
        if lines < HOOK_MIN_LINES:
            return
    session = str(event.get("session_id") or "nosession")
    key = str(target.resolve())
    state = nudge_state_load()
    seen = state.setdefault(session, [])
    base = {"kind": "hook", "session": session, "harness": "claude", "repo": repo_name(Path(event.get("cwd") or Path.cwd())), "file": key, "lines": lines, "tool": event.get("tool_name")}
    if key in seen:
        ledger_append({**base, "event": "read_full_after_nudge"})
        return
    seen.append(key)
    nudge_state_save(state)
    ledger_append({**base, "event": "read_nudge"})
    reason = (
        f"rpce-jev: {target.name} has {lines if lines is not None else 'very many'} lines and this read has no range. "
        f"Run `python3 {SCRIPT_PATH} find-lines --query \"<what you need from this file>\" --file {path}` and read only the returned "
        "ranges, or re-issue the read with a range (start_line/limit or offset/limit). If you need the whole file, repeat this exact "
        "read — it will be allowed — and say why in your reply."
    )
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason}}))


def cmd_hook(args: argparse.Namespace, client: JevClient | None) -> None:
    """Hook entry point. Fail-open: any problem means exit 0 with no output."""
    try:
        raw = "" if sys.stdin.isatty() else sys.stdin.read()
        event = json.loads(raw) if raw.strip() else {}
        if not isinstance(event, dict):
            event = {}
        if args.event == "session-start":
            hook_session_start(event)
        elif args.event == "pre-read":
            hook_pre_read(event)
    except Exception:  # noqa: BLE001 - hooks must never break the agent's tool call
        return


def hook_settings_entries(script: Path) -> dict[str, dict[str, Any]]:
    base = f"python3 {shlex.quote(str(script))} hook"
    return {
        "SessionStart": {"matcher": "", "hooks": [{"type": "command", "command": f"{base} session-start", "timeout": 10}]},
        "PreToolUse": {
            "matcher": "Read|mcp__RepoPrompt__read_file|mcp__RepoPromptCE__read_file",
            "hooks": [{"type": "command", "command": f"{base} pre-read", "timeout": 10}],
        },
    }


def is_jev_hook_entry(entry: dict[str, Any]) -> bool:
    return any("jev.py" in str(h.get("command", "")) and " hook " in str(h.get("command", "")) for h in entry.get("hooks", []) if isinstance(h, dict))


def cmd_install_claude_hooks(args: argparse.Namespace, client: JevClient | None) -> None:
    settings_path = Path(args.settings).expanduser()
    data: dict[str, Any] = {}
    if settings_path.is_file():
        try:
            data = json.loads(settings_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            raise JevError(f"{settings_path} is not valid JSON ({error}); fix it before installing hooks") from None
        if not isinstance(data, dict):
            raise JevError(f"{settings_path} must contain a JSON object")
    global_copy = Path.home() / ".agents" / "skills" / "rpce-jev" / "scripts" / "jev.py"
    script = global_copy if global_copy.is_file() else SCRIPT_PATH
    entries = hook_settings_entries(script)
    hooks = data.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise JevError("settings.hooks must be an object")
    changed = False
    for event, entry in entries.items():
        existing = hooks.get(event, [])
        kept = [e for e in existing if not (isinstance(e, dict) and is_jev_hook_entry(e))]
        if not args.uninstall:
            kept.append(entry)
        if kept != existing:
            if kept:
                hooks[event] = kept
            else:
                hooks.pop(event, None)
            changed = True
    if not changed:
        print(f"no change: {settings_path} already {'has no' if args.uninstall else 'has the'} rpce-jev hooks")
        return
    if settings_path.is_file():
        backup = settings_path.with_name(settings_path.name + ".bak-rpce-jev")
        backup.write_text(settings_path.read_text(encoding="utf-8"), encoding="utf-8")
        print(f"backup: {backup}")
    settings_path.parent.mkdir(parents=True, exist_ok=True)
    settings_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    action = "removed from" if args.uninstall else "installed into"
    print(f"rpce-jev hooks {action} {settings_path} (script: {script})")
    if not args.uninstall:
        print("SessionStart: advertises the skill; PreToolUse (Read / read_file): nudges once per file over "
              f"{HOOK_MIN_LINES} lines read without a range. Open /hooks or restart Claude Code to load them.")


# --------------------------------------------------------------------------- main


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="jev.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-url", default=os.environ.get("TYPESAFE_BASE_URL", DEFAULT_BASE_URL))
    parser.add_argument("--model", default=os.environ.get("TYPESAFE_DEFAULT_MODEL", DEFAULT_MODEL))
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    # Also accept --json after the subcommand (agents overwhelmingly write it there).
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", default=argparse.SUPPRESS, help="machine-readable output")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("find-lines", help="rank lines of a file against a query", parents=[common])
    p.add_argument("--query", required=True)
    p.add_argument("--file", required=True, help="path or - for stdin")
    p.add_argument("--start", type=int)
    p.add_argument("--end", type=int)
    p.add_argument("--top", type=int, default=8)
    p.add_argument("--threshold", type=float, default=0.02, help="min presence*p to keep a line")
    p.add_argument("--presence-threshold", type=float, default=0.7)
    p.add_argument("--partial-threshold", type=float, default=0.35)
    p.add_argument("--context", type=int, default=6, help="context lines around each hit when building read ranges")
    p.set_defaults(func=cmd_find_lines)

    p = sub.add_parser("filter-search", help="rerank grep-style path:line:text hits", parents=[common])
    p.add_argument("--query", required=True)
    p.add_argument("--input", default="-", help="file with hits, or - for stdin")
    p.add_argument("--top", type=int, default=12)
    p.add_argument("--threshold", type=float, default=0.02)
    p.add_argument("--presence-threshold", type=float, default=0.7)
    p.add_argument("--partial-threshold", type=float, default=0.35)
    p.add_argument("--max-chars", type=int, default=240, help="truncate each hit line to this many chars")
    p.set_defaults(func=cmd_filter_search)

    p = sub.add_parser("rank-files", help="score files for relevance to a task", parents=[common])
    p.add_argument("--task", required=True)
    p.add_argument("paths", nargs="*")
    p.add_argument("--from-stdin", action="store_true", help="also read newline-separated paths from stdin")
    p.add_argument("--mode", choices=["signatures", "head", "full"], default="signatures")
    p.add_argument("--max-lines", type=int, default=60)
    p.add_argument("--batch-size", type=int, default=40, help="max files per request")
    p.add_argument("--top", type=int, default=15)
    p.add_argument("--threshold", type=float, default=1.5, help="min 0-3 score to keep")
    p.set_defaults(func=cmd_rank_files)

    p = sub.add_parser("pick-skill", help="suggest one installed skill for a prompt", parents=[common])
    p.add_argument("--prompt", required=True)
    p.add_argument("--skills-dir", action="append", default=[], help="extra skills directory")
    p.add_argument("--shortlist", type=int, default=3)
    p.add_argument("--gate", type=float, default=0.30)
    p.add_argument("--fit", type=float, default=0.30)
    p.add_argument("--max-chars", type=int, default=160, help="stage-1 description truncation")
    p.set_defaults(func=cmd_pick_skill)

    p = sub.add_parser("verify-claim", help="check that a source span supports a claim", parents=[common])
    p.add_argument("--claim", required=True)
    p.add_argument("--file", required=True)
    p.add_argument("--lines", help="a-b range (1-based, inclusive)")
    p.add_argument("--high", type=float, default=0.7)
    p.add_argument("--low", type=float, default=0.3)
    p.set_defaults(func=cmd_verify_claim)

    p = sub.add_parser("ask", help="raw System One request", parents=[common])
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--state")
    g.add_argument("--state-file", help="text file, or .json for structured state")
    p.add_argument("--questions-file", required=True, help="JSON map of question id -> question")
    p.set_defaults(func=cmd_ask)

    p = sub.add_parser("doctor", help="check key and connectivity", parents=[common])
    p.set_defaults(func=cmd_doctor)

    p = sub.add_parser("ledger", help="summarize the local usage ledger (no API call)", parents=[common])
    p.add_argument("--since", help="window: 7d, 24h, 2w, or an ISO date/time")
    p.add_argument("--tail", type=int, help="print the last N raw records instead of a summary")
    p.set_defaults(func=cmd_ledger, needs_client=False, log_call=False)

    p = sub.add_parser("hook", help="Claude Code hook entry point (reads the hook event JSON from stdin)")
    p.add_argument("event", choices=["session-start", "pre-read"])
    p.set_defaults(func=cmd_hook, needs_client=False, log_call=False)

    p = sub.add_parser("install-claude-hooks", help="add (or --uninstall) the SessionStart/PreToolUse hooks in Claude settings")
    p.add_argument("--settings", default=str(Path.home() / ".claude" / "settings.json"))
    p.add_argument("--uninstall", action="store_true")
    p.set_defaults(func=cmd_install_claude_hooks, needs_client=False, log_call=False)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    started = time.monotonic()
    client: JevClient | None = None
    code = 0
    error_text: str | None = None
    try:
        if getattr(args, "needs_client", True):
            client = JevClient(resolve_api_key(), args.base_url, args.model, timeout=args.timeout)
        args.func(args, client)
    except (JevError, OSError) as error:
        error_text = str(error)
        print(f"jev: {error_text}", file=sys.stderr)
        code = 2
    except KeyboardInterrupt:
        return 130
    if getattr(args, "log_call", True):
        ledger_invocation(args, client, code == 0, error_text, started)
    return code


if __name__ == "__main__":
    sys.exit(main())
