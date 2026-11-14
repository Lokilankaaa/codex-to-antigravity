# Codex ↔ Antigravity Native Session & Project Format Specification

This reference documents the exact schema mapping implemented by `codex2agy.py` and `codex2agy.ps1`.

---

## 1. OpenAI Codex Source Storage (`~/.codex` or `$CODEX_HOME`)

| Source File | Role | Key Fields |
| :--- | :--- | :--- |
| `state_<N>.sqlite` | Metadata & Project index (highest `<N>` wins, e.g. `state_5.sqlite`) | `threads` (`id`, `cwd`, `name`, `title`, `archived`, `project_id`, `created_at`, `updated_at`, `agent_role`, `source`, `attached_thread_parent_id`), `projects` (`id`, `name`, `position`), `project_roots` (`project_id`, `position`, `path`), `thread_spawn_edges` (`parent_thread_id`, `child_thread_id`) |
| `thread_history_<N>.sqlite` | Migrated historical turns & items (Codex Desktop 26.x+) | `thread_turns`, `thread_items` (`thread_id`, `rollout_ordinal`, `created_at_ms`, `item_type`, `item_json`) |
| `sessions/YYYY/MM/DD/rollout-*.jsonl` & `archived_sessions/*.jsonl` | Active and archived JSONL rollouts | `session_meta`, `turn_context`, `response_item` (`message`, `reasoning`, `function_call`, `local_shell_call`), `event_msg` |
| `session_index.jsonl` | Lightweight thread title index | `id`, `thread_name`, `updated_at` |

### Project Resolution Order
1. Explicit override in `rename-config.json` (`thread_projects`).
2. `threads.project_id` in `state_<N>.sqlite` (when non-null).
3. Normalized `threads.cwd` (preferring `state_<N>.sqlite`'s latest `cwd` over initial rollout `.jsonl` `cwd`) matched against `project_roots` with **`position = 0` (primary root)** first, then secondary roots (`position > 0`).

---

## 2. Google Antigravity 5-Layer Target Storage

### Layer 1: Project Registry (`~/.gemini/config/projects/<project_id>.json`)
- **URI Encoding**:
  - **macOS / Linux**: `file:///Users/alice/code/my-app` (percent-encoded segments, preserving case).
  - **Windows**: `file:///c%3A/Users/alice/code/my-app` (lowercase drive letter + `%3A` + forward slashes — required to avoid Antigravity's Windows duplicate-project / missing-folder bug).
- **Missing Folders**: If the local directory no longer exists on disk, `projectResources` is written as `{}` so the project group still appears in the **Projects** sidebar without `"folder doesn't exist"` warnings.
- **UUID Reuse**: Existing `.json` files in `~/.gemini/config/projects/` are scanned first; if a matching `folderUri` already exists, its UUID is reused.

### Layer 2: Persistent Annotations (`~/.gemini/antigravity/annotations/<conversation_id>.pbtxt`)
- UTF-8 **without** BOM, serialized in Go `prototext` single-line format:
  ```protobuf
  title:"Session Title" last_user_view_time:{seconds:1792938477 nanos:1000000} permission_preset:AGENT_PERMISSION_PRESET_TURBO
  ```
- Without `title:"..."` in `annotations/<id>.pbtxt`, Antigravity clears `conversation_summaries.title` during Hub sync and falls back to line 1 of step 0.

### Layer 3: Trajectory Database (`~/.gemini/antigravity/conversations/<conversation_id>.db`)
- **Critical Pragma**: `PRAGMA user_version = 1;` (leaving `user_version = 0` triggers Antigravity's legacy `v0 -> v1` startup migration, which overwrites `trajectory_metadata_blob` with `0 bytes` and wipes `project_id`).
- `trajectory_meta`: `(trajectory_id, cascade_id, trajectory_type=4, source=1)`
- `trajectory_metadata_blob`: `id='main'`, `TrajectoryMetadata` Protobuf (`f2`=created Timestamp, `f3`=execution UUID, `f6`=conversation UUID, `f18`=`project_id` or `"outside-of-project"`).
- `steps`:
  - `USER_INPUT` (`step_type = 14`, `status = 3`, `step_format = 0`): `CortexStep` with `f5`=`metadata` (`source = 4`) and `f19`=`UserInput` (`f2`=text, `f3={f1: text}`).
  - `PLANNER_RESPONSE` (`step_type = 15`, `status = 3`, `step_format = 0`): `CortexStep` with `f5`=`metadata` (`source = 2`) and `f20`=`PlannerResponse` (`f1`=text, `f3`=folded reasoning & tool trace, `f8`=text, `f12`=2).

### Layer 4: Sidebar Summary Index (`~/.gemini/antigravity/conversation_summaries.db`)
- `PRAGMA user_version = 3;` on newly created DBs.
- `conversation_summaries` row + `raw_summary` (`CascadeRunSummary` Protobuf: `f1`=title, `f2`=step_count, `f3`=updatedAt, `f4`=trajectoryId, `f5`=1 (`IDLE`), `f7`=createdAt, `f10`=lastUserAt, `f15`=`{f1: title, f7: updatedAt, f19: 3}`, `f16`=lastUserStepIdx, `f17`=`TrajectoryMetadata`, `f22`=4, `f26`=1, `f28`=4).
- During `--install`, stale `~/.gemini/antigravity/agyhub_summaries_proto.pb` and any per-conversation `-wal` / `-shm` files are backed up/cleared so Antigravity rebuilds its Hub cache cleanly on launch.

### Layer 5: Agent Transcripts (`~/.gemini/antigravity/brain/<conversation_id>/.system_generated/logs/`)
- `transcript_full.jsonl` & `transcript.jsonl` (truncating `content` > 8,000 chars with `truncated_fields: ["content"]`), enabling cross-conversation `@` mentions and search.
