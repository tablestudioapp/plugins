#!/bin/bash
# Tests for scripts/tablestudio-hook. Needs jq to build and check JSON (preinstalled on macOS 15+).
# The checks that read TableStudio's settings and saved connections run on macOS only.
#
#   tests/run.sh            run everything
#   tests/run.sh -v         also print each passing case

cd "$(dirname "$0")/.." || exit 1
HOOK="tablestudio/scripts/tablestudio-hook"
PROJECT="$PWD/tests/fixtures/project"
EMPTY="$PWD/tests/fixtures/empty-project"
PREFS="$PWD/tests/fixtures/prefs/sh.tablestudio.plist"
VERBOSE="${1:-}"
pass=0
fail=0

# Keep the developer's own environment, and their real TableStudio, out of the results: no real
# preferences or saved connections, no launching the app, a throwaway home and state directory.
unset DATABASE_URL REMOTE_URL PGHOST TABLESTUDIO_GUARD_MODE CLAUDE_PLUGIN_OPTION_GUARD_MODE CLAUDE_PROJECT_DIR \
      CLAUDE_PLUGIN_OPTION_PORT TABLESTUDIO_MCP_PORT CLAUDE_CODE_MCP_SERVER_URL
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
export HOME="$SCRATCH/home" CLAUDE_PLUGIN_DATA="$SCRATCH/data"
export TABLESTUDIO_PREFS=/nonexistent/sh.tablestudio.plist TABLESTUDIO_APP_PATH=/nonexistent/TableStudio.app
export TABLESTUDIO_OPEN_APP=0
mkdir -p "$HOME"

ON_MAC=0
[ -x /usr/bin/plutil ] && command -v osascript >/dev/null 2>&1 && ON_MAC=1

report() { # report <ok> <name> <detail>
    if [ "$1" = 1 ]; then
        pass=$((pass + 1))
        [ "$VERBOSE" = "-v" ] && printf '  ok    %s\n' "$2"
    else
        fail=$((fail + 1))
        printf '  FAIL  %s\n        %s\n' "$2" "$3"
    fi
}

# Decision the hook reached: none (no output), allow, ask, deny, or "invalid" for broken JSON.
decision_of() { # decision_of <client> <output>
    local out="$2"
    if [ -z "$out" ]; then echo none; return; fi
    if ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then echo invalid; return; fi
    if [ "$1" = cursor ]; then
        printf '%s' "$out" | jq -r '.permission'
    else
        printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'
    fi
}

# guard <expected> <command> [cwd] [client] — run the shell guard on one command.
guard() {
    local expected="$1" cmd="$2" cwd="${3:-$PROJECT}" client="${4:-claude}" input out got
    if [ "$client" = cursor ]; then
        input="$(jq -n --arg c "$cmd" --arg d "$cwd" '{command: $c, cwd: $d, workspace_roots: [$d], hook_event_name: "beforeShellExecution"}')"
    else
        input="$(jq -n --arg c "$cmd" --arg d "$cwd" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}')"
    fi
    out="$(printf '%s' "$input" | /bin/bash "$HOOK" guard-shell "$client")"
    got="$(decision_of "$client" "$out")"
    [ "$got" = "$expected" ]
    report $((1 - $?)) "[$client] $expected ← $cmd" "got $got: $out"
}

echo "Shell guard: commands that aren't database writes pass untouched"
guard none 'ls -la'
guard none 'npm test'
guard none 'git commit -m "drop the old prod config"'
guard none 'psql -c "select * from users"'
guard none 'psql -h db.prod.example.com -c "select count(*) from users"'
guard none 'psql --version'
guard none 'pg_dump -h db.prod.example.com app > dump.sql'
guard none 'mysql -h prod-mysql.internal -e "SELECT * FROM t LIMIT 5"'
guard none 'psql -h db.example.com -f queries/report.sql'
guard none 'psql -h db.example.com -l'
guard none 'npx wrangler d1 execute mydb --remote --command "SELECT count(*) FROM t"'
guard none 'npx wrangler d1 execute mydb --remote --file=queries/report.sql'
guard none 'turso db shell mydb "SELECT * FROM t LIMIT 5"'

