"""Noturcode integration for local Hermes Agent CLI sessions.

The plugin sends session IDs, model metadata, lifecycle state, tool names, and
subagent IDs to the local Noturcode bridge. It never sends prompts, model
responses, tool arguments, or tool results. Noturcode reads conversation rows
from Hermes' own state.db in read-only mode.
"""
from __future__ import annotations

import atexit
import json
import os
import queue
import sqlite3
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Optional

_SOURCE = "hermes"
_BRIDGE = Path.home() / "Library/Application Support/Noturcode/bin/noturcode-bridge"
_EVENTS: "queue.Queue[list[str]]" = queue.Queue()
_NAMES: dict[str, str] = {}
_SUPPRESSED: set[str] = set()
_CURRENT_SESSION: Optional[str] = None
_WORKER_STARTED = False
_WORKER_LOCK = threading.Lock()


def _hermes_home() -> Path:
    try:
        from hermes_constants import get_hermes_home
        return Path(get_hermes_home())
    except Exception:
        return Path(os.environ.get("HERMES_HOME") or (Path.home() / ".hermes"))


def _is_local_terminal() -> bool:
    if os.environ.get("TERM_SESSION_ID") or os.environ.get("TMUX_PANE"):
        return True
    if os.environ.get("ZELLIJ_PANE_ID") or os.environ.get("KITTY_WINDOW_ID"):
        return True
    if os.environ.get("WEZTERM_PANE") or os.environ.get("WT_SESSION"):
        return True
    for stream in (sys.stdin, sys.stdout):
        try:
            if stream.isatty():
                return True
        except Exception:
            pass
    return False


def _worker() -> None:
    while True:
        args = _EVENTS.get()
        try:
            subprocess.run(
                [str(_BRIDGE), "emit", "--source", _SOURCE, *args, "--pid", str(os.getpid())],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=3,
                check=False,
            )
        except Exception:
            pass
        finally:
            _EVENTS.task_done()


def _start_worker() -> None:
    global _WORKER_STARTED
    if _WORKER_STARTED:
        return
    with _WORKER_LOCK:
        if _WORKER_STARTED:
            return
        thread = threading.Thread(target=_worker, name="noturcode-hermes-events", daemon=True)
        thread.start()
        _WORKER_STARTED = True


def _flush(timeout: float = 2.0) -> None:
    deadline = time.monotonic() + timeout
    while _EVENTS.unfinished_tasks and time.monotonic() < deadline:
        time.sleep(0.01)


def _session_row(session_id: str) -> dict[str, Any]:
    database = _hermes_home() / "state.db"
    if not database.is_file():
        return {}
    connection = None
    try:
        connection = sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True, timeout=0.1)
        connection.row_factory = sqlite3.Row
        row = connection.execute(
            """
            SELECT id, title, display_name, cwd, model, billing_provider,
                   profile_name, parent_session_id,
                   COALESCE(input_tokens, 0) + COALESCE(output_tokens, 0)
                     + COALESCE(cache_read_tokens, 0) + COALESCE(cache_write_tokens, 0)
                     + COALESCE(reasoning_tokens, 0) AS total_tokens
            FROM sessions WHERE id = ? LIMIT 1
            """,
            (session_id,),
        ).fetchone()
        return dict(row) if row is not None else {}
    except Exception:
        return {}
    finally:
        if connection is not None:
            try:
                connection.close()
            except Exception:
                pass


def _breadcrumb() -> dict[str, Any]:
    try:
        from hermes_cli.terminal_breadcrumbs import read_breadcrumb
        value = read_breadcrumb()
        return value if isinstance(value, dict) else {}
    except Exception:
        return {}


