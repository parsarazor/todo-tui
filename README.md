# kanban — a terminal Kanban with a priority matrix

Zig 0.17 + [libvaxis](https://github.com/rockorager/libvaxis). Black canvas, bone-white text,
coloured outlines for the four priority squares.


![Kanban board screenshot](assets/todoapp.png)


## Build & run

```sh
zig build run              # needs Zig 0.16.0
zig build -Doptimize=ReleaseSafe && ./zig-out/bin/kanban
zig build test             # model + date parsing tests
```

Data lives in `$KANBAN_FILE`, else `$XDG_DATA_HOME/kanban/board.tsv`,
else `~/.local/share/kanban/board.tsv` — plain tab-separated text, saved after every change.

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

## Layout of the code

```
src/main.zig    event loop only
src/state.zig   App state + every operation (select, move, edit, delete, form submit)
src/input.zig   key / mouse events  →  state operations
src/ui.zig      layout, drawing, hit-map for the mouse
src/form.zig    the new/edit modal
src/draw.zig    boxes, clipped text
src/theme.zig   every colour
src/model.zig   Task / Board / Zone  (pure, unit-tested)
src/dates.zig   civil-date maths + deadline parsing (pure, unit-tested)
src/storage.zig load / atomic save
```

### Why I Made a tui Kanban for Zig

I made this Kanban for Zig because I found it to be more efficient compared to Go. Zig's performance and control over memory management made it a better fit for this project. The ability to write low-level code with high-level abstractions was particularly appealing, allowing me to create a tool that is both powerful and easy to use.