echo "Shell guard: database words in text the command only reads or writes"
guard none 'grep -rn "psql -h db.prod.example.com" docs/'
guard none 'rg "DELETE FROM users" src/ | head -20'
guard none 'git commit -m "run psql -h db.prod.example.com in deploy"'
guard none 'git log --oneline | grep "mysql -h prod"'
guard none 'find . -name "*.sql" | xargs grep -l "DROP TABLE"'
guard deny 'cat fix.sql | psql -h db.prod.example.com'
guard deny 'grep -q ok status && psql -h db.prod.example.com -c "DELETE FROM users"'
guard deny 'find . -name "*.sql" -exec psql -h db.prod.example.com -f {} \;'

echo "Shell guard: text inside a heredoc that isn't fed to a database client is data"
guard none "$(printf 'cat > tests/case.sh <<%sEOF%s\npsql -h db.prod.example.com -c "delete from users"\nEOF' "'" "'")"
guard none "$(printf 'python3 - <<%sPY%s\nprint("npx prisma migrate deploy against prod")\nPY\necho done' "'" "'")"
guard ask "$(printf 'cat > notes.txt <<%sEOF%s\nhello\nEOF\npsql -h db.example.com -c "delete from x"' "'" "'")"
guard none "printf 'Run npm run migrate.\n' > README.md && printf 'DATABASE_URL=postgresql://u:p@db.prod.example.com/x\n' > .env.production"
guard none 'echo "psql -h db.prod.example.com -c \"delete from users\"" >> notes.md'
guard deny 'echo "delete from users" | psql -h db.prod.example.com app'
guard ask "printf 'update t set a = 1;' | psql -h db.example.com app"

echo "Shell guard: writes to local databases pass untouched"
guard none 'psql postgres://u:p@localhost:5432/app -c "drop table scratch"'
guard none 'psql "$DATABASE_URL" -c "delete from sessions"'
guard none 'echo "DELETE FROM users" | psql -h localhost app'
guard none 'psql -h db -U postgres -c "truncate table jobs"'
guard none 'npx prisma migrate dev --name add_widgets'
guard none 'npx prisma migrate deploy'
guard none 'pnpm db:push'
guard none 'bin/rails db:migrate'
guard none 'alembic upgrade head'
guard none 'npx wrangler d1 execute mydb --command "DELETE FROM t"'
guard none 'npx supabase db push --local'

echo "Shell guard: writes to production are blocked"
guard deny 'psql -h db.prod.example.com -c "delete from users where id = 1"'
guard deny 'psql "$PROD_DATABASE_URL" -c "delete from x"'
guard deny 'DATABASE_URL=postgres://u:p@prod-db.aws.example.com/app npx prisma migrate deploy'
guard deny 'RAILS_ENV=production bin/rails db:migrate'
guard deny 'npm run migrate:prod'
guard deny 'mysql -h prod-mysql.internal -e "DELETE FROM t"'
guard deny 'PGHOST=prod.db.internal psql -c "truncate table x"'
guard deny 'npx prisma migrate deploy --env-file .env.production'
guard deny 'dotenv -e .env.production -- npx prisma db push'
guard deny 'python manage.py migrate --settings=app.settings.production'
guard deny 'npx wrangler d1 execute mydb --remote --env production --command "DELETE FROM t"'

echo "Shell guard: writes to other remote databases ask first"
guard ask 'psql -h db.example.com -c "update users set active = false"'
guard ask 'psql "$REMOTE_URL" -c "delete from x"'
guard ask 'psql "$MISSING_DB_URL" -c "delete from x"'
guard ask 'npx prisma migrate deploy' "$EMPTY"
guard ask 'cd apps/api && npx prisma migrate deploy'
guard ask 'psql -v ON_ERROR_STOP=1 -h db.example.com -f migrations/001_widgets.sql'
guard ask 'cat dump.sql | psql -h db.example.com mydb'
guard ask 'pg_restore -h db.example.com -d app dump.sql'
guard ask 'npx supabase db push'
guard ask 'npx wrangler d1 execute mydb --remote --command "DELETE FROM t"'
guard ask 'npx wrangler d1 execute mydb --remote --file=missing-seed.sql'
guard ask 'turso db shell mydb "DELETE FROM t"'
guard ask 'turso db shell mydb'
guard ask 'mysql -h db.example.com app < missing-seed.sql'
guard ask "$(printf 'psql -h db.example.com <<%sSQL%s\nUPDATE t SET a = 1;\nSQL' "'" "'")"
guard ask 'goose -dir db/migrations postgres "postgres://u:p@db.example.com/app" up'

