# Security model: todo-tui ("kanban")

This document describes what todo-tui protects, from whom, and where its trust boundaries are. Security scans start from it. The maintainer's decisions are recorded under **Maintainer decisions**; the rest describes the code as it is.

## System overview
A single-user, offline terminal kanban/todo app. Zig 0.17, one static binary (`kanban`), UI on libvaxis (`build.zig.zon`, pinned by commit + hash). Linux/macOS, plus Windows through a `HOME=%USERPROFILE%` launcher (README). It has no network code, no server, no IPC, no subprocesses and no authentication. The process runs with the invoking user's privileges.

## Components
| Name | Code | Notes |
| --- | --- | --- |
| **Persistence** | `src/storage.zig`, `src/notes.zig`, `src/worklog.zig`, `src/settings.zig` | Path resolution from env, parsers for KANBAN1/2/3, notes, log and settings; `atomicWrite` (`<path>.tmp` then rename); KANBAN3 backup `<path>.kanban3.bak` |
| **Core model** | `src/model.zig`, `src/dates.zig`, `src/stats.zig`, `src/editor.zig` | Task board, date parsing, statistics, text editor buffer (pure, unit-tested) |
| **Input** | `src/input.zig`, `src/form.zig`, `src/main.zig` (event loop, bracketed paste) | Keyboard, mouse and paste events from the terminal |
| **Rendering** | `src/ui.zig`, `src/draw.zig`, `src/viewkit.zig`, `src/charts.zig`, `src/dashboard.zig`, `src/log_view.zig`, `src/logbook.zig`, `src/brain_view.zig`, `src/brainstorm.zig`, `src/theme.zig`, `src/state.zig` | Draws file-derived text (titles, notes) into the terminal through libvaxis |
| **Legacy copy** | `src/src/**` | An older duplicate of `src/`. It is not referenced by `build.zig` (root is `src/main.zig`), so it isn't compiled. **In scope by maintainer decision**: treat its findings like `src/` |
| **Dependencies/Build** | `build.zig`, `build.zig.zon` | libvaxis fetched by git URL + content hash |

## Trust boundaries and entry points
1. **Data files** (main boundary): `board.tsv` (`$KANBAN_FILE`, else `$XDG_DATA_HOME/kanban/board.tsv`, else `$HOME/.local/share/kanban/board.tsv`) and its siblings `.notes`, `.log`, `.settings`, `.tmp`, `.kanban3.bak`. Normally the user writes them. They become untrusted when they come from someone else: a shared or imported board, or a KANBAN3 file "from another build of this app" (`storage.parse`). Read limits: board 8 MiB, notes 32 MiB, log 64 MiB, settings 64 KiB.
2. **Environment variables**: `KANBAN_FILE`, `XDG_DATA_HOME`, `HOME`, all set by the user. The directory is created with `createDirPath`.
3. **Terminal input**: keys, mouse, bracketed paste (`input.collectPaste`, `handlePaste`). Comes from the local user, though pasted text can come from elsewhere.
4. **Terminal output**: file-derived strings are drawn through libvaxis `printSegment`/`writeCell`. Unsanitised control or escape bytes could reach the terminal.

## Assets
- Integrity and availability of the user's board, notes and work log (README: "atomic save after every change").
- Confidentiality of task titles and notes (personal data, local only).
- The user's terminal session: no escape-sequence injection, no crash or hang.

## Attacker profiles (both confirmed by the maintainer)
- **A1: crafted data file.** Someone gets the user to open a board, notes or log file they control (shared via `KANBAN_FILE`, or a KANBAN3 import).
- **A2: other local user** on a shared machine, when the data path is in a world-writable directory (e.g. `KANBAN_FILE=/tmp/...`). Relevant to the predictable `<path>.tmp` and `.kanban3.bak` names (symlink/TOCTOU).
- Remote network attackers: no network surface exists.

## Existing controls
- Bounded file reads; parsers skip malformed lines (`catch continue`) and reject unknown headers (`error.BadFormat`). On fatal errors the app stops without modifying files (`main.fatal`).
- Titles are cleaned/truncated to `max_title = 200` (`model.cleanTitle`). Settings values are clamped (`Params.clamp`). Error messages replace control characters with `?` (`storage.firstLine`).
- Atomic temp-file-plus-rename writes. A KANBAN3 backup is written once and never overwritten.
- Zig safety checks in Debug/ReleaseSafe builds (README recommends `-Doptimize=ReleaseSafe`).
- Dependency is pinned by content hash.

## Maintainer decisions
- Attackers: **all matter**. That covers A1 (crafted data file), A2 (other local user on a shared machine) and accidental corruption or data loss.
- Assets: **all equally important**: data integrity, confidentiality of notes and tasks, and the terminal session.
- `src/src/` is **in scope**, treated like `src/`.
- Nothing is out of scope and nothing is accepted risk. That includes Windows behaviour and DoS from large files.
- Finding tags: `Component`, `CWE`, `Platform`.

## Out of scope / accepted risk
None.

## Open questions
None outstanding.
