#!/usr/bin/env python3
"""
codex2agy.py — Cross-platform OpenAI Codex -> Google Antigravity native session & project converter.

Supports macOS, Linux, and Windows using ONLY the Python 3.8+ standard library (zero pip dependencies).
Writes Antigravity's complete 5-layer native storage format:
  1. conversations/<conversation_id>.db       (SQLite user_version=1 + CortexStep binary Protobuf)
  2. annotations/<conversation_id>.pbtxt      (Go prototext persistent title & view timestamp)
  3. projects/<project_id>.json               (Antigravity Project config for ~/.gemini/config/projects)
  4. brain/<conversation_id>/.system_generated/logs/transcript.jsonl & transcript_full.jsonl
  5. conversation_summaries.db                (SQLite user_version=3 + CascadeRunSummary Protobuf)
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

EPOCH_UTC = datetime(1970, 1, 1, tzinfo=timezone.utc)

RX_ENV_BLOCK = re.compile(
    r"^\s*<(environment_context|permissions|collaboration_mode|app-context|user_instructions|"
    r"system-reminder|turn_aborted|subagent_notification|external_codex_[a-z0-9_]+)\b[\s\S]*</\1>\s*$",
    re.IGNORECASE,
)
RX_INLINE_SYS_TAGS = re.compile(
    r"<(environment_context|permissions[^>\s]*|collaboration_mode|app-context|"
    r"user_instructions|system-reminder|external_codex_[a-z0-9_]+)\b[^>]*>[\s\S]*?</\1>",
    re.IGNORECASE,
)
RX_WIN_DRIVE = re.compile(r"^[A-Za-z]:([\\/]|$)")
RX_UUID_TAIL = re.compile(r"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$")


# =============================================================================
# 1. Minimal Zero-Dependency Protobuf Wire Encoder & Validator (Proto3)
# =============================================================================
class ProtoWriter:
    def __init__(self) -> None:
        self._buf = bytearray()

    def to_bytes(self) -> bytes:
        return bytes(self._buf)

    def write_varint(self, value: int) -> None:
        v = value & 0xFFFFFFFFFFFFFFFF
        while v >= 0x80:
            self._buf.append((v & 0x7F) | 0x80)
            v >>= 7
        self._buf.append(v)

    def write_tag(self, field_number: int, wire_type: int) -> None:
        self.write_varint((field_number << 3) | (wire_type & 7))

    def write_int64_field(self, field_number: int, value: int, write_default: bool = False) -> None:
        if value == 0 and not write_default:
            return
        self.write_tag(field_number, 0)
        self.write_varint(value)

    def write_bytes_field(self, field_number: int, data: Optional[bytes], write_empty: bool = False) -> None:
        if data is None:
            return
        if len(data) == 0 and not write_empty:
            return
        self.write_tag(field_number, 2)
        self.write_varint(len(data))
        if data:
            self._buf.extend(data)

    def write_string_field(self, field_number: int, value: Optional[str], write_empty: bool = False) -> None:
        if value is None:
            return
        if len(value) == 0 and not write_empty:
            return
        self.write_bytes_field(field_number, value.encode("utf-8"), write_empty)

    def write_timestamp_field(self, field_number: int, dt: datetime) -> None:
        utc = dt.astimezone(timezone.utc)
        delta = utc - EPOCH_UTC
        unix_sec = int(delta.days * 86400 + delta.seconds)
        nanos = int(delta.microseconds * 1000)
        sub = ProtoWriter()
        sub.write_int64_field(1, unix_sec, False)
        sub.write_int64_field(2, nanos, False)
        self.write_bytes_field(field_number, sub.to_bytes(), True)


def deterministic_uuid_v4(ns: str, text: str) -> str:
    digest = bytearray(hashlib.md5(f"{ns}:{text.lower()}".encode("utf-8")).digest())
    digest[6] = (digest[6] & 0x0F) | 0x40
    digest[8] = (digest[8] & 0x3F) | 0x80
    hx = digest.hex()
    return f"{hx[0:8]}-{hx[8:12]}-{hx[12:16]}-{hx[16:20]}-{hx[20:32]}"


def deterministic_hex32(ns: str, text: str) -> str:
    return deterministic_uuid_v4(ns, text).replace("-", "")


def escape_pbtxt_string(s: str) -> str:
    out: List[str] = []
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif ord(ch) >= 0x20:
            out.append(ch)
    return "".join(out)


def build_annotation_pbtxt(title: str, view_time: datetime) -> str:
    utc = view_time.astimezone(timezone.utc)
    delta = utc - EPOCH_UTC
    sec = int(delta.days * 86400 + delta.seconds)
    nanos = int(delta.microseconds * 1000) or 1000000
    return (
        f'title:"{escape_pbtxt_string(title)}" '
        f"last_user_view_time:{{seconds:{sec} nanos:{nanos}}} "
        f"permission_preset:AGENT_PERMISSION_PRESET_TURBO"
    )


def build_trajectory_metadata(created_at: datetime, execution_id: str, cascade_id: str, project_id: str) -> bytes:
    pw = ProtoWriter()
    pw.write_timestamp_field(2, created_at)
    pw.write_string_field(3, execution_id)
    pw.write_string_field(6, cascade_id)
    pw.write_string_field(18, project_id if project_id else "outside-of-project")
    return pw.to_bytes()


def _build_step_info(trajectory_id: str, step_idx: int, turn_idx: int, cascade_id: str) -> bytes:
    pw = ProtoWriter()
    pw.write_string_field(1, trajectory_id)
    pw.write_int64_field(2, step_idx, False)
    pw.write_int64_field(3, turn_idx, False)
    pw.write_string_field(4, cascade_id)
    return pw.to_bytes()


def _build_status_transition_item(status_enum: int, ts: datetime) -> bytes:
    pw = ProtoWriter()
    pw.write_int64_field(1, status_enum, False)
    pw.write_timestamp_field(2, ts)
    return pw.to_bytes()


def build_user_input_step(
    cascade_id: str,
    trajectory_id: str,
    turn_exec_id: str,
    step_idx: int,
    turn_idx: int,
    ts: datetime,
    user_text: str,
) -> Tuple[bytes, bytes]:
    step_hex = deterministic_hex32("step", f"{cascade_id}:{step_idx}")
    cmsg_uuid = deterministic_uuid_v4("cmsg", f"{cascade_id}:{step_idx}")

    trans = ProtoWriter()
    trans.write_bytes_field(1, _build_status_transition_item(3, ts), True)

    meta = ProtoWriter()
    meta.write_timestamp_field(1, ts)
    meta.write_int64_field(3, 4)  # CORTEX_STEP_SOURCE_USER_EXPLICIT = 4
    meta.write_string_field(12, turn_exec_id)
    meta.write_bytes_field(20, _build_step_info(trajectory_id, step_idx, turn_idx, cascade_id), True)
    meta.write_bytes_field(26, trans.to_bytes(), True)
    meta.write_string_field(35, step_hex)
    meta_bytes = meta.to_bytes()

    item = ProtoWriter()
    item.write_string_field(1, user_text, True)

    uin = ProtoWriter()
    uin.write_string_field(2, user_text, True)
    uin.write_bytes_field(3, item.to_bytes(), True)
    uin.write_string_field(4, "", True)
    uin.write_string_field(16, f"client_msg:{cmsg_uuid}")
    uin.write_string_field(19, cmsg_uuid)

    step = ProtoWriter()
    step.write_int64_field(1, 14)  # CORTEX_STEP_TYPE_USER_INPUT = 14
    step.write_int64_field(4, 3)   # CORTEX_STEP_STATUS_DONE = 3
    step.write_bytes_field(5, meta_bytes, True)
    step.write_bytes_field(19, uin.to_bytes(), True)
    return meta_bytes, step.to_bytes()


def build_planner_response_step(
    cascade_id: str,
    trajectory_id: str,
    turn_exec_id: str,
    step_idx: int,
    turn_idx: int,
    ts: datetime,
    response_text: str,
    thinking_text: Optional[str],
) -> Tuple[bytes, bytes]:
    step_hex = deterministic_hex32("step", f"{cascade_id}:{step_idx}")

    trans = ProtoWriter()
    trans.write_bytes_field(1, _build_status_transition_item(8, ts), True)
    trans.write_bytes_field(1, _build_status_transition_item(3, ts), True)

    meta = ProtoWriter()
    meta.write_timestamp_field(1, ts)
    meta.write_int64_field(3, 2)  # CORTEX_STEP_SOURCE_MODEL = 2
    meta.write_timestamp_field(6, ts)
    meta.write_timestamp_field(7, ts)
    meta.write_timestamp_field(8, ts)
    meta.write_string_field(12, turn_exec_id)
    meta.write_bytes_field(20, _build_step_info(trajectory_id, step_idx, turn_idx, cascade_id), True)
    meta.write_bytes_field(26, trans.to_bytes(), True)
    meta.write_timestamp_field(32, ts)
    meta.write_string_field(35, step_hex)
    meta_bytes = meta.to_bytes()

    pr = ProtoWriter()
    pr.write_string_field(1, response_text, True)
    if thinking_text and thinking_text.strip():
        pr.write_string_field(3, thinking_text)
    pr.write_string_field(8, response_text, True)
    pr.write_int64_field(12, 2)  # stop_reason = 2

    step = ProtoWriter()
    step.write_int64_field(1, 15)  # CORTEX_STEP_TYPE_PLANNER_RESPONSE = 15
    step.write_int64_field(4, 3)   # CORTEX_STEP_STATUS_DONE = 3
    step.write_bytes_field(5, meta_bytes, True)
    step.write_bytes_field(20, pr.to_bytes(), True)
    return meta_bytes, step.to_bytes()


def build_cascade_run_summary(
    title: str,
    step_count: int,
    created_at: datetime,
    updated_at: datetime,
    last_user_at: datetime,
    last_user_step_idx: int,
    trajectory_id: str,
    execution_id: str,
    cascade_id: str,
    project_id: str,
) -> bytes:
    title_info = ProtoWriter()
    title_info.write_string_field(1, title)
    title_info.write_timestamp_field(7, updated_at)
    title_info.write_int64_field(19, 3)  # AGENT_PERMISSION_PRESET_TURBO = 3

    pid = project_id if project_id else "outside-of-project"
    traj_meta = build_trajectory_metadata(created_at, execution_id, cascade_id, pid)

    s = ProtoWriter()
    s.write_string_field(1, title)
    s.write_int64_field(2, step_count)
    s.write_timestamp_field(3, updated_at)
    s.write_string_field(4, trajectory_id)
    s.write_int64_field(5, 1)  # CASCADE_RUN_STATUS_IDLE = 1
    s.write_timestamp_field(7, created_at)
    s.write_timestamp_field(10, last_user_at)
    s.write_bytes_field(15, title_info.to_bytes(), True)
    if last_user_step_idx >= 0:
        s.write_int64_field(16, last_user_step_idx, True)
    s.write_bytes_field(17, traj_meta, True)
    s.write_int64_field(22, 4)
    s.write_int64_field(26, 1)
    s.write_int64_field(28, 4)
    return s.to_bytes()


def validate_proto_wire(buf: Optional[bytes]) -> bool:
    if not buf:
        return False
    pos, end = 0, len(buf)
    while pos < end:
        tag, shift = 0, 0
        while pos < end and shift < 70:
            b = buf[pos]
            pos += 1
            tag |= (b & 0x7F) << shift
            if (b & 0x80) == 0:
                break
            shift += 7
        if tag == 0 or (tag >> 3) == 0:
            return False
        wt = tag & 7
        if wt == 0:
            shift, ok = 0, False
            while pos < end and shift < 70:
                b = buf[pos]
                pos += 1
                if (b & 0x80) == 0:
                    ok = True
                    break
                shift += 7
            if not ok:
                return False
        elif wt == 1:
            if pos + 8 > end:
                return False
            pos += 8
        elif wt == 2:
            ln, shift, ok = 0, 0, False
            while pos < end and shift < 70:
                b = buf[pos]
                pos += 1
                ln |= (b & 0x7F) << shift
                if (b & 0x80) == 0:
                    ok = True
                    break
                shift += 7
            if not ok or ln > (end - pos):
                return False
            pos += ln
        elif wt == 5:
            if pos + 4 > end:
                return False
            pos += 4
        else:
            return False
    return pos == end


# =============================================================================
# 2. Cross-Platform Path & URI Utilities (macOS, Linux, Windows)
# =============================================================================
def clean_fs_path(raw: Optional[str]) -> str:
    if not raw or not raw.strip():
        return ""
    s = raw.strip()
    if s.startswith("\\\\?\\"):
        s = s[4:]
    if RX_WIN_DRIVE.match(s):
        s = s.replace("/", "\\")
        if len(s) > 3:
            s = s.rstrip("\\")
        return s
    s = re.sub(r"/+", "/", s)
    if len(s) > 1:
        s = s.rstrip("/")
    return s


def normalize_lookup_key(raw: Optional[str]) -> str:
    p = clean_fs_path(raw)
    if not p:
        return ""
    if RX_WIN_DRIVE.match(p):
        return p.replace("\\", "/").rstrip("/").lower()
    if os.name != "nt" and os.path.exists(p):
        try:
            p = os.path.realpath(p)
        except OSError:
            pass
    p = p.rstrip("/") or "/"
    if sys.platform == "darwin":
        return p.lower()
    return p


def path_to_vscode_file_uri(raw: Optional[str]) -> str:
    p = clean_fs_path(raw)
    if not p:
        return ""
    if RX_WIN_DRIVE.match(p):
        norm = p.replace("\\", "/").rstrip("/")
        drive = norm[0].lower() + "%3A"
        rest = norm[2:].lstrip("/")
        if not rest:
            return f"file:///{drive}/"
        segs = [urllib.parse.quote(seg, safe="-._~") for seg in rest.split("/") if seg]
        return f"file:///{drive}/" + "/".join(segs)
    if p.startswith("/"):
        segs = [urllib.parse.quote(seg, safe="-._~") for seg in p.split("/") if seg]
        return "file:///" + "/".join(segs)
    return ""


def find_latest_versioned_sqlite(directory: Path, prefix: str) -> Optional[Path]:
    best_ver = -1
    best_path: Optional[Path] = None
    pat = re.compile(rf"^{re.escape(prefix)}_(\d+)\.sqlite$", re.IGNORECASE)
    if not directory.is_dir():
        return None
    for entry in directory.iterdir():
        if entry.is_file():
            m = pat.match(entry.name)
            if m:
                ver = int(m.group(1))
                if ver > best_ver:
                    best_ver = ver
                    best_path = entry
    return best_path


def open_sqlite_ro(path: Path) -> sqlite3.Connection:
    # Open read-only when possible; fallback to standard connect if WAL shm requires read-write open
    try:
        uri = path.resolve().as_uri() + "?mode=ro"
        conn = sqlite3.connect(uri, uri=True)
        conn.row_factory = sqlite3.Row
        conn.execute("SELECT 1 FROM sqlite_master LIMIT 1").fetchall()
        return conn
    except sqlite3.Error:
        conn = sqlite3.connect(str(path))
        conn.row_factory = sqlite3.Row
        return conn


# =============================================================================
# 3. Codex Parsing & Session Conversion
# =============================================================================
def parse_timestamp(raw: Any, fallback: datetime) -> datetime:
    if raw is None:
        return fallback
    s = str(raw).strip()
    if not s:
        return fallback
    if re.fullmatch(r"-?\d+", s):
        val = int(s)
        if val > 1_000_000_000_000:
            return datetime.fromtimestamp(val / 1000.0, tz=timezone.utc)
        if val > 100_000_000:
            return datetime.fromtimestamp(float(val), tz=timezone.utc)
    try:
        iso = s.replace("Z", "+00:00")
        dt = datetime.fromisoformat(iso)
        return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
    except ValueError:
        return fallback


def clean_user_text(raw: Optional[str]) -> str:
    if not raw or not raw.strip():
        return ""
    s = raw.strip()
    if RX_ENV_BLOCK.match(s):
        return ""
    sl = s.lower()
    if sl.startswith("# agents.md instructions for "):
        return ""
    if sl.startswith("<permissions instructions>") and sl.endswith("</permissions instructions>"):
        return ""
    if sl.startswith("<instructions>") and sl.endswith("</instructions>"):
        return ""
    s = RX_INLINE_SYS_TAGS.sub("", s).strip()
    if RX_ENV_BLOCK.match(s):
        return ""
    return s


def clean_title(raw: Optional[str]) -> str:
    if not raw or not raw.strip():
        return ""
    s = raw.strip()
    m_req = re.search(r"##\s*My request:\s*([\s\S]+)$", s, re.IGNORECASE)
    if m_req and m_req.group(1).strip():
        s = m_req.group(1).strip()
    elif s.lower().startswith("# files "):
        m_q = re.search(r'##\s*"([^"]+)"', s)
        if m_q:
            s = m_q.group(1).strip()
    s = re.sub(r"^#+\s*", "", s)
    s = re.sub(r"\[([^\]]+)\]\([^\)]+\)", r"\1", s)
    no_url = re.sub(r"https?://\S+", "", s).strip()
    if len(no_url) >= 4:
        s = no_url
    s = re.sub(r"\s+", " ", s).strip()
    if len(s) > 36:
        s = s[:36].strip() + "..."
    return s


def truncate_one_line(s: Optional[str], max_len: int) -> str:
    if not s:
        return ""
    c = re.sub(r"\s+", " ", s).strip()
    return c if len(c) <= max_len else (c[:max_len] + "...")


def extract_content_parts(content_obj: Any, is_user: bool) -> str:
    if content_obj is None:
        return ""
    if isinstance(content_obj, str):
        return clean_user_text(content_obj) if is_user else content_obj.strip()
    if not isinstance(content_obj, list):
        return ""
    parts: List[str] = []
    for elem in content_obj:
        if isinstance(elem, str):
            st = clean_user_text(elem) if is_user else elem.strip()
            if st:
                parts.append(st)
            continue
        if not isinstance(elem, dict):
            continue
        pt = str(elem.get("type") or "").strip()
        if pt in ("input_text", "output_text", "text"):
            txt = str(elem.get("text") or "")
            txt = clean_user_text(txt) if is_user else txt.strip()
            if txt:
                parts.append(txt)
        elif pt in ("input_image", "image_url", "image", "localImage", "local_image"):
            p = elem.get("path")
            parts.append(f"`[Image: {p}]`" if p else "`[Image Attachment]`")
    return "\n\n".join(parts).strip()


def parse_jsonl_events(path: Path) -> Tuple[List[Dict[str, Any]], Optional[str], Optional[str], Optional[str], Optional[str]]:
    found_id: Optional[str] = None
    found_cwd: Optional[str] = None
    agent_role: Optional[str] = None
    source_kind: Optional[str] = None

    m_uuid = RX_UUID_TAIL.search(path.stem)
    if m_uuid:
        found_id = m_uuid.group(1).lower()

    resp_events: List[Dict[str, Any]] = []
    fallback_events: List[Dict[str, Any]] = []
    has_resp_msgs = False
    last_ts = datetime.now(timezone.utc)

    with path.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(obj, dict):
                continue

            last_ts = parse_timestamp(obj.get("timestamp"), last_ts)
            top_type = obj.get("type")
            payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else None

            if top_type == "session_meta" and payload:
                pid = payload.get("id")
                if pid:
                    found_id = str(pid).lower()
                if not found_cwd and payload.get("cwd"):
                    found_cwd = str(payload.get("cwd"))
                if not agent_role and payload.get("agent_role"):
                    agent_role = str(payload.get("agent_role"))
                if payload.get("source") is not None:
                    src = payload.get("source")
                    source_kind = src if isinstance(src, str) else json.dumps(src, ensure_ascii=False)
            elif top_type == "turn_context" and payload:
                if payload.get("cwd"):
                    found_cwd = str(payload.get("cwd"))
            elif top_type == "response_item" and payload:
                ptype = payload.get("type")
                if ptype == "message":
                    role = payload.get("role")
                    if role in ("user", "assistant"):
                        txt = extract_content_parts(payload.get("content"), role == "user")
                        if txt:
                            has_resp_msgs = True
                            resp_events.append({"kind": role, "text": txt, "ts": last_ts})
                elif ptype == "reasoning":
                    rsum = extract_content_parts(payload.get("summary"), False)
                    if rsum:
                        resp_events.append({"kind": "thinking", "text": rsum, "ts": last_ts})
                elif ptype in ("function_call", "custom_tool_call"):
                    tn = str(payload.get("name") or "tool")
                    ta = str(payload.get("arguments") or payload.get("input") or "")
                    resp_events.append({"kind": "tool", "text": f"[Tool] {tn}: {truncate_one_line(ta, 140)}", "ts": last_ts})
                elif ptype == "local_shell_call":
                    act = payload.get("action") if isinstance(payload.get("action"), dict) else {}
                    cmd_list = act.get("command") if isinstance(act.get("command"), list) else []
                    cmd = " ".join(str(x) for x in cmd_list)
                    resp_events.append({"kind": "tool", "text": f"[Shell] {truncate_one_line(cmd, 140)}", "ts": last_ts})
            elif top_type == "event_msg" and payload:
                et = payload.get("type")
                if et == "user_message":
                    m = clean_user_text(str(payload.get("message") or ""))
                    if m:
                        fallback_events.append({"kind": "user", "text": m, "ts": last_ts})
                elif et == "agent_message":
                    m = str(payload.get("message") or "").strip()
                    if m:
                        fallback_events.append({"kind": "assistant", "text": m, "ts": last_ts})
            elif top_type == "message" or "role" in obj:
                role = obj.get("role")
                if role in ("user", "assistant"):
                    txt = extract_content_parts(obj.get("content"), role == "user")
                    if txt:
                        has_resp_msgs = True
                        resp_events.append({"kind": role, "text": txt, "ts": last_ts})

    return (resp_events if has_resp_msgs else fallback_events), found_id, found_cwd, agent_role, source_kind


def parse_sqlite_item(item_type_col: Optional[str], item_json: Optional[str], ts: datetime) -> Optional[Dict[str, Any]]:
    if not item_json or not item_json.strip():
        return None
    try:
        obj = json.loads(item_json)
    except json.JSONDecodeError:
        return None
    if not isinstance(obj, dict):
        return None
    if "type" not in obj and isinstance(obj.get("item"), dict):
        obj = obj["item"]

    itype = str(obj.get("type") or item_type_col or "").strip()
    il = itype.lower()

    if il in ("usermessage", "user_message"):
        txt = extract_content_parts(obj.get("content"), True)
        if not txt:
            txt = clean_user_text(str(obj.get("text") or obj.get("message") or ""))
        return {"kind": "user", "text": txt, "ts": ts} if txt else None
    if il in ("agentmessage", "agent_message", "assistantmessage", "assistant_message"):
        txt = str(obj.get("text") or obj.get("message") or "").strip()
        if not txt:
            txt = extract_content_parts(obj.get("content"), False)
        return {"kind": "assistant", "text": txt, "ts": ts} if txt else None
    if il == "plan":
        txt = str(obj.get("text") or extract_content_parts(obj.get("content"), False) or "").strip()
        return {"kind": "assistant", "text": "**[Codex Plan]**\n\n" + txt, "ts": ts} if txt else None
    if il == "message":
        role = str(obj.get("role") or "").lower()
        if role in ("user", "assistant"):
            txt = extract_content_parts(obj.get("content"), role == "user")
            if txt:
                return {"kind": role, "text": txt, "ts": ts}
        return None
    if il == "reasoning":
        rsum = extract_content_parts(obj.get("summary"), False)
        return {"kind": "thinking", "text": rsum, "ts": ts} if rsum else None
    if il in ("commandexecution", "command_execution", "localshellcall", "local_shell_call"):
        cmd = str(obj.get("command") or "")
        return {"kind": "tool", "text": f"[Command] {truncate_one_line(cmd, 140)}", "ts": ts}
    if il in ("filechange", "file_change"):
        changes = obj.get("changes") if isinstance(obj.get("changes"), list) else []
        ps = [str(c.get("path")) for c in changes if isinstance(c, dict) and c.get("path")]
        return {"kind": "tool", "text": f"[FileChange] {truncate_one_line(', '.join(ps), 140)}", "ts": ts}
    if il in ("mcptoolcall", "mcp_tool_call", "dynamictoolcall", "function_call", "custom_tool_call", "websearch", "web_search"):
        tn = str(obj.get("tool") or obj.get("name") or obj.get("query") or itype)
        return {"kind": "tool", "text": f"[{itype}] {truncate_one_line(tn, 140)}", "ts": ts}
    return None


def build_converted_session(
    codex_thread_id: str,
    raw_title: str,
    title_prefix: str,
    cwd: str,
    archived: bool,
    agy_project_id: str,
    agy_project_name: str,
    workspace_uri: str,
    meta_created: Optional[datetime],
    meta_updated: Optional[datetime],
    events: List[Dict[str, Any]],
) -> Optional[Dict[str, Any]]:
    tid = codex_thread_id.lower()
    agy_conv_id = deterministic_uuid_v4("agy-conv", tid)
    agy_traj_id = deterministic_uuid_v4("agy-traj", tid)
    agy_exec_id = deterministic_uuid_v4("agy-exec", tid)

    base_title = clean_title(raw_title)
    steps: List[Dict[str, Any]] = []
    pending_notes: List[str] = []
    prev_kind, prev_text = None, None
    first_user_text: Optional[str] = None
    user_turns = 0
    assistant_turns = 0

    for ev in events:
        if not ev or not str(ev.get("text") or "").strip():
            continue
        k, txt, ts = ev["kind"], ev["text"], ev["ts"]
        if k == prev_kind and txt == prev_text:
            continue
        prev_kind, prev_text = k, txt

        if k in ("thinking", "tool"):
            if len(pending_notes) < 60:
                pending_notes.append(txt)
            continue

        if k == "user":
            if first_user_text is None:
                first_user_text = txt
            steps.append({"is_user": True, "content": txt, "thinking": None, "ts": ts})
            user_turns += 1
        elif k == "assistant":
            if not steps:
                synth = base_title if base_title else f"Codex {tid[:8]}"
                steps.append({"is_user": True, "content": synth, "thinking": None, "ts": ts})
                user_turns += 1
            thinking_joined = "\n".join(pending_notes) if pending_notes else None
            pending_notes.clear()
            steps.append({"is_user": False, "content": txt, "thinking": thinking_joined, "ts": ts})
            assistant_turns += 1

    if not steps:
        return None

    created_at = meta_created or steps[0]["ts"]
    updated_at = meta_updated or steps[-1]["ts"]

    if not base_title:
        base_title = clean_title(first_user_text)
    if not base_title:
        base_title = f"Codex Session {tid[:8]}"

    full_title = (title_prefix or "") + base_title
    preview = truncate_one_line(first_user_text, 100) if first_user_text else full_title

    return {
        "codex_thread_id": tid,
        "agy_conversation_id": agy_conv_id,
        "agy_trajectory_id": agy_traj_id,
        "agy_execution_id": agy_exec_id,
        "agy_project_id": agy_project_id or "outside-of-project",
        "agy_project_name": agy_project_name or "",
        "workspace_uri": workspace_uri or "",
        "title": full_title,
        "preview": preview,
        "cwd": clean_fs_path(cwd),
        "archived": archived,
        "created_at": created_at,
        "updated_at": updated_at,
        "steps": steps,
        "user_turns": user_turns,
        "assistant_turns": assistant_turns,
    }


# =============================================================================
# 4. Antigravity 5-Layer Writer & Verifier
# =============================================================================
def write_conversation_files(conv: Dict[str, Any], root_out_dir: Path) -> None:
    cid = conv["agy_conversation_id"]
    conv_dir = root_out_dir / "conversations"
    conv_dir.mkdir(parents=True, exist_ok=True)
    conv_db_path = conv_dir / f"{cid}.db"
    if conv_db_path.exists():
        conv_db_path.unlink()

    conn = sqlite3.connect(str(conv_db_path))
    try:
        conn.executescript(
            """
            PRAGMA journal_mode=WAL;
            PRAGMA user_version=1;
            CREATE TABLE `trajectory_meta` (`trajectory_id` text,`cascade_id` text,`trajectory_type` integer,`source` integer,PRIMARY KEY (`trajectory_id`));
            CREATE TABLE `steps` (`idx` integer,`step_type` integer NOT NULL DEFAULT 0,`status` integer NOT NULL DEFAULT 0,`has_subtrajectory` numeric NOT NULL DEFAULT false,`metadata` blob,`error_details` blob,`permissions` blob,`task_details` blob,`render_info` blob,`step_payload` blob,`step_format` integer NOT NULL DEFAULT 0,PRIMARY KEY (`idx`));
            CREATE INDEX `idx_steps_status` ON `steps`(`status`);
            CREATE INDEX `idx_steps_step_type` ON `steps`(`step_type`);
            CREATE TABLE `gen_metadata` (`idx` integer,`data` blob,`size` integer NOT NULL DEFAULT 0,PRIMARY KEY (`idx`));
            CREATE TABLE `executor_metadata` (`idx` integer,`data` blob,PRIMARY KEY (`idx`));
            CREATE TABLE `parent_references` (`idx` integer,`data` blob,PRIMARY KEY (`idx`));
            CREATE TABLE `trajectory_metadata_blob` (`id` text DEFAULT "main",`data` blob,PRIMARY KEY (`id`));
            CREATE TABLE `battle_mode_infos` (`idx` integer,`data` blob,PRIMARY KEY (`idx`));
            """
        )
        with conn:
            conn.execute(
                "INSERT INTO `trajectory_meta` (`trajectory_id`, `cascade_id`, `trajectory_type`, `source`) VALUES (?, ?, 4, 1)",
                (conv["agy_trajectory_id"], cid),
            )
            traj_blob = build_trajectory_metadata(
                conv["created_at"], conv["agy_execution_id"], cid, conv["agy_project_id"]
            )
            conn.execute(
                "INSERT INTO `trajectory_metadata_blob` (`id`, `data`) VALUES ('main', ?)",
                (sqlite3.Binary(traj_blob),),
            )

            turn_idx = -1
            turn_exec_id = deterministic_uuid_v4("turn", f"{cid}:0")
            for idx, st in enumerate(conv["steps"]):
                if st["is_user"]:
                    turn_idx += 1
                    turn_exec_id = deterministic_uuid_v4("turn", f"{cid}:{turn_idx}")
                    meta_b, payload_b = build_user_input_step(
                        cid, conv["agy_trajectory_id"], turn_exec_id, idx, max(0, turn_idx), st["ts"], st["content"]
                    )
                    conn.execute(
                        "INSERT INTO `steps` (`idx`, `step_type`, `status`, `has_subtrajectory`, `metadata`, `step_payload`, `step_format`) VALUES (?, 14, 3, 0, ?, ?, 0)",
                        (idx, sqlite3.Binary(meta_b), sqlite3.Binary(payload_b)),
                    )
                else:
                    meta_b, payload_b = build_planner_response_step(
                        cid,
                        conv["agy_trajectory_id"],
                        turn_exec_id,
                        idx,
                        max(0, turn_idx),
                        st["ts"],
                        st["content"],
                        st["thinking"],
                    )
                    conn.execute(
                        "INSERT INTO `steps` (`idx`, `step_type`, `status`, `has_subtrajectory`, `metadata`, `step_payload`, `step_format`) VALUES (?, 15, 3, 0, ?, ?, 0)",
                        (idx, sqlite3.Binary(meta_b), sqlite3.Binary(payload_b)),
                    )
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE);")
    finally:
        conn.close()

    # Write annotations/<id>.pbtxt (UTF-8 without BOM)
    ann_dir = root_out_dir / "annotations"
    ann_dir.mkdir(parents=True, exist_ok=True)
    pbtxt = build_annotation_pbtxt(conv["title"], conv["updated_at"])
    (ann_dir / f"{cid}.pbtxt").write_text(pbtxt, encoding="utf-8")

    # Write brain/<id>/.system_generated/logs/transcript*.jsonl
    logs_dir = root_out_dir / "brain" / cid / ".system_generated" / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)
    full_lines: List[str] = []
    compact_lines: List[str] = []
    for idx, st in enumerate(conv["steps"]):
        iso = st["ts"].astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        full_content = f"<USER_REQUEST>\n{st['content']}\n</USER_REQUEST>" if st["is_user"] else st["content"]
        row_full: Dict[str, Any] = {
            "step_index": idx,
            "source": "USER_EXPLICIT" if st["is_user"] else "MODEL",
            "type": "USER_INPUT" if st["is_user"] else "PLANNER_RESPONSE",
            "status": "DONE",
            "created_at": iso,
            "content": full_content,
        }
        if not st["is_user"] and st["thinking"]:
            row_full["thinking"] = st["thinking"]
        full_lines.append(json.dumps(row_full, ensure_ascii=False))

        if len(full_content) > 8000:
            row_comp = dict(row_full)
            cut = len(full_content) - 4000
            row_comp["content"] = f"{full_content[:2000]}\n<truncated {cut} chars>\n{full_content[-2000:]}"
            row_comp["truncated_fields"] = ["content"]
            compact_lines.append(json.dumps(row_comp, ensure_ascii=False))
        else:
            compact_lines.append(full_lines[-1])

    (logs_dir / "transcript_full.jsonl").write_text("\n".join(full_lines) + "\n", encoding="utf-8")
    (logs_dir / "transcript.jsonl").write_text("\n".join(compact_lines) + "\n", encoding="utf-8")


def _fmt_agy_datetime(dt: datetime) -> str:
    utc = dt.astimezone(timezone.utc)
    return utc.strftime("%Y-%m-%d %H:%M:%S.") + f"{utc.microsecond * 10:07d}+00:00"


def upsert_summaries_db(summaries_db_path: Path, sessions: List[Dict[str, Any]]) -> None:
    existed = summaries_db_path.exists()
    summaries_db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(summaries_db_path))
    try:
        if not existed:
            conn.execute("PRAGMA user_version=3;")
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS `conversation_summaries` (
                `conversation_id` text,
                `title` text NOT NULL DEFAULT "",
                `preview` text NOT NULL DEFAULT "",
                `step_count` integer NOT NULL DEFAULT 0,
                `last_modified_time` datetime NOT NULL,
                `workspace_uris` text NOT NULL,
                `status` text NOT NULL DEFAULT "",
                `source` text NOT NULL DEFAULT "",
                `project_id` text NOT NULL DEFAULT "",
                `agent_name` text NOT NULL DEFAULT "",
                `parent_conversation_id` text NOT NULL DEFAULT "",
                `nesting_depth` integer NOT NULL DEFAULT 0,
                `battle_id` text NOT NULL DEFAULT "",
                `winning_conversation_id` text NOT NULL DEFAULT "",
                `not_fully_idle` numeric NOT NULL DEFAULT false,
                `killed` numeric NOT NULL DEFAULT false,
                `last_user_input_time` datetime NOT NULL,
                `last_user_input_step_index` integer NOT NULL DEFAULT -1,
                `app_data_dir` text NOT NULL DEFAULT "",
                `raw_summary` blob,
                `group_id` text NOT NULL DEFAULT "",
                PRIMARY KEY (`conversation_id`)
            );
            CREATE INDEX IF NOT EXISTS `idx_conversation_summaries_last_user_input_time` ON `conversation_summaries`(`last_user_input_time`);
            CREATE INDEX IF NOT EXISTS `idx_conversation_summaries_last_modified_time` ON `conversation_summaries`(`last_modified_time`);
            """
        )
        has_fts = bool(
            conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='conversations_fts'"
            ).fetchall()
        )
        with conn:
            for conv in sessions:
                last_user_idx = -1
                last_user_ts = conv["created_at"]
                for i in range(len(conv["steps"]) - 1, -1, -1):
                    if conv["steps"][i]["is_user"]:
                        last_user_idx = i
                        last_user_ts = conv["steps"][i]["ts"]
                        break

                pid = conv["agy_project_id"] or "outside-of-project"
                ws_uris = conv["workspace_uri"] or ""
                raw_sum = build_cascade_run_summary(
                    conv["title"],
                    len(conv["steps"]),
                    conv["created_at"],
                    conv["updated_at"],
                    last_user_ts,
                    last_user_idx,
                    conv["agy_trajectory_id"],
                    conv["agy_execution_id"],
                    conv["agy_conversation_id"],
                    pid,
                )
                conn.execute(
                    """
                    INSERT OR REPLACE INTO `conversation_summaries` (
                        `conversation_id`, `title`, `preview`, `step_count`,
                        `last_modified_time`, `workspace_uris`, `status`, `source`,
                        `project_id`, `agent_name`, `parent_conversation_id`, `nesting_depth`,
                        `battle_id`, `winning_conversation_id`, `not_fully_idle`, `killed`,
                        `last_user_input_time`, `last_user_input_step_index`, `app_data_dir`,
                        `raw_summary`, `group_id`
                    ) VALUES (?, ?, ?, ?, ?, ?, 'CASCADE_RUN_STATUS_IDLE', '', ?, '', '', 0, '', '', 0, 0, ?, ?, 'antigravity', ?, '')
                    """,
                    (
                        conv["agy_conversation_id"],
                        conv["title"],
                        conv["preview"],
                        len(conv["steps"]),
                        _fmt_agy_datetime(conv["updated_at"]),
                        ws_uris,
                        pid,
                        _fmt_agy_datetime(last_user_ts),
                        last_user_idx,
                        sqlite3.Binary(raw_sum),
                    ),
                )
                if has_fts:
                    conn.execute(
                        "DELETE FROM `conversations_fts` WHERE `conversation_id` = ?",
                        (conv["agy_conversation_id"],),
                    )
    finally:
        conn.close()