echo "Shell guard: modes and clients"
TABLESTUDIO_GUARD_MODE=off guard none 'psql -h db.prod.example.com -c "delete from users"'
TABLESTUDIO_GUARD_MODE=ask guard ask 'psql -h db.prod.example.com -c "delete from users"'
guard allow 'ls -la' "$PROJECT" cursor
guard allow 'psql -c "select 1"' "$PROJECT" cursor
guard deny 'psql -h db.prod.example.com -c "delete from users"' "$PROJECT" cursor
guard ask 'psql -h db.example.com -c "delete from users"' "$PROJECT" cursor
guard none 'psql -c "select 1"' "$PROJECT" codex
guard deny 'psql -h db.prod.example.com -c "delete from users"' "$PROJECT" codex
# Codex can't ask the user, so what asks elsewhere is stopped there.
guard deny 'psql -h db.example.com -c "delete from users"' "$PROJECT" codex
out="$(jq -n --arg c 'npx supabase db push' --arg d "$PROJECT" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}' |
    /bin/bash "$HOOK" guard-shell codex | jq -r '.hookSpecificOutput.permissionDecisionReason')"
printf '%s' "$out" | grep -q "Codex can't ask the user to approve it: this command writes to a non-local database"
report $((1 - $?)) "[codex] explains why it stopped instead of asking" "got: $out"
! printf '%s' "$out" | grep -q 'Allow it only'
report $((1 - $?)) "[codex] no approval wording, since nobody is asked" "got: $out"

echo "Shell guard: broken input never blocks"
out="$(printf 'not json at all' | /bin/bash "$HOOK" guard-shell claude)"
[ -z "$out" ]; report $((1 - $?)) "[claude] garbage input → no decision" "got: $out"
out="$(printf 'not json at all' | /bin/bash "$HOOK" guard-shell cursor)"
[ "$out" = '{"permission":"allow"}' ]; report $((1 - $?)) "[cursor] garbage input → allow" "got: $out"
out="$(printf '' | /bin/bash "$HOOK" guard-shell cursor)"
[ "$out" = '{"permission":"allow"}' ]; report $((1 - $?)) "[cursor] empty input → allow" "got: $out"

if [ "$ON_MAC" = 1 ]; then
    echo "Shell guard: a session's first database CLI call points at TableStudio"
    nudge() { # nudge <session> <command> — prints the additionalContext, or nothing
        jq -n --arg c "$2" --arg d "$PROJECT" --arg s "$1" \
            '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, session_id: $s, hook_event_name: "PreToolUse"}' |
            TABLESTUDIO_PREFS="$PREFS" /bin/bash "$HOOK" guard-shell claude |
            jq -r 'select(.hookSpecificOutput.permissionDecision == null) | .hookSpecificOutput.additionalContext // empty' 2>/dev/null
    }
    out="$(nudge s1 'psql "$DATABASE_URL" -c "select count(*) from users"')"
    printf '%s' "$out" | grep -q 'ran psql directly'; report $((1 - $?)) "first psql read gets the reminder" "got: $out"
    out="$(nudge s1 'psql "$DATABASE_URL" -c "select 1"')"
    [ -z "$out" ]; report $((1 - $?)) "only once per session" "got: $out"
    out="$(nudge s2 'psql --version')"
    [ -z "$out" ]; report $((1 - $?)) "not for --version" "got: $out"
    out="$(nudge s3 'ls -la')"
    [ -z "$out" ]; report $((1 - $?)) "not for other commands" "got: $out"
    out="$(nudge s4 "$(printf 'cat > a.sh <<%sEOF%s\npsql -c "select 1"\nEOF' "'" "'")")"
    [ -z "$out" ]; report $((1 - $?)) "not for psql inside a file being written" "got: $out"
    out="$(nudge "" 'psql -c "select 1"')"
    [ -z "$out" ]; report $((1 - $?)) "not without a session id" "got: $out"
    out="$(jq -n --arg c 'psql -c "select 1"' --arg d "$PROJECT" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, session_id: "x1", hook_event_name: "PreToolUse"}' |
        TABLESTUDIO_PREFS="$PREFS" /bin/bash "$HOOK" guard-shell codex | jq -r '.hookSpecificOutput.additionalContext // empty')"
    printf '%s' "$out" | grep -q 'ran psql directly'; report $((1 - $?)) "[codex] gets the reminder too" "got: $out"
