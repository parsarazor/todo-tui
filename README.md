# kanban — a terminal todo list with a priority matrix

Zig 0.17 + [libvaxis](https://github.com/rockorager/libvaxis). Keyboard-first, mouse-friendly,
one static binary, all data in plain text. Black canvas, bone-white text, coloured outlines
for the four priority squares.


![Kanban board screenshot](assets/todoapp.png)
![Kanban board screenshot](assets/dashboard3.png)
![Kanban board screenshot](assets/dashboard1.png)




## Features

- kanban columns crossed with a four-square priority matrix — every task sits in a priority × column cell
- keyboard-first: vim keys, `⇧+arrows` / `H J K L` to move cards; mouse drag-and-drop, wheel scroll, double-click edit
- deadlines that parse like a human types them: `2026-10-05`, `10-05`, `+3`, `+2w`, `today`, `tomorrow`
- management dashboard (`s`): KPI cards plus column, line, donut, stacked-bar, horizontal-bar, scatter and calendar-heatmap charts — see below
- work log + statistics: tracked sessions, completions, weekly comparison, streaks, forecasts, backlog velocity
- brainstorm popup: titled free-text pages for ideas
- plaintext everywhere: one greppable TSV for the board, atomic save after every change
- pure, unit-tested core (model, dates, stats, editor)

## Build & run

```sh
zig build run              # needs Zig 0.17.0
zig build -Doptimize=ReleaseSafe && ./zig-out/bin/kanban
zig build test             # model + date parsing tests
```

Data lives in `$KANBAN_FILE`, else `$XDG_DATA_HOME/kanban/board.tsv`,
else `~/.local/share/kanban/board.tsv` — plain tab-separated text, saved after every change.

## Windows
The board saves to `$HOME/.local/share/kanban/board.tsv`, and Windows does not define
`HOME`, so it must be exported from `USERPROFILE`. Open a terminal **at the repo root**
first — the folder's name and location don't matter; `git clone` and GitHub's
"Download ZIP" each put it in a folder of their own choosing, and any name works the same.

Build once:

```powershell
$env:HOME = $env:USERPROFILE      # needed every session — add to your $PROFILE to persist
zig build -Doptimize=ReleaseSafe  # builds zig-out\bin\kanban.exe without launching it
zig build run                     # or just try it out live
```

Install it like a real terminal command (type `kanban` from any folder, just like `cd`
or `ls`): copy the exe out of the repo and drop a launcher into
`%LOCALAPPDATA%\Microsoft\WindowsApps`, which is already on your `PATH`.

```powershell
$dest = "$env:LOCALAPPDATA\Programs\kanban"
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item "zig-out\bin\kanban.exe" $dest -Force

@'
@echo off
set "HOME=%USERPROFILE%"
"%LOCALAPPDATA%\Programs\kanban\kanban.exe" %*
'@ | Set-Content -Encoding ASCII "$env:LOCALAPPDATA\Microsoft\WindowsApps\kanban.cmd"
```

Open a new terminal and `kanban` works from anywhere, whatever the repo folder is
called and wherever it lives, since the launcher points at the installed copy, not
the repo. The wrapper sets `HOME` itself, so it also works when double-clicked from
Explorer. To keep the board somewhere else, add `set "KANBAN_FILE=C:\path\to\board.tsv"`
to the launcher; to uninstall, delete `kanban.cmd` and the
`%LOCALAPPDATA%\Programs\kanban` folder.

## Keys

| key | action |
| --- | --- |
| `← ↑ ↓ →` / `h j k l` | move the cursor (edges jump to the neighbouring square / column) |
| `⇧+arrows` / `H J K L` | move the selected task to the neighbouring square / column |
| mouse drag | drag a card and drop it on any square or column |
| `n` | new task (lands in the focused square / column) |
| `e`, `Enter`, double-click | edit |
| `1 2 3 4` | set priority (moves it to that square) |
| `space` | advance: backlog → in progress → done |
| `x` | delete (asks first) |
| mouse wheel | scroll a long list |
| `?` | help · `q` / `ctrl+c` quit |

Deadline field accepts `2026-10-05`, `10-05` (next occurrence), `+3` (days), `+2w`,
`today`, `tomorrow`, or empty for none.

## Dashboard

Press `s` to open it. Five tabs (`1`–`5`, or `tab` / `shift+tab`):

| tab | what is on it |
|-----|---------------|
| Dashboard | six KPI cards (focus hours vs goal, tasks done, streak, goal odds, backlog ETA, deadlines) · hours per day (columns, last week as ticks) · weekly trend with forecast band (braille line) · time by priority (donut) · board status (stacked bar) · when you work (hour histogram) · weekday rhythm (bars) |
| Trends | activity calendar heatmap · weekly hours · tasks done per week · running total · task-duration scatter · duration histogram |
| Board | priority matrix counts · board status · deadlines · work in progress vs its usual pace (gauges) · typical duration per priority · finished work by priority |
| Week | day-by-day view with comparison against last week |
| Insights | the full numbers behind every forecast |

`g/G` goal · `w/W` history window · `m/M` active-day threshold · `a/A` smoothing work on every tab except Week.
Charts are drawn with block and braille characters, so nothing extra is needed. The layout adapts to the terminal
size (cards go 6 → 3 → 2 → 1 per row, panels drop from the bottom/right); a 120×38 terminal shows everything.

## Layout of the code

```
src/main.zig      event loop only
src/state.zig     App state + every operation (select, move, edit, delete, form submit)
src/input.zig     key / mouse events  →  state operations
src/ui.zig        layout, drawing, hit-map for the mouse
src/form.zig      the new/edit modal
src/draw.zig      boxes, clipped text
src/theme.zig     every colour
src/model.zig     Task / Board / Zone  (pure, unit-tested)
src/dates.zig     civil-date maths + deadline parsing (pure, unit-tested)
src/storage.zig   load / atomic save
src/worklog.zig   append-only log of work sessions & completions (pure)
src/stats.zig     weekly stats, streaks, forecasts over the log (pure, unit-tested)
src/settings.zig  stat parameters, saved as key=value next to the board
src/brainstorm.zig  brainstorm popup state machine (topics + free-text pages)
src/brain_view.zig  draws the brainstorm popup
src/notes.zig       brainstorm topic data + on-disk format (pure)
src/editor.zig      UTF-8 multi-line text editor core (pure)
src/logbook.zig     Log popup state and keys
src/log_view.zig    draws the popup frame, the Week and Insights tabs
src/dashboard.zig   KPI cards + chart panels for the Dashboard / Trends / Board tabs
src/charts.zig      column, hbar, stacked, gauge, sparkline, braille line / scatter / donut, heatmap
src/viewkit.zig     shared rich-text lines and number formatting for the log views
```

### Why I made a TUI kanban in Zig

I made this Kanban for Zig because I found it to be more efficient compared to Go. Zig's performance and control over memory management made it a better fit for this project. The ability to write low-level code with high-level abstractions was particularly appealing, allowing me to create a tool that is both powerful and easy to use.