def _context(session_id: str) -> dict[str, Any]:
    row = _session_row(session_id)
    crumb = _breadcrumb()
    title = _NAMES.get(session_id) or row.get("display_name") or row.get("title")
    return {
        "name": str(title or "Hermes Agent"),
        "cwd": str(row.get("cwd") or crumb.get("cwd") or os.getcwd()),
        "model": str(row.get("model") or ""),
        "provider": str(row.get("billing_provider") or ""),
        "agent_role": str(row.get("profile_name") or ""),
        "parent": str(row.get("parent_session_id") or ""),
        "tokens": int(row.get("total_tokens") or 0),
        "transcript": str(_hermes_home() / "state.db"),
    }


def _theme() -> str:
    return str(os.environ.get("HERMES_TUI_THEME") or "").strip().lower()


def _append(args: list[str], option: str, value: Any) -> None:
    text = str(value or "").strip()
    if text:
        args.extend([option, text])


def _queue_event(
    kind: str,
    session_id: str,
    *,
    activity: str = "",
    error: str = "",
    subagent_id: str = "",
    subagent_type: str = "",
    force: bool = False,
) -> None:
    if not session_id or not _is_local_terminal() or not _BRIDGE.is_file():
        return
    if session_id in _SUPPRESSED and not force:
        return
    metadata = _context(session_id)
    args = ["--session", session_id, "--kind", kind]
    _append(args, "--name", metadata["name"])
    _append(args, "--cwd", metadata["cwd"])
    _append(args, "--transcript", metadata["transcript"])
    _append(args, "--provider", metadata["provider"])
    _append(args, "--model", metadata["model"])
    _append(args, "--theme", _theme())
    _append(args, "--agent-role", metadata["agent_role"])
    _append(args, "--activity", activity)
    _append(args, "--error", error)
    _append(args, "--subagent", subagent_id)
    _append(args, "--subagent-type", subagent_type)
    if kind == "responseCompleted" and metadata["tokens"] > 0:
        args.extend(["--session-tokens", str(metadata["tokens"])])
    _start_worker()
    _EVENTS.put(args)


def _emit_session(kind: str, session_id: str, **details: Any) -> None:
    global _CURRENT_SESSION
    if not session_id:
        return
    _CURRENT_SESSION = session_id
    metadata = _context(session_id)
    parent = metadata["parent"]
    if not parent:
        _queue_event(kind, session_id, **details)
        return

    role = metadata["agent_role"] or details.get("subagent_type") or "delegate"
    if kind in {"connect", "promptSubmitted"}:
        mapped = "subagentStarted"
    elif kind in {"responseCompleted", "sessionEnded"}:
        mapped = "subagentCompleted"
    elif kind == "failed":
        mapped = "subagentFailed"
    else:
        mapped = "subagentActivity"
    _queue_event(
        mapped,
        parent,
        activity=str(details.get("activity") or "working"),
        error=str(details.get("error") or ""),
        subagent_id=session_id,
        subagent_type=str(role),
    )


def _session_id(kwargs: dict[str, Any]) -> str:
    value = kwargs.get("session_id") or kwargs.get("task_id")
    if value:
        return str(value)
    crumb = _breadcrumb()
    return str(crumb.get("session_id") or _CURRENT_SESSION or "")


def _tool_label(value: Any) -> str:
    text = str(value or "tool").replace("_", " ").replace("-", " ")
    return " ".join(part.capitalize() for part in text.split()) or "Tool"


def _on_session_start(session_id: str = "", **kwargs: Any) -> None:
    _emit_session("connect", str(session_id or _session_id(kwargs)))


def _on_pre_llm_call(session_id: str = "", **kwargs: Any) -> None:
    sid = str(session_id or _session_id(kwargs))
    _emit_session("connect", sid)
    _emit_session("promptSubmitted", sid, activity="thinking")


def _on_pre_api_request(session_id: str = "", **kwargs: Any) -> None:
    sid = str(session_id or _session_id(kwargs))
    if sid:
        _emit_session("metadataUpdated", sid)


def _on_post_llm_call(session_id: str = "", **kwargs: Any) -> None:
    _emit_session("responseCompleted", str(session_id or _session_id(kwargs)))


