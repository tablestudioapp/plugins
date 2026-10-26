#!/bin/bash
# Installs TableStudio (when it's missing, with its MCP server on) and its plugin into the coding
# agents on this Mac: Claude Code, Cursor, Codex and OpenCode. The ones you name, else the ones it
# finds, asking which at a terminal.
#
#   ./install.sh                     from a checkout of this repository
#   ./install.sh cursor opencode     only these
#   curl -fsSL https://tablestudio.sh/install | bash
#
# Run it again to update. It ends with a check of what's set up (also: ./install.sh --doctor).
# TABLESTUDIO_INSTALL_APP=0 never installs the app.

REPO="https://github.com/tablestudioapp/plugins.git"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

if [ -f "$HERE/tablestudio/scripts/tablestudio-hook" ]; then
    ROOT="$HERE"
else
    # Piped from curl: keep a checkout under ~/.tablestudio so updates are a pull.
    ROOT="$HOME/.tablestudio/plugins"
    if [ -d "$ROOT/.git" ]; then
        git -C "$ROOT" pull --ff-only --quiet || exit 1
    else
        command -v git >/dev/null 2>&1 || { echo "Needs git (xcode-select --install)."; exit 1; }
        mkdir -p "$(dirname "$ROOT")" && git clone --depth 1 --quiet "$REPO" "$ROOT" || exit 1
    fi
fi

if [ "${1:-}" = "--doctor" ]; then
    exec /bin/bash "$ROOT/tablestudio/scripts/tablestudio-hook" doctor
fi
exec /bin/bash "$ROOT/tablestudio/scripts/tablestudio-hook" install "$@"