def verify_output_dir(root_out_dir: Path) -> int:
    sum_db = root_out_dir / "conversation_summaries.db"
    if not sum_db.is_file():
        raise FileNotFoundError(f"Missing conversation_summaries.db in {root_out_dir}")

    verified = 0
    sconn = sqlite3.connect(str(sum_db))
    try:
        rows = sconn.execute(
            "SELECT conversation_id, title, project_id, step_count, raw_summary FROM conversation_summaries"
        ).fetchall()
        for cid, title, pid, expected_steps, raw_sum in rows:
            if not title or not str(title).strip():
                raise ValueError(f"Empty title in conversation_summaries for {cid}")
            if not validate_proto_wire(bytes(raw_sum) if raw_sum is not None else None):
                raise ValueError(f"Invalid raw_summary protobuf for {cid}")

            ann_path = root_out_dir / "annotations" / f"{cid}.pbtxt"
            if not ann_path.is_file() or not ann_path.read_text(encoding="utf-8").startswith('title:"'):
                raise ValueError(f"Missing or invalid annotation pbtxt: {ann_path}")

            if pid and pid != "outside-of-project":
                proj_json = root_out_dir / "projects" / f"{pid}.json"
                if not proj_json.is_file():
                    raise FileNotFoundError(f"Missing staged project JSON for project_id {pid}: {proj_json}")

            cdb_path = root_out_dir / "conversations" / f"{cid}.db"
            if not cdb_path.is_file():
                raise FileNotFoundError(f"Missing conversation DB: {cdb_path}")

            cconn = sqlite3.connect(str(cdb_path))
            try:
                uv = cconn.execute("PRAGMA user_version").fetchone()[0]
                if uv != 1:
                    raise ValueError(f"Conversation DB user_version must be 1 for {cid} (got {uv})")
                tmeta = cconn.execute("SELECT data FROM trajectory_metadata_blob WHERE id='main'").fetchall()
                if len(tmeta) != 1 or not validate_proto_wire(bytes(tmeta[0][0]) if tmeta[0][0] else None):
                    raise ValueError(f"Invalid trajectory_metadata_blob for {cid}")
                steps = cconn.execute("SELECT idx, metadata, step_payload FROM steps ORDER BY idx ASC").fetchall()
                if len(steps) != expected_steps:
                    raise ValueError(f"Step count mismatch for {cid}: expected {expected_steps}, got {len(steps)}")
                for idx, m_b, p_b in steps:
                    if not validate_proto_wire(bytes(m_b)) or not validate_proto_wire(bytes(p_b)):
                        raise ValueError(f"Invalid step protobuf in {cid} at idx {idx}")
            finally:
                cconn.close()

            tr_path = root_out_dir / "brain" / cid / ".system_generated" / "logs" / "transcript.jsonl"
            if not tr_path.is_file():
                raise FileNotFoundError(f"Missing transcript.jsonl for {cid}")
            verified += 1
    finally:
        sconn.close()
    return verified


