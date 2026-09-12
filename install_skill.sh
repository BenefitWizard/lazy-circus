#!/usr/bin/env sh
# Install the lazy-circus AI skill into the user's skills directory.
# Performs a clean mirror: stale files in the destination are removed.
# Usage: ./install_skill.sh [--agents|--opencode|--path <dir>]
#   --agents      install into ~/.agents/skills (default)
#   --opencode    install into ~/.opencode/skills
#   --path <dir>  install into the given directory

set -eu

DEST_BASE="${HOME}/.agents/skills"
while [ $# -gt 0 ]; do
    case "$1" in
        --agents)   DEST_BASE="${HOME}/.agents/skills" ;;
        --opencode) DEST_BASE="${HOME}/.opencode/skills" ;;
        --path)
            if [ $# -lt 2 ]; then
                printf 'Error: --path requires a directory argument\n' >&2
                printf 'Usage: %s [--agents|--opencode|--path <dir>]\n' "$0" >&2
                exit 1
            fi
            DEST_BASE="$2"
            shift
            ;;
        *)
            printf 'Error: unknown option %s\n' "$1" >&2
            printf 'Usage: %s [--agents|--opencode|--path <dir>]\n' "$0" >&2
            exit 1
            ;;
    esac
    shift
done

SCRIPT_DIR=$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd)
SKILL_NAME="lazy-circus"
SRC="$SCRIPT_DIR/docs/skills/$SKILL_NAME"

if [ ! -f "$SRC/SKILL.md" ]; then
    printf 'Error: skill source not found at %s/SKILL.md\n' "$SRC" >&2
    exit 1
fi

DEST="$DEST_BASE/$SKILL_NAME"

printf 'Installing %s skill...\n' "$SKILL_NAME"
printf '  source:      %s\n' "$SRC"
printf '  destination: %s\n' "$DEST"

mkdir -p "$DEST_BASE"

# Clean mirror so removed reference files do not linger.
if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "$SRC/" "$DEST/"
else
    rm -rf "$DEST"
    mkdir -p "$DEST"
    cp -R "$SRC/." "$DEST/"
fi

printf 'Installed files:\n'
( cd "$DEST" && find . -type f | sort | sed 's|^\./|  |' )

printf 'Done. Skill "%s" installed to %s\n' "$SKILL_NAME" "$DEST"
