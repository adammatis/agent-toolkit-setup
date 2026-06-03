#!/usr/bin/env python3

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


HOME = Path.home()
CLAUDE_PROJECTS_DIR = HOME / ".claude" / "projects"
PATH_CANDIDATES = [
    "/opt/homebrew/bin",
    "/opt/homebrew/sbin",
    "/usr/local/bin",
    "/usr/local/sbin",
]


def resolve_command(binary: str) -> str:
    found = shutil.which(binary)
    if found:
        return found
    for candidate in PATH_CANDIDATES:
        path = Path(candidate) / binary
        if path.exists() and os.access(path, os.X_OK):
            return str(path)
    return binary


def run_command(cmd: list[str], cwd: Path | None = None) -> tuple[int, str, str]:
    proc = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        capture_output=True,
        text=True,
        env={
            **os.environ,
            "PATH": ":".join(PATH_CANDIDATES + [os.environ.get("PATH", "")]),
        },
    )
    return proc.returncode, proc.stdout, proc.stderr


def safe_int(value: Any) -> int:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, (int, float)):
        return int(value)
    return 0


def iso_cutoff(days: int | None) -> dt.datetime | None:
    if days is None:
        return None
    return dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)


def parse_timestamp(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    try:
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        return dt.datetime.fromisoformat(value)
    except ValueError:
        return None


def normalize_path_key(path: Path) -> str:
    return str(path).replace("/", "-")


def get_rtk_report(project_path: Path | None) -> dict[str, Any]:
    cmd = [resolve_command("rtk"), "gain", "--format", "json"]
    cwd = None
    if project_path is not None:
      cmd.append("--project")
      cwd = project_path

    code, stdout, stderr = run_command(cmd, cwd=cwd)
    if code != 0:
        return {
            "available": False,
            "error": stderr.strip() or stdout.strip() or "rtk gain failed",
        }

    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError:
        return {
            "available": False,
            "error": "rtk gain did not return valid JSON",
            "raw": stdout.strip(),
        }

    summary = payload.get("summary", {})
    return {
        "available": True,
        "scope": str(project_path) if project_path else "global",
        "total_commands": safe_int(summary.get("total_commands")),
        "total_input": safe_int(summary.get("total_input")),
        "total_output": safe_int(summary.get("total_output")),
        "total_saved": safe_int(summary.get("total_saved")),
        "avg_savings_pct": summary.get("avg_savings_pct", 0.0),
        "total_time_ms": safe_int(summary.get("total_time_ms")),
        "avg_time_ms": safe_int(summary.get("avg_time_ms")),
    }


def iter_claude_logs(project_path: Path | None) -> list[Path]:
    if not CLAUDE_PROJECTS_DIR.exists():
        return []

    if project_path is None:
        return sorted(CLAUDE_PROJECTS_DIR.rglob("*.jsonl"))

    specific_dir = CLAUDE_PROJECTS_DIR / normalize_path_key(project_path.resolve())
    if specific_dir.exists():
        return sorted(specific_dir.glob("*.jsonl"))

    return []


def session_has_caveman_markers(path: Path) -> bool:
    try:
        with path.open("r", encoding="utf-8") as fh:
            for line in fh:
                line_l = line.lower()
                if "/caveman" in line_l or "caveman mode" in line_l or "talk like caveman" in line_l:
                    return True
    except OSError:
        return False
    return False


def get_claude_report(project_path: Path | None, days: int | None) -> dict[str, Any]:
    logs = iter_claude_logs(project_path)
    cutoff = iso_cutoff(days)

    if not logs:
        return {
            "available": False,
            "error": "No Claude project logs found for the selected scope",
        }

    totals: dict[str, int] = {
        "sessions": 0,
        "assistant_messages": 0,
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_read_input_tokens": 0,
        "cache_creation_input_tokens": 0,
    }
    matched_logs = 0
    caveman_sessions = 0
    latest_ts: dt.datetime | None = None

    for log_path in logs:
        session_used = False
        caveman_marked = session_has_caveman_markers(log_path)
        try:
            with log_path.open("r", encoding="utf-8") as fh:
                for raw in fh:
                    raw = raw.strip()
                    if not raw:
                        continue
                    try:
                        event = json.loads(raw)
                    except json.JSONDecodeError:
                        continue

                    ts = parse_timestamp(event.get("timestamp"))
                    if cutoff is not None and ts is not None and ts < cutoff:
                        continue

                    if ts is not None and (latest_ts is None or ts > latest_ts):
                        latest_ts = ts

                    if event.get("type") != "assistant":
                        continue

                    usage = ((event.get("message") or {}).get("usage")) or {}
                    if not usage:
                        continue

                    session_used = True
                    totals["assistant_messages"] += 1
                    totals["input_tokens"] += safe_int(usage.get("input_tokens"))
                    totals["output_tokens"] += safe_int(usage.get("output_tokens"))
                    totals["cache_read_input_tokens"] += safe_int(usage.get("cache_read_input_tokens"))
                    totals["cache_creation_input_tokens"] += safe_int(usage.get("cache_creation_input_tokens"))
        except OSError:
            continue

        if session_used:
            matched_logs += 1
            totals["sessions"] += 1
            if caveman_marked:
                caveman_sessions += 1

    if matched_logs == 0:
        return {
            "available": False,
            "error": "Claude logs exist, but no usage records matched the selected scope",
        }

    actual_total = totals["input_tokens"] + totals["output_tokens"]
    cached_total = totals["cache_read_input_tokens"] + totals["cache_creation_input_tokens"]
    return {
        "available": True,
        "scope": str(project_path) if project_path else "global",
        "days": days,
        "sessions": totals["sessions"],
        "assistant_messages": totals["assistant_messages"],
        "input_tokens": totals["input_tokens"],
        "output_tokens": totals["output_tokens"],
        "cache_read_input_tokens": totals["cache_read_input_tokens"],
        "cache_creation_input_tokens": totals["cache_creation_input_tokens"],
        "actual_total_tokens": actual_total,
        "cached_total_tokens": cached_total,
        "latest_timestamp": latest_ts.isoformat() if latest_ts else None,
        "caveman_marker_sessions": caveman_sessions,
        "caveman_savings_available": False,
        "caveman_savings_note": (
            "Claude session logs expose real token usage, but Caveman savings are not persisted in a stable machine-readable file by default. "
            "Use /caveman-stats inside Claude for per-session savings when the hook is installed."
        ),
    }


def format_int(value: int) -> str:
    return f"{value:,}"


def print_text_report(report: dict[str, Any]) -> None:
    print("Agent usage report")
    print("")

    rtk = report["rtk"]
    print("RTK")
    if rtk.get("available"):
        print(f"  scope:           {rtk['scope']}")
        print(f"  commands:        {format_int(rtk['total_commands'])}")
        print(f"  total input:     {format_int(rtk['total_input'])}")
        print(f"  total output:    {format_int(rtk['total_output'])}")
        print(f"  tokens saved:    {format_int(rtk['total_saved'])}")
        print(f"  avg savings:     {rtk['avg_savings_pct']:.1f}%")
        print(f"  total time ms:   {format_int(rtk['total_time_ms'])}")
    else:
        print(f"  unavailable:     {rtk.get('error', 'unknown error')}")

    print("")
    claude = report["claude"]
    print("Claude")
    if claude.get("available"):
        print(f"  scope:           {claude['scope']}")
        if claude.get("days") is not None:
            print(f"  days:            {claude['days']}")
        print(f"  sessions:        {format_int(claude['sessions'])}")
        print(f"  assistant msgs:  {format_int(claude['assistant_messages'])}")
        print(f"  input tokens:    {format_int(claude['input_tokens'])}")
        print(f"  output tokens:   {format_int(claude['output_tokens'])}")
        print(f"  actual total:    {format_int(claude['actual_total_tokens'])}")
        print(f"  cache read:      {format_int(claude['cache_read_input_tokens'])}")
        print(f"  cache created:   {format_int(claude['cache_creation_input_tokens'])}")
        print(f"  cached total:    {format_int(claude['cached_total_tokens'])}")
        if claude.get("latest_timestamp"):
            print(f"  latest session:  {claude['latest_timestamp']}")
        print(f"  caveman marks:   {format_int(claude['caveman_marker_sessions'])} session(s)")
        print("  caveman saved:   unavailable via stable file")
        print(f"  note:            {claude['caveman_savings_note']}")
    else:
        print(f"  unavailable:     {claude.get('error', 'unknown error')}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Report RTK token savings and Claude token usage from local machine artifacts."
    )
    parser.add_argument(
        "--project",
        help="Project path for scoped RTK and Claude reporting.",
    )
    parser.add_argument(
        "--claude-days",
        type=int,
        default=None,
        help="Limit Claude log aggregation to the last N days.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit JSON instead of text.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    project_path = Path(args.project).expanduser().resolve() if args.project else None

    report = {
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "project": str(project_path) if project_path else None,
        "rtk": get_rtk_report(project_path),
        "claude": get_claude_report(project_path, args.claude_days),
    }

    if args.json:
        json.dump(report, sys.stdout, indent=2)
        print("")
    else:
        print_text_report(report)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