fi

echo "Session start"
start() { # start <client> <dir> [source]
    jq -n --arg d "$2" --arg s "${3:-startup}" '{hook_event_name: "SessionStart", source: $s, cwd: $d, workspace_roots: [$d]}' |
        TABLESTUDIO_MCP_PORT=1 /bin/bash "$HOOK" session-start "$1"
}
ctx="$(start claude "$PROJECT")"
text="$(printf '%s' "$ctx" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
[ -n "$text" ]; report $((1 - $?)) "[claude] valid SessionStart JSON with context" "got: $ctx"
check() { # check <name> <grep -E pattern> — on $text
    printf '%s' "$text" | grep -Eq -- "$2"
    report $((1 - $?)) "$1" "pattern not found: $2"
}
check_absent() {
    ! printf '%s' "$text" | grep -Eq -- "$2"
    report $((1 - $?)) "$1" "pattern should not appear: $2"
}
check "lists the local DATABASE_URL" 'DATABASE_URL \(\.env\): postgresql, localhost:5432, database "app" — local'
check "flags the production file" 'DATABASE_URL \(\.env\.production\): postgres, db\.acme-internal\.com:5432, database "acme" — remote, production'
check "describes a remote Neon URL" 'REMOTE_URL \(\.env\): postgres, ep-cool-river-123\.us-east-2\.aws\.neon\.tech, database "neondb" — remote'
check "finds the nested app's settings" 'apps/api/\.env'
check "lists the D1 database" 'D1 database "widgets" \(wrangler\.toml\)'
check "detects Prisma" 'Prisma \(prisma/schema\.prisma\)'
check "detects plain SQL migrations" 'Plain SQL migration files in migrations/'
check "detects the compose database" 'postgres:17 \(docker-compose\.yml\)'
check "says TableStudio isn't installed" "TableStudio isn't installed"
check "falls back to matching list_connections" 'match these to list_connections'
check_absent "no connection names without TableStudio" 'TableStudio connection|not saved in TableStudio'
check_absent "never leaks passwords" 'supersecret|topsecret|hunter2|secret@'
check_absent "never leaks usernames" 'neon_user|prod_user|app:'
check_absent "skips .env.example" '\.env\.example'
check_absent "skips HTTPS API URLs" 'supabase\.co'

ctx="$(start cursor "$PROJECT")"
printf '%s' "$ctx" | jq -e '.additional_context | length > 100' >/dev/null 2>&1
report $((1 - $?)) "[cursor] valid sessionStart JSON with context" "got: $ctx"
ctx="$(start codex "$PROJECT")"
printf '%s' "$ctx" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart" and (.hookSpecificOutput.additionalContext | length > 100)' >/dev/null 2>&1
report $((1 - $?)) "[codex] valid SessionStart JSON with context" "got: $ctx"
ctx="$(start claude "$EMPTY")"
[ -z "$ctx" ]; report $((1 - $?)) "silent in a repo with no database" "got: $ctx"
ctx="$(start claude "$PROJECT" resume)"
[ -z "$ctx" ]; report $((1 - $?)) "silent on resume" "got: $ctx"

