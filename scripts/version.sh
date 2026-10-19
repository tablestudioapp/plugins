#!/bin/bash
# The plugin's version is written in six files. This keeps them in step.
#
#   scripts/version.sh            check they agree and CHANGELOG.md has notes for it; prints it
#   scripts/version.sh 0.5.2      write 0.5.2 into all six and add its CHANGELOG.md heading
#   scripts/version.sh --notes    print the current version's CHANGELOG.md notes
#
# CI runs the check on every push and pull request, and the release job publishes the notes.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

MANIFESTS=(
    package.json
    tablestudio/opencode/package.json
    tablestudio/.claude-plugin/plugin.json
    tablestudio/.cursor-plugin/plugin.json
    tablestudio/.codex-plugin/plugin.json
)
# Codex's header helper can't read a manifest, so the version is also written into its command.
CODEX_MCP=tablestudio/codex-mcp.json

codex_version() {
    jq -r '.mcpServers.tablestudio.http_headers_helper' "$CODEX_MCP" |
        grep -o '"X-TableStudio-Plugin":"[^"]*"' | cut -d'"' -f4
}

# The CHANGELOG.md section for $1, without its heading.
notes() {
    awk -v heading="## $1" '$0 == heading { on = 1; next } on && /^## / { exit } on' CHANGELOG.md
}

version="$(jq -r .version "${MANIFESTS[0]}")"

case "${1:-}" in
    --notes)
        notes "$version" | sed -e '/./,$!d'
        exit 0
        ;;
    "") ;;
    *)
        [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Not a version: $1 (expected one like 0.5.2)" >&2; exit 1; }
        for f in "${MANIFESTS[@]}"; do
            V="$1" perl -0777 -pi -e 's/"version": "[^"]*"/"version": "$ENV{V}"/' "$f"
        done
        V="$1" perl -pi -e 's/(X-TableStudio-Plugin\\":\\")[^\\]*/${1}$ENV{V}/' "$CODEX_MCP"
        if ! grep -qxF "## $1" CHANGELOG.md; then
            V="$1" perl -0777 -pi -e 's/\n## /\n## $ENV{V}\n\n## /' CHANGELOG.md
        fi
        echo "Version $1. Write its notes under \"## $1\" in CHANGELOG.md."
        exit 0
        ;;
esac

status=0
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "${MANIFESTS[0]}: not a version: $version" >&2; status=1; }
for f in "${MANIFESTS[@]:1}"; do
    v="$(jq -r .version "$f")"
    [ "$v" = "$version" ] || { echo "$f says $v, ${MANIFESTS[0]} says $version" >&2; status=1; }
done
v="$(codex_version)"
[ "$v" = "$version" ] || { echo "$CODEX_MCP sends X-TableStudio-Plugin $v, not $version" >&2; status=1; }
notes "$version" | grep -q '[^[:space:]]' || { echo "CHANGELOG.md has no notes under \"## $version\"" >&2; status=1; }
[ "$status" = 0 ] && echo "$version"
exit "$status"
