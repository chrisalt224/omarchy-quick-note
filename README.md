# Quick Note

Capture a thought straight into your open Obsidian vault without opening the app.

Bind a key, type, press `Ctrl+Enter`. The overlay never leaves the keyboard and
Obsidian does not have to be running.

## Install

```bash
omarchy plugin add https://github.com/chrisalt224/omarchy-quick-note.git --enable
```

Then bind a key in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + Q", "Quick note", "omarchy-shell shell summon io.github.chrisalt224.quick-note {}")
```

Requires `jq` and `xdg-utils`, both of which Omarchy already ships.

## Keys

| Key | Action |
|-----|--------|
| `Ctrl+Enter` | Save and close |
| `Ctrl+Shift+Enter` | Save and open the note in Obsidian |
| `Tab` | Switch between **New note** and **Daily** |
| `Esc` | Discard |

The two buttons on the card do the same as `Tab` and `Ctrl+Shift+Enter`.

## Where notes go

Nothing is hardcoded. The plugin reads `~/.config/obsidian/obsidian.json` at
capture time and picks the vault like this:

1. Among vaults Obsidian has open (`"open": true`), the one with the newest
   `ts` — so with two windows open you get the one you used last, not whichever
   sorts first.
2. If none are open, because Obsidian is closed, the most recently used vault
   overall.

So it follows you when you switch vaults, and still works with Obsidian shut.

- **New note** — a new file in `Quick Notes/`, named `YYYYMMDDHHMM.md`.
  Same-minute collisions get `-2`, `-3`.
- **Daily** — appends a `## HH:MM` section to today's daily note, using the
  folder and moment format from the vault's `.obsidian/daily-notes.json`, so it
  matches the note Obsidian itself would create. An existing note is only ever
  appended to, never overwritten. Nested formats like `YYYY/MM/DD` work.

Set `QUICK_NOTE_FOLDER` to change the target folder for new notes.

## A note on filenames

Notes are named with a timestamp rather than from their first line, so capture
never becomes a naming decision. Obsidian's file explorer lists notes by
filename, so these appear as `202609021741` rather than a readable title — that
is the tradeoff. If you would rather have titles, the "first line becomes the
filename" behaviour is a small change in `save-note.sh`.

## Why it works with Obsidian closed

Obsidian watches its vault directory, so a file written here shows up in the
explorer without the app being told about it. With Obsidian shut, the note still
lands on disk and appears the next time you open the vault.

## Files

```
manifest.json    id io.github.chrisalt224.quick-note, kind: overlay
QuickNote.qml    the overlay
save-note.sh     vault resolution and writing
```

`save-note.sh` works on its own:

```bash
./save-note.sh 'Body text'            # new note
./save-note.sh --daily 'Body text'    # append to today
./save-note.sh --info                 # print destinations as JSON
./save-note.sh --open <abs path>      # open a note in Obsidian
echo 'Body' | ./save-note.sh          # stdin also works
```

## Developing

`keepLoaded: true` keeps the overlay resident, so saving a file does **not**
hot-reload it. After editing:

```bash
omarchy restart shell
```

## License

MIT. This plugin runs unsandboxed with your user's permissions, like every
Omarchy plugin — read `save-note.sh` before trusting it with your vault.