if [ "$ON_MAC" = 1 ]; then
    echo "Session start: with TableStudio set up"
    text="$(TABLESTUDIO_PREFS="$PREFS" start claude "$PROJECT" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
    check "names the local connection" 'localhost:5432, database "app" — local → TableStudio connection "Acme local" \(id 11111111-1111-4111-8111-111111111111, development\)'
    check "names the production connection" 'database "acme" — remote, production → TableStudio connection "Acme prod" \(id 22222222-[0-9a-f-]+, production, read-only\)'
    check "marks a setting TableStudio doesn't have" 'database "neondb" — remote → not saved in TableStudio'
    check "matches D1 by database id" 'D1 database "widgets" \(wrangler\.toml\) — remote, Cloudflare → TableStudio connection "Widgets D1"'
    check "lists the folder's project" 'project "Project" \(named like this folder\):'
    check "with connections the settings didn't name" '- "Analytics" \(id 55555555-[0-9a-f-]+, postgres, analytics\.example\.com/analytics, production\)'
    check_absent "doesn't repeat a listed connection in the project list" '- "Acme prod"'
    check_absent "leaves sandboxes out" 'Acme sandbox'
    check_absent "never leaks saved usernames" 'prod_user|analyst'
    check "tells the agent to use the ids" 'Pass the id shown as connection_id'
    check "explains the server is closed" "MCP server isn't answering on localhost:1"
    check "says how to reconnect in Claude Code" 'run /mcp and reconnect plugin:tablestudio:tablestudio'

    cp "$PREFS" "$SCRATCH/off.plist"
    plutil -replace mcpServerEnabled -bool false "$SCRATCH/off.plist"
    text="$(TABLESTUDIO_PREFS="$SCRATCH/off.plist" start claude "$PROJECT" | jq -r '.hookSpecificOutput.additionalContext')"
    check "says when the MCP server is off" "MCP server is turned off.*Settings → MCP"

    cp "$PREFS" "$SCRATCH/port.plist"
    plutil -replace mcpServerPort -integer 7500 "$SCRATCH/port.plist"
    text="$(TABLESTUDIO_PREFS="$SCRATCH/port.plist" start claude "$PROJECT" | jq -r '.hookSpecificOutput.additionalContext')"
    check "explains a port mismatch" 'serves MCP on port 7500, but the plugin connects to 1'

    cp "$PREFS" "$SCRATCH/default-port.plist"
    plutil -remove mcpServerPort "$SCRATCH/default-port.plist"
    text="$(TABLESTUDIO_PREFS="$SCRATCH/default-port.plist" start claude "$PROJECT" | jq -r '.hookSpecificOutput.additionalContext')"
    check "an unsaved port is TableStudio's default" 'serves MCP on port 7432, but the plugin connects to 1'

    text="$(TABLESTUDIO_PREFS="$PREFS" start cursor "$PROJECT" | jq -r '.additional_context')"
    check_absent "[cursor] the plugin registers the server, so there's nothing to offer" 'connect-cursor'
    check_absent "[cursor] no duplicate warning without a manual entry" 'registered by hand in Cursor'
    mkdir -p "$HOME/.cursor"
    printf '{"mcpServers":{"tablestudio":{"url":"http://localhost:1"}}}' >"$HOME/.cursor/mcp.json"
    text="$(TABLESTUDIO_PREFS="$PREFS" start cursor "$PROJECT" | jq -r '.additional_context')"
    check "[cursor] spots a manual entry that duplicates the plugin's" 'registered by hand in Cursor.s mcp.json'
    rm -f "$HOME/.cursor/mcp.json"
    rm -rf "$HOME/.cursor"

    printf '{"mcpServers":{"tablestudio":{"type":"http","url":"http://localhost:1"}}}' >"$HOME/.claude.json"
    text="$(TABLESTUDIO_PREFS="$PREFS" start claude "$PROJECT" | jq -r '.hookSpecificOutput.additionalContext')"
    check "spots a duplicate claude mcp add entry" 'claude mcp remove tablestudio'
    rm -f "$HOME/.claude.json"

    codex_text() { TABLESTUDIO_PREFS="${1:-$PREFS}" start codex "$PROJECT" | jq -r '.hookSpecificOutput.additionalContext'; }
    text="$(codex_text)"
    check "[codex] names the connection too" 'TableStudio connection "Acme local"'
    check "[codex] says to start a new session" 'start a new Codex session'
    check_absent "[codex] no Claude Code tool names or commands" 'mcp__plugin_|/mcp|/plugin'
    text="$(codex_text "$SCRATCH/port.plist")"
    check "[codex] port fix is TableStudio's setting" "set TableStudio's MCP port back to 1 \(Settings → MCP\)"
    mkdir -p "$HOME/.codex"
    printf '[mcp_servers.tablestudio]\nurl = "http://localhost:1"\n' >"$HOME/.codex/config.toml"
    text="$(codex_text)"
    check "[codex] spots a duplicate config.toml entry" 'registered by hand in ~/.codex/config.toml'
    rm -rf "$HOME/.codex"

    echo "After a migration is written"
    after() { # after <client> <session> <tool> <file-or-command> [prefs] — prints the context, or nothing
        local input
        if [ "$3" = Bash ] || [ "$3" = Shell ] || [ "$3" = apply_patch ]; then
            input="$(jq -n --arg t "$3" --arg c "$4" --arg d "$PROJECT" --arg s "$2" '{tool_name: $t, tool_input: {command: $c}, cwd: $d, session_id: $s, conversation_id: $s}')"
        else
            input="$(jq -n --arg t "$3" --arg f "$4" --arg d "$PROJECT" --arg s "$2" '{tool_name: $t, tool_input: {file_path: $f}, cwd: $d, session_id: $s, conversation_id: $s}')"
        fi
        printf '%s' "$input" | TABLESTUDIO_PREFS="${5:-$PREFS}" /bin/bash "$HOOK" after-tool "$1" |
            jq -r '.hookSpecificOutput.additionalContext // .additional_context // empty' 2>/dev/null
    }
    out="$(after claude m1 Write "$PROJECT/migrations/002_add_status.sql")"
    printf '%s' "$out" | grep -q 'changed a database migration (migrations/002_add_status.sql)'
    report $((1 - $?)) "a new migration file gets the real-data check" "got: $out"
    out="$(after claude m1 Edit "$PROJECT/migrations/003_more.sql")"
    [ -z "$out" ]; report $((1 - $?)) "only once per session" "got: $out"
    out="$(after claude m2 Edit "$PROJECT/src/app.ts")"
    [ -z "$out" ]; report $((1 - $?)) "not for other files" "got: $out"
    out="$(after claude m3 Edit "$PROJECT/prisma/schema.prisma")"
    printf '%s' "$out" | grep -q 'prisma/schema.prisma'; report $((1 - $?)) "a Prisma schema edit counts" "got: $out"
    out="$(after claude m4 Bash 'npx prisma migrate dev --name add_status')"
    printf '%s' "$out" | grep -q 'prisma migrate dev'; report $((1 - $?)) "generating a migration counts" "got: $out"
    out="$(after claude m5 Bash 'npm test')"
    [ -z "$out" ]; report $((1 - $?)) "not for other commands" "got: $out"
    out="$(after cursor m6 Write "$PROJECT/db/migrate/20250101_add_status.rb")"
    printf '%s' "$out" | grep -q 'Check a migration against real data'; report $((1 - $?)) "[cursor] gets it too" "got: $out"
    out="$(after claude m7 Write "$PROJECT/migrations/004.sql" "$SCRATCH/off.plist")"
    [ -z "$out" ]; report $((1 - $?)) "not when TableStudio's MCP server is off" "got: $out"
    patch="$(printf '*** Begin Patch\n*** Update File: src/app.ts\n@@\n-a\n+b\n*** Add File: migrations/005_add_priority.sql\n+ALTER TABLE t ADD COLUMN priority text;\n*** End Patch')"
    out="$(after codex m8 apply_patch "$patch")"
    printf '%s' "$out" | grep -q 'changed a database migration (migrations/005_add_priority.sql)'
    report $((1 - $?)) "[codex] finds the migration inside an apply_patch" "got: $out"
    out="$(after codex m9 apply_patch "$(printf '*** Begin Patch\n*** Update File: src/app.ts\n@@\n-a\n+b\n*** End Patch')")"
    [ -z "$out" ]; report $((1 - $?)) "[codex] not for a patch that touches no migration" "got: $out"

    echo "MCP headers helper"
    out="$(TABLESTUDIO_PREFS="$PREFS" CLAUDE_CODE_MCP_SERVER_URL=http://localhost:1 /bin/bash "$HOOK" mcp-headers </dev/null)"
    [ "$(printf '%s' "$out" | jq -r '.Authorization')" = 'Bearer test-token-0000' ]; report $((1 - $?)) "prints TableStudio's own token" "got: $out"
    [ "$(printf '%s' "$out" | jq -r '."X-TableStudio-Client"')" = 'claude-code' ]; report $((1 - $?)) "says which client is connecting" "got: $out"
    [ "$(printf '%s' "$out" | jq -r '."X-TableStudio-Project"')" = "$PWD" ]; report $((1 - $?)) "and from which project" "got: $out"
    out="$(/bin/bash "$HOOK" mcp-headers </dev/null 2>/dev/null)"; code=$?
    [ -z "$out" ] && [ "$code" -ne 0 ]; report $((1 - $?)) "fails without a token" "got $code: $out"

    # A fake TableStudio for the bridge and the attribution hook.
    FAKE_PORT=$((20000 + RANDOM % 20000))
    FAKE_LOG="$SCRATCH/fake-server.log"
    : >"$FAKE_LOG"
    python3 tests/fake_mcp_server.py "$FAKE_PORT" "$FAKE_LOG" test-token-0000 &
    FAKE_PID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        curl -s -o /dev/null --max-time 1 -X POST "http://127.0.0.1:$FAKE_PORT/" && break
        sleep 0.3
    done
    cp "$PREFS" "$SCRATCH/fake.plist"
    plutil -replace mcpServerPort -integer "$FAKE_PORT" "$SCRATCH/fake.plist"

    echo "MCP stdio bridge"
    out="$(printf '%s\n' \
        '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' \
        '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
        '{"jsonrpc":"2.0","id":"call-1","method":"tools/call","params":{"name":"list_connections","arguments":{}}}' |
        TABLESTUDIO_PREFS="$SCRATCH/fake.plist" /bin/bash "$HOOK" mcp-stdio cursor)"
    [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 2 ]; report $((1 - $?)) "answers requests, one line each, and nothing for a notification" "got: $out"
    [ "$(printf '%s\n' "$out" | sed -n 2p | jq -r '.id')" = call-1 ]; report $((1 - $?)) "a pretty-printed response comes back as one line" "got: $out"
    last="$(tail -n 1 "$FAKE_LOG")"
    [ "$(printf '%s' "$last" | jq -r '.headers."Authorization"')" = 'Bearer test-token-0000' ]; report $((1 - $?)) "sends TableStudio's token, read from the app" "got: $last"
    [ "$(printf '%s' "$last" | jq -r '.headers."X-TableStudio-Client"')" = cursor ]; report $((1 - $?)) "says which client it is" "got: $last"
    [ "$(printf '%s' "$last" | jq -r '.headers."MCP-Protocol-Version" // .headers."Mcp-Protocol-Version"')" = 2025-06-18 ]; report $((1 - $?)) "sends the protocol version initialize agreed" "got: $last"
    out="$(printf '%s\n' '{"jsonrpc":"2.0","id":5,"method":"tools/list"}' | TABLESTUDIO_PREFS="$SCRATCH/fake.plist" TABLESTUDIO_MCP_PORT=1 /bin/bash "$HOOK" mcp-stdio opencode)"
    [ "$(printf '%s' "$out" | jq -r '.id')" = 5 ] && printf '%s' "$out" | jq -r '.error.message' | grep -q "isn't answering"
    report $((1 - $?)) "a JSON-RPC error when TableStudio isn't running" "got: $out"

    echo "Which chat made a call"
    : >"$FAKE_LOG"
    event='{"session_id":"s-1","tool_use_id":"toolu_1","tool_name":"mcp__plugin_tablestudio_tablestudio__execute_query","tool_input":{"sql":"select 1"},"cwd":"/tmp/p","transcript_path":"/tmp/t.jsonl"}'
    printf '%s' "$event" | TABLESTUDIO_PREFS="$SCRATCH/fake.plist" CLAUDE_PLUGIN_OPTION_PORT="$FAKE_PORT" /bin/bash "$HOOK" agent-event claude
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$FAKE_LOG" ] && break; sleep 0.2; done
    sent="$(grep '/agent/events' "$FAKE_LOG" | tail -n 1 | jq -r '.body')"
    [ "$(printf '%s' "$sent" | jq -r '.client + " " + .hook.tool_use_id + " " + .hook.session_id')" = 'claude-code toolu_1 s-1' ]
    report $((1 - $?)) "reports the session and tool call to TableStudio" "got: $sent"
    : >"$FAKE_LOG"
    printf '%s' '{"conversation_id":"c-1","tool_name":"execute_query","mcp_server_name":"tablestudio","tool_input":{}}' |
        TABLESTUDIO_PREFS="$SCRATCH/fake.plist" /bin/bash "$HOOK" agent-event cursor
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$FAKE_LOG" ] && break; sleep 0.2; done
    grep -q '"conversation_id\\": \\"c-1\\"\|conversation_id.*c-1' "$FAKE_LOG"; report $((1 - $?)) "[cursor] knows TableStudio's tools by mcp_server_name" "got: $(cat "$FAKE_LOG")"
    : >"$FAKE_LOG"
    printf '%s' '{"session_id":"s-2","tool_name":"mcp__github__create_issue","tool_input":{}}' |
        TABLESTUDIO_PREFS="$SCRATCH/fake.plist" /bin/bash "$HOOK" agent-event codex
    sleep 0.6
    [ ! -s "$FAKE_LOG" ]; report $((1 - $?)) "ignores other servers' tools" "got: $(cat "$FAKE_LOG")"
    kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null
