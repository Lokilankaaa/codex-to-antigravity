<#
.SYNOPSIS
    Converts OpenAI Codex local sessions & projects (~/.codex) into Google Antigravity native format.

.DESCRIPTION
    Reads Codex sessions and projects from ~/.codex (state_5.sqlite, thread_history_1.sqlite,
    session_index.jsonl, sessions/*.jsonl, archived_sessions/*.jsonl) or a single .jsonl file,
    and converts them into Antigravity's native five-part session & project format:
      1. conversations/<conversation_id>.db       (SQLite user_version=1 + CortexStep Protobuf wire format)
      2. annotations/<conversation_id>.pbtxt      (Persistent conversation title & view timestamp)
      3. projects/<project_id>.json               (Antigravity Project metadata for ~/.gemini/config/projects)
      4. brain/<conversation_id>/.system_generated/logs/transcript.jsonl & transcript_full.jsonl
      5. conversation_summaries.db                (SQLite user_version=3 + CascadeRunSummary Protobuf)

.PARAMETER CodexDir
    Source Codex directory. Defaults to "$HOME\.codex".

.PARAMETER InputJsonl
    Optional path to a single Codex rollout .jsonl file to convert.

.PARAMETER ThreadId
    Optional specific Codex thread UUID to convert.

.PARAMETER OutputDir
    Staging output directory where converted Antigravity files are written. Defaults to ".\dist-agy".

.PARAMETER RenameConfig
    Optional JSON file mapping Codex project IDs -> custom project names ("project_names")
    and Codex thread IDs -> custom concise session titles ("thread_titles").
    Defaults to ".\rename-config.json" if present.

.PARAMETER TitlePrefix
    Optional prefix added to imported session titles in Antigravity sidebar. Defaults to "" (no prefix).

.PARAMETER NoProjects
    Do not map sessions into Antigravity Projects (places all sessions under top-level Conversations).

.PARAMETER IncludeGuardian
    Include automated "Guardian review" internal approval sub-sessions (skipped by default).

.PARAMETER IncludeSubagents
    Include internal spawned child subagent threads (skipped by default).

.PARAMETER Install
    After staging and verifying, install the converted sessions, annotations, and projects into
    -AntigravityDir (~/.gemini/antigravity) and -GeminiConfigDir (~/.gemini/config) with automatic backups.
    Close Antigravity completely before running -Install.

.PARAMETER AntigravityDir
    Target Antigravity app data directory when -Install is specified. Defaults to "$HOME\.gemini\antigravity".

.PARAMETER GeminiConfigDir
    Target Gemini/Antigravity global config directory when -Install is specified. Defaults to "$HOME\.gemini\config".

.PARAMETER Force
    Bypass the running-process check when using -Install.

.PARAMETER Verify
    Read back all generated SQLite .db, .pbtxt, and project .json files and verify integrity.
#>
param(
    [string]$CodexDir = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }),
    [string]$InputJsonl = "",
    [string]$ThreadId = "",
    [string]$OutputDir = (Join-Path $PSScriptRoot "dist-agy"),
    [string]$RenameConfig = (Join-Path $PSScriptRoot "rename-config.json"),
    [string]$TitlePrefix = "",
    [switch]$NoProjects,
    [switch]$IncludeGuardian,
    [switch]$IncludeSubagents,
    [switch]$Install,
    [string]$AntigravityDir = (Join-Path $HOME ".gemini\antigravity"),
    [string]$GeminiConfigDir = (Join-Path $HOME ".gemini\config"),
    [switch]$Force,
    [switch]$Verify
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Web.Extensions

$csharpSource = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace CodexToAgyV2 {

    // =========================================================================
    // 1. Minimal Zero-Dependency Protobuf Wire Encoder & Validator (Proto3)
    // =========================================================================
    public class ProtoWriter {
        private readonly MemoryStream _ms = new MemoryStream();

        public byte[] ToArray() { return _ms.ToArray(); }

        public void WriteVarint(ulong value) {
            while (value >= 0x80) {
                _ms.WriteByte((byte)((value & 0x7F) | 0x80));
                value >>= 7;
            }
            _ms.WriteByte((byte)value);
        }

        public void WriteTag(int fieldNumber, int wireType) {
            uint fn = (uint)fieldNumber;
            uint wt = (uint)(wireType & 7);
            WriteVarint(((ulong)fn << 3) | (ulong)wt);
        }

        public void WriteVarintField(int fieldNumber, ulong value, bool writeDefault = false) {
            if (value == 0 && !writeDefault) return;
            WriteTag(fieldNumber, 0);
            WriteVarint(value);
        }

        public void WriteInt64Field(int fieldNumber, long value, bool writeDefault = false) {
            if (value == 0 && !writeDefault) return;
            WriteTag(fieldNumber, 0);
            WriteVarint((ulong)value);
        }

        public void WriteBytesField(int fieldNumber, byte[] data, bool writeEmpty = false) {
            if (data == null) return;
            if (data.Length == 0 && !writeEmpty) return;
            WriteTag(fieldNumber, 2);
            WriteVarint((ulong)data.Length);
            if (data.Length > 0) _ms.Write(data, 0, data.Length);
        }

        public void WriteStringField(int fieldNumber, string value, bool writeEmpty = false) {
            if (value == null) return;
            if (value.Length == 0 && !writeEmpty) return;
            byte[] utf8 = Encoding.UTF8.GetBytes(value);
            WriteBytesField(fieldNumber, utf8, writeEmpty);
        }

        public void WriteTimestampField(int fieldNumber, DateTimeOffset dto) {
            DateTimeOffset utc = dto.ToUniversalTime();
            long unixSec = utc.ToUnixTimeSeconds();
            long ticksRemainder = utc.Ticks % TimeSpan.TicksPerSecond;
            if (ticksRemainder < 0) ticksRemainder += TimeSpan.TicksPerSecond;
            long nanos = ticksRemainder * 100L; // 1 tick = 100ns

            var sub = new ProtoWriter();
            sub.WriteInt64Field(1, unixSec, false);
            sub.WriteInt64Field(2, nanos, false);
            WriteBytesField(fieldNumber, sub.ToArray(), true);
        }
    }

    public static class AgyProtoBuilder {
        public static string DeterministicUuidV4(string ns, string input) {
            using (var md5 = MD5.Create()) {
                byte[] hash = md5.ComputeHash(Encoding.UTF8.GetBytes(ns + ":" + input.ToLowerInvariant()));
                hash[6] = (byte)((hash[6] & 0x0F) | 0x40);
                hash[8] = (byte)((hash[8] & 0x3F) | 0x80);
                var sb = new StringBuilder(36);
                for (int i = 0; i < 16; i++) {
                    if (i == 4 || i == 6 || i == 8 || i == 10) sb.Append('-');
                    sb.Append(hash[i].ToString("x2"));
                }
                return sb.ToString();
            }
        }

        public static string DeterministicHex32(string ns, string input) {
            return DeterministicUuidV4(ns, input).Replace("-", "");
        }

        public static string EscapePbtxtString(string s) {
            if (string.IsNullOrEmpty(s)) return "";
            var sb = new StringBuilder(s.Length + 8);
            foreach (char c in s) {
                if (c == '\\') sb.Append("\\\\");
                else if (c == '"') sb.Append("\\\"");
                else if (c == '\n') sb.Append("\\n");
                else if (c == '\r') sb.Append("\\r");
                else if (c == '\t') sb.Append("\\t");
                else if (!char.IsControl(c)) sb.Append(c);
            }
            return sb.ToString();
        }

        public static string BuildAnnotationPbtxt(string title, DateTimeOffset viewTime) {
            DateTimeOffset utc = viewTime.ToUniversalTime();
            long sec = utc.ToUnixTimeSeconds();
            long ticksRem = utc.Ticks % TimeSpan.TicksPerSecond;
            if (ticksRem < 0) ticksRem += TimeSpan.TicksPerSecond;
            long nanos = ticksRem * 100L;
            if (nanos == 0) nanos = 1000000L;
            return string.Format(
                CultureInfo.InvariantCulture,
                "title:\"{0}\" last_user_view_time:{{seconds:{1} nanos:{2}}} permission_preset:AGENT_PERMISSION_PRESET_TURBO",
                EscapePbtxtString(title), sec, nanos);
        }

        public static string PathToVscodeFileUri(string rawPath) {
            if (string.IsNullOrWhiteSpace(rawPath)) return "";
            string p = Regex.Replace(rawPath.Trim(), @"^\\\\\?\\", "");
            p = p.Replace('\\', '/').TrimEnd('/');
            if (p.Length >= 2 && char.IsLetter(p[0]) && p[1] == ':') {
                string drive = char.ToLowerInvariant(p[0]) + "%3A";
                string rest = p.Length > 2 ? p.Substring(2).TrimStart('/') : "";
                if (string.IsNullOrEmpty(rest)) return "file:///" + drive + "/";
                string[] segs = rest.Split(new char[] { '/' }, StringSplitOptions.RemoveEmptyEntries);
                for (int i = 0; i < segs.Length; i++) segs[i] = Uri.EscapeDataString(segs[i]);
                return "file:///" + drive + "/" + string.Join("/", segs);
            }
            if (p.StartsWith("/")) {
                string[] segs = p.Split(new char[] { '/' }, StringSplitOptions.RemoveEmptyEntries);
                for (int i = 0; i < segs.Length; i++) segs[i] = Uri.EscapeDataString(segs[i]);
                return "file:///" + string.Join("/", segs);
            }
            return "";
        }

        public static byte[] BuildTrajectoryMetadata(DateTimeOffset createdAt, string executionId, string cascadeId, string projectId) {
            var pw = new ProtoWriter();
            pw.WriteTimestampField(2, createdAt);
            pw.WriteStringField(3, executionId);
            pw.WriteStringField(6, cascadeId);
            pw.WriteStringField(18, string.IsNullOrEmpty(projectId) ? "outside-of-project" : projectId);
            return pw.ToArray();
        }

        private static byte[] BuildStepInfo(string trajectoryId, int stepIdx, int turnIdx, string cascadeId) {
            var pw = new ProtoWriter();
            pw.WriteStringField(1, trajectoryId);
            pw.WriteInt64Field(2, stepIdx, false);
            pw.WriteInt64Field(3, turnIdx, false);
            pw.WriteStringField(4, cascadeId);
            return pw.ToArray();
        }

        private static byte[] BuildStatusTransitionItem(int statusEnum, DateTimeOffset ts) {
            var pw = new ProtoWriter();
            pw.WriteInt64Field(1, statusEnum, false);
            pw.WriteTimestampField(2, ts);
            return pw.ToArray();
        }

        public static void BuildUserInputStep(
            string cascadeId, string trajectoryId, string turnExecId,
            int stepIdx, int turnIdx, DateTimeOffset ts, string userText,
            out byte[] metadataBytes, out byte[] stepPayloadBytes)
        {
            string stepHex = DeterministicHex32("step", cascadeId + ":" + stepIdx);
            string clientMsgUuid = DeterministicUuidV4("cmsg", cascadeId + ":" + stepIdx);

            var trans = new ProtoWriter();
            trans.WriteBytesField(1, BuildStatusTransitionItem(3, ts), true);

            var meta = new ProtoWriter();
            meta.WriteTimestampField(1, ts);
            meta.WriteInt64Field(3, 4); // CORTEX_STEP_SOURCE_USER_EXPLICIT = 4
            meta.WriteStringField(12, turnExecId);
            meta.WriteBytesField(20, BuildStepInfo(trajectoryId, stepIdx, turnIdx, cascadeId), true);
            meta.WriteBytesField(26, trans.ToArray(), true);
            meta.WriteStringField(35, stepHex);
            metadataBytes = meta.ToArray();

            var item = new ProtoWriter();
            item.WriteStringField(1, userText, true);

            var uin = new ProtoWriter();
            uin.WriteStringField(2, userText, true);
            uin.WriteBytesField(3, item.ToArray(), true);
            uin.WriteStringField(4, "", true);
            uin.WriteStringField(16, "client_msg:" + clientMsgUuid);
            uin.WriteStringField(19, clientMsgUuid);

            var step = new ProtoWriter();
            step.WriteInt64Field(1, 14); // CORTEX_STEP_TYPE_USER_INPUT = 14
            step.WriteInt64Field(4, 3);  // CORTEX_STEP_STATUS_DONE = 3
            step.WriteBytesField(5, metadataBytes, true);
            step.WriteBytesField(19, uin.ToArray(), true);
            stepPayloadBytes = step.ToArray();
        }

        public static void BuildPlannerResponseStep(
            string cascadeId, string trajectoryId, string turnExecId,
            int stepIdx, int turnIdx, DateTimeOffset ts, string responseText, string thinkingText,
            out byte[] metadataBytes, out byte[] stepPayloadBytes)
        {
            string stepHex = DeterministicHex32("step", cascadeId + ":" + stepIdx);

            var trans = new ProtoWriter();
            trans.WriteBytesField(1, BuildStatusTransitionItem(8, ts), true);
            trans.WriteBytesField(1, BuildStatusTransitionItem(3, ts), true);

            var meta = new ProtoWriter();
            meta.WriteTimestampField(1, ts);
            meta.WriteInt64Field(3, 2); // CORTEX_STEP_SOURCE_MODEL = 2
            meta.WriteTimestampField(6, ts);
            meta.WriteTimestampField(7, ts);
            meta.WriteTimestampField(8, ts);
            meta.WriteStringField(12, turnExecId);
            meta.WriteBytesField(20, BuildStepInfo(trajectoryId, stepIdx, turnIdx, cascadeId), true);
            meta.WriteBytesField(26, trans.ToArray(), true);
            meta.WriteTimestampField(32, ts);
            meta.WriteStringField(35, stepHex);
            metadataBytes = meta.ToArray();

            var pr = new ProtoWriter();
            pr.WriteStringField(1, responseText, true);
            if (!string.IsNullOrWhiteSpace(thinkingText)) {
                pr.WriteStringField(3, thinkingText);
            }
            pr.WriteStringField(8, responseText, true);
            pr.WriteInt64Field(12, 2); // stop_reason = 2

            var step = new ProtoWriter();
            step.WriteInt64Field(1, 15); // CORTEX_STEP_TYPE_PLANNER_RESPONSE = 15
            step.WriteInt64Field(4, 3);  // CORTEX_STEP_STATUS_DONE = 3
            step.WriteBytesField(5, metadataBytes, true);
            step.WriteBytesField(20, pr.ToArray(), true);
            stepPayloadBytes = step.ToArray();
        }

        public static byte[] BuildCascadeRunSummary(
            string title, int stepCount, DateTimeOffset createdAt, DateTimeOffset updatedAt,
            DateTimeOffset lastUserAt, int lastUserStepIdx,
            string trajectoryId, string executionId, string cascadeId, string projectId)
        {
            var titleInfo = new ProtoWriter();
            titleInfo.WriteStringField(1, title);
            titleInfo.WriteTimestampField(7, updatedAt);
            titleInfo.WriteInt64Field(19, 3); // AGENT_PERMISSION_PRESET_TURBO = 3

            string pid = string.IsNullOrEmpty(projectId) ? "outside-of-project" : projectId;
            byte[] trajMeta = BuildTrajectoryMetadata(createdAt, executionId, cascadeId, pid);

            var sum = new ProtoWriter();
            sum.WriteStringField(1, title);
            sum.WriteInt64Field(2, stepCount);
            sum.WriteTimestampField(3, updatedAt);
            sum.WriteStringField(4, trajectoryId);
            sum.WriteInt64Field(5, 1); // CASCADE_RUN_STATUS_IDLE = 1
            sum.WriteTimestampField(7, createdAt);
            sum.WriteTimestampField(10, lastUserAt);
            sum.WriteBytesField(15, titleInfo.ToArray(), true);
            if (lastUserStepIdx >= 0) {
                sum.WriteInt64Field(16, lastUserStepIdx, true);
            }
            sum.WriteBytesField(17, trajMeta, true);
            sum.WriteInt64Field(22, 4);
            sum.WriteInt64Field(26, 1);
            sum.WriteInt64Field(28, 4);
            return sum.ToArray();
        }

        public static bool ValidateProtoWire(byte[] buf) {
            if (buf == null || buf.Length == 0) return false;
            int pos = 0, end = buf.Length;
            while (pos < end) {
                ulong tag = 0; int shift = 0;
                while (pos < end && shift < 70) {
                    byte b = buf[pos++];
                    tag |= ((ulong)(b & 0x7F)) << shift;
                    if ((b & 0x80) == 0) break;
                    shift += 7;
                }
                if (tag == 0) return false;
                int wt = (int)(tag & 7);
                if ((tag >> 3) == 0) return false;
                if (wt == 0) {
                    shift = 0;
                    bool ok = false;
                    while (pos < end && shift < 70) {
                        byte b = buf[pos++];
                        if ((b & 0x80) == 0) { ok = true; break; }
                        shift += 7;
                    }
                    if (!ok) return false;
                } else if (wt == 1) {
                    if (pos + 8 > end) return false;
                    pos += 8;
                } else if (wt == 2) {
                    ulong len = 0; shift = 0;
                    bool ok = false;
                    while (pos < end && shift < 70) {
                        byte b = buf[pos++];
                        len |= ((ulong)(b & 0x7F)) << shift;
                        if ((b & 0x80) == 0) { ok = true; break; }
                        shift += 7;
                    }
                    if (!ok || len > (ulong)(end - pos)) return false;
                    pos += (int)len;
                } else if (wt == 5) {
                    if (pos + 4 > end) return false;
                    pos += 4;
                } else return false;
            }
            return pos == end;
        }
    }

    // =========================================================================
    // 2. Native Windows SQLite Wrapper (winsqlite3.dll)
    // =========================================================================
    public class WinSqlite : IDisposable {
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr zvfs);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_close_v2(IntPtr db);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_exec(IntPtr db, byte[] sql, IntPtr cb, IntPtr arg, out IntPtr errmsg);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int nByte, out IntPtr stmt, IntPtr pzTail);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_step(IntPtr stmt);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_finalize(IntPtr stmt);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_bind_int64(IntPtr stmt, int idx, long val);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_bind_null(IntPtr stmt, int idx);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_bind_text(IntPtr stmt, int idx, byte[] val, int nByte, IntPtr destructor);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_bind_blob(IntPtr stmt, int idx, byte[] val, int nByte, IntPtr destructor);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_column_count(IntPtr stmt);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr sqlite3_column_name(IntPtr stmt, int iCol);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_column_type(IntPtr stmt, int iCol);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern long sqlite3_column_int64(IntPtr stmt, int iCol);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern double sqlite3_column_double(IntPtr stmt, int iCol);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr sqlite3_column_text(IntPtr stmt, int iCol);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr sqlite3_column_blob(IntPtr stmt, int iCol);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_column_bytes(IntPtr stmt, int iCol);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr sqlite3_errmsg(IntPtr db);

        private static readonly IntPtr SQLITE_TRANSIENT = new IntPtr(-1);
        private IntPtr _db = IntPtr.Zero;

        private static byte[] Utf8Z(string s) {
            byte[] b = Encoding.UTF8.GetBytes(s);
            byte[] r = new byte[b.Length + 1];
            Buffer.BlockCopy(b, 0, r, 0, b.Length);
            return r;
        }

        private static string PtrToUtf8(IntPtr p, int len = -1) {
            if (p == IntPtr.Zero) return null;
            if (len < 0) { len = 0; while (Marshal.ReadByte(p, len) != 0) len++; }
            if (len == 0) return "";
            byte[] b = new byte[len];
            Marshal.Copy(p, b, 0, len);
            return Encoding.UTF8.GetString(b);
        }

        public WinSqlite(string path, bool readOnly) {
            int flags = readOnly ? 1 : 6;
            if (!readOnly) {
                string dir = Path.GetDirectoryName(path);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            }
            int rc = sqlite3_open_v2(Utf8Z(path), out _db, flags, IntPtr.Zero);
            if (rc != 0 || _db == IntPtr.Zero) {
                string msg = _db != IntPtr.Zero ? PtrToUtf8(sqlite3_errmsg(_db)) : ("rc=" + rc);
                if (_db != IntPtr.Zero) { sqlite3_close_v2(_db); _db = IntPtr.Zero; }
                throw new IOException("Failed to open SQLite DB '" + path + "': " + msg);
            }
        }

        public void Exec(string sql) {
            IntPtr err;
            int rc = sqlite3_exec(_db, Utf8Z(sql), IntPtr.Zero, IntPtr.Zero, out err);
            if (rc != 0) {
                string msg = err != IntPtr.Zero ? PtrToUtf8(err) : PtrToUtf8(sqlite3_errmsg(_db));
                throw new InvalidOperationException("SQLite exec error (" + rc + "): " + msg);
            }
        }

        public void ExecuteNonQuery(string sql, params object[] args) {
            IntPtr stmt;
            int rc = sqlite3_prepare_v2(_db, Utf8Z(sql), -1, out stmt, IntPtr.Zero);
            if (rc != 0 || stmt == IntPtr.Zero) {
                throw new InvalidOperationException("SQLite prepare error: " + PtrToUtf8(sqlite3_errmsg(_db)));
            }
            try {
                for (int i = 0; i < args.Length; i++) {
                    int idx = i + 1;
                    object v = args[i];
                    if (v == null || v is DBNull) {
                        sqlite3_bind_null(stmt, idx);
                    } else if (v is long || v is int || v is short || v is byte || v is bool) {
                        long lv = (v is bool) ? (((bool)v) ? 1L : 0L) : Convert.ToInt64(v);
                        sqlite3_bind_int64(stmt, idx, lv);
                    } else if (v is byte[]) {
                        byte[] bv = (byte[])v;
                        sqlite3_bind_blob(stmt, idx, bv, bv.Length, SQLITE_TRANSIENT);
                    } else {
                        byte[] sv = Encoding.UTF8.GetBytes(Convert.ToString(v));
                        sqlite3_bind_text(stmt, idx, sv, sv.Length, SQLITE_TRANSIENT);
                    }
                }
                int stepRc = sqlite3_step(stmt);
                if (stepRc != 101 && stepRc != 100) {
                    throw new InvalidOperationException("SQLite step error (" + stepRc + "): " + PtrToUtf8(sqlite3_errmsg(_db)));
                }
            } finally {
                sqlite3_finalize(stmt);
            }
        }

        public List<Dictionary<string, object>> Query(string sql, bool keepBlobs = false) {
            var rows = new List<Dictionary<string, object>>();
            IntPtr stmt;
            int rc = sqlite3_prepare_v2(_db, Utf8Z(sql), -1, out stmt, IntPtr.Zero);
            if (rc != 0 || stmt == IntPtr.Zero) return rows;
            try {
                int colCount = sqlite3_column_count(stmt);
                string[] names = new string[colCount];
                for (int i = 0; i < colCount; i++) names[i] = PtrToUtf8(sqlite3_column_name(stmt, i)) ?? ("col_" + i);
                while (sqlite3_step(stmt) == 100) {
                    var row = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
                    for (int i = 0; i < colCount; i++) {
                        int t = sqlite3_column_type(stmt, i);
                        if (t == 1) row[names[i]] = sqlite3_column_int64(stmt, i);
                        else if (t == 2) row[names[i]] = sqlite3_column_double(stmt, i);
                        else if (t == 3) row[names[i]] = PtrToUtf8(sqlite3_column_text(stmt, i), sqlite3_column_bytes(stmt, i));
                        else if (t == 4) {
                            int n = sqlite3_column_bytes(stmt, i);
                            if (keepBlobs) {
                                byte[] b = new byte[n];
                                if (n > 0) Marshal.Copy(sqlite3_column_blob(stmt, i), b, 0, n);
                                row[names[i]] = b;
                            } else row[names[i]] = "[BLOB " + n + "]";
                        } else row[names[i]] = null;
                    }
                    rows.Add(row);
                }
            } finally {
                sqlite3_finalize(stmt);
            }
            return rows;
        }

        public void Dispose() {
            if (_db != IntPtr.Zero) {
                sqlite3_close_v2(_db);
                _db = IntPtr.Zero;
            }
        }
    }

    // =========================================================================
    // 3. Codex Session & Project Models + Antigravity Writer
    // =========================================================================
    public class RawTurnEvent {
        public string Kind; // "user", "assistant", "thinking", "tool"
        public string Text;
        public DateTimeOffset Timestamp;
    }

    public class AgyStepModel {
        public bool IsUser;
        public string Content;
        public string Thinking;
        public DateTimeOffset Timestamp;
    }

    public class AgyProjectModel {
        public string CodexProjectId;
        public string AgyProjectId;
        public string Name;
        public string PrimaryPath;
        public string FolderUri;
        public bool FolderExists;
        public int SessionCount;
    }

    public class ConvertedSession {
        public string CodexThreadId;
        public string AgyConversationId;
        public string AgyTrajectoryId;
        public string AgyExecutionId;
        public string AgyProjectId;
        public string AgyProjectName;
        public string WorkspaceUri;
        public string Title;
        public string Preview;
        public string Cwd;
        public bool Archived;
        public DateTimeOffset CreatedAt;
        public DateTimeOffset UpdatedAt;
        public List<AgyStepModel> Steps = new List<AgyStepModel>();
        public int UserTurns;
        public int AssistantTurns;
    }

    public static class SessionConverter {
        private static readonly Regex RxEnvBlock = new Regex(
            @"^\s*<(environment_context|permissions|collaboration_mode|app-context|user_instructions|system-reminder|turn_aborted|subagent_notification|external_codex_[a-z0-9_]+)\b[\s\S]*</\1>\s*$",
            RegexOptions.Compiled | RegexOptions.IgnoreCase);

        private static readonly Regex RxInlineSysTags = new Regex(
            @"<(environment_context|permissions[^>\s]*|collaboration_mode|app-context|user_instructions|system-reminder|external_codex_[a-z0-9_]+)\b[^>]*>[\s\S]*?</\1>",
            RegexOptions.Compiled | RegexOptions.IgnoreCase);

        private static string GetStr(IDictionary d, string k) {
            if (d == null || !d.Contains(k) || d[k] == null) return null;
            return Convert.ToString(d[k]);
        }

        public static string NormalizeWinPath(string raw) {
            if (string.IsNullOrWhiteSpace(raw)) return "";
            string s = Regex.Replace(raw.Trim(), @"^\\\\\?\\", "");
            s = s.Replace('/', '\\').TrimEnd('\\');
            return s;
        }

        public static DateTimeOffset ParseTimestamp(string raw, DateTimeOffset fallback) {
            if (string.IsNullOrWhiteSpace(raw)) return fallback;
            long epoch;
            if (long.TryParse(raw.Trim(), out epoch)) {
                if (epoch > 1000000000000L) return DateTimeOffset.FromUnixTimeMilliseconds(epoch);
                if (epoch > 100000000L) return DateTimeOffset.FromUnixTimeSeconds(epoch);
            }
            DateTimeOffset dto;
            if (DateTimeOffset.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out dto)) return dto;
            return fallback;
        }

        public static string CleanUserText(string raw) {
            if (string.IsNullOrWhiteSpace(raw)) return "";
            string s = raw.Trim();
            if (RxEnvBlock.IsMatch(s)) return "";
            if (s.StartsWith("# AGENTS.md instructions for ", StringComparison.OrdinalIgnoreCase)) return "";
            if (s.StartsWith("<permissions instructions>", StringComparison.OrdinalIgnoreCase) && s.EndsWith("</permissions instructions>", StringComparison.OrdinalIgnoreCase)) return "";
            if (s.StartsWith("<instructions>", StringComparison.OrdinalIgnoreCase) && s.EndsWith("</instructions>", StringComparison.OrdinalIgnoreCase)) return "";
            s = RxInlineSysTags.Replace(s, "").Trim();
            if (RxEnvBlock.IsMatch(s)) return "";
            return s;
        }

        public static string CleanTitle(string raw) {
            if (string.IsNullOrWhiteSpace(raw)) return "";
            string s = raw.Trim();
            var mReq = Regex.Match(s, @"##\s*My request:\s*([\s\S]+)$", RegexOptions.IgnoreCase);
            if (mReq.Success && !string.IsNullOrWhiteSpace(mReq.Groups[1].Value)) {
                s = mReq.Groups[1].Value.Trim();
            } else if (s.StartsWith("# Files ", StringComparison.OrdinalIgnoreCase)) {
                var mQuote = Regex.Match(s, @"##\s*""([^""]+)""");
                if (mQuote.Success) s = mQuote.Groups[1].Value.Trim();
            }
            s = Regex.Replace(s, @"^#+\s*", "");
            s = Regex.Replace(s, @"\[([^\]]+)\]\([^\)]+\)", "$1");
            string noUrl = Regex.Replace(s, @"https?://\S+", "").Trim();
            if (noUrl.Length >= 4) s = noUrl;
            s = Regex.Replace(s, @"\s+", " ").Trim();
            if (s.Length > 36) s = s.Substring(0, 36).Trim() + "...";
            return s;
        }

        private static string TruncateOneLine(string s, int maxLen) {
            if (string.IsNullOrEmpty(s)) return "";
            string clean = Regex.Replace(s, @"\s+", " ").Trim();
            return clean.Length <= maxLen ? clean : (clean.Substring(0, maxLen) + "...");
        }

        private static string ExtractContentParts(object contentObj, bool isUser) {
            if (contentObj == null) return "";
            if (contentObj is string) return isUser ? CleanUserText((string)contentObj) : ((string)contentObj).Trim();
            var list = contentObj as IEnumerable;
            if (list == null) return "";
            var sb = new StringBuilder();
            foreach (var elem in list) {
                if (elem is string) {
                    string st = isUser ? CleanUserText((string)elem) : ((string)elem).Trim();
                    if (!string.IsNullOrEmpty(st)) {
                        if (sb.Length > 0) sb.Append("\n\n");
                        sb.Append(st);
                    }
                    continue;
                }
                var part = elem as IDictionary;
                if (part == null) continue;
                string pt = (GetStr(part, "type") ?? "").Trim();
                if (pt == "input_text" || pt == "output_text" || pt == "text") {
                    string txt = GetStr(part, "text") ?? "";
                    txt = isUser ? CleanUserText(txt) : txt.Trim();
                    if (!string.IsNullOrEmpty(txt)) {
                        if (sb.Length > 0) sb.Append("\n\n");
                        sb.Append(txt);
                    }
                } else if (pt == "input_image" || pt == "image_url" || pt == "image" || pt == "localImage" || pt == "local_image") {
                    string p = GetStr(part, "path");
                    if (sb.Length > 0) sb.Append("\n\n");
                    // [\u56fe\u7247\u9644\u4ef6] = [图片附件], [\u56fe\u7247: ] = [图片: ]
                    sb.Append(string.IsNullOrEmpty(p) ? "`[\u56fe\u7247\u9644\u4ef6]`" : ("`[\u56fe\u7247: " + p + "]`"));
                }
            }
            return sb.ToString().Trim();
        }

        public static List<RawTurnEvent> ParseJsonlEvents(string path, JavaScriptSerializer ser, out string foundId, out string foundCwd, out string agentRole, out string sourceKind, out long firstOrdinal) {
            foundId = null; foundCwd = null; agentRole = null; sourceKind = null; firstOrdinal = 0;
            bool hasFirstOrdinal = false;
            var mPair = Regex.Match(Path.GetFileName(path), @"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})_([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})");
            if (mPair.Success) {
                foundId = mPair.Groups[1].Value.ToLowerInvariant();
            } else {
                var mUuid = Regex.Match(Path.GetFileNameWithoutExtension(path), @"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$");
                if (mUuid.Success) foundId = mUuid.Groups[1].Value.ToLowerInvariant();
            }

            var respEvents = new List<RawTurnEvent>();
            var fallbackEvents = new List<RawTurnEvent>();
            bool hasRespMsgs = false;
            DateTimeOffset lastTs = DateTimeOffset.UtcNow;

            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            using (var sr = new StreamReader(fs, Encoding.UTF8)) {
                string line;
                while ((line = sr.ReadLine()) != null) {
                    if (string.IsNullOrWhiteSpace(line)) continue;
                    IDictionary obj;
                    try { obj = ser.DeserializeObject(line) as IDictionary; } catch { continue; }
                    if (obj == null) continue;

                    if (!hasFirstOrdinal && obj.Contains("ordinal") && obj["ordinal"] != null) {
                        long parsedOrd;
                        if (long.TryParse(Convert.ToString(obj["ordinal"]), out parsedOrd)) {
                            firstOrdinal = parsedOrd;
                            hasFirstOrdinal = true;
                        }
                    }

                    lastTs = ParseTimestamp(GetStr(obj, "timestamp"), lastTs);
                    string topType = GetStr(obj, "type");
                    IDictionary payload = obj.Contains("payload") ? (obj["payload"] as IDictionary) : null;

                    if (topType == "session_meta" && payload != null) {
                        string pid = GetStr(payload, "id");
                        if (string.IsNullOrEmpty(pid)) pid = GetStr(payload, "session_id");
                        if (!string.IsNullOrEmpty(pid)) foundId = pid.ToLowerInvariant();
                        if (string.IsNullOrEmpty(foundCwd)) foundCwd = GetStr(payload, "cwd");
                        if (string.IsNullOrEmpty(agentRole)) agentRole = GetStr(payload, "agent_role");
                        if (payload.Contains("source") && payload["source"] != null) {
                            sourceKind = payload["source"] is string ? (string)payload["source"] : ser.Serialize(payload["source"]);
                        }
                    } else if (topType == "turn_context" && payload != null) {
                        if (string.IsNullOrEmpty(foundCwd)) foundCwd = GetStr(payload, "cwd");
                    } else if (topType == "response_item" && payload != null) {
                        string ptype = GetStr(payload, "type");
                        if (ptype == "message") {
                            string role = GetStr(payload, "role");
                            if (role == "user" || role == "assistant") {
                                string txt = ExtractContentParts(payload["content"], role == "user");
                                if (!string.IsNullOrEmpty(txt)) {
                                    hasRespMsgs = true;
                                    respEvents.Add(new RawTurnEvent { Kind = role, Text = txt, Timestamp = lastTs });
                                }
                            }
                        } else if (ptype == "reasoning") {
                            string rsum = ExtractContentParts(payload["summary"], false);
                            if (!string.IsNullOrEmpty(rsum)) {
                                respEvents.Add(new RawTurnEvent { Kind = "thinking", Text = rsum, Timestamp = lastTs });
                            }
                        } else if (ptype == "function_call" || ptype == "custom_tool_call") {
                            string tn = GetStr(payload, "name") ?? "tool";
                            string ta = GetStr(payload, "arguments") ?? GetStr(payload, "input") ?? "";
                            respEvents.Add(new RawTurnEvent { Kind = "tool", Text = "[Tool] " + tn + ": " + TruncateOneLine(ta, 140), Timestamp = lastTs });
                        } else if (ptype == "local_shell_call") {
                            IDictionary act = payload.Contains("action") ? (payload["action"] as IDictionary) : null;
                            string cmd = "";
                            if (act != null && act.Contains("command") && act["command"] is IEnumerable) {
                                var ps = new List<string>();
                                foreach (var p in (IEnumerable)act["command"]) ps.Add(Convert.ToString(p));
                                cmd = string.Join(" ", ps.ToArray());
                            }
                            respEvents.Add(new RawTurnEvent { Kind = "tool", Text = "[Shell] " + TruncateOneLine(cmd, 140), Timestamp = lastTs });
                        }
                    } else if (topType == "event_msg" && payload != null) {
                        string et = GetStr(payload, "type");
                        if (et == "user_message") {
                            string m = CleanUserText(GetStr(payload, "message"));
                            if (!string.IsNullOrEmpty(m)) fallbackEvents.Add(new RawTurnEvent { Kind = "user", Text = m, Timestamp = lastTs });
                        } else if (et == "agent_message") {
                            string m = (GetStr(payload, "message") ?? "").Trim();
                            if (!string.IsNullOrEmpty(m)) fallbackEvents.Add(new RawTurnEvent { Kind = "assistant", Text = m, Timestamp = lastTs });
                        }
                    } else if (topType == "message" || obj.Contains("role")) {
                        string role = GetStr(obj, "role");
                        if (role == "user" || role == "assistant") {
                            string txt = ExtractContentParts(obj["content"], role == "user");
                            if (!string.IsNullOrEmpty(txt)) {
                                hasRespMsgs = true;
                                respEvents.Add(new RawTurnEvent { Kind = role, Text = txt, Timestamp = lastTs });
                            }
                        }
                    }
                }
            }
            return hasRespMsgs ? respEvents : fallbackEvents;
        }

        public static RawTurnEvent ParseSqliteItem(string itemTypeCol, string itemJson, DateTimeOffset ts, JavaScriptSerializer ser) {
            if (string.IsNullOrWhiteSpace(itemJson)) return null;
            IDictionary obj;
            try { obj = ser.DeserializeObject(itemJson) as IDictionary; } catch { return null; }
            if (obj == null) return null;
            if (!obj.Contains("type") && obj.Contains("item") && obj["item"] is IDictionary) obj = (IDictionary)obj["item"];

            string itype = (GetStr(obj, "type") ?? itemTypeCol ?? "").Trim();
            string il = itype.ToLowerInvariant();

            if (il == "usermessage" || il == "user_message") {
                string txt = ExtractContentParts(obj["content"], true);
                if (string.IsNullOrEmpty(txt)) txt = CleanUserText(GetStr(obj, "text") ?? GetStr(obj, "message"));
                return string.IsNullOrEmpty(txt) ? null : new RawTurnEvent { Kind = "user", Text = txt, Timestamp = ts };
            }
            if (il == "agentmessage" || il == "agent_message" || il == "assistantmessage" || il == "assistant_message") {
                string txt = (GetStr(obj, "text") ?? GetStr(obj, "message") ?? "").Trim();
                if (string.IsNullOrEmpty(txt)) txt = ExtractContentParts(obj["content"], false);
                return string.IsNullOrEmpty(txt) ? null : new RawTurnEvent { Kind = "assistant", Text = txt, Timestamp = ts };
            }
            if (il == "plan") {
                string txt = (GetStr(obj, "text") ?? ExtractContentParts(obj["content"], false) ?? "").Trim();
                // **[\u8ba1\u5212\u65b9\u6848]** = **[计划方案]**
                return string.IsNullOrEmpty(txt) ? null : new RawTurnEvent { Kind = "assistant", Text = "**[Codex \u8ba1\u5212\u65b9\u6848]**\n\n" + txt, Timestamp = ts };
            }
            if (il == "message") {
                string role = (GetStr(obj, "role") ?? "").ToLowerInvariant();
                if (role == "user" || role == "assistant") {
                    string txt = ExtractContentParts(obj["content"], role == "user");
                    if (!string.IsNullOrEmpty(txt)) return new RawTurnEvent { Kind = role, Text = txt, Timestamp = ts };
                }
                return null;
            }
            if (il == "reasoning") {
                string rsum = ExtractContentParts(obj["summary"], false);
                if (!string.IsNullOrEmpty(rsum)) return new RawTurnEvent { Kind = "thinking", Text = rsum, Timestamp = ts };
                return null;
            }
            if (il == "commandexecution" || il == "command_execution" || il == "localshellcall" || il == "local_shell_call") {
                string cmd = GetStr(obj, "command") ?? "";
                return new RawTurnEvent { Kind = "tool", Text = "[Command] " + TruncateOneLine(cmd, 140), Timestamp = ts };
            }
            if (il == "filechange" || il == "file_change") {
                var ps = new List<string>();
                if (obj.Contains("changes") && obj["changes"] is IEnumerable) {
                    foreach (var ch in (IEnumerable)obj["changes"]) {
                        var cd = ch as IDictionary;
                        if (cd != null && cd["path"] != null) ps.Add(Convert.ToString(cd["path"]));
                    }
                }
                return new RawTurnEvent { Kind = "tool", Text = "[FileChange] " + TruncateOneLine(string.Join(", ", ps.ToArray()), 140), Timestamp = ts };
            }
            if (il == "mcptoolcall" || il == "mcp_tool_call" || il == "dynamictoolcall" || il == "function_call" || il == "custom_tool_call" || il == "websearch" || il == "web_search") {
                string tn = GetStr(obj, "tool") ?? GetStr(obj, "name") ?? GetStr(obj, "query") ?? itype;
                return new RawTurnEvent { Kind = "tool", Text = "[" + itype + "] " + TruncateOneLine(tn, 140), Timestamp = ts };
            }
            return null;
        }

        public static ConvertedSession BuildConvertedSession(
            string codexThreadId, string rawTitle, string titlePrefix, string cwd, bool archived,
            string agyProjectId, string agyProjectName, string workspaceUri,
            DateTimeOffset metaCreated, DateTimeOffset metaUpdated, List<RawTurnEvent> events)
        {
            var conv = new ConvertedSession();
            conv.CodexThreadId = codexThreadId.ToLowerInvariant();
            conv.AgyConversationId = AgyProtoBuilder.DeterministicUuidV4("agy-conv", conv.CodexThreadId);
            conv.AgyTrajectoryId = AgyProtoBuilder.DeterministicUuidV4("agy-traj", conv.CodexThreadId);
            conv.AgyExecutionId = AgyProtoBuilder.DeterministicUuidV4("agy-exec", conv.CodexThreadId);
            conv.Cwd = NormalizeWinPath(cwd);
            conv.Archived = archived;
            conv.AgyProjectId = string.IsNullOrEmpty(agyProjectId) ? "outside-of-project" : agyProjectId;
            conv.AgyProjectName = agyProjectName ?? "";
            conv.WorkspaceUri = workspaceUri ?? "";

            string baseTitle = CleanTitle(rawTitle);

            var pendingNotes = new List<string>();
            string prevKind = null, prevText = null;
            string firstUserText = null;

            foreach (var ev in events) {
                if (ev == null || string.IsNullOrWhiteSpace(ev.Text)) continue;
                if (ev.Kind == prevKind && ev.Text == prevText) continue;
                prevKind = ev.Kind;
                prevText = ev.Text;

                if (ev.Kind == "thinking" || ev.Kind == "tool") {
                    if (pendingNotes.Count < 60) pendingNotes.Add(ev.Text);
                    continue;
                }

                if (ev.Kind == "user") {
                    if (firstUserText == null) firstUserText = ev.Text;
                    conv.Steps.Add(new AgyStepModel {
                        IsUser = true,
                        Content = ev.Text,
                        Thinking = null,
                        Timestamp = ev.Timestamp
                    });
                    conv.UserTurns++;
                } else if (ev.Kind == "assistant") {
                    if (conv.Steps.Count == 0) {
                        string synthLabel = !string.IsNullOrWhiteSpace(baseTitle) ? baseTitle : ("Codex " + conv.CodexThreadId.Substring(0, 8));
                        conv.Steps.Add(new AgyStepModel { IsUser = true, Content = synthLabel, Timestamp = ev.Timestamp });
                        conv.UserTurns++;
                    }
                    string thinkingJoined = pendingNotes.Count > 0 ? string.Join("\n", pendingNotes.ToArray()) : null;
                    pendingNotes.Clear();
                    conv.Steps.Add(new AgyStepModel {
                        IsUser = false,
                        Content = ev.Text,
                        Thinking = thinkingJoined,
                        Timestamp = ev.Timestamp
                    });
                    conv.AssistantTurns++;
                }
            }

            if (conv.Steps.Count == 0) return null;

            conv.CreatedAt = metaCreated != DateTimeOffset.MinValue ? metaCreated : conv.Steps[0].Timestamp;
            conv.UpdatedAt = metaUpdated != DateTimeOffset.MinValue ? metaUpdated : conv.Steps[conv.Steps.Count - 1].Timestamp;
            if (conv.CreatedAt == DateTimeOffset.MinValue) conv.CreatedAt = DateTimeOffset.UtcNow;
            if (conv.UpdatedAt == DateTimeOffset.MinValue) conv.UpdatedAt = conv.CreatedAt;

            if (string.IsNullOrWhiteSpace(baseTitle)) {
                baseTitle = CleanTitle(firstUserText);
            }
            if (string.IsNullOrWhiteSpace(baseTitle)) {
                baseTitle = "Codex Session " + conv.CodexThreadId.Substring(0, Math.Min(8, conv.CodexThreadId.Length));
            }
            conv.Title = (titlePrefix ?? "") + baseTitle;
            conv.Preview = !string.IsNullOrWhiteSpace(firstUserText) ? TruncateOneLine(firstUserText, 100) : conv.Title;
            return conv;
        }

        public static void WriteAntigravityConversationFiles(ConvertedSession conv, string rootOutDir, JavaScriptSerializer ser) {
            string convDbPath = Path.Combine(Path.Combine(rootOutDir, "conversations"), conv.AgyConversationId + ".db");
            if (File.Exists(convDbPath)) File.Delete(convDbPath);

            using (var db = new WinSqlite(convDbPath, false)) {
                // CRITICAL: PRAGMA user_version=1 prevents Antigravity v0->v1 startup migration from wiping trajectory_metadata_blob!
                db.Exec(@"
                    PRAGMA journal_mode=WAL;
                    PRAGMA user_version=1;
                    CREATE TABLE `trajectory_meta` (`trajectory_id` text,`cascade_id` text,`trajectory_type` integer,`source` integer,PRIMARY KEY (`trajectory_id`));
                    CREATE TABLE `steps` (`idx` integer,`step_type` integer NOT NULL DEFAULT 0,`status` integer NOT NULL DEFAULT 0,`has_subtrajectory` numeric NOT NULL DEFAULT false,`metadata` blob,`error_details` blob,`permissions` blob,`task_details` blob,`render_info` blob,`step_payload` blob,`step_format` integer NOT NULL DEFAULT 0,PRIMARY KEY (`idx`));
                    CREATE INDEX `idx_steps_status` ON `steps`(`status`);
                    CREATE INDEX `idx_steps_step_type` ON `steps`(`step_type`);
                    CREATE TABLE `gen_metadata` (`idx` integer,`data` blob,`size` integer NOT NULL DEFAULT 0,PRIMARY KEY (`idx`));
                    CREATE TABLE `executor_metadata` (`idx` integer,`data` blob,PRIMARY KEY (`idx`));
                    CREATE TABLE `parent_references` (`idx` integer,`data` blob,PRIMARY KEY (`idx`));
                    CREATE TABLE `trajectory_metadata_blob` (`id` text DEFAULT ""main"",`data` blob,PRIMARY KEY (`id`));
                    CREATE TABLE `battle_mode_infos` (`idx` integer,`data` blob,PRIMARY KEY (`idx`));
                    BEGIN TRANSACTION;
                ");

                db.ExecuteNonQuery(
                    "INSERT INTO `trajectory_meta` (`trajectory_id`, `cascade_id`, `trajectory_type`, `source`) VALUES (?, ?, 4, 1)",
                    conv.AgyTrajectoryId, conv.AgyConversationId);

                byte[] trajMetaBlob = AgyProtoBuilder.BuildTrajectoryMetadata(conv.CreatedAt, conv.AgyExecutionId, conv.AgyConversationId, conv.AgyProjectId);
                db.ExecuteNonQuery(
                    "INSERT INTO `trajectory_metadata_blob` (`id`, `data`) VALUES ('main', ?)",
                    trajMetaBlob);

                int turnIdx = -1;
                string turnExecId = AgyProtoBuilder.DeterministicUuidV4("turn", conv.AgyConversationId + ":0");
                for (int i = 0; i < conv.Steps.Count; i++) {
                    AgyStepModel st = conv.Steps[i];
                    byte[] metaBytes, payloadBytes;
                    if (st.IsUser) {
                        turnIdx++;
                        turnExecId = AgyProtoBuilder.DeterministicUuidV4("turn", conv.AgyConversationId + ":" + turnIdx);
                        AgyProtoBuilder.BuildUserInputStep(
                            conv.AgyConversationId, conv.AgyTrajectoryId, turnExecId,
                            i, Math.Max(0, turnIdx), st.Timestamp, st.Content,
                            out metaBytes, out payloadBytes);
                        db.ExecuteNonQuery(
                            "INSERT INTO `steps` (`idx`, `step_type`, `status`, `has_subtrajectory`, `metadata`, `step_payload`, `step_format`) VALUES (?, 14, 3, 0, ?, ?, 0)",
                            i, metaBytes, payloadBytes);
                    } else {
                        AgyProtoBuilder.BuildPlannerResponseStep(
                            conv.AgyConversationId, conv.AgyTrajectoryId, turnExecId,
                            i, Math.Max(0, turnIdx), st.Timestamp, st.Content, st.Thinking,
                            out metaBytes, out payloadBytes);
                        db.ExecuteNonQuery(
                            "INSERT INTO `steps` (`idx`, `step_type`, `status`, `has_subtrajectory`, `metadata`, `step_payload`, `step_format`) VALUES (?, 15, 3, 0, ?, ?, 0)",
                            i, metaBytes, payloadBytes);
                    }
                }
                db.Exec("COMMIT; PRAGMA wal_checkpoint(TRUNCATE);");
            }

            // Write annotations/<id>.pbtxt (UTF-8 without BOM — required by Go prototext parser)
            string annDir = Path.Combine(rootOutDir, "annotations");
            Directory.CreateDirectory(annDir);
            string pbtxt = AgyProtoBuilder.BuildAnnotationPbtxt(conv.Title, conv.UpdatedAt);
            var utf8NoBom = new UTF8Encoding(false);
            File.WriteAllText(Path.Combine(annDir, conv.AgyConversationId + ".pbtxt"), pbtxt, utf8NoBom);

            // Write brain/<id>/.system_generated/logs/transcript_full.jsonl & transcript.jsonl
            string logsDir = Path.Combine(Path.Combine(Path.Combine(Path.Combine(rootOutDir, "brain"), conv.AgyConversationId), ".system_generated"), "logs");
            Directory.CreateDirectory(logsDir);
            var fullSb = new StringBuilder();
            var compactSb = new StringBuilder();
            for (int i = 0; i < conv.Steps.Count; i++) {
                AgyStepModel st = conv.Steps[i];
                string iso = st.Timestamp.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture);
                var rowFull = new Dictionary<string, object>();
                rowFull["step_index"] = i;
                rowFull["source"] = st.IsUser ? "USER_EXPLICIT" : "MODEL";
                rowFull["type"] = st.IsUser ? "USER_INPUT" : "PLANNER_RESPONSE";
                rowFull["status"] = "DONE";
                rowFull["created_at"] = iso;
                string fullContent = st.IsUser ? ("<USER_REQUEST>\n" + st.Content + "\n</USER_REQUEST>") : st.Content;
                rowFull["content"] = fullContent;
                if (!st.IsUser && !string.IsNullOrEmpty(st.Thinking)) rowFull["thinking"] = st.Thinking;
                fullSb.AppendLine(ser.Serialize(rowFull));

                if (fullContent.Length > 8000) {
                    var rowComp = new Dictionary<string, object>(rowFull);
                    int cut = fullContent.Length - 4000;
                    rowComp["content"] = fullContent.Substring(0, 2000) + "\n<truncated " + cut + " chars>\n" + fullContent.Substring(fullContent.Length - 2000);
                    rowComp["truncated_fields"] = new string[] { "content" };
                    compactSb.AppendLine(ser.Serialize(rowComp));
                } else {
                    compactSb.AppendLine(ser.Serialize(rowFull));
                }
            }
            File.WriteAllText(Path.Combine(logsDir, "transcript_full.jsonl"), fullSb.ToString(), utf8NoBom);
            File.WriteAllText(Path.Combine(logsDir, "transcript.jsonl"), compactSb.ToString(), utf8NoBom);
        }

        public static void UpsertSummariesDb(string summariesDbPath, List<ConvertedSession> sessions) {
            bool existed = File.Exists(summariesDbPath);
            using (var db = new WinSqlite(summariesDbPath, false)) {
                if (!existed) {
                    db.Exec("PRAGMA user_version=3;");
                }
                db.Exec(@"
                    CREATE TABLE IF NOT EXISTS `conversation_summaries` (
                        `conversation_id` text,
                        `title` text NOT NULL DEFAULT """",
                        `preview` text NOT NULL DEFAULT """",
                        `step_count` integer NOT NULL DEFAULT 0,
                        `last_modified_time` datetime NOT NULL,
                        `workspace_uris` text NOT NULL,
                        `status` text NOT NULL DEFAULT """",
                        `source` text NOT NULL DEFAULT """",
                        `project_id` text NOT NULL DEFAULT """",
                        `agent_name` text NOT NULL DEFAULT """",
                        `parent_conversation_id` text NOT NULL DEFAULT """",
                        `nesting_depth` integer NOT NULL DEFAULT 0,
                        `battle_id` text NOT NULL DEFAULT """",
                        `winning_conversation_id` text NOT NULL DEFAULT """",
                        `not_fully_idle` numeric NOT NULL DEFAULT false,
                        `killed` numeric NOT NULL DEFAULT false,
                        `last_user_input_time` datetime NOT NULL,
                        `last_user_input_step_index` integer NOT NULL DEFAULT -1,
                        `app_data_dir` text NOT NULL DEFAULT """",
                        `raw_summary` blob,
                        `group_id` text NOT NULL DEFAULT """",
                        PRIMARY KEY (`conversation_id`)
                    );
                    CREATE INDEX IF NOT EXISTS `idx_conversation_summaries_last_user_input_time` ON `conversation_summaries`(`last_user_input_time`);
                    CREATE INDEX IF NOT EXISTS `idx_conversation_summaries_last_modified_time` ON `conversation_summaries`(`last_modified_time`);
                    BEGIN TRANSACTION;
                ");

                var ftsCheck = db.Query("SELECT name FROM sqlite_master WHERE type='table' AND name='conversations_fts'");
                bool hasFts = ftsCheck.Count > 0;

                foreach (var conv in sessions) {
                    int lastUserIdx = -1;
                    DateTimeOffset lastUserTs = conv.CreatedAt;
                    for (int i = conv.Steps.Count - 1; i >= 0; i--) {
                        if (conv.Steps[i].IsUser) {
                            lastUserIdx = i;
                            lastUserTs = conv.Steps[i].Timestamp;
                            break;
                        }
                    }

                    string pid = string.IsNullOrEmpty(conv.AgyProjectId) ? "outside-of-project" : conv.AgyProjectId;
                    string wsUris = string.IsNullOrEmpty(conv.WorkspaceUri)
                        ? ""
                        : ("[\"" + conv.WorkspaceUri.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"]");

                    byte[] rawSum = AgyProtoBuilder.BuildCascadeRunSummary(
                        conv.Title, conv.Steps.Count, conv.CreatedAt, conv.UpdatedAt,
                        lastUserTs, lastUserIdx,
                        conv.AgyTrajectoryId, conv.AgyExecutionId, conv.AgyConversationId, pid);

                    string fmtUpdated = conv.UpdatedAt.ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss.fffffff+00:00", CultureInfo.InvariantCulture);
                    string fmtLastUser = lastUserTs.ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss.fffffff+00:00", CultureInfo.InvariantCulture);

                    db.ExecuteNonQuery(@"
                        INSERT OR REPLACE INTO `conversation_summaries` (
                            `conversation_id`, `title`, `preview`, `step_count`,
                            `last_modified_time`, `workspace_uris`, `status`, `source`,
                            `project_id`, `agent_name`, `parent_conversation_id`, `nesting_depth`,
                            `battle_id`, `winning_conversation_id`, `not_fully_idle`, `killed`,
                            `last_user_input_time`, `last_user_input_step_index`, `app_data_dir`,
                            `raw_summary`, `group_id`
                        ) VALUES (?, ?, ?, ?, ?, ?, 'CASCADE_RUN_STATUS_IDLE', '', ?, '', '', 0, '', '', 0, 0, ?, ?, 'antigravity', ?, '')",
                        conv.AgyConversationId, conv.Title, conv.Preview, conv.Steps.Count,
                        fmtUpdated, wsUris, pid, fmtLastUser, lastUserIdx, rawSum);

                    if (hasFts) {
                        db.ExecuteNonQuery("DELETE FROM `conversations_fts` WHERE `conversation_id` = ?", conv.AgyConversationId);
                    }
                }

                db.Exec("COMMIT;");
            }
        }

        public static int VerifyOutputDir(string rootOutDir) {
            string sumDb = Path.Combine(rootOutDir, "conversation_summaries.db");
            if (!File.Exists(sumDb)) throw new FileNotFoundException("Missing conversation_summaries.db in " + rootOutDir);

            int verifiedCount = 0;
            using (var sdb = new WinSqlite(sumDb, true)) {
                var rows = sdb.Query("SELECT conversation_id, title, project_id, step_count, raw_summary FROM conversation_summaries", true);
                foreach (var r in rows) {
                    string cid = Convert.ToString(r["conversation_id"]);
                    string title = Convert.ToString(r["title"]);
                    string pid = Convert.ToString(r["project_id"]);
                    long expectedSteps = Convert.ToInt64(r["step_count"]);
                    byte[] rawSum = r["raw_summary"] as byte[];
                    if (string.IsNullOrWhiteSpace(title)) {
                        throw new InvalidDataException("Empty title in conversation_summaries for " + cid);
                    }
                    if (!AgyProtoBuilder.ValidateProtoWire(rawSum)) {
                        throw new InvalidDataException("Invalid raw_summary protobuf for " + cid);
                    }

                    string annPath = Path.Combine(Path.Combine(rootOutDir, "annotations"), cid + ".pbtxt");
                    if (!File.Exists(annPath)) throw new FileNotFoundException("Missing annotation pbtxt: " + annPath);
                    string annText = File.ReadAllText(annPath, Encoding.UTF8);
                    if (!annText.StartsWith("title:\"")) {
                        throw new InvalidDataException("Annotation pbtxt missing title field: " + annPath);
                    }

                    if (!string.IsNullOrEmpty(pid) && pid != "outside-of-project") {
                        string projJson = Path.Combine(Path.Combine(rootOutDir, "projects"), pid + ".json");
                        if (!File.Exists(projJson)) {
                            throw new FileNotFoundException("Missing staged project JSON for project_id " + pid + ": " + projJson);
                        }
                    }

                    string cdbPath = Path.Combine(Path.Combine(rootOutDir, "conversations"), cid + ".db");
                    if (!File.Exists(cdbPath)) throw new FileNotFoundException("Missing conversation DB: " + cdbPath);

                    using (var cdb = new WinSqlite(cdbPath, true)) {
                        var uv = cdb.Query("PRAGMA user_version", false);
                        if (uv.Count != 1 || Convert.ToInt64(uv[0]["user_version"]) != 1L) {
                            throw new InvalidDataException("Conversation DB user_version must be 1 for " + cid);
                        }
                        var tmeta = cdb.Query("SELECT data FROM trajectory_metadata_blob WHERE id='main'", true);
                        if (tmeta.Count != 1 || !AgyProtoBuilder.ValidateProtoWire(tmeta[0]["data"] as byte[])) {
                            throw new InvalidDataException("Invalid trajectory_metadata_blob for " + cid);
                        }
                        var steps = cdb.Query("SELECT idx, metadata, step_payload FROM steps ORDER BY idx ASC", true);
                        if (steps.Count != expectedSteps) {
                            throw new InvalidDataException("Step count mismatch for " + cid + ": expected " + expectedSteps + ", got " + steps.Count);
                        }
                        foreach (var st in steps) {
                            if (!AgyProtoBuilder.ValidateProtoWire(st["metadata"] as byte[]) ||
                                !AgyProtoBuilder.ValidateProtoWire(st["step_payload"] as byte[])) {
                                throw new InvalidDataException("Invalid step protobuf in " + cid + " at idx " + st["idx"]);
                            }
                        }
                    }

                    string trPath = Path.Combine(Path.Combine(Path.Combine(Path.Combine(rootOutDir, "brain"), cid), ".system_generated"), @"logs\transcript.jsonl");
                    if (!File.Exists(trPath)) throw new FileNotFoundException("Missing transcript.jsonl for " + cid);
                    verifiedCount++;
                }
            }
            return verifiedCount;
        }
    }
}
'@

if (-not ("CodexToAgyV2.SessionConverter" -as [type])) {
    Add-Type -TypeDefinition $csharpSource -ReferencedAssemblies "System.Web.Extensions"
}

$ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$ser.MaxJsonLength = [int]::MaxValue
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Load optional rename-config.json
$customProjectNames = @{}
$customThreadTitles = @{}
if (-not [string]::IsNullOrWhiteSpace($RenameConfig) -and (Test-Path $RenameConfig)) {
    $rcObj = $ser.DeserializeObject([System.IO.File]::ReadAllText($RenameConfig, [System.Text.Encoding]::UTF8))
    if ($rcObj -and $rcObj.ContainsKey("project_names") -and $rcObj["project_names"]) {
        foreach ($k in $rcObj["project_names"].Keys) {
            $customProjectNames[([string]$k).ToLowerInvariant()] = [string]$rcObj["project_names"][$k]
        }
    }
    if ($rcObj -and $rcObj.ContainsKey("thread_titles") -and $rcObj["thread_titles"]) {
        foreach ($k in $rcObj["thread_titles"].Keys) {
            $customThreadTitles[([string]$k).ToLowerInvariant()] = [string]$rcObj["thread_titles"][$k]
        }
    }
}

# Scan existing Antigravity projects in ~/.gemini/config/projects to reuse UUIDs and prevent duplicate projects
$existingUriToAgyProjId = @{}
$existingCfgProjDir = Join-Path $GeminiConfigDir "projects"
if (Test-Path $existingCfgProjDir) {
    foreach ($pf in (Get-ChildItem -Path $existingCfgProjDir -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
        try {
            $po = $ser.DeserializeObject([System.IO.File]::ReadAllText($pf.FullName, [System.Text.Encoding]::UTF8))
            if ($po -and $po.ContainsKey("id") -and $po["id"] -and $po.ContainsKey("projectResources") -and $po["projectResources"]) {
                $pr = $po["projectResources"]
                if ($pr.ContainsKey("resources") -and $pr["resources"]) {
                    foreach ($resItem in $pr["resources"]) {
                        if (-not $resItem) { continue }
                        $rawFuri = $null
                        if ($resItem.ContainsKey("gitFolder") -and $resItem["gitFolder"] -and $resItem["gitFolder"].ContainsKey("folderUri")) {
                            $rawFuri = [string]$resItem["gitFolder"]["folderUri"]
                        } elseif ($resItem.ContainsKey("folderUri") -and $resItem["folderUri"]) {
                            $rawFuri = [string]$resItem["folderUri"]
                        }
                        if ($rawFuri) {
                            $furi = $rawFuri.TrimEnd('/')
                            if ($furi) { $existingUriToAgyProjId[$furi.ToLowerInvariant()] = [string]$po["id"] }
                        }
                    }
                }
            }
        } catch {}
    }
}

[void][System.IO.Directory]::CreateDirectory($OutputDir)
foreach ($subDir in @("annotations", "projects")) {
    $sd = Join-Path $OutputDir $subDir
    if (Test-Path $sd) { Remove-Item $sd -Recurse -Force }
    [void][System.IO.Directory]::CreateDirectory($sd)
}

$convertedSessions = New-Object 'System.Collections.Generic.List[CodexToAgyV2.ConvertedSession]'
$codexProjects = @{}     # codexProjectId -> AgyProjectModel
$primaryRootMap = @{}    # normalizedPathLower -> codexProjectId (position == 0)
$secondaryRootList = @() # @{ PathLower; CodexProjectId; Position }
$skippedGuardian = 0
$skippedSubagent = 0
$skippedEmpty = 0

if (-not [string]::IsNullOrWhiteSpace($InputJsonl)) {
    $fullJsonl = (Resolve-Path $InputJsonl).Path
    $fid = $null; $fcwd = $null; $frole = $null; $fsrc = $null; $ford = [long]0
    $evts = [CodexToAgyV2.SessionConverter]::ParseJsonlEvents($fullJsonl, $ser, [ref]$fid, [ref]$fcwd, [ref]$frole, [ref]$fsrc, [ref]$ford)
    if ([string]::IsNullOrEmpty($fid)) { $fid = [Guid]::NewGuid().ToString() }
    $ovrTitle = if ($customThreadTitles.ContainsKey($fid)) { $customThreadTitles[$fid] } else { "" }
    $conv = [CodexToAgyV2.SessionConverter]::BuildConvertedSession(
        $fid, $ovrTitle, $TitlePrefix, $fcwd, $false,
        "outside-of-project", "", "",
        [DateTimeOffset]::MinValue, [DateTimeOffset]::MinValue, $evts)
    if ($conv -ne $null) { $convertedSessions.Add($conv) }
} else {
    $indexTitles = @{}
    $indexUpdated = @{}
    $idxFile = Join-Path $CodexDir "session_index.jsonl"
    if (Test-Path $idxFile) {
        foreach ($line in [System.IO.File]::ReadLines($idxFile, [System.Text.Encoding]::UTF8)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $obj = $ser.DeserializeObject($line)
                if ($obj -and $obj.ContainsKey("id") -and $obj["id"]) {
                    $id = ([string]$obj["id"]).ToLowerInvariant()
                    if ($obj.ContainsKey("thread_name") -and $obj["thread_name"]) { $indexTitles[$id] = [string]$obj["thread_name"] }
                    if ($obj.ContainsKey("updated_at") -and $obj["updated_at"]) { $indexUpdated[$id] = [string]$obj["updated_at"] }
                }
            } catch {}
        }
    }

    $sqliteMeta = @{}
    $spawnedChildIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    function Find-LatestVersionedSqlite([string]$dir, [string]$prefix) {
    if (-not (Test-Path -LiteralPath $dir)) { return "" }
    $bestVer = -1
    $bestPath = ""
    $rx = "^" + [Regex]::Escape($prefix) + "_(\d+)\.sqlite$"
    foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter "$prefix_*.sqlite" -File -ErrorAction SilentlyContinue)) {
        if ($f.Name -imatch $rx) {
            $v = [int]$Matches[1]
            if ($v -gt $bestVer) { $bestVer = $v; $bestPath = $f.FullName }
        }
    }
    return $bestPath
}
    $stateDb = Find-LatestVersionedSqlite $CodexDir "state"
    if ($stateDb -and (Test-Path -LiteralPath $stateDb)) {
        $sdb = New-Object CodexToAgyV2.WinSqlite($stateDb, $true)
        try {
            foreach ($r in $sdb.Query("SELECT * FROM threads", $false)) {
                if ($r.ContainsKey("id") -and $r["id"]) { $sqliteMeta[([string]$r["id"]).ToLowerInvariant()] = $r }
            }
            foreach ($e in $sdb.Query("SELECT child_thread_id FROM thread_spawn_edges", $false)) {
                if ($e.ContainsKey("child_thread_id") -and $e["child_thread_id"]) {
                    [void]$spawnedChildIds.Add(([string]$e["child_thread_id"]).ToLowerInvariant())
                }
            }
            if (-not $NoProjects) {
                $projRows = $sdb.Query("SELECT id, name, position FROM projects ORDER BY position ASC", $false)
                $rootRows = $sdb.Query("SELECT project_id, position, path FROM project_roots ORDER BY position ASC", $false)
                $rootsByProj = @{}
                foreach ($rr in $rootRows) {
                    $projKey = ([string]$rr["project_id"]).ToLowerInvariant()
                    $pos = [Convert]::ToInt32($rr["position"])
                    $normPath = [CodexToAgyV2.SessionConverter]::NormalizeWinPath([string]$rr["path"])
                    if (-not $rootsByProj.ContainsKey($projKey)) { $rootsByProj[$projKey] = @() }
                    $rootsByProj[$projKey] += @{ Position = $pos; Path = $normPath }
                    if (-not [string]::IsNullOrEmpty($normPath)) {
                        $pl = $normPath.ToLowerInvariant()
                        if ($pos -eq 0) {
                            $primaryRootMap[$pl] = $projKey
                        } else {
                            $secondaryRootList += @{ PathLower = $pl; CodexProjectId = $projKey; Position = $pos }
                        }
                    }
                }
                foreach ($pr in $projRows) {
                    $cpid = ([string]$pr["id"]).ToLowerInvariant()
                    $pname = [string]$pr["name"]
                    if ($customProjectNames.ContainsKey($cpid) -and -not [string]::IsNullOrWhiteSpace($customProjectNames[$cpid])) {
                        $pname = $customProjectNames[$cpid]
                    }
                    $primPath = ""
                    if ($rootsByProj.ContainsKey($cpid) -and $rootsByProj[$cpid].Count -gt 0) {
                        $primPath = $rootsByProj[$cpid][0].Path
                    }
                    $furi = [CodexToAgyV2.AgyProtoBuilder]::PathToVscodeFileUri($primPath)
                    $fexists = (-not [string]::IsNullOrEmpty($primPath)) -and (Test-Path -LiteralPath $primPath)
                    $agyPid = [CodexToAgyV2.AgyProtoBuilder]::DeterministicUuidV4("agy-proj", $cpid)
                    if (-not [string]::IsNullOrEmpty($furi) -and $existingUriToAgyProjId.ContainsKey($furi.TrimEnd('/').ToLowerInvariant())) {
                        $agyPid = $existingUriToAgyProjId[$furi.TrimEnd('/').ToLowerInvariant()]
                    }
                    $pm = New-Object CodexToAgyV2.AgyProjectModel
                    $pm.CodexProjectId = $cpid
                    $pm.AgyProjectId = $agyPid
                    $pm.Name = $pname
                    $pm.PrimaryPath = $primPath
                    $pm.FolderUri = if ($fexists) { $furi } else { "" }
                    $pm.FolderExists = $fexists
                    $pm.SessionCount = 0
                    $codexProjects[$cpid] = $pm
                }
            }
        } finally { $sdb.Dispose() }
    }

    function Resolve-SessionProject([string]$explicitCodexProjId, [string]$rawCwd) {
        if ($NoProjects) { return $null }
        if (-not [string]::IsNullOrWhiteSpace($explicitCodexProjId)) {
            $k = $explicitCodexProjId.Trim().ToLowerInvariant()
            if ($codexProjects.ContainsKey($k)) { return $codexProjects[$k] }
        }
        $normCwd = [CodexToAgyV2.SessionConverter]::NormalizeWinPath($rawCwd)
        if ([string]::IsNullOrEmpty($normCwd)) { return $null }
        $cl = $normCwd.ToLowerInvariant()

        # 1. Exact or longest-prefix subdirectory match on primary root (position == 0)
        if ($primaryRootMap.ContainsKey($cl)) {
            return $codexProjects[$primaryRootMap[$cl]]
        }
        foreach ($rk in ($primaryRootMap.Keys | Sort-Object Length -Descending)) {
            if ($cl.StartsWith($rk + "\")) {
                return $codexProjects[$primaryRootMap[$rk]]
            }
        }
        # 2. Fallback to secondary roots (position > 0, longest prefix within same position)
        foreach ($sr in ($secondaryRootList | Sort-Object @{Expression={$_.Position}; Ascending=$true}, @{Expression={$_.PathLower.Length}; Descending=$true})) {
            if ($cl -eq $sr.PathLower -or $cl.StartsWith($sr.PathLower + "\")) {
                return $codexProjects[$sr.CodexProjectId]
            }
        }
        return $null
    }

    function Test-SkipCodexThread([string]$id, $metaRow, [string]$agentRole, [string]$sourceKind) {
        if (-not [string]::IsNullOrWhiteSpace($ThreadId) -and ($id -ine $ThreadId.Trim())) { return "filter" }
        if (-not $IncludeGuardian) {
            $titles = @()
            if ($indexTitles.ContainsKey($id)) { $titles += $indexTitles[$id] }
            if ($metaRow) {
                if ($metaRow.ContainsKey("name") -and $metaRow["name"]) { $titles += [string]$metaRow["name"] }
                if ($metaRow.ContainsKey("title") -and $metaRow["title"]) { $titles += [string]$metaRow["title"] }
                if (-not $agentRole -and $metaRow.ContainsKey("agent_role") -and $metaRow["agent_role"]) { $agentRole = [string]$metaRow["agent_role"] }
                if (-not $sourceKind -and $metaRow.ContainsKey("source") -and $metaRow["source"]) { $sourceKind = [string]$metaRow["source"] }
            }
            foreach ($t in $titles) { if ($t -and $t.Trim() -ieq "Guardian review") { return "guardian" } }
            if (($agentRole -and $agentRole -imatch "guardian") -or ($sourceKind -and $sourceKind -imatch "guardian")) { return "guardian" }
        }
        if (-not $IncludeSubagents) {
            $hasName = ($metaRow -and $metaRow.ContainsKey("name") -and -not [string]::IsNullOrWhiteSpace([string]$metaRow["name"]))
            $hasIdx = ($indexTitles.ContainsKey($id) -and -not [string]::IsNullOrWhiteSpace($indexTitles[$id]))
            if (-not $hasName -and -not $hasIdx) {
                if ($spawnedChildIds.Contains($id)) { return "subagent" }
                if ($sourceKind -and $sourceKind -imatch "subagent") { return "subagent" }
                if ($metaRow -and $metaRow.ContainsKey("attached_thread_parent_id") -and $metaRow["attached_thread_parent_id"]) { return "subagent" }
            }
        }
        return $null
    }

    function Resolve-ThreadMeta([string]$id, [string]$fallbackCwd, [bool]$fallbackArch) {
        $sm = if ($sqliteMeta.ContainsKey($id)) { $sqliteMeta[$id] } else { $null }
        $rawTitle = ""
        $cwd = $fallbackCwd
        $arch = $fallbackArch
        $explicitProj = ""
        $cAt = [DateTimeOffset]::MinValue
        $uAt = [DateTimeOffset]::MinValue

        if ($sm) {
            if ($sm.ContainsKey("name") -and -not [string]::IsNullOrWhiteSpace([string]$sm["name"])) { $rawTitle = [string]$sm["name"] }
            if ($sm.ContainsKey("cwd") -and -not [string]::IsNullOrWhiteSpace([string]$sm["cwd"])) { $cwd = [string]$sm["cwd"] }
            if ($sm.ContainsKey("project_id") -and $sm["project_id"]) { $explicitProj = [string]$sm["project_id"] }
            if ($sm.ContainsKey("archived") -and $sm["archived"] -ne $null -and [Convert]::ToInt64($sm["archived"]) -ne 0) { $arch = $true }
            if ($sm.ContainsKey("created_at") -and $sm["created_at"] -ne $null) { $cAt = [CodexToAgyV2.SessionConverter]::ParseTimestamp([string]$sm["created_at"], $cAt) }
            if ($sm.ContainsKey("updated_at") -and $sm["updated_at"] -ne $null) { $uAt = [CodexToAgyV2.SessionConverter]::ParseTimestamp([string]$sm["updated_at"], $uAt) }
        }
        if ($customThreadTitles.ContainsKey($id) -and -not [string]::IsNullOrWhiteSpace($customThreadTitles[$id])) {
            $rawTitle = $customThreadTitles[$id]
        } else {
            if ([string]::IsNullOrWhiteSpace($rawTitle) -and $indexTitles.ContainsKey($id)) { $rawTitle = $indexTitles[$id] }
            if ([string]::IsNullOrWhiteSpace($rawTitle) -and $sm -and $sm.ContainsKey("title") -and $sm["title"]) { $rawTitle = [string]$sm["title"] }
        }
        if ($uAt -eq [DateTimeOffset]::MinValue -and $indexUpdated.ContainsKey($id)) {
            $uAt = [CodexToAgyV2.SessionConverter]::ParseTimestamp($indexUpdated[$id], $uAt)
        }
        $proj = Resolve-SessionProject $explicitProj $cwd
        return @{
            Title = $rawTitle
            Cwd = $cwd
            Archived = $arch
            CreatedAt = $cAt
            UpdatedAt = $uAt
            Project = $proj
        }
    }

    $byId = @{}

    # Map Codex segmented rollout filenames (<root_uuid>_<segment_uuid>.jsonl[.zst]) back to root_uuid
    $segmentToRoot = @{}
    $rxPair = [Regex]"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})_([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"
    foreach ($sub in @("sessions", "archived_sessions")) {
        $p = Join-Path $CodexDir $sub
        if (Test-Path $p) {
            foreach ($rf in (Get-ChildItem -Path $p -Filter "*_*" -Recurse -File -ErrorAction SilentlyContinue)) {
                $mp = $rxPair.Match($rf.Name)
                if ($mp.Success) {
                    $rootU = $mp.Groups[1].Value.ToLowerInvariant()
                    $segU  = $mp.Groups[2].Value.ToLowerInvariant()
                    if ($segU -ne $rootU) { $segmentToRoot[$segU] = $rootU }
                }
            }
        }
    }
    foreach ($segKey in @($segmentToRoot.Keys)) {
        $cur = $segmentToRoot[$segKey]
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        [void]$seen.Add($segKey)
        while ($segmentToRoot.ContainsKey($cur) -and -not $seen.Contains($cur)) {
            [void]$seen.Add($cur)
            $cur = $segmentToRoot[$cur]
        }
        $segmentToRoot[$segKey] = $cur
    }

    # A. Scan .jsonl files in sessions & archived_sessions, grouping multi-segment rollouts
    $jsonlFiles = @()
    foreach ($sub in @("sessions", "archived_sessions")) {
        $p = Join-Path $CodexDir $sub
        if (Test-Path $p) { $jsonlFiles += Get-ChildItem -Path $p -Filter "*.jsonl" -Recurse -File -ErrorAction SilentlyContinue }
    }
    $jsonlSegments = @{}
    foreach ($f in $jsonlFiles) {
        $fid = $null; $fcwd = $null; $frole = $null; $fsrc = $null; $ford = [long]0
        $evts = [CodexToAgyV2.SessionConverter]::ParseJsonlEvents($f.FullName, $ser, [ref]$fid, [ref]$fcwd, [ref]$frole, [ref]$fsrc, [ref]$ford)
        $rawFid = if ([string]::IsNullOrEmpty($fid)) { [System.IO.Path]::GetFileNameWithoutExtension($f.Name).ToLowerInvariant() } else { $fid }
        $rootFid = if ($segmentToRoot.ContainsKey($rawFid)) { $segmentToRoot[$rawFid] } else { $rawFid }
        if (-not $jsonlSegments.ContainsKey($rootFid)) { $jsonlSegments[$rootFid] = @() }
        $jsonlSegments[$rootFid] += [PSCustomObject]@{
            FirstOrdinal = $ford
            FileName     = $f.Name
            Events       = $evts
            Cwd          = $fcwd
            Role         = $frole
            Source       = $fsrc
            IsArch       = ($f.FullName -imatch "archived_sessions")
        }
    }

    foreach ($fid in $jsonlSegments.Keys) {
        $segs = $jsonlSegments[$fid] | Sort-Object FirstOrdinal, FileName
        $mergedEvts = New-Object 'System.Collections.Generic.List[CodexToAgyV2.RawTurnEvent]'
        $fcwdMerged = $null; $froleMerged = $null; $fsrcMerged = $null; $archMerged = $true
        foreach ($sg in $segs) {
            foreach ($e in $sg.Events) { $mergedEvts.Add($e) }
            if (-not [string]::IsNullOrEmpty($sg.Cwd)) { $fcwdMerged = $sg.Cwd }
            if ([string]::IsNullOrEmpty($froleMerged) -and $sg.Role) { $froleMerged = $sg.Role }
            if ([string]::IsNullOrEmpty($fsrcMerged) -and $sg.Source) { $fsrcMerged = $sg.Source }
            if (-not $sg.IsArch) { $archMerged = $false }
        }

        $sm = if ($sqliteMeta.ContainsKey($fid)) { $sqliteMeta[$fid] } else { $null }
        $skip = Test-SkipCodexThread $fid $sm $froleMerged $fsrcMerged
        if ($skip -eq "guardian") { $skippedGuardian++; continue }
        if ($skip -eq "subagent") { $skippedSubagent++; continue }
        if ($skip -ne $null) { continue }

        $m = Resolve-ThreadMeta $fid $fcwdMerged $archMerged
        $agyProjId = if ($m.Project) { $m.Project.AgyProjectId } else { "outside-of-project" }
        $pName = if ($m.Project) { $m.Project.Name } else { "" }
        $pUri = if ($m.Project) { $m.Project.FolderUri } else { "" }
        $conv = [CodexToAgyV2.SessionConverter]::BuildConvertedSession($fid, $m.Title, $TitlePrefix, $m.Cwd, $m.Archived, $agyProjId, $pName, $pUri, $m.CreatedAt, $m.UpdatedAt, $mergedEvts)
        if ($conv -eq $null) { $skippedEmpty++; continue }
        $byId[$fid] = $conv
    }

    # B. Scan thread_history_*.sqlite (merging segmented rollout IDs)
    $histDbPath = Find-LatestVersionedSqlite $CodexDir "thread_history"
    if ($histDbPath -and (Test-Path -LiteralPath $histDbPath)) {
        $hdb = New-Object CodexToAgyV2.WinSqlite($histDbPath, $true)
        try {
            $rootToRawIds = @{}
            foreach ($k in $sqliteMeta.Keys) {
                $rawVal = if ($sqliteMeta[$k].ContainsKey("id") -and $sqliteMeta[$k]["id"]) { [string]$sqliteMeta[$k]["id"] } else { $k }
                $rTid = if ($segmentToRoot.ContainsKey($k)) { $segmentToRoot[$k] } else { $k }
                if (-not $rootToRawIds.ContainsKey($rTid)) { $rootToRawIds[$rTid] = New-Object 'System.Collections.Generic.List[string]' }
                if (-not $rootToRawIds[$rTid].Contains($rawVal)) { $rootToRawIds[$rTid].Add($rawVal) }
            }
            foreach ($tr in $hdb.Query("SELECT DISTINCT thread_id FROM thread_turns", $false)) {
                if ($tr.ContainsKey("thread_id") -and $tr["thread_id"]) {
                    $rawVal = [string]$tr["thread_id"]
                    $lowVal = $rawVal.ToLowerInvariant()
                    $rTid = if ($segmentToRoot.ContainsKey($lowVal)) { $segmentToRoot[$lowVal] } else { $lowVal }
                    if (-not $rootToRawIds.ContainsKey($rTid)) { $rootToRawIds[$rTid] = New-Object 'System.Collections.Generic.List[string]' }
                    if (-not $rootToRawIds[$rTid].Contains($rawVal)) { $rootToRawIds[$rTid].Add($rawVal) }
                }
            }

            $targets = New-Object 'System.Collections.Generic.List[string]'
            foreach ($cid in $rootToRawIds.Keys) {
                $sm = if ($sqliteMeta.ContainsKey($cid)) { $sqliteMeta[$cid] } else { $null }
                $skip = Test-SkipCodexThread $cid $sm $null $null
                if (-not $byId.ContainsKey($cid)) {
                    if ($skip -eq "guardian") { $skippedGuardian++; continue }
                    if ($skip -eq "subagent") { $skippedSubagent++; continue }
                    if ($skip -ne $null) { continue }
                } else {
                    if ($skip -ne $null) { continue }
                }
                $targets.Add($cid)
            }

            $batchSize = 40
            for ($bi = 0; $bi -lt $targets.Count; $bi += $batchSize) {
                $endIdx = [Math]::Min($bi + $batchSize - 1, $targets.Count - 1)
                $quoted = @()
                $rawToRoot = @{}
                for ($j = $bi; $j -le $endIdx; $j++) {
                    $rTid = $targets[$j]
                    foreach ($rv in $rootToRawIds[$rTid]) {
                        $quoted += "'" + ($rv -replace "'", "''") + "'"
                        $rawToRoot[$rv.ToLowerInvariant()] = $rTid
                    }
                }
                $sql = "SELECT thread_id, rollout_ordinal, created_at_ms, item_type, item_json FROM thread_items WHERE thread_id IN (" + ($quoted -join ",") + ")"
                $rows = $hdb.Query($sql, $false)

                $groupedRaw = @{}
                foreach ($r in $rows) {
                    $lowTid = ([string]$r["thread_id"]).ToLowerInvariant()
                    $rTid = if ($rawToRoot.ContainsKey($lowTid)) { $rawToRoot[$lowTid] } else { $lowTid }
                    $ordVal = if ($r.ContainsKey("rollout_ordinal") -and $r["rollout_ordinal"] -ne $null) { [Convert]::ToInt64($r["rollout_ordinal"]) } else { [long]0 }
                    $cmsVal = if ($r.ContainsKey("created_at_ms") -and $r["created_at_ms"] -ne $null) { [Convert]::ToInt64($r["created_at_ms"]) } else { [long]0 }
                    $ts = [CodexToAgyV2.SessionConverter]::ParseTimestamp([string]$r["created_at_ms"], [DateTimeOffset]::UtcNow)
                    $ev = [CodexToAgyV2.SessionConverter]::ParseSqliteItem([string]$r["item_type"], [string]$r["item_json"], $ts, $ser)
                    if ($ev -ne $null) {
                        if (-not $groupedRaw.ContainsKey($rTid)) { $groupedRaw[$rTid] = @() }
                        $groupedRaw[$rTid] += [PSCustomObject]@{ Ord = $ordVal; Cms = $cmsVal; Ev = $ev }
                    }
                }

                for ($j = $bi; $j -le $endIdx; $j++) {
                    $tid = $targets[$j]
                    if (-not $groupedRaw.ContainsKey($tid)) {
                        if (-not $byId.ContainsKey($tid)) { $skippedEmpty++ }
                        continue
                    }
                    $sortedEvts = New-Object 'System.Collections.Generic.List[CodexToAgyV2.RawTurnEvent]'
                    foreach ($it in ($groupedRaw[$tid] | Sort-Object Ord, Cms)) { $sortedEvts.Add($it.Ev) }

                    $m = Resolve-ThreadMeta $tid "" $false
                    $agyProjId = if ($m.Project) { $m.Project.AgyProjectId } else { "outside-of-project" }
                    $pName = if ($m.Project) { $m.Project.Name } else { "" }
                    $pUri = if ($m.Project) { $m.Project.FolderUri } else { "" }
                    $conv = [CodexToAgyV2.SessionConverter]::BuildConvertedSession($tid, $m.Title, $TitlePrefix, $m.Cwd, $m.Archived, $agyProjId, $pName, $pUri, $m.CreatedAt, $m.UpdatedAt, $sortedEvts)
                    if ($conv -eq $null) {
                        if (-not $byId.ContainsKey($tid)) { $skippedEmpty++ }
                        continue
                    }
                    if (-not $byId.ContainsKey($tid) -or $conv.Steps.Count -gt $byId[$tid].Steps.Count) {
                        $byId[$tid] = $conv
                    }
                }
            }
        } finally { $hdb.Dispose() }
    }

    foreach ($v in ($byId.Values | Sort-Object UpdatedAt -Descending)) {
        $convertedSessions.Add($v)
        foreach ($pm in $codexProjects.Values) {
            if ($pm.AgyProjectId -eq $v.AgyProjectId) { $pm.SessionCount++ }
        }
    }
}

# Stage Antigravity Project JSON files (only projects that have >= 1 session)
$stagedProjectFiles = @()
foreach ($pm in $codexProjects.Values) {
    if ($pm.SessionCount -le 0) { continue }
    $projRes = [ordered]@{}
    if ($pm.FolderExists -and -not [string]::IsNullOrEmpty($pm.FolderUri)) {
        $projRes["resources"] = @(
            [ordered]@{
                gitFolder = [ordered]@{
                    folderUri  = $pm.FolderUri
                    allowWrite = $true
                }
            }
        )
    }
    $projDoc = [ordered]@{
        id               = $pm.AgyProjectId
        name             = $pm.Name
        projectResources = $projRes
        permissionGrants = [ordered]@{
            permissionGrants = [ordered]@{}
            v2Migrated       = $true
        }
        settings         = [ordered]@{
            artifactReviewMode = "ARTIFACT_REVIEW_MODE_TURBO"
        }
    }
    $projOutPath = Join-Path (Join-Path $OutputDir "projects") ($pm.AgyProjectId + ".json")
    [System.IO.File]::WriteAllText($projOutPath, ($projDoc | ConvertTo-Json -Depth 8), $utf8NoBom)
    $stagedProjectFiles += $projOutPath
}

# Write staged Antigravity conversation DBs, annotations, transcripts, and summaries DB
$stagingSumDb = Join-Path $OutputDir "conversation_summaries.db"
if (Test-Path $stagingSumDb) { Remove-Item $stagingSumDb -Force }

$manifest = @()
foreach ($conv in $convertedSessions) {
    [CodexToAgyV2.SessionConverter]::WriteAntigravityConversationFiles($conv, $OutputDir, $ser)
    $manifest += [ordered]@{
        codex_thread_id     = $conv.CodexThreadId
        agy_conversation_id = $conv.AgyConversationId
        agy_trajectory_id   = $conv.AgyTrajectoryId
        agy_project_id      = $conv.AgyProjectId
        agy_project_name    = $conv.AgyProjectName
        title               = $conv.Title
        cwd                 = $conv.Cwd
        workspace_uri       = $conv.WorkspaceUri
        step_count          = $conv.Steps.Count
        user_turns          = $conv.UserTurns
        assistant_turns     = $conv.AssistantTurns
        created_at          = $conv.CreatedAt.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")
        updated_at          = $conv.UpdatedAt.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")
    }
}

[CodexToAgyV2.SessionConverter]::UpsertSummariesDb($stagingSumDb, $convertedSessions)
[System.IO.File]::WriteAllText((Join-Path $OutputDir "mapping.json"), ($manifest | ConvertTo-Json -Depth 6), $utf8NoBom)

Write-Host ("[Stage] Converted {0} sessions & {1} projects -> {2} (Skipped Guardian={3}, Subagent={4}, Empty={5})" -f `
    $convertedSessions.Count, $stagedProjectFiles.Count, $OutputDir, $skippedGuardian, $skippedSubagent, $skippedEmpty)

if ($Verify -or $Install) {
    $vCount = [CodexToAgyV2.SessionConverter]::VerifyOutputDir($OutputDir)
    Write-Host ("[Verify] Validated Protobuf wire format, SQLite user_version=1, annotations, and project JSONs for {0} sessions." -f $vCount)
}

if ($Install) {
    if (-not $Force) {
        $running = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -imatch "antigravity" }
        if ($running) {
            throw "Detected running Antigravity process(es). Please close Antigravity completely before running with -Install (or pass -Force to override)."
        }
    }

    $tsTag = Get-Date -Format "yyyyMMdd-HHmmss"
    $targetConvDir = Join-Path $AntigravityDir "conversations"
    $targetAnnDir = Join-Path $AntigravityDir "annotations"
    $targetBrainDir = Join-Path $AntigravityDir "brain"
    $targetSumDb = Join-Path $AntigravityDir "conversation_summaries.db"
    $targetHubPb = Join-Path $AntigravityDir "agyhub_summaries_proto.pb"
    $targetProjectsDir = Join-Path $GeminiConfigDir "projects"

    [void][System.IO.Directory]::CreateDirectory($targetConvDir)
    [void][System.IO.Directory]::CreateDirectory($targetAnnDir)
    [void][System.IO.Directory]::CreateDirectory($targetBrainDir)
    [void][System.IO.Directory]::CreateDirectory($targetProjectsDir)

    if (Test-Path $targetSumDb) {
        $bakPath = "$targetSumDb.bak.$tsTag"
        Copy-Item -Path $targetSumDb -Destination $bakPath -Force
        Write-Host ("[Backup] Backed up conversation_summaries.db -> {0}" -f $bakPath)
    }
    if (Test-Path $targetHubPb) {
        $bakPb = "$targetHubPb.bak.$tsTag"
        Move-Item -Path $targetHubPb -Destination $bakPb -Force
        Write-Host ("[Cache] Cleared stale agyhub_summaries_proto.pb (backed up -> {0})" -f $bakPb)
    }

    foreach ($pf in $stagedProjectFiles) {
        $dstProj = Join-Path $targetProjectsDir ([System.IO.Path]::GetFileName($pf))
        if (Test-Path -LiteralPath $dstProj) {
            $pfStem = [System.IO.Path]::GetFileNameWithoutExtension($pf)
            $explicitRename = $false
            foreach ($cpid in $codexProjects.Keys) {
                if ($codexProjects[$cpid].AgyProjectId -ieq $pfStem -and $customProjectNames.ContainsKey($cpid)) {
                    $explicitRename = $true
                    break
                }
            }
            if (-not $explicitRename) { continue }
        }
        Copy-Item -Path $pf -Destination $dstProj -Force
    }

    foreach ($conv in $convertedSessions) {
        $cid = $conv.AgyConversationId
        foreach ($walExt in @("", "-wal", "-shm")) {
            $oldWal = Join-Path $targetConvDir ($cid + ".db" + $walExt)
            if ($walExt -ne "" -and (Test-Path $oldWal)) { Remove-Item $oldWal -Force }
        }
        Copy-Item -Path (Join-Path (Join-Path $OutputDir "conversations") ($cid + ".db")) -Destination (Join-Path $targetConvDir ($cid + ".db")) -Force
        Copy-Item -Path (Join-Path (Join-Path $OutputDir "annotations") ($cid + ".pbtxt")) -Destination (Join-Path $targetAnnDir ($cid + ".pbtxt")) -Force

        $srcLogs = Join-Path $OutputDir ("brain\" + $cid + "\.system_generated\logs")
        $dstLogs = Join-Path $targetBrainDir ($cid + "\.system_generated\logs")
        [void][System.IO.Directory]::CreateDirectory($dstLogs)
        Copy-Item -Path (Join-Path $srcLogs "transcript.jsonl") -Destination (Join-Path $dstLogs "transcript.jsonl") -Force
        Copy-Item -Path (Join-Path $srcLogs "transcript_full.jsonl") -Destination (Join-Path $dstLogs "transcript_full.jsonl") -Force
    }

    [CodexToAgyV2.SessionConverter]::UpsertSummariesDb($targetSumDb, $convertedSessions)
    Write-Host ("[Install] Imported {0} sessions & {1} projects! Open Antigravity to view them under Projects." -f $convertedSessions.Count, $stagedProjectFiles.Count)
}