def is_antigravity_running() -> bool:
    try:
        if os.name == "nt":
            out = subprocess.check_output(["tasklist", "/FO", "CSV", "/NH"], text=True, stderr=subprocess.DEVNULL)
            for line in out.splitlines():
                if line.strip().lower().startswith('"antigravity.exe"'):
                    return True
            return False
        cmd = ["ps", "-axo", "comm="] if sys.platform == "darwin" else ["ps", "-eo", "comm="]
        out = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
        for line in out.splitlines():
            base = os.path.basename(line.strip()).lower()
            if base == "antigravity":
                return True
    except Exception:
        pass
    return False


# =============================================================================
# 5. CLI Entrypoint
# =============================================================================
def main() -> int:
    default_codex = os.environ.get("CODEX_HOME") or str(Path.home() / ".codex")
    default_agy = str(Path.home() / ".gemini" / "antigravity")
    default_cfg = str(Path.home() / ".gemini" / "config")

    parser = argparse.ArgumentParser(
        description="Convert OpenAI Codex local sessions & projects into Google Antigravity native format."
    )
    parser.add_argument("--codex-dir", default=default_codex, help="Source Codex directory (default: ~/.codex)")
    parser.add_argument("--input-jsonl", default="", help="Optional single Codex rollout .jsonl file to convert")
    parser.add_argument("--thread-id", default="", help="Optional specific Codex thread UUID to convert")
    parser.add_argument("--output-dir", default="./dist-agy", help="Staging output directory (default: ./dist-agy)")
    parser.add_argument("--rename-config", default="", help="Optional JSON file overriding project_names / thread_titles")
    parser.add_argument("--title-prefix", default="", help="Optional prefix added to session titles (default: empty)")
    parser.add_argument("--no-projects", action="store_true", help="Place all sessions under top-level Conversations")
    parser.add_argument("--include-guardian", action="store_true", help="Include Guardian review internal sub-sessions")
    parser.add_argument("--include-subagents", action="store_true", help="Include spawned child subagent threads")
    parser.add_argument("--verify", action="store_true", help="Verify generated SQLite DBs, Protobuf blobs, and annotations")
    parser.add_argument("--install", action="store_true", help="Install staged sessions & projects into Antigravity")
    parser.add_argument("--antigravity-dir", default=default_agy, help="Target Antigravity app data dir (~/.gemini/antigravity)")
    parser.add_argument("--gemini-config-dir", default=default_cfg, help="Target Gemini global config dir (~/.gemini/config)")
    parser.add_argument("--force", action="store_true", help="Bypass running Antigravity process check during --install")
    args = parser.parse_args()

    codex_dir = Path(args.codex_dir).expanduser()
    out_dir = Path(args.output_dir).expanduser().resolve()
    agy_dir = Path(args.antigravity_dir).expanduser()
    cfg_dir = Path(args.gemini_config_dir).expanduser()

    # Load optional rename-config.json
    custom_project_names: Dict[str, str] = {}
    custom_thread_titles: Dict[str, str] = {}
    custom_thread_projects: Dict[str, str] = {}
    rc_path = Path(args.rename_config).expanduser() if args.rename_config else None
    if rc_path and rc_path.is_file():
        rc_obj = json.loads(rc_path.read_text(encoding="utf-8"))
        if isinstance(rc_obj, dict):
            for k, v in (rc_obj.get("project_names") or {}).items():
                if v:
                    custom_project_names[str(k).lower()] = str(v)
            for k, v in (rc_obj.get("thread_titles") or {}).items():
                if v:
                    custom_thread_titles[str(k).lower()] = str(v)
            for k, v in (rc_obj.get("thread_projects") or {}).items():
                if v:
                    custom_thread_projects[str(k).lower()] = str(v).lower()

    # Reuse existing project UUIDs in ~/.gemini/config/projects to prevent duplicate sidebar entries
    existing_uri_to_proj_id: Dict[str, str] = {}
    existing_proj_dir = cfg_dir / "projects"
    if existing_proj_dir.is_dir():
        for pf in existing_proj_dir.glob("*.json"):
            try:
                po = json.loads(pf.read_text(encoding="utf-8"))
                pid = po.get("id")
                resources = (po.get("projectResources") or {}).get("resources") or []
                if pid and isinstance(resources, list):
                    for r_item in resources:
                        furi = ((r_item or {}).get("gitFolder") or {}).get("folderUri")
                        if furi:
                            existing_uri_to_proj_id[str(furi).rstrip("/").lower()] = str(pid)
            except Exception:
                pass

    out_dir.mkdir(parents=True, exist_ok=True)
    for sub in ("annotations", "projects"):
        sd = out_dir / sub
        if sd.exists():
            shutil.rmtree(sd)
        sd.mkdir(parents=True, exist_ok=True)

    converted_sessions: List[Dict[str, Any]] = []
    codex_projects: Dict[str, Dict[str, Any]] = {}
    primary_root_map: Dict[str, str] = {}
    secondary_roots: List[Tuple[str, str, int]] = []
    skipped_guardian = 0
    skipped_subagent = 0
    skipped_empty = 0

    if args.input_jsonl:
        jpath = Path(args.input_jsonl).expanduser().resolve()
        evts, fid, fcwd, _, _ = parse_jsonl_events(jpath)
        fid = fid or deterministic_uuid_v4("jsonl", str(jpath))
        ovr = custom_thread_titles.get(fid, "")
        conv = build_converted_session(
            fid, ovr, args.title_prefix, fcwd or "", False, "outside-of-project", "", "", None, None, evts
        )
        if conv:
            converted_sessions.append(conv)
    else:
        index_titles: Dict[str, str] = {}
        index_updated: Dict[str, str] = {}
        idx_file = codex_dir / "session_index.jsonl"
        if idx_file.is_file():
            for line in idx_file.read_text(encoding="utf-8", errors="replace").splitlines():
                if not line.strip():
                    continue
                try:
                    obj = json.loads(line)
                    tid = str(obj.get("id") or "").lower()
                    if tid:
                        if obj.get("thread_name"):
                            index_titles[tid] = str(obj["thread_name"])
                        if obj.get("updated_at"):
                            index_updated[tid] = str(obj["updated_at"])
                except Exception:
                    pass

        sqlite_meta: Dict[str, Dict[str, Any]] = {}
        spawned_child_ids: Set[str] = set()
        state_db = find_latest_versioned_sqlite(codex_dir, "state")
        if state_db and state_db.is_file():
            sconn = open_sqlite_ro(state_db)
            try:
                tables = {
                    r[0].lower()
                    for r in sconn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
                }
                if "threads" in tables:
                    for r in sconn.execute("SELECT * FROM threads").fetchall():
                        d = dict(r)
                        if d.get("id"):
                            sqlite_meta[str(d["id"]).lower()] = d
                if "thread_spawn_edges" in tables:
                    for r in sconn.execute("SELECT child_thread_id FROM thread_spawn_edges").fetchall():
                        if r[0]:
                            spawned_child_ids.add(str(r[0]).lower())
                if not args.no_projects and "projects" in tables:
                    proj_rows = sconn.execute("SELECT id, name, position FROM projects ORDER BY position ASC").fetchall()
                    root_rows = (
                        sconn.execute("SELECT project_id, position, path FROM project_roots ORDER BY position ASC").fetchall()
                        if "project_roots" in tables
                        else []
                    )
                    roots_by_proj: Dict[str, List[Tuple[int, str]]] = {}
                    for rr in root_rows:
                        cpid = str(rr["project_id"]).lower()
                        pos = int(rr["position"])
                        cpath = clean_fs_path(str(rr["path"]))
                        roots_by_proj.setdefault(cpid, []).append((pos, cpath))
                        lkey = normalize_lookup_key(cpath)
                        if lkey:
                            if pos == 0:
                                primary_root_map[lkey] = cpid
                            else:
                                secondary_roots.append((lkey, cpid, pos))

                    for pr in proj_rows:
                        cpid = str(pr["id"]).lower()
                        pname = custom_project_names.get(cpid) or str(pr["name"])
                        prim_path = roots_by_proj[cpid][0][1] if roots_by_proj.get(cpid) else ""
                        furi = path_to_vscode_file_uri(prim_path)
                        fexists = bool(prim_path) and os.path.isdir(prim_path)
                        agy_pid = deterministic_uuid_v4("agy-proj", cpid)
                        if furi and furi.rstrip("/").lower() in existing_uri_to_proj_id:
                            agy_pid = existing_uri_to_proj_id[furi.rstrip("/").lower()]
                        codex_projects[cpid] = {
                            "codex_project_id": cpid,
                            "agy_project_id": agy_pid,
                            "name": pname,
                            "primary_path": prim_path,
                            "folder_uri": furi if fexists else "",
                            "folder_exists": fexists,
                            "session_count": 0,
                        }
            finally:
                sconn.close()

        def resolve_project(tid: str, explicit_proj_id: Optional[str], raw_cwd: Optional[str]) -> Optional[Dict[str, Any]]:
            if args.no_projects:
                return None
            if tid in custom_thread_projects:
                target = custom_thread_projects[tid]
                if target in codex_projects:
                    return codex_projects[target]
                for pm in codex_projects.values():
                    if pm["name"].lower() == target:
                        return pm
            if explicit_proj_id:
                k = explicit_proj_id.strip().lower()
                if k in codex_projects:
                    return codex_projects[k]
            ck = normalize_lookup_key(raw_cwd)
            if not ck:
                return None
            if ck in primary_root_map:
                return codex_projects[primary_root_map[ck]]
            for rk, cpid in primary_root_map.items():
                if ck.startswith(rk.rstrip("/") + "/"):
                    return codex_projects[cpid]
            for rk, cpid, _ in secondary_roots:
                if ck == rk or ck.startswith(rk.rstrip("/") + "/"):
                    return codex_projects[cpid]
            return None

        def check_skip(tid: str, sm: Optional[Dict[str, Any]], role: Optional[str], src: Optional[str]) -> Optional[str]:
            if args.thread_id and tid != args.thread_id.strip().lower():
                return "filter"
            if not args.include_guardian:
                titles = []
                if tid in index_titles:
                    titles.append(index_titles[tid])
                if sm:
                    if sm.get("name"):
                        titles.append(str(sm["name"]))
                    if sm.get("title"):
                        titles.append(str(sm["title"]))
                    role = role or (str(sm["agent_role"]) if sm.get("agent_role") else None)
                    src = src or (str(sm["source"]) if sm.get("source") else None)
                if any(t.strip().lower() == "guardian review" for t in titles if t):
                    return "guardian"
                if (role and "guardian" in role.lower()) or (src and "guardian" in src.lower()):
                    return "guardian"
            if not args.include_subagents:
                has_name = bool(sm and str(sm.get("name") or "").strip()) or bool(index_titles.get(tid, "").strip())
                if not has_name:
                    if tid in spawned_child_ids:
                        return "subagent"
                    if src and "subagent" in src.lower():
                        return "subagent"
                    if sm and sm.get("attached_thread_parent_id"):
                        return "subagent"
            return None

        def resolve_meta(tid: str, fallback_cwd: Optional[str], fallback_arch: bool) -> Dict[str, Any]:
            sm = sqlite_meta.get(tid)
            raw_title = ""
            cwd = fallback_cwd or ""
            arch = fallback_arch
            explicit_proj = None
            c_at: Optional[datetime] = None
            u_at: Optional[datetime] = None

            if sm:
                if sm.get("name") and str(sm["name"]).strip():
                    raw_title = str(sm["name"])
                if sm.get("cwd") and str(sm["cwd"]).strip():
                    cwd = str(sm["cwd"])
                if sm.get("project_id"):
                    explicit_proj = str(sm["project_id"])
                if sm.get("archived"):
                    arch = bool(int(sm["archived"]))
                if sm.get("created_at") is not None:
                    c_at = parse_timestamp(sm["created_at"], EPOCH_UTC)
                if sm.get("updated_at") is not None:
                    u_at = parse_timestamp(sm["updated_at"], EPOCH_UTC)

            if tid in custom_thread_titles:
                raw_title = custom_thread_titles[tid]
            else:
                if not raw_title.strip() and tid in index_titles:
                    raw_title = index_titles[tid]
                if not raw_title.strip() and sm and sm.get("title"):
                    raw_title = str(sm["title"])

            if u_at is None and tid in index_updated:
                u_at = parse_timestamp(index_updated[tid], datetime.now(timezone.utc))

            proj = resolve_project(tid, explicit_proj, cwd)
            return {"title": raw_title, "cwd": cwd, "archived": arch, "created_at": c_at, "updated_at": u_at, "proj": proj}

        by_id: Dict[str, Dict[str, Any]] = {}

        # A. Scan .jsonl files in sessions/ and archived_sessions/
        for sub in ("sessions", "archived_sessions"):
            sp = codex_dir / sub
            if not sp.is_dir():
                continue
            for jfile in sp.rglob("*.jsonl"):
                evts, fid, fcwd, frole, fsrc = parse_jsonl_events(jfile)
                fid = (fid or jfile.stem).lower()
                skip = check_skip(fid, sqlite_meta.get(fid), frole, fsrc)
                if skip == "guardian":
                    skipped_guardian += 1
                    continue
                if skip == "subagent":
                    skipped_subagent += 1
                    continue
                if skip is not None:
                    continue

                m = resolve_meta(fid, fcwd, sub == "archived_sessions")
                pm = m["proj"]
                conv = build_converted_session(
                    fid,
                    m["title"],
                    args.title_prefix,
                    m["cwd"],
                    m["archived"],
                    pm["agy_project_id"] if pm else "outside-of-project",
                    pm["name"] if pm else "",
                    pm["folder_uri"] if pm else "",
                    m["created_at"],
                    m["updated_at"],
                    evts,
                )
                if not conv:
                    skipped_empty += 1
                    continue
                if fid not in by_id or len(conv["steps"]) > len(by_id[fid]["steps"]):
                    by_id[fid] = conv

        # B. Scan thread_history_*.sqlite for migrated threads
        hist_db = find_latest_versioned_sqlite(codex_dir, "thread_history")
        if hist_db and hist_db.is_file():
            hconn = open_sqlite_ro(hist_db)
            try:
                htables = {
                    r[0].lower()
                    for r in hconn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
                }
                cand_ids: Set[str] = set(sqlite_meta.keys())
                if "thread_turns" in htables:
                    for r in hconn.execute("SELECT DISTINCT thread_id FROM thread_turns").fetchall():
                        if r[0]:
                            cand_ids.add(str(r[0]).lower())

                targets: List[str] = []
                for cid in cand_ids:
                    if cid in by_id:
                        continue
                    skip = check_skip(cid, sqlite_meta.get(cid), None, None)
                    if skip == "guardian":
                        skipped_guardian += 1
                        continue
                    if skip == "subagent":
                        skipped_subagent += 1
                        continue
                    if skip is not None:
                        continue
                    targets.append(cid)

                if "thread_items" in htables and targets:
                    batch_size = 40
                    for bi in range(0, len(targets), batch_size):
                        chunk = targets[bi : bi + batch_size]
                        placeholders = ",".join("?" for _ in chunk)
                        rows = hconn.execute(
                            f"SELECT thread_id, rollout_ordinal, created_at_ms, item_type, item_json "
                            f"FROM thread_items WHERE lower(thread_id) IN ({placeholders}) "
                            f"ORDER BY thread_id, rollout_ordinal ASC",
                            chunk,
                        ).fetchall()
                        grouped: Dict[str, List[Dict[str, Any]]] = {}
                        for r in rows:
                            tid = str(r["thread_id"]).lower()
                            ts = parse_timestamp(r["created_at_ms"], datetime.now(timezone.utc))
                            ev = parse_sqlite_item(r["item_type"], r["item_json"], ts)
                            if ev:
                                grouped.setdefault(tid, []).append(ev)

                        for tid in chunk:
                            if tid not in grouped:
                                skipped_empty += 1
                                continue
                            m = resolve_meta(tid, "", False)
                            pm = m["proj"]
                            conv = build_converted_session(
                                tid,
                                m["title"],
                                args.title_prefix,
                                m["cwd"],
                                m["archived"],
                                pm["agy_project_id"] if pm else "outside-of-project",
                                pm["name"] if pm else "",
                                pm["folder_uri"] if pm else "",
                                m["created_at"],
                                m["updated_at"],
                                grouped[tid],
                            )
                            if not conv:
                                skipped_empty += 1
                                continue
                            by_id[tid] = conv
            finally:
                hconn.close()

        for conv in sorted(by_id.values(), key=lambda x: x["updated_at"], reverse=True):
            converted_sessions.append(conv)
            for pm in codex_projects.values():
                if pm["agy_project_id"] == conv["agy_project_id"]:
                    pm["session_count"] += 1

    # Stage Antigravity Project JSON files
    staged_project_files: List[Path] = []
    for pm in codex_projects.values():
        if pm["session_count"] <= 0:
            continue
        proj_res: Dict[str, Any] = {}
        if pm["folder_exists"] and pm["folder_uri"]:
            proj_res["resources"] = [{"gitFolder": {"folderUri": pm["folder_uri"], "allowWrite": True}}]
        proj_doc = {
            "id": pm["agy_project_id"],
            "name": pm["name"],
            "projectResources": proj_res,
            "permissionGrants": {"permissionGrants": {}, "v2Migrated": True},
            "settings": {"artifactReviewMode": "ARTIFACT_REVIEW_MODE_TURBO"},
        }
        p_out = out_dir / "projects" / f"{pm['agy_project_id']}.json"
        p_out.write_text(json.dumps(proj_doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        staged_project_files.append(p_out)

    staging_sum_db = out_dir / "conversation_summaries.db"
    if staging_sum_db.exists():
        staging_sum_db.unlink()

    manifest: List[Dict[str, Any]] = []
    for conv in converted_sessions:
        write_conversation_files(conv, out_dir)
        manifest.append(
            {
                "codex_thread_id": conv["codex_thread_id"],
                "agy_conversation_id": conv["agy_conversation_id"],
                "agy_trajectory_id": conv["agy_trajectory_id"],
                "agy_project_id": conv["agy_project_id"],
                "agy_project_name": conv["agy_project_name"],
                "title": conv["title"],
                "cwd": conv["cwd"],
                "workspace_uri": conv["workspace_uri"],
                "step_count": len(conv["steps"]),
                "user_turns": conv["user_turns"],
                "assistant_turns": conv["assistant_turns"],
                "created_at": conv["created_at"].astimezone().strftime("%Y-%m-%d %H:%M:%S"),
                "updated_at": conv["updated_at"].astimezone().strftime("%Y-%m-%d %H:%M:%S"),
            }
        )

    upsert_summaries_db(staging_sum_db, converted_sessions)
    (out_dir / "mapping.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print(
        f"[Stage] Converted {len(converted_sessions)} sessions & {len(staged_project_files)} projects -> {out_dir} "
        f"(Skipped Guardian={skipped_guardian}, Subagent={skipped_subagent}, Empty={skipped_empty})"
    )

    if args.verify or args.install:
        v_count = verify_output_dir(out_dir)
        print(
            f"[Verify] Validated Protobuf wire format, SQLite user_version=1, annotations, "
            f"and project JSONs for {v_count} sessions."
        )

    if args.install:
        if not args.force and is_antigravity_running():
            print(
                "ERROR: Detected running Antigravity process. Close Antigravity completely before running --install "
                "(or pass --force to override).",
                file=sys.stderr,
            )
            return 2

        ts_tag = datetime.now().strftime("%Y%m%d-%H%M%S")
        target_conv = agy_dir / "conversations"
        target_ann = agy_dir / "annotations"
        target_brain = agy_dir / "brain"
        target_sum_db = agy_dir / "conversation_summaries.db"
        target_hub_pb = agy_dir / "agyhub_summaries_proto.pb"
        target_projects = cfg_dir / "projects"

        for d in (target_conv, target_ann, target_brain, target_projects):
            d.mkdir(parents=True, exist_ok=True)

        if target_sum_db.is_file():
            bak_db = Path(f"{target_sum_db}.bak.{ts_tag}")
            shutil.copy2(target_sum_db, bak_db)
            print(f"[Backup] Backed up conversation_summaries.db -> {bak_db}")

        if target_hub_pb.is_file():
            bak_pb = Path(f"{target_hub_pb}.bak.{ts_tag}")
            shutil.move(str(target_hub_pb), str(bak_pb))
            print(f"[Cache] Cleared stale agyhub_summaries_proto.pb (backed up -> {bak_pb})")

        for pf in staged_project_files:
            shutil.copy2(pf, target_projects / pf.name)

        for conv in converted_sessions:
            cid = conv["agy_conversation_id"]
            for wal_ext in ("-wal", "-shm"):
                old_wal = target_conv / f"{cid}.db{wal_ext}"
                if old_wal.exists():
                    old_wal.unlink()
            shutil.copy2(out_dir / "conversations" / f"{cid}.db", target_conv / f"{cid}.db")
            shutil.copy2(out_dir / "annotations" / f"{cid}.pbtxt", target_ann / f"{cid}.pbtxt")

            src_logs = out_dir / "brain" / cid / ".system_generated" / "logs"
            dst_logs = target_brain / cid / ".system_generated" / "logs"
            dst_logs.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src_logs / "transcript.jsonl", dst_logs / "transcript.jsonl")
            shutil.copy2(src_logs / "transcript_full.jsonl", dst_logs / "transcript_full.jsonl")

        upsert_summaries_db(target_sum_db, converted_sessions)
        print(
            f"[Install] Imported {len(converted_sessions)} sessions & {len(staged_project_files)} projects! "
            f"Launch Antigravity to view them under Projects."
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
