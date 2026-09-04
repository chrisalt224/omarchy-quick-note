#!/bin/bash
# Write a note into the Obsidian vault that is currently open.
#
# Obsidian watches its vault directory, so a file written here appears in the
# file explorer without the app being told about it. With Obsidian closed the
# note still lands on disk and shows up next time the vault is opened.
#
# Usage:
#   save-note.sh [--daily] <body>     body may also arrive on stdin
#   save-note.sh --info               print destinations as JSON, write nothing
#
# Prints the path written. Errors go to stderr.
set -uo pipefail

REGISTRY="${OBSIDIAN_CONFIG:-$HOME/.config/obsidian/obsidian.json}"
FOLDER="${QUICK_NOTE_FOLDER:-Quick Notes}"

[[ -f $REGISTRY ]] || { echo "no obsidian.json at $REGISTRY" >&2; exit 1; }

# Obsidian marks the vault it has open with "open": true. Fall back to the most
# recently touched one, which is what you get when Obsidian is closed.
# Obsidian marks every vault it has a window open for with "open": true, so
# there can be several. Rank by ts within those to get the one most recently
# used rather than whichever happens to come first in the JSON. With no vault
# open at all -- Obsidian closed -- fall back to the most recent overall.
vault=$(jq -r '
  [.vaults | to_entries[] | .value | select(.path != null)]
  | ( (map(select(.open == true)) | sort_by(.ts // 0) | last)
      // (sort_by(.ts // 0) | last) )
  | .path // empty' "$REGISTRY")
[[ -n $vault && -d $vault ]] || { echo "no usable vault (got: ${vault:-none})" >&2; exit 1; }
vname=$(basename "$vault")

# The folder and date-format values come from the vault's own config and from
# the environment. Neither is trusted to stay inside the vault: a ".." in either
# would otherwise let a write land anywhere the user can write. Resolve the
# candidate path with symlinks followed and require it to sit under the vault.
require_inside_vault() {
  local candidate="$1" rp rbase
  rp=$(realpath -m -- "$candidate" 2>/dev/null) || return 1
  rbase=$(realpath -m -- "$vault" 2>/dev/null) || return 1
  [[ $rp == "$rbase"/* ]]
}

reject_traversal() {
  local label="$1" value="$2"
  case "$value" in
    /*|*/../*|*/..|../*|..) echo "$label must be a relative path inside the vault: $value" >&2; exit 1;;
  esac
}

# Daily-note settings live in the vault. Obsidian uses moment.js tokens; map the
# common ones onto strftime so the filename matches what Obsidian would create.
dn="$vault/.obsidian/daily-notes.json"
daily_folder=$(jq -r '.folder // ""' "$dn" 2>/dev/null)
daily_format=$(jq -r '.format // ""' "$dn" 2>/dev/null)
[[ -n $daily_folder && $daily_folder != "null" ]] || daily_folder=""
reject_traversal "daily-notes folder" "$daily_folder"
reject_traversal "QUICK_NOTE_FOLDER" "$FOLDER"
[[ -n $daily_format && $daily_format != "null" ]] || daily_format="YYYY-MM-DD"
# A format may legitimately contain "/" (YYYY/MM/DD nests directories), which
# makes it path input like the folder, so it gets the same treatment.
reject_traversal "daily-notes format" "$daily_format"

moment_to_strftime() {
  # Longest tokens first so MM is not eaten by M, etc.
  printf '%s' "$1" | sed -e 's/YYYY/%Y/g' -e 's/YY/%y/g' \
    -e 's/MMMM/%B/g' -e 's/MMM/%b/g' -e 's/MM/%m/g' \
    -e 's/dddd/%A/g' -e 's/ddd/%a/g' \
    -e 's/DD/%d/g' -e 's/HH/%H/g' -e 's/mm/%M/g'
}
daily_name=$(date +"$(moment_to_strftime "$daily_format")")

if [[ ${1:-} == "--info" ]]; then
  rel="$daily_name.md"; [[ -n $daily_folder ]] && rel="$daily_folder/$daily_name.md"
  jq -n --arg v "$vname" --arg p "$vault" --arg nf "$FOLDER" --arg df "$daily_folder" --arg dn "$rel" \
    '{vault:$v, path:$p, noteFolder:$nf, dailyFolder:$df, dailyNote:$dn}'
  exit 0
fi

# Hand a note to Obsidian. The obsidian:// scheme wants the vault name and a
# path relative to the vault root, both percent-encoded -- jq's @uri does that
# correctly, including the spaces that vault and folder names usually contain.
if [[ ${1:-} == "--open" ]]; then
  [[ -n ${2:-} ]] || { echo "--open needs a path" >&2; exit 1; }
  require_inside_vault "$2" || { echo "refusing to open a path outside the vault: $2" >&2; exit 1; }
  # Plain string strip: "${2#$vault/}" treats $vault as a pattern, so a vault
  # path containing glob characters would strip the wrong prefix or none.
  rel="${2:${#vault}}"; rel="${rel#/}"
  uri=$(jq -rn --arg v "$vname" --arg f "$rel" '"obsidian://open?vault=\($v|@uri)&file=\($f|@uri)"')
  echo "$uri"
  xdg-open "$uri" >/dev/null 2>&1 &
  exit 0
fi

mode="note"
[[ ${1:-} == "--daily" ]] && { mode="daily"; shift; }

if (( $# > 0 )); then body="$1"; else body=$(cat); fi
[[ -n ${body//[[:space:]]/} ]] || { echo "empty note, nothing written" >&2; exit 2; }

if [[ $mode == "daily" ]]; then
  dir="$vault"; [[ -n $daily_folder ]] && dir="$vault/$daily_folder"
  target="$dir/$daily_name.md"
  # A format like YYYY/MM/DD nests directories, so create the target's parent
  # rather than just the configured folder.
  require_inside_vault "$target" || { echo "refusing to write outside the vault: $target" >&2; exit 1; }
  mkdir -p "$(dirname "$target")" || { echo "cannot create $(dirname "$target")" >&2; exit 1; }
  # Appending through a symlink would redirect the write to whatever it points
  # at, so only ever append to a regular file.
  if [[ -L $target ]]; then echo "refusing to append through a symlink: $target" >&2; exit 1; fi
  if [[ -e $target && ! -f $target ]]; then echo "not a regular file: $target" >&2; exit 1; fi
  # An existing daily note is only ever appended to, so nothing already written
  # for today can be lost.
  printf '\n## %s\n%s\n' "$(date +%H:%M)" "$body" >> "$target" || { echo "append failed: $target" >&2; exit 1; }
  echo "$target"
  exit 0
fi

# Notes are named with a timestamp id rather than from their text: quick capture
# should not make you name the thing before you have written it. Obsidian shows
# the first "# heading" as the title when there is one.
base=$(date +%Y%m%d%H%M)

dir="$vault"; [[ -n $FOLDER ]] && dir="$vault/$FOLDER"
require_inside_vault "$dir/x" || { echo "refusing to write outside the vault: $dir" >&2; exit 1; }
mkdir -p "$dir" || { echo "cannot create $dir" >&2; exit 1; }

# noclobber makes ">" an O_CREAT|O_EXCL open: it fails if anything is already
# at the path, symlink included, rather than testing first and writing after.
# That closes both the check-then-open race and the symlink redirect, and the
# loop simply advances to the next free name when the create loses.
set -C
n=1
target="$dir/$base.md"
until printf '%s\n' "$body" 2>/dev/null > "$target"; do
  if (( n > 50 )); then echo "could not find a free filename in $dir" >&2; exit 1; fi
  n=$((n + 1))
  target="$dir/$base-$n.md"
done
set +C
echo "$target"
