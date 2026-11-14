---
name: import-codex-sessions
description: >-
  Imports local OpenAI Codex (~/.codex) and Qoder (~/.qoder) conversation history and project groupings into Google Antigravity's native Projects and Conversations sidebar on macOS, Windows, and Linux (automatically merging Codex threads that were continued in Qoder). Use this skill whenever the user asks to import, migrate, convert, or bring over their Codex or Qoder sessions, chat history, rollouts, or projects into Antigravity (例如：导入 Codex/Qoder 会话、迁移本机 Codex 与 Qoder 历史记录与项目分组).
---

# Import Local Codex & Qoder Sessions into Antigravity

Convert and import local OpenAI Codex (`~/.codex` or `$CODEX_HOME`) and Qoder (`~/.qoder` or `$QODER_HOME`) threads and project groupings into Google Antigravity's native 5-layer session format on **macOS**, **Windows**, and **Linux** with zero third-party dependencies.

- **`--source auto` (default)**: Imports both Codex and Qoder when present, **automatically merging** sessions that started in Codex and continued in Qoder (UUIDv5 -> UUIDv4 active-leaf chain) into a single complete timeline while skipping zero-delta duplicate snapshots. Pass `--source codex` or `--source qoder` (`-Source codex|qoder`) to restrict to one source.

For low-level SQLite DDL, Protobuf wire tags, and URI normalization details, read [format-spec.md](./references/format-spec.md).

---

## Bundled Converter Scripts

Resolve paths relative to this `SKILL.md` directory:

- **macOS & Linux**: [codex2agy.sh](./scripts/codex2agy.sh) (wraps [codex2agy.py](./scripts/codex2agy.py), pure Python 3.8+ stdlib `sqlite3`, zero `pip` packages)
- **Windows**: [codex2agy.ps1](./scripts/codex2agy.ps1) (native PowerShell + Windows built-in `winsqlite3.dll`, works even when Python is not installed; [codex2agy.py](./scripts/codex2agy.py) also works on Windows if Python 3 is installed)

---

## Step-by-Step Workflow

> **Important Guardrail**: Never run `--install` / `-Install` or mutate `~/.gemini/antigravity/conversation_summaries.db` directly while Antigravity is running — the live daemon holds open SQLite WAL connections and in-memory summary caches. Always stage and verify into a temporary directory first, curate titles with the user, and give the user the one-line offline install command to run after closing Antigravity.

### Step 1: Stage & Verify (Read-Only Discovery)

Choose a temporary staging folder (such as `<artifact-dir>/scratch/codex-stage` or `/tmp/codex-stage`) and run the converter in **stage + verify** mode without `--install`:

**macOS / Linux:**
```bash
sh "<skill-dir>/scripts/codex2agy.sh" --output-dir "/tmp/codex-stage" --verify
```

**Windows (PowerShell):**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\codex2agy.ps1" -OutputDir "$env:TEMP\codex-stage" -Verify
```

- If the sandbox blocks reading `~/.codex`, explain why read access to `~/.codex` is needed and request permission (do not modify any file inside `~/.codex`).
- By default, internal `Guardian review` approval sub-sessions and spawned subagent child threads are automatically filtered out. Pass `--include-guardian` / `-IncludeGuardian` or `--include-subagents` / `-IncludeSubagents` only if the user explicitly asks for them.

### Step 2: Inspect `mapping.json` & Curate Titles (`rename-config.json`)

Read `<stage-dir>/mapping.json` and check every entry's `agy_project_name` and `title`:

1. **Detect raw or placeholder titles**:
   - Threads in Codex without a custom `threads.name` fall back to the raw first user message (often long sentences, pasted markdown headers, or placeholders like `project f`).
   - Proactively draft concise, descriptive titles (in the user's language, 6–18 words/characters) for any untitled, truncated, or placeholder threads.
2. **Write `<stage-dir>/rename-config.json`** (UTF-8):
   ```json
   {
     "project_names": {
       "<codex-project-uuid>": "Clean Project Name"
     },
     "thread_titles": {
       "<codex-thread-uuid>": "Concise Session Title"
     },
     "thread_projects": {
       "<codex-thread-uuid>": "<optional-codex-project-uuid-or-name>"
     }
   }
   ```
3. **Re-run Stage & Verify with `--rename-config` / `-RenameConfig`** so the staged `.pbtxt` annotations, SQLite DBs, and `mapping.json` reflect the curated names:
   - **macOS / Linux**:
     ```bash
     sh "<skill-dir>/scripts/codex2agy.sh" --output-dir "/tmp/codex-stage" --rename-config "/tmp/codex-stage/rename-config.json" --verify
     ```
   - **Windows**:
     ```powershell
     powershell -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\codex2agy.ps1" -OutputDir "$env:TEMP\codex-stage" -RenameConfig "$env:TEMP\codex-stage\rename-config.json" -Verify
     ```

### Step 3: Present Summary & Offline Install Command

Show the user a concise table grouped by **Antigravity Project** (`Projects -> <agy_project_name>`, or top-level `Conversations` for ungrouped sessions) listing the curated session titles, and let them know they can ask to rename any project or session before installing.

Provide the exact copy-pasteable install command for their OS:

**macOS / Linux (quit Antigravity with `Cmd+Q` first, then run in Terminal):**
```bash
sh "<skill-dir>/scripts/codex2agy.sh" --output-dir "/tmp/codex-stage" --rename-config "/tmp/codex-stage/rename-config.json" --install
```

**Windows (exit Antigravity completely first, then run in PowerShell):**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\codex2agy.ps1" -OutputDir "$env:TEMP\codex-stage" -RenameConfig "$env:TEMP\codex-stage\rename-config.json" -Install
```

Explain what `--install` / `-Install` does automatically:
- Backs up `~/.gemini/antigravity/conversation_summaries.db` to `conversation_summaries.db.bak.<timestamp>` and clears stale `agyhub_summaries_proto.pb` (also backed up).
- Registers project configs in `~/.gemini/config/projects/<project_id>.json` (reusing existing project UUIDs when matching `folderUri`s already exist, and omitting `projectResources` for deleted folders so Antigravity never shows `"folder doesn't exist"`).
- Installs `conversations/<id>.db` (`PRAGMA user_version=1`), `annotations/<id>.pbtxt` (persistent title), and `brain/<id>/.system_generated/logs/transcript*.jsonl`.
- Deterministic UUIDv4 mapping ensures re-running `--install` updates titles and project bindings idempotently without creating duplicates.