fi

echo "Installer"
INST="$SCRATCH/install"
mkdir -p "$INST/xdg/opencode" "$INST/home"
printf '{\n  "model": "anthropic/claude-sonnet-4-5"\n}\n' >"$INST/xdg/opencode/opencode.json"
if command -v osascript >/dev/null 2>&1; then
    XDG_CONFIG_HOME="$INST/xdg" /bin/bash "$HOOK" install opencode >/dev/null 2>&1
    [ "$(jq -r '.model' "$INST/xdg/opencode/opencode.json")" = anthropic/claude-sonnet-4-5 ]; report $((1 - $?)) "[opencode] keeps the settings already in opencode.json" "got: $(cat "$INST/xdg/opencode/opencode.json")"
    jq -e '.plugins | map(select(endswith("tablestudio/opencode"))) | length == 1' "$INST/xdg/opencode/opencode.json" >/dev/null
    report $((1 - $?)) "[opencode] adds the plugin" "got: $(cat "$INST/xdg/opencode/opencode.json")"
    XDG_CONFIG_HOME="$INST/xdg" /bin/bash "$HOOK" install opencode >/dev/null 2>&1
    [ "$(jq '.plugins | length' "$INST/xdg/opencode/opencode.json")" = 1 ]; report $((1 - $?)) "[opencode] running it again adds nothing" "got: $(cat "$INST/xdg/opencode/opencode.json")"
    printf '{ // a comment\n "model": "x" }\n' >"$INST/xdg/opencode/opencode.json"
    out="$(XDG_CONFIG_HOME="$INST/xdg" /bin/bash "$HOOK" install opencode 2>&1)"
    grep -q '"model": "x" }' "$INST/xdg/opencode/opencode.json" && printf '%s' "$out" | grep -q 'has comments'
    report $((1 - $?)) "[opencode] leaves a config with comments alone, and says what to add" "got: $out"
fi
HOME="$INST/home" /bin/bash "$HOOK" install cursor >/dev/null 2>&1
[ -f "$INST/home/.cursor/plugins/local/tablestudio/.cursor-plugin/plugin.json" ] && [ -f "$INST/home/.cursor/plugins/local/tablestudio/cursor-mcp.json" ]
report $((1 - $?)) "[cursor] copies the plugin, MCP entry included, where Cursor loads local plugins" "got: $(ls -a "$INST/home/.cursor/plugins/local/tablestudio" 2>&1)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
