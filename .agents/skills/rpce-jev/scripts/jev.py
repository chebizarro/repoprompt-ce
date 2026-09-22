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
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
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
    return Path(path).read_text(encoding="utf-8", errors="replace")


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


def emit(args: argparse.Namespace, client: JevClient, payload: dict[str, Any], text_lines: list[str]) -> None:
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
    emit(
        args,
        client,
        {"file": name, "total_lines": total, "presence": overall, "presence_label": label, "windows": presences, "hits": hits, "ranges": ranges},
        out,
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
    emit(args, client, {"grep_mode": grep_mode, "presence": overall, "presence_label": label, "hits": hits}, out)


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
    emit(args, client, {"files": scored, "kept": kept, "threshold": args.threshold}, out)


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
    emit(args, client, {"gate": gate, "none_p": none_p, "candidates": verified, "recommendation": best["name"] if best else None}, out)


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
    emit(args, client, {"supported": supported, "elsewhere": elsewhere, "verdict": verdict, "lines": [lo, hi]}, out)


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


# --------------------------------------------------------------------------- main


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="jev.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-url", default=os.environ.get("TYPESAFE_BASE_URL", DEFAULT_BASE_URL))
    parser.add_argument("--model", default=os.environ.get("TYPESAFE_DEFAULT_MODEL", DEFAULT_MODEL))
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("find-lines", help="rank lines of a file against a query")
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

    p = sub.add_parser("filter-search", help="rerank grep-style path:line:text hits")
    p.add_argument("--query", required=True)
    p.add_argument("--input", default="-", help="file with hits, or - for stdin")
    p.add_argument("--top", type=int, default=12)
    p.add_argument("--threshold", type=float, default=0.02)
    p.add_argument("--presence-threshold", type=float, default=0.7)
    p.add_argument("--partial-threshold", type=float, default=0.35)
    p.add_argument("--max-chars", type=int, default=240, help="truncate each hit line to this many chars")
    p.set_defaults(func=cmd_filter_search)

    p = sub.add_parser("rank-files", help="score files for relevance to a task")
    p.add_argument("--task", required=True)
    p.add_argument("paths", nargs="*")
    p.add_argument("--from-stdin", action="store_true", help="also read newline-separated paths from stdin")
    p.add_argument("--mode", choices=["signatures", "head", "full"], default="signatures")
    p.add_argument("--max-lines", type=int, default=60)
    p.add_argument("--batch-size", type=int, default=40, help="max files per request")
    p.add_argument("--top", type=int, default=15)
    p.add_argument("--threshold", type=float, default=1.5, help="min 0-3 score to keep")
    p.set_defaults(func=cmd_rank_files)

    p = sub.add_parser("pick-skill", help="suggest one installed skill for a prompt")
    p.add_argument("--prompt", required=True)
    p.add_argument("--skills-dir", action="append", default=[], help="extra skills directory")
    p.add_argument("--shortlist", type=int, default=3)
    p.add_argument("--gate", type=float, default=0.30)
    p.add_argument("--fit", type=float, default=0.30)
    p.add_argument("--max-chars", type=int, default=160, help="stage-1 description truncation")
    p.set_defaults(func=cmd_pick_skill)

    p = sub.add_parser("verify-claim", help="check that a source span supports a claim")
    p.add_argument("--claim", required=True)
    p.add_argument("--file", required=True)
    p.add_argument("--lines", help="a-b range (1-based, inclusive)")
    p.add_argument("--high", type=float, default=0.7)
    p.add_argument("--low", type=float, default=0.3)
    p.set_defaults(func=cmd_verify_claim)

    p = sub.add_parser("ask", help="raw System One request")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--state")
    g.add_argument("--state-file", help="text file, or .json for structured state")
    p.add_argument("--questions-file", required=True, help="JSON map of question id -> question")
    p.set_defaults(func=cmd_ask)

    p = sub.add_parser("doctor", help="check key and connectivity")
    p.set_defaults(func=cmd_doctor)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        client = JevClient(resolve_api_key(), args.base_url, args.model, timeout=args.timeout)
        args.func(args, client)
    except JevError as error:
        print(f"jev: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