def _on_pre_tool_call(tool_name: str = "", **kwargs: Any) -> None:
    _emit_session(
        "activityStarted",
        _session_id(kwargs),
        activity=_tool_label(tool_name),
    )


def _on_post_tool_call(tool_name: str = "", **kwargs: Any) -> None:
    _emit_session(
        "activityFinished",
        _session_id(kwargs),
        activity=_tool_label(tool_name),
    )


def _on_session_end(session_id: str = "", **kwargs: Any) -> None:
    sid = str(session_id or _session_id(kwargs))
    if kwargs.get("failed"):
        _emit_session("failed", sid, error="Hermes reported a failed turn")
    elif kwargs.get("interrupted"):
        _emit_session("turnInterrupted", sid)


def _on_session_finalize(session_id: str = "", **kwargs: Any) -> None:
    sid = str(session_id or _session_id(kwargs))
    _emit_session("sessionEnded", sid)
    _flush()


def _on_session_reset(session_id: str = "", **kwargs: Any) -> None:
    sid = str(session_id or kwargs.get("new_session_id") or _session_id(kwargs))
    _emit_session("connect", sid)


def _on_subagent_start(
    parent_session_id: Any = None,
    child_session_id: Any = None,
    child_role: str = "",
    **kwargs: Any,
) -> None:
    parent = str(parent_session_id or _session_id(kwargs))
    child = str(child_session_id or "")
    _queue_event(
        "subagentStarted",
        parent,
        activity="working",
        subagent_id=child,
        subagent_type=child_role or "delegate",
    )


def _on_subagent_stop(
    parent_session_id: Any = None,
    child_session_id: Any = None,
    child_role: str = "",
    child_status: Any = None,
    **kwargs: Any,
) -> None:
    status = str(child_status or "").lower()
    _queue_event(
        "subagentFailed" if status in {"failed", "error"} else "subagentCompleted",
        str(parent_session_id or _session_id(kwargs)),
        subagent_id=str(child_session_id or ""),
        subagent_type=child_role or "delegate",
        error="Hermes subagent failed" if status in {"failed", "error"} else "",
    )


def _handle_nc(raw_args: str) -> str:
    sid = _session_id({})
    if not sid:
        return "Noturcode could not find this Hermes session ID."
    value = raw_args.strip()
    if not value:
        return "Usage: /nc <name> or /nc stop"
    if value.lower() == "stop":
        _SUPPRESSED.add(sid)
        _queue_event("disconnect", sid, force=True)
        _flush()
        return "Disconnected this Hermes session from Noturcode. Hermes is still running."
    _SUPPRESSED.discard(sid)
    _NAMES[sid] = value
    _queue_event("connect", sid)
    _queue_event("metadataUpdated", sid)
    return f"Noturcode session name: {value}"


def _shutdown() -> None:
    if _CURRENT_SESSION and _CURRENT_SESSION not in _SUPPRESSED:
        _emit_session("sessionEnded", _CURRENT_SESSION)
    _flush(1.5)


def register(ctx: Any) -> None:
    ctx.register_hook("on_session_start", _on_session_start)
    ctx.register_hook("pre_llm_call", _on_pre_llm_call)
    ctx.register_hook("post_llm_call", _on_post_llm_call)
    ctx.register_hook("pre_api_request", _on_pre_api_request)
    ctx.register_hook("pre_tool_call", _on_pre_tool_call)
    ctx.register_hook("post_tool_call", _on_post_tool_call)
    ctx.register_hook("on_session_end", _on_session_end)
    ctx.register_hook("on_session_finalize", _on_session_finalize)
    ctx.register_hook("on_session_reset", _on_session_reset)
    ctx.register_hook("subagent_start", _on_subagent_start)
    ctx.register_hook("subagent_stop", _on_subagent_stop)
    ctx.register_command(
        "nc",
        handler=_handle_nc,
        description="Name or disconnect this Hermes session in Noturcode.",
        args_hint="<name|stop>",
    )


atexit.register(_shutdown)
