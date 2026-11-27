#!/usr/bin/env python3
"""Stdio MCP server wrapping the local OpenCode v2 CLI for Antigravity."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

PROTOCOL_VERSION = "2025-03-26"
MAX_WAIT_SECONDS = 45.0
MAX_TEXT_CHARS = 12000
MAX_STDERR_CHARS = 4000
LOG_RETENTION_SECONDS = 24 * 3600
MAX_LOG_DIRS = 100


@dataclass
class Job:
    job_id: str
    role: str
    workdir: str
    model: str
    agent: str | None
    requested_session_id: str | None
    handoff_file: str | None
    prompt: str
    events_path: Path
    stderr_path: Path
    stdout_fh: Any
    stderr_fh: Any
    process: subprocess.Popen[bytes]
    started_at: float
    git_baseline: set[str] | None = None
    finished_at: float | None = None
    exit_code: int | None = None
    status: str = "running"
    stopped_by_user: bool = False
    cached_summary: dict[str, Any] = field(default_factory=dict)


JOBS: dict[str, Job] = {}
LOG_ROOT = Path(tempfile.gettempdir()) / f"xz-opencode-mcp-{os.getuid() if hasattr(os, 'getuid') else 'user'}"


def _git_status_lines(workdir: str) -> set[str] | None:
    try:
        res = subprocess.run(
            ["git", "-C", workdir, "status", "--porcelain"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if res.returncode != 0:
        return None
    return {line for line in res.stdout.splitlines() if line.strip()}


def _find_first_key(obj: Any, keys: tuple[str, ...], depth: int = 0) -> str | None:
    if depth > 6:
        return None
    if isinstance(obj, dict):
        for key in keys:
            val = obj.get(key)
            if isinstance(val, str) and val.strip():
                return val.strip()
        for val in obj.values():
            found = _find_first_key(val, keys, depth + 1)
            if found:
                return found
    elif isinstance(obj, list):
        for item in obj:
            found = _find_first_key(item, keys, depth + 1)
            if found:
                return found
    return None


def _tail_text(text: str, limit: int) -> tuple[str, bool]:
    if len(text) <= limit:
        return text, False
    return text[-limit:], True


def _parse_events(events_path: Path, stderr_path: Path) -> dict[str, Any]:
    session_id: str | None = None
    model_used: str | None = None
    parts_by_id: dict[str, str] = {}
    part_order: list[str] = []
    anonymous_texts: list[str] = []
    errors: list[str] = []
    raw_lines: list[str] = []
    event_count = 0

    if events_path.is_file():
        with events_path.open("r", encoding="utf-8", errors="replace") as fh:
            for raw_line in fh:
                line = raw_line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    raw_lines.append(line)
                    continue

                event_count += 1
                if not isinstance(event, dict):
                    continue

                if not session_id:
                    session_id = _find_first_key(event, ("sessionID", "session_id"))

                if not model_used:
                    model_used = _find_first_key(event, ("modelID", "model"))
                    provider_id = _find_first_key(event, ("providerID", "provider"))
                    if model_used and provider_id and "/" not in model_used:
                        model_used = f"{provider_id}/{model_used}"

                ev_type = event.get("type")
                part = event.get("part")
                if isinstance(part, dict):
                    part_type = part.get("type")
                    part_id = part.get("id")
                    part_text = part.get("text")
                    if part_type == "text" and isinstance(part_text, str):
                        if isinstance(part_id, str) and part_id:
                            if part_id not in parts_by_id:
                                part_order.append(part_id)
                            parts_by_id[part_id] = part_text
                        else:
                            anonymous_texts.append(part_text)
                    elif part_type == "error":
                        err_val = part.get("error") or part.get("message") or part.get("text")
                        if err_val:
                            errors.append(str(err_val))

                if ev_type == "text" and isinstance(event.get("text"), str):
                    anonymous_texts.append(event["text"])
                elif ev_type == "error":
                    err_val = event.get("error") or event.get("message")
                    if err_val:
                        errors.append(json.dumps(err_val, ensure_ascii=False) if isinstance(err_val, dict) else str(err_val))
                elif isinstance(event.get("error"), (str, dict)):
                    err_val = event["error"]
                    errors.append(json.dumps(err_val, ensure_ascii=False) if isinstance(err_val, dict) else str(err_val))

    if parts_by_id:
        assistant_text = "\n".join(parts_by_id[pid] for pid in part_order if parts_by_id.get(pid))
    elif anonymous_texts:
        assistant_text = "\n".join(anonymous_texts)
    else:
        assistant_text = "\n".join(raw_lines)

    stderr_text = ""
    if stderr_path.is_file():
        stderr_text = stderr_path.read_text(encoding="utf-8", errors="replace").strip()

    assistant_text, text_truncated = _tail_text(assistant_text.strip(), MAX_TEXT_CHARS)
    stderr_tail, stderr_truncated = _tail_text(stderr_text, MAX_STDERR_CHARS)

    return {
        "session_id": session_id,
        "model_reported": model_used,
        "event_count": event_count,
        "assistant_text": assistant_text,
        "assistant_text_truncated": text_truncated,
        "errors": errors,
        "stderr_tail": stderr_tail,
        "stderr_truncated": stderr_truncated,
    }


def _close_job_files(job: Job) -> None:
    for fh in (job.stdout_fh, job.stderr_fh):
        if fh is not None:
            try:
                fh.close()
            except OSError:
                pass
    job.stdout_fh = None
    job.stderr_fh = None


OUTCOME_RE = re.compile(r"^\s*(?:STATUS|VERDICT)\s*:\s*(DONE|BLOCKED|NO_CHANGE|APPROVED|CHANGES_REQUIRED)\b", re.IGNORECASE | re.MULTILINE)


def _detect_outcome(assistant_text: str) -> str | None:
    matches = OUTCOME_RE.findall(assistant_text)
    if not matches:
        return None
    return matches[-1].upper()


def _refresh_job(job: Job) -> dict[str, Any]:
    if job.status == "running":
        rc = job.process.poll()
        if rc is not None:
            job.exit_code = rc
            job.finished_at = time.time()
            _close_job_files(job)
            if job.stopped_by_user:
                job.status = "stopped"
            elif rc == 0:
                job.status = "completed"
            else:
                job.status = "failed"

    parsed = _parse_events(job.events_path, job.stderr_path)
    session_id = parsed["session_id"] or job.requested_session_id
    elapsed = round((job.finished_at or time.time()) - job.started_at, 2)
    detected_outcome = _detect_outcome(parsed["assistant_text"])

    attention_reasons: list[str] = []
    if job.status == "running":
        attention_reasons.append("job_running")
    if job.status == "failed" or (job.exit_code is not None and job.exit_code != 0):
        attention_reasons.append("process_failed")
    if parsed["errors"]:
        attention_reasons.append("runtime_errors")
    if detected_outcome == "BLOCKED":
        attention_reasons.append("reported_blocked")
    elif detected_outcome == "CHANGES_REQUIRED":
        attention_reasons.append("review_changes_required")
    elif job.status == "completed":
        if not parsed["assistant_text"]:
            attention_reasons.append("empty_assistant_reply")
        elif detected_outcome is None:
            attention_reasons.append("missing_status_or_verdict")

    payload: dict[str, Any] = {
        "job_id": job.job_id,
        "status": job.status,
        "role": job.role,
        "workdir": job.workdir,
        "model_requested": job.model,
        "model_reported": parsed["model_reported"],
        "agent": job.agent,
        "session_id": session_id,
        "exit_code": job.exit_code,
        "elapsed_seconds": elapsed,
        "event_count": parsed["event_count"],
        "detected_outcome": detected_outcome,
        "needs_attention": False,
        "attention_reasons": attention_reasons,
        "assistant_text": parsed["assistant_text"],
        "assistant_text_truncated": parsed["assistant_text_truncated"],
        "errors": parsed["errors"],
        "stderr_tail": parsed["stderr_tail"],
        "stderr_truncated": parsed["stderr_truncated"],
        "events_path": str(job.events_path),
        "stderr_path": str(job.stderr_path),
    }

    if job.role == "reviewer" and job.status != "running" and job.git_baseline is not None:
        after = _git_status_lines(job.workdir)
        if after is not None:
            new_changes = sorted(after - job.git_baseline)
            payload["workdir_changes_during_review"] = new_changes
            if new_changes:
                attention_reasons.append("reviewer_modified_workdir")

    payload["needs_attention"] = bool(attention_reasons)
    job.cached_summary = payload
    return payload


def _wait_job(job: Job, wait_seconds: float) -> dict[str, Any]:
    timeout = max(0.0, min(float(wait_seconds), MAX_WAIT_SECONDS))
    if job.status == "running" and timeout > 0:
        try:
            job.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            pass
    return _refresh_job(job)


def _resolve_opencode_bin(configured: str) -> str:
    resolved = shutil.which(configured)
    if resolved:
        return resolved
    candidate = Path(configured)
    if candidate.is_file() and os.access(candidate, os.X_OK):
        return str(candidate)
    raise FileNotFoundError(f"OpenCode binary not found or not executable: {configured}")


def _handle_opencode_run(args: dict[str, Any], opencode_bin: str) -> tuple[dict[str, Any], bool]:
    role = args.get("role")
    if role not in ("worker", "reviewer"):
        return {"error": "role must be 'worker' or 'reviewer'"}, True

    workdir = args.get("workdir")
    if not isinstance(workdir, str) or not workdir.strip():
        return {"error": "workdir is required"}, True
    workdir_path = Path(workdir).expanduser().resolve()
    if not workdir_path.is_dir():
        return {"error": f"workdir does not exist or is not a directory: {workdir}"}, True

    handoff_file = args.get("handoff_file")
    handoff_resolved: str | None = None
    if handoff_file is not None:
        if not isinstance(handoff_file, str) or not handoff_file.strip():
            return {"error": "handoff_file must be a non-empty file path when provided"}, True
        hp = Path(handoff_file).expanduser().resolve()
        if not hp.is_file():
            return {"error": f"handoff_file does not exist: {handoff_file}"}, True
        handoff_resolved = str(hp)

    prompt = args.get("prompt")
    if prompt is None:
        prompt = "按附件执行并回报" if handoff_resolved else ""
    if not isinstance(prompt, str) or (not prompt.strip() and not handoff_resolved):
        return {"error": "either handoff_file or a non-empty prompt is required"}, True

    model = args.get("model")
    if not isinstance(model, str) or not model.strip():
        return {"error": "model is required (expected provider/model or provider/model#variant)"}, True
    model = model.strip()
    if "/" not in model:
        return {"error": f"invalid model format (expected provider/model or provider/model#variant): {model}"}, True

    agent = args.get("agent")
    if agent is not None:
        if not isinstance(agent, str) or not agent.strip():
            return {"error": "agent must be a non-empty string when provided"}, True
        agent = agent.strip()

    session_id = args.get("session_id")
    if session_id is not None:
        if not isinstance(session_id, str) or not session_id.strip():
            return {"error": "session_id must be a non-empty string when provided"}, True
        session_id = session_id.strip()

    archived = bool(args.get("archived", False))
    wait_seconds = float(args.get("wait_seconds", 0.0))

    try:
        bin_path = _resolve_opencode_bin(opencode_bin)
    except FileNotFoundError as exc:
        return {"error": str(exc)}, True

    job_id = uuid.uuid4().hex[:12]
    LOG_ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    job_dir = LOG_ROOT / job_id
    job_dir.mkdir(parents=True, exist_ok=True)
    events_path = job_dir / "events.jsonl"
    stderr_path = job_dir / "stderr.log"

    cmd = [bin_path, "run", "--model", model, "--format", "json", "--auto"]
    if agent:
        cmd.extend(["--agent", agent])
    if session_id:
        cmd.extend(["--session", session_id])
    if archived:
        cmd.append("--archived")
    if handoff_resolved:
        cmd.extend(["--file", handoff_resolved])
    if prompt:
        cmd.append(prompt)

    git_baseline = _git_status_lines(str(workdir_path)) if role == "reviewer" else None

    stdout_fh = events_path.open("wb")
    stderr_fh = stderr_path.open("wb")
    try:
        proc = subprocess.Popen(
            cmd,
            cwd=str(workdir_path),
            stdin=subprocess.DEVNULL,
            stdout=stdout_fh,
            stderr=stderr_fh,
            start_new_session=True,
        )
    except OSError as exc:
        stdout_fh.close()
        stderr_fh.close()
        return {"error": f"Failed to launch opencode: {exc}"}, True

    job = Job(
        job_id=job_id,
        role=role,
        workdir=str(workdir_path),
        model=model,
        agent=agent,
        requested_session_id=session_id,
        handoff_file=handoff_resolved,
        prompt=prompt,
        events_path=events_path,
        stderr_path=stderr_path,
        stdout_fh=stdout_fh,
        stderr_fh=stderr_fh,
        process=proc,
        started_at=time.time(),
        git_baseline=git_baseline,
    )
    JOBS[job_id] = job
    result = _wait_job(job, wait_seconds)
    is_error = result["status"] == "failed"
    return result, is_error


def _handle_opencode_status(args: dict[str, Any]) -> tuple[dict[str, Any], bool]:
    job_id = args.get("job_id")
    if not isinstance(job_id, str) or job_id not in JOBS:
        return {"error": f"Unknown job_id: {job_id}"}, True
    wait_seconds = float(args.get("wait_seconds", 0.0))
    result = _wait_job(JOBS[job_id], wait_seconds)
    return result, result["status"] == "failed"


def _prune_old_logs() -> None:
    if not LOG_ROOT.is_dir():
        return
    now = time.time()
    entries: list[tuple[float, Path]] = []
    for child in LOG_ROOT.iterdir():
        if not child.is_dir():
            continue
        try:
            mtime = child.stat().st_mtime
        except OSError:
            continue
        entries.append((mtime, child))
    entries.sort(key=lambda item: item[0], reverse=True)
    for idx, (mtime, child) in enumerate(entries):
        if idx >= MAX_LOG_DIRS or (now - mtime) > LOG_RETENTION_SECONDS:
            shutil.rmtree(child, ignore_errors=True)


def _terminate_job_process(job: Job) -> None:
    if job.process.poll() is None:
        job.stopped_by_user = True
        try:
            pgid = os.getpgid(job.process.pid)
            os.killpg(pgid, signal.SIGTERM)
        except OSError:
            job.process.terminate()
        try:
            job.process.wait(timeout=3.0)
        except subprocess.TimeoutExpired:
            try:
                pgid = os.getpgid(job.process.pid)
                os.killpg(pgid, signal.SIGKILL)
            except OSError:
                job.process.kill()
            try:
                job.process.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                pass
    _close_job_files(job)


def _cleanup_all_jobs() -> None:
    for job in list(JOBS.values()):
        _terminate_job_process(job)


def _handle_opencode_stop(args: dict[str, Any]) -> tuple[dict[str, Any], bool]:
    job_id = args.get("job_id")
    if not isinstance(job_id, str) or job_id not in JOBS:
        return {"error": f"Unknown job_id: {job_id}"}, True
    job = JOBS[job_id]
    _refresh_job(job)
    if job.status == "running":
        _terminate_job_process(job)
    result = _refresh_job(job)
    return result, False


def _handle_opencode_list_jobs() -> tuple[dict[str, Any], bool]:
    items = []
    for job in JOBS.values():
        refreshed = _refresh_job(job)
        items.append(
            {
                "job_id": refreshed["job_id"],
                "role": refreshed["role"],
                "status": refreshed["status"],
                "session_id": refreshed["session_id"],
                "workdir": refreshed["workdir"],
                "model_requested": refreshed["model_requested"],
                "exit_code": refreshed["exit_code"],
                "elapsed_seconds": refreshed["elapsed_seconds"],
            }
        )
    return {"jobs": items}, False


TOOLS = [
    {
        "name": "opencode_run",
        "description": (
            "Start an OpenCode v2 worker or reviewer job asynchronously in the host environment outside the terminal sandbox. "
            "Returns status='running' with job_id immediately by default (wait_seconds=0), or waits up to wait_seconds (max 45s)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "role": {
                    "type": "string",
                    "enum": ["worker", "reviewer"],
                    "description": "Delegated role: 'worker' or 'reviewer'.",
                },
                "workdir": {
                    "type": "string",
                    "description": "Absolute path to the target project working directory.",
                },
                "handoff_file": {
                    "type": "string",
                    "description": "Optional absolute path to the handoff file attached via --file.",
                },
                "prompt": {
                    "type": "string",
                    "description": "Instruction message sent to OpenCode. Defaults to '按附件执行并回报' when handoff_file is given.",
                },
                "model": {
                    "type": "string",
                    "description": "Required model in provider/model or provider/model#variant format.",
                },
                "agent": {
                    "type": "string",
                    "description": "Optional OpenCode agent name passed via --agent (e.g. 'reviewer').",
                },
                "session_id": {
                    "type": "string",
                    "description": "Optional OpenCode session ID to continue via --session.",
                },
                "archived": {
                    "type": "boolean",
                    "description": "Whether to pass --archived to keep the session out of interactive lists.",
                },
                "wait_seconds": {
                    "type": "number",
                    "description": "Optional bounded wait in seconds (0-45, default 0 for immediate async return).",
                },
            },
            "required": ["role", "workdir", "model"],
        },
    },
    {
        "name": "opencode_status",
        "description": "Check an OpenCode job immediately (default wait_seconds=0) or wait up to wait_seconds (max 45s) and return its status, session_id, summary, and logs.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "job_id": {
                    "type": "string",
                    "description": "Job ID returned by opencode_run.",
                },
                "wait_seconds": {
                    "type": "number",
                    "description": "Optional bounded wait in seconds (0-45, default 0).",
                },
            },
            "required": ["job_id"],
        },
    },
    {
        "name": "opencode_stop",
        "description": "Terminate a running OpenCode job and its child process group.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "job_id": {
                    "type": "string",
                    "description": "Job ID returned by opencode_run.",
                }
            },
            "required": ["job_id"],
        },
    },
    {
        "name": "opencode_list_jobs",
        "description": "List all OpenCode jobs started in this MCP server session with their status and session_id.",
        "inputSchema": {
            "type": "object",
            "properties": {},
        },
    },
]


def _write_message(payload: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def _error_response(req_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}}


def _handle_request(msg: dict[str, Any], opencode_bin: str) -> dict[str, Any] | None:
    req_id = msg.get("id")
    method = msg.get("method")
    params = msg.get("params") or {}

    if method == "notifications/initialized" or method == "notifications/cancelled":
        return None

    if req_id is None:
        return None

    if method == "initialize":
        client_version = params.get("protocolVersion")
        negotiated = client_version if isinstance(client_version, str) and client_version else PROTOCOL_VERSION
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": negotiated,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "xz-agent-skills-opencode", "version": "0.1.0"},
            },
        }

    if method == "ping":
        return {"jsonrpc": "2.0", "id": req_id, "result": {}}

    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": req_id, "result": {"tools": TOOLS}}

    if method == "tools/call":
        name = params.get("name")
        arguments = params.get("arguments") or {}
        if not isinstance(arguments, dict):
            return _error_response(req_id, -32602, "Tool arguments must be an object")

        if name == "opencode_run":
            result, is_error = _handle_opencode_run(arguments, opencode_bin)
        elif name == "opencode_status":
            result, is_error = _handle_opencode_status(arguments)
        elif name == "opencode_stop":
            result, is_error = _handle_opencode_stop(arguments)
        elif name == "opencode_list_jobs":
            result, is_error = _handle_opencode_list_jobs()
        else:
            return _error_response(req_id, -32601, f"Unknown tool: {name}")

        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "content": [{"type": "text", "text": json.dumps(result, ensure_ascii=False, indent=2)}],
                "isError": is_error,
            },
        }

    return _error_response(req_id, -32601, f"Method not found: {method}")


def _ensure_standard_paths() -> None:
    current = os.environ.get("PATH", "")
    parts = [p for p in current.split(os.pathsep) if p]
    home = Path.home()
    extra_dirs = (
        str(home / ".opencode" / "bin"),
        str(home / ".local" / "bin"),
        str(home / ".bun" / "bin"),
        str(home / ".cargo" / "bin"),
        "/opt/homebrew/bin",
        "/usr/local/bin",
    )
    for extra in extra_dirs:
        if os.path.isdir(extra) and extra not in parts:
            parts.append(extra)
    os.environ["PATH"] = os.pathsep.join(parts)


def main() -> int:
    _ensure_standard_paths()
    _prune_old_logs()
    parser = argparse.ArgumentParser(description="OpenCode Stdio MCP Server")
    parser.add_argument("--opencode-bin", default=os.environ.get("OPENCODE_BIN", "opencode"))
    parsed = parser.parse_args()

    def _on_signal(_signum: int, _frame: Any) -> None:
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    try:
        for raw_line in sys.stdin:
            line = raw_line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError as exc:
                _write_message(_error_response(None, -32700, f"Parse error: {exc}"))
                continue
            if not isinstance(msg, dict):
                _write_message(_error_response(None, -32600, "Invalid Request"))
                continue
            response = _handle_request(msg, parsed.opencode_bin)
            if response is not None:
                _write_message(response)
    finally:
        _cleanup_all_jobs()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
