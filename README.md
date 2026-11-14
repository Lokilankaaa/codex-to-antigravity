# Codex to Antigravity (`codex-to-antigravity`)

Migrate your local **OpenAI Codex (`~/.codex`)** and **Qoder (`~/.qoder`)** conversation history and project groupings into **Google Antigravity**'s native **Projects** and **Conversations** sidebar — packaged as a cross-platform Antigravity **Plugin & Skill** plus standalone CLI scripts.

- **Cross-Platform**: Verified on **macOS**, **Windows**, and **Linux**.
- **Codex + Qoder Smart Continuation Merge (`--source auto|codex|qoder|both`)**:
  - Converts both `~/.codex` threads and `~/.qoder/projects/<slug>/*.jsonl` active-leaf session trees.
  - When a session started in Codex and was later continued in Qoder, automatically merges the Codex history (UUIDv5) with Qoder's new turns (UUIDv4, plaintext compaction summaries, thinking, and tool calls) into a **single unified conversation**, while deduplicating zero-delta migrated snapshots.
- **Zero Third-Party Dependencies**:
  - **macOS & Linux**: Pure Python 3.8+ standard library (`sqlite3`, zero `pip install` needed) via `codex2agy.sh` / `codex2agy.py`.
  - **Windows**: Native PowerShell + built-in `winsqlite3.dll` via `codex2agy.ps1` (works out-of-the-box on fresh Windows 10/11 machines even without Python installed).
- **Full 5-Layer Native Conversion**:
  1. Migrates Codex **Projects** (`projects` & `project_roots`) into `~/.gemini/config/projects/<uuid>.json` (reusing existing Antigravity project UUIDs for both Git and plain folders without overwriting existing project configs).
  2. Preserves & locks **Session Titles** via `~/.gemini/antigravity/annotations/<uuid>.pbtxt` so titles never get overwritten on sync.
  3. Encodes full multi-turn conversations, segmented long rollouts (`<root_uuid>_<segment_uuid>`), reasoning summaries, and tool call traces into `conversations/<uuid>.db` (`CortexStep` Protobuf + `PRAGMA user_version=1`).
  4. Indexes sessions in `conversation_summaries.db` (`CascadeRunSummary` Protobuf + JSON array `workspace_uris`).
  5. Generates `brain/<uuid>/.system_generated/logs/transcript*.jsonl` for `@` conversation mentions.
- **Noise-Free & Idempotent**: Automatically merges paginated/segmented long threads, skips internal `Guardian review` approval sub-sessions and spawned subagent child threads, and uses deterministic UUIDv4 mapping so re-running updates titles/projects in place without duplicates.

---

## Installation (For Users)

### Option 1: Install as an Antigravity Plugin via CLI

```bash
# Install directly from GitHub
agy plugin install https://github.com/Lokilankaaa/codex-to-antigravity

# Or install from a local clone
agy plugin install ./codex-to-antigravity
```

### Option 2: Manual Plugin Drop-In (macOS / Linux / Windows)

Clone or copy this repository into your global Antigravity plugins folder:

- **macOS / Linux**: `~/.gemini/config/plugins/codex-to-antigravity`
- **Windows**: `C:\Users\<You>\.gemini\config\plugins\codex-to-antigravity`

### Option 3: Standalone Skill Only

If you only want the standalone skill without a plugin wrapper, copy `skills/import-codex-sessions` into:
- Global skills: `~/.gemini/config/skills/import-codex-sessions`
- Or workspace skills: `<your-repo>/.agents/skills/import-codex-sessions`

---

## Usage Inside Antigravity

Once installed, simply ask Antigravity in chat:

- *"迁移我本机的 Codex 会话和项目分组到 Antigravity"*
- *"Migrate my local Codex sessions into Antigravity"*

The agent will automatically:
1. Stage & verify your `~/.codex` threads and projects in a temporary folder,
2. Clean up any untitled/placeholder session names via `rename-config.json` and show you a preview table grouped by Project,
3. Give you a single copy-pasteable `--install` / `-Install` command to run right after quitting Antigravity (with automatic backups).

---

## Direct CLI Usage (Without Agent)

### macOS & Linux

```bash
# 1. Stage & verify into ./dist-agy
sh ./skills/import-codex-sessions/scripts/codex2agy.sh --verify

# 2. Quit Antigravity (Cmd+Q), then install
sh ./skills/import-codex-sessions/scripts/codex2agy.sh --install
```

### Windows (PowerShell)

```powershell
# 1. Stage & verify into .\dist-agy
powershell -NoProfile -ExecutionPolicy Bypass -File .\skills\import-codex-sessions\scripts\codex2agy.ps1 -Verify

# 2. Exit Antigravity completely, then install
powershell -NoProfile -ExecutionPolicy Bypass -File .\skills\import-codex-sessions\scripts\codex2agy.ps1 -Install
```

---

## License

MIT
