# Codex Session Importer (`codex-session-importer`)

An Antigravity **Plugin & Skill** that imports your local OpenAI Codex (`~/.codex`) conversation history and project groupings into Google Antigravity's native **Projects** and **Conversations** sidebar.

- **Cross-Platform**: Works natively on **macOS**, **Windows**, and **Linux**.
- **Zero Third-Party Dependencies**:
  - **macOS & Linux**: Pure Python 3.8+ standard library (`sqlite3`, zero `pip install` needed) via `codex2agy.sh` / `codex2agy.py`.
  - **Windows**: Native PowerShell + built-in `winsqlite3.dll` via `codex2agy.ps1` (works out-of-the-box on fresh Windows 10/11 machines even without Python installed).
- **Full 5-Layer Native Conversion**:
  1. Migrates Codex **Projects** (`projects` & `project_roots`) into `~/.gemini/config/projects/<uuid>.json` (reusing existing Antigravity project UUIDs to avoid duplicates).
  2. Preserves & cleans **Session Titles** via `~/.gemini/antigravity/annotations/<uuid>.pbtxt` so titles never get overwritten on sync.
  3. Encodes full multi-turn conversations, reasoning summaries, and tool call traces into `conversations/<uuid>.db` (`CortexStep` Protobuf + `PRAGMA user_version=1`).
  4. Indexes sessions in `conversation_summaries.db` (`CascadeRunSummary` Protobuf).
  5. Generates `brain/<uuid>/.system_generated/logs/transcript*.jsonl` for `@` conversation mentions.
- **Noise-Free & Idempotent**: Automatically skips internal `Guardian review` approval sub-sessions and spawned subagent child threads; deterministic UUIDv4 mapping means re-running updates titles/projects in place without duplicates.

---

## Installation (For Users)

### Option 1: Install as an Antigravity Plugin via CLI (Recommended)

```bash
# Install directly from GitHub
agy plugin install https://github.com/Lokilankaaa/codex-session-importer

# Or install from a local clone
agy plugin install ./codex-session-importer
```

### Option 2: Manual Plugin Drop-In (macOS / Linux / Windows)

Copy or clone this repository into your global Antigravity plugins folder:

- **macOS / Linux**: `~/.gemini/config/plugins/codex-session-importer`
- **Windows**: `C:\Users\<You>\.gemini\config\plugins\codex-session-importer`

### Option 3: Standalone Skill Only

If you only want the standalone skill without a plugin wrapper, copy `skills/import-codex-sessions` into:
- Global skills: `~/.gemini/config/skills/import-codex-sessions`
- Or workspace skills: `<your-repo>/.agents/skills/import-codex-sessions`

---

## Usage Inside Antigravity

Once installed, simply ask Antigravity in chat:

- *"导入我本机的 Codex 会话和项目分组"*
- *"Import my local Codex sessions into Antigravity"*

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

## Publishing Guide (For Maintainers)

1. **Validate Plugin Manifest & Structure** (if `agy` CLI is installed):
   ```bash
   agy plugin validate --strict .
   ```
2. **Publish to GitHub**:
   ```bash
   git init -b main
   git add .
   git commit -m "feat: initial release of codex-session-importer plugin & skill"
   git remote add origin https://github.com/Lokilankaaa/codex-session-importer.git
   git push -u origin main
   ```
   Anyone can then install it immediately with:
   ```bash
   agy plugin install https://github.com/Lokilankaaa/codex-session-importer
   ```

---

## License

MIT
