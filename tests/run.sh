#!/bin/bash
# Tests for scripts/tablestudio-hook. Needs jq to build and check JSON (preinstalled on macOS 15+).
# The checks that read TableStudio's settings and saved connections run on macOS only.
#
#   tests/run.sh            run everything
#   tests/run.sh -v         also print each passing case

cd "$(dirname "$0")/.." || exit 1
HOOK="${HOOK:-tablestudio/scripts/tablestudio-hook}"
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
export TABLESTUDIO_OPEN_APP=0 TABLESTUDIO_INSTALL_APP=0 TABLESTUDIO_APPCAST_URL=file:///nonexistent/appcast.xml
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

echo "Plugin version"
# Codex's header helper can't read the manifest, so its version is written into codex-mcp.json.
manifest_version="$(jq -r .version tablestudio/.claude-plugin/plugin.json)"
jq -r '.mcpServers.tablestudio.http_headers_helper' tablestudio/codex-mcp.json | grep -qF "\"X-TableStudio-Plugin\":\"$manifest_version\""
report $((1 - $?)) "codex-mcp.json sends the manifest's version ($manifest_version)" "update X-TableStudio-Plugin in tablestudio/codex-mcp.json"

if [ "$ON_MAC" = 1 ]; then
    echo "Session start: no database in the folder"
    # A copy of the prefs where the user turned agent access off for one connection.
    OFF_PREFS="$(mktemp -d)/sh.tablestudio.plist"
    cp "$PREFS" "$OFF_PREFS"
    plutil -insert agentAccessLevels -json '{"55555555-5555-4555-8555-555555555555":"off","11111111-1111-4111-8111-111111111111":"structure"}' "$OFF_PREFS"
    text="$(TABLESTUDIO_PREFS="$OFF_PREFS" start claude "$EMPTY" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
    check "still gives a note with no database in the folder" 'This folder doesn.t configure a database'
    check "says to choose with use_database" 'call use_database with it'
    check "lists the saved databases" '- "Acme local" \(postgres, local'
    check "marks production as named-only" '- "Acme prod" \(postgres, remote, PRODUCTION: only when the user names it'
    check "marks an untagged remote one" 'untagged: treat as production'
    check "says when agents see structure only" 'Acme local.*agents see structure only'
    check_absent "never lists a connection set to Off" 'Analytics'
    check_absent "leaves sandboxes out of the map" 'Acme sandbox'
    rm -f "$OFF_PREFS"

    echo "Shell guard: TableStudio's own settings for a database, however a command reaches it"
    # A production database whose name says nothing, and two SQLite files the user restricted.
    TAGGED_DIR="$(mktemp -d)"
    TAGGED_PREFS="$TAGGED_DIR/sh.tablestudio.plist"
    cp "$PREFS" "$TAGGED_PREFS"
    TAGGED_CONNECTIONS="[{\"id\":\"66666666-6666-4666-8666-666666666666\",\"name\":\"Shop\",\"kind\":\"postgres\",\"host\":\"127.0.0.1\",\"port\":5434,\"database\":\"shop_main\",\"username\":\"postgres\",\"password\":\"\",\"environment\":\"production\",\"readOnly\":false,\"isSandbox\":false},{\"id\":\"77777777-7777-4777-8777-777777777777\",\"name\":\"Shop dev\",\"kind\":\"postgres\",\"host\":\"127.0.0.1\",\"port\":5434,\"database\":\"shop_dev\",\"username\":\"postgres\",\"password\":\"\",\"environment\":\"development\",\"readOnly\":false,\"isSandbox\":false},{\"id\":\"AAAAAAAA-0000-4000-8000-000000000001\",\"name\":\"Server admin\",\"kind\":\"postgres\",\"host\":\"127.0.0.1\",\"port\":5434,\"database\":\"postgres\",\"username\":\"postgres\",\"password\":\"\",\"environment\":\"production\",\"readOnly\":true,\"isSandbox\":false},{\"id\":\"88888888-8888-4888-8888-888888888888\",\"name\":\"Payroll\",\"kind\":\"sqlite\",\"host\":\"\",\"port\":0,\"database\":\"payroll\",\"filePath\":\"$TAGGED_DIR/payroll.sqlite\",\"password\":\"\",\"isSandbox\":false},{\"id\":\"99999999-9999-4999-8999-999999999999\",\"name\":\"Secrets\",\"kind\":\"sqlite\",\"host\":\"\",\"port\":0,\"database\":\"secrets\",\"filePath\":\"$TAGGED_DIR/secrets.sqlite\",\"password\":\"\",\"isSandbox\":false},{\"id\":\"BBBBBBBB-0000-4000-8000-000000000002\",\"name\":\"Vault\",\"kind\":\"sqlite\",\"host\":\"\",\"port\":0,\"database\":\"vault\",\"filePath\":\"$TAGGED_DIR/Application Support/vault_hidden.sqlite\",\"password\":\"\",\"isSandbox\":false}]"
    plutil -replace postgres_connections -data "$(printf '%s' "$TAGGED_CONNECTIONS" | base64)" "$TAGGED_PREFS"
    plutil -insert agentAccessLevels -json '{"88888888-8888-4888-8888-888888888888":"structure","99999999-9999-4999-8999-999999999999":"off","BBBBBBBB-0000-4000-8000-000000000002":"off"}' "$TAGGED_PREFS"
    tagged() { TABLESTUDIO_PREFS="$TAGGED_PREFS" guard "$@"; }
    tagged deny 'psql -h /tmp/tables-020DA161 -p 5434 -U postgres shop_main -c "UPDATE canary SET note = 1 WHERE id = 1"'
    tagged deny "psql postgresql://postgres@127.0.0.1:5434/shop_main -c 'DELETE FROM canary'"
    tagged deny "python3 -c \"import psycopg2; c = psycopg2.connect(host='127.0.0.1', port=5434, dbname='shop_main', user='postgres'); c.cursor().execute('UPDATE canary SET note = 2')\""
    tagged deny "node -e \"const {Client} = require('pg'); new Client('postgres://postgres@localhost:5434/shop_main').connect().then(c => c.query('DELETE FROM canary'))\""
    tagged deny "PGPORT=5434 PGDATABASE=shop_main psql -h localhost -c 'TRUNCATE canary'"
    tagged deny "sqlite3 $TAGGED_DIR/payroll.sqlite 'SELECT * FROM payroll'"
    tagged deny "sqlite3 -readonly $TAGGED_DIR/secrets.sqlite 'SELECT count(*) FROM secrets'"
    tagged deny "python3 -c \"import sqlite3; print(sqlite3.connect('$TAGGED_DIR/secrets.sqlite').execute('select 1').fetchall())\""
    out="$(jq -n --arg c "sqlite3 $TAGGED_DIR/secrets.sqlite 'select 1'" --arg d "$PROJECT" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' \
        | TABLESTUDIO_PREFS="$TAGGED_PREFS" /bin/bash "$HOOK" guard-shell claude)"
    ! printf '%s' "$out" | grep -q 'Secrets'; report $((1 - $?)) "never names a database set to Off" "got: $out"
    # Reads of production pass, as they do through TableStudio at Read; so does a development write.
    tagged none 'psql -h 127.0.0.1 -p 5434 shop_main -c "SELECT count(*) FROM canary"'
    tagged none 'psql -h 127.0.0.1 -p 5434 shop_dev -c "UPDATE canary SET note = 3"'
    # The user name isn't a database name, unless psql has nothing else to go on.
    tagged none 'psql -h 127.0.0.1 -p 5434 -U postgres shop_dev -c "UPDATE canary SET note = 3"'
    tagged deny 'psql -h 127.0.0.1 -p 5434 -U postgres -c "UPDATE settings SET v = 1"'
    tagged none "sqlite3 $TAGGED_DIR/other.sqlite 'SELECT 1'"
    tagged none 'ls -la'
    # A path with a space, however it's written, a file: URI, and a restricted file by its name alone.
    tagged deny "sqlite3 '$TAGGED_DIR/Application Support/vault_hidden.sqlite' 'select 1'"
    tagged deny "sqlite3 ${TAGGED_DIR}/Application\\ Support/vault_hidden.sqlite 'select 1'"
    tagged deny "python3 -I -c \"import sqlite3; sqlite3.connect('file:$TAGGED_DIR/Application%20Support/vault_hidden.sqlite?mode=ro', uri=True)\""
    tagged deny "python3 -c \"import sqlite3; sqlite3.connect('file:$TAGGED_DIR/secrets.sqlite?mode=ro', uri=True).execute('select 1')\""
    tagged deny "strings $TAGGED_DIR/secrets.sqlite | head"
    tagged deny "cat $TAGGED_DIR/payroll.sqlite > /tmp/copy.bin"
    tagged deny "cp ~/Library/Instances/*/vault_hidden.sqlite /tmp/v.db"
    # What a script or .sql file would run counts as much as what's on the command line.
    printf 'UPDATE canary SET note = 9 WHERE id = 1;\n' >"$TAGGED_DIR/fix.sql"
    printf 'SELECT count(*) FROM canary;\n' >"$TAGGED_DIR/report.sql"
    printf 'import psycopg2\nc = psycopg2.connect(host="127.0.0.1", port=5434, dbname="shop_main")\nc.cursor().execute("UPDATE canary SET note = 7")\nc.commit()\n' >"$TAGGED_DIR/fix_canary.py"
    printf 'import os, psycopg2\nc = psycopg2.connect(os.environ["DATABASE_URL"])\nc.cursor().execute("DELETE FROM canary")\n' >"$TAGGED_DIR/fix_env.py"
    printf 'DATABASE_URL=postgresql://postgres@127.0.0.1:5434/shop_main\n' >"$TAGGED_DIR/.env"
    tagged deny "psql -h 127.0.0.1 -p 5434 -d shop_main -f $TAGGED_DIR/fix.sql"
    tagged deny "psql -h 127.0.0.1 -p 5434 shop_main < $TAGGED_DIR/fix.sql"
    tagged none "psql -h 127.0.0.1 -p 5434 -d shop_main -f $TAGGED_DIR/report.sql"
    tagged deny "psql -h 127.0.0.1 -p 5434 -d shop_main -f $TAGGED_DIR/missing.sql"
    tagged deny "python3 $TAGGED_DIR/fix_canary.py"
    tagged deny "cd $TAGGED_DIR && python3 fix_canary.py"
    tagged deny "python3 fix_env.py" "$TAGGED_DIR"
    tagged deny "$(printf 'python3 <<%sPY%s\nimport psycopg2\nc = psycopg2.connect(host="127.0.0.1", port=5434, dbname="shop_main")\nc.cursor().execute("UPDATE canary SET note = 4")\nPY' "'" "'")"
    tagged deny 'echo "UPDATE canary SET note = 6" | psql -h 127.0.0.1 -p 5434 shop_main'
    tagged deny 'export PGHOST=127.0.0.1 PGPORT=5434 PGDATABASE=shop_main; psql -c "UPDATE canary SET note = 5"'
    # Each part on its own: a development write next to a production read passes.
    tagged none 'psql -h 127.0.0.1 -p 5434 shop_dev -c "CREATE TABLE t (id int)" && psql -h 127.0.0.1 -p 5434 shop_main -c "SELECT count(*) FROM canary"'
    tagged none 'pg_dump -h 127.0.0.1 -p 5434 shop_main | psql -h 127.0.0.1 -p 5434 shop_dev'
    tagged deny 'psql -h 127.0.0.1 -p 5434 shop_dev -c "SELECT 1" && psql -h 127.0.0.1 -p 5434 shop_main -c "DELETE FROM canary"'
    # A script the same command writes, then runs.
    tagged deny "$(printf 'cat > %s/later.py <<%sEOF%s\nimport psycopg2\nc = psycopg2.connect(host="127.0.0.1", port=5434, dbname="shop_main")\nc.cursor().execute("UPDATE canary SET note = 8")\nEOF\npython3 %s/later.py' "$TAGGED_DIR" "'" "'" "$TAGGED_DIR")"
    # The database named through a variable, from the project's .env or one the command sources.
    DEV_DIR="$TAGGED_DIR/devapp"; mkdir -p "$DEV_DIR/app"
    printf 'DATABASE_URL=postgresql://postgres@127.0.0.1:5434/shop_dev\n' >"$DEV_DIR/.env"
    printf 'DATABASE_URL=postgresql://postgres@127.0.0.1:5434/shop_dev\n' >"$DEV_DIR/app/.env"
    printf 'DATABASE_URL=postgresql://postgres@127.0.0.1:5434/shop_main\n' >"$DEV_DIR/app/live.env"
    tagged none 'psql "$DATABASE_URL" -c "CREATE TABLE t (id int)" && psql -h 127.0.0.1 -p 5434 shop_main -c "SELECT 1"' "$DEV_DIR"
    tagged none 'set -a; source app/.env; psql "$DATABASE_URL" -c "ALTER TABLE t ADD COLUMN c int"' "$DEV_DIR"
    tagged deny 'set -a; . app/live.env; psql "$DATABASE_URL" -c "ALTER TABLE t ADD COLUMN c int"' "$DEV_DIR"
    rm -rf "$TAGGED_DIR"

    echo "Session start: no folder open"
    # An empty window runs the hook from the home folder; a project a few levels down isn't this one.
    mkdir -p "$HOME/Desktop/shop"
    cp "$PROJECT/.env" "$HOME/Desktop/shop/.env"
    text="$(TABLESTUDIO_PREFS="$PREFS" start cursor "$HOME" | jq -r '.additional_context' 2>/dev/null)"
    check "says no project folder is open" 'No project folder is open'
    check "still lists the saved databases" '- "Acme local" \(postgres, local'
    check_absent "doesn't take a project under the home folder for this one" "database settings|Desktop/shop"
    text="$(TABLESTUDIO_PREFS="$PREFS" start cursor / | jq -r '.additional_context' 2>/dev/null)"
    check "the filesystem root counts as no folder too" 'No project folder is open'
    rm -rf "$HOME/Desktop"
fi

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
    check "tells the agent to choose the database" 'Call use_database with the id shown'
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
    out="$(after claude m10 Bash "$(printf 'cat >> reports/run.md <<%sEOF%s\nRan npx prisma migrate dev and ALTER TABLE t ADD COLUMN x int.\nEOF' "'" "'")")"
    [ -z "$out" ]; report $((1 - $?)) "not for a report that only quotes a migration command" "got: $out"
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
    # In a project with a database and TableStudio's server not answering, it opens TableStudio,
    # but never a second copy beside one that's open (a development build, say).
    mkdir -p "$SCRATCH/open-bin" "$SCRATCH/Open.app/Contents/MacOS"
    printf '#!/bin/sh\necho "$*" >>"%s/open.log"\n' "$SCRATCH" >"$SCRATCH/open-bin/open"
    chmod +x "$SCRATCH/open-bin/open"
    printf '#!/bin/bash\nwhile :; do sleep 1; done\n' >"$SCRATCH/Open.app/Contents/MacOS/TableStudio"
    chmod +x "$SCRATCH/Open.app/Contents/MacOS/TableStudio"
    headers_opening() { # headers_opening <app path> [prefs] — mcp-headers in the project, `open` recorded
        local hook="$PWD/$HOOK"
        : >"$SCRATCH/open.log"
        (cd "$PROJECT" && PATH="$SCRATCH/open-bin:$PATH" TABLESTUDIO_OPEN_APP=1 TABLESTUDIO_APP_PATH="$1" \
            TABLESTUDIO_PREFS="${2:-$PREFS}" CLAUDE_CODE_MCP_SERVER_URL=http://localhost:1 /bin/bash "$hook" mcp-headers </dev/null >/dev/null 2>&1)
    }
    headers_opening "$SCRATCH/Closed.app"
    grep -q -- "-b sh.tablestudio" "$SCRATCH/open.log"; report $((1 - $?)) "opens TableStudio when it's closed" "open got: $(cat "$SCRATCH/open.log")"
    # The copy that ran last, which the app records, not the one Launch Services knows.
    mkdir -p "$SCRATCH/Dev.app"
    cp "$PREFS" "$SCRATCH/dev-prefs.plist"
    plutil -replace appBundlePath -string "$SCRATCH/Dev.app" "$SCRATCH/dev-prefs.plist"
    headers_opening "$SCRATCH/Closed.app" "$SCRATCH/dev-prefs.plist"
    [ "$(cat "$SCRATCH/open.log")" = "-g -j $SCRATCH/Dev.app" ]; report $((1 - $?)) "opens the copy that ran last" "open got: $(cat "$SCRATCH/open.log")"
    "$SCRATCH/Open.app/Contents/MacOS/TableStudio" &
    OPEN_APP_PID=$!
    headers_opening "$SCRATCH/Open.app"
    kill "$OPEN_APP_PID" 2>/dev/null
    [ ! -s "$SCRATCH/open.log" ]; report $((1 - $?)) "but not a second copy beside one that's open" "open got: $(cat "$SCRATCH/open.log")"
    # Restarting (an update, a rebuild): back a second later, so nothing is opened beside it.
    (sleep 1; exec "$SCRATCH/Open.app/Contents/MacOS/TableStudio") &
    OPEN_APP_PID=$!
    headers_opening "$SCRATCH/Open.app"
    kill "$OPEN_APP_PID" 2>/dev/null
    [ ! -s "$SCRATCH/open.log" ]; report $((1 - $?)) "nor while it restarts" "open got: $(cat "$SCRATCH/open.log")"

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
    out="$(printf '%s\n' \
        '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' \
        '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
        '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_connections","arguments":{}}}' \
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_connections","arguments":{}}}' \
        '{"jsonrpc":"2.0","id":3,"method":"tools/list"}' \
        '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_connections","arguments":{}}}' |
        TABLESTUDIO_PREFS="$SCRATCH/fake.plist" /bin/bash "$HOOK" mcp-stdio cursor)"
    ids="$(printf '%s\n' "$out" | jq -r '.id' 2>/dev/null | sort | tr '\n' ' ')"
    [ "$ids" = "0 1 2 3 4 " ]; report $((1 - $?)) "calls in flight together each come back whole, once" "got ids: $ids, output: $out"
    out="$(printf '%s\n' '{"jsonrpc":"2.0","id":5,"method":"tools/list"}' | TABLESTUDIO_PREFS="$SCRATCH/fake.plist" TABLESTUDIO_MCP_PORT=1 /bin/bash "$HOOK" mcp-stdio opencode)"
    [ "$(printf '%s' "$out" | jq -r '.id')" = 5 ] && printf '%s' "$out" | jq -r '.error.message' | grep -q "isn't answering"
    report $((1 - $?)) "a JSON-RPC error when TableStudio isn't running" "got: $out"

    # An update replaces the plugin under a running bridge: it moves to the new copy by itself.
    SWAP="$SCRATCH/swap"
    mkdir -p "$SWAP" && cp -R tablestudio "$SWAP/tablestudio" && mkfifo "$SWAP/in"
    : >"$FAKE_LOG"
    TABLESTUDIO_PREFS="$SCRATCH/fake.plist" /bin/bash "$SWAP/tablestudio/scripts/tablestudio-hook" mcp-stdio opencode <"$SWAP/in" >"$SWAP/out" &
    SWAP_PID=$!
    exec 7>"$SWAP/in"
    printf '%s\n' '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' \
        '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' >&7
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(wc -l <"$SWAP/out" | tr -d ' ')" -ge 2 ] && break; sleep 0.2; done
    sleep 1.1 # modification times compare to the second
    sed -i '' 's/"version"[[:space:]]*:[[:space:]]*"[^"]*"/"version": "9.9.9"/' "$SWAP/tablestudio/.claude-plugin/plugin.json"
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' '{"jsonrpc":"2.0","id":3,"method":"tools/list"}' >&7
    exec 7>&-
    wait "$SWAP_PID"
    ids="$(jq -r '.id' "$SWAP/out" 2>/dev/null | sort | tr '\n' ' ')"
    first="$(grep -v '/agent/events' "$FAKE_LOG" | head -n 1)"; last="$(grep -v '/agent/events' "$FAKE_LOG" | tail -n 1)"
    [ "$ids" = "0 1 2 3 " ] && [ "$(printf '%s' "$last" | jq -r '.headers."X-TableStudio-Plugin"')" = 9.9.9 ]
    report $((1 - $?)) "an updated plugin takes over a running bridge, with every call answered" "got ids: $ids, last: $last"
    [ "$(printf '%s' "$first" | jq -r '.headers."X-TableStudio-Bridge"')" = "$(printf '%s' "$last" | jq -r '.headers."X-TableStudio-Bridge"')" ] &&
        [ "$(printf '%s' "$last" | jq -r '.headers."MCP-Protocol-Version" // .headers."Mcp-Protocol-Version"')" = 2025-06-18 ]
    report $((1 - $?)) "and keeps the same MCP session" "first: $first, last: $last"

    # Cursor loads Claude Code's copy of the plugin besides its own. Only its own acts.
    CURSOR_HOME="$SCRATCH/cursor-home"
    CURSOR_COPY="$CURSOR_HOME/.cursor/plugins/local/tablestudio"
    mkdir -p "$(dirname "$CURSOR_COPY")" && cp -R tablestudio "$CURSOR_COPY"
    sed -i '' 's/"version"[[:space:]]*:[[:space:]]*"[^"]*"/"version": "8.8.8"/' "$CURSOR_COPY/.claude-plugin/plugin.json"
    : >"$FAKE_LOG"
    printf '%s\n' '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' |
        HOME="$CURSOR_HOME" TABLESTUDIO_PREFS="$SCRATCH/fake.plist" /bin/bash "$HOOK" mcp-stdio cursor >/dev/null
    [ "$(tail -n 1 "$FAKE_LOG" | jq -r '.headers."X-TableStudio-Plugin"')" = 8.8.8 ]
    report $((1 - $?)) "[cursor] another copy hands the MCP bridge to Cursor's own" "got: $(tail -n 1 "$FAKE_LOG")"
    write="$(jq -n --arg d "$PROJECT" '{command: "psql -h db.prod.example.com -c \"DELETE FROM users\"", cwd: $d, workspace_roots: [$d], hook_event_name: "beforeShellExecution"}')"
    out="$(printf '%s' "$write" | HOME="$CURSOR_HOME" /bin/bash "$HOOK" guard-shell cursor)"
    [ "$out" = '{"permission":"allow"}' ]; report $((1 - $?)) "[cursor] and leaves the shell guard to it" "got: $out"
    out="$(printf '%s' "$write" | HOME="$CURSOR_HOME" /bin/bash "$CURSOR_COPY/scripts/tablestudio-hook" guard-shell cursor)"
    [ "$(printf '%s' "$out" | jq -r '.permission')" = deny ]; report $((1 - $?)) "[cursor] which guards as usual" "got: $out"
    out="$(jq -n --arg d "$PROJECT" '{hook_event_name: "sessionStart", workspace_roots: [$d]}' |
        HOME="$CURSOR_HOME" /bin/bash "$HOOK" session-start cursor)"
    [ -z "$out" ]; report $((1 - $?)) "[cursor] and leaves the session note to it" "got: $out"

    echo "After the trial"
    note() {
        jq -n --arg d "$PROJECT" '{hook_event_name: "SessionStart", source: "startup", cwd: $d, workspace_roots: [$d]}' |
            TABLESTUDIO_PREFS="$SCRATCH/fake.plist" TABLESTUDIO_MCP_PORT="$FAKE_PORT" /bin/bash "$HOOK" session-start claude |
            jq -r '.hookSpecificOutput.additionalContext'
    }
    printf 'expired\n' >"$FAKE_LOG.license"
    text="$(note)"
    check "the session note says the trial has ended, and where to buy" 'free trial has ended.*tablestudio\.sh/buy'
    check_absent "and doesn't offer tools that only refuse" 'mcp__plugin_tablestudio_tablestudio__list_connections'
    out="$(TABLESTUDIO_PREFS="$SCRATCH/fake.plist" /bin/bash "$HOOK" doctor 2>&1)"
    printf '%s' "$out" | grep -q 'free trial has ended' && printf '%s' "$out" | grep -q 'tablestudio\.sh/buy'
    report $((1 - $?)) "doctor says the trial has ended, and where to buy" "got: $out"
    rm -f "$FAKE_LOG.license"
    text="$(note)"
    check "during the trial the tools are offered as usual" 'TableStudio is running \(MCP on localhost'

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
: >"$INST/home/.cursor/plugins/local/tablestudio/stale-file"
out="$(HOME="$INST/home" /bin/bash "$HOOK" install cursor 2>&1)"
[ ! -e "$INST/home/.cursor/plugins/local/tablestudio/stale-file" ] && [ -f "$INST/home/.cursor/plugins/local/tablestudio/cursor-mcp.json" ] &&
    [ "$(ls -a "$INST/home/.cursor" | grep -c tablestudio-plugin)" = 0 ] && printf '%s' "$out" | grep -q 'moves to it by itself'
report $((1 - $?)) "[cursor] an update replaces the copy whole, leaving nothing behind" "got: $(ls -a "$INST/home/.cursor" "$INST/home/.cursor/plugins/local/tablestudio" 2>&1) $out"

if [ "$ON_MAC" = 1 ]; then
    echo "Installer: TableStudio itself"
    APPI="$SCRATCH/app-install"
    mkdir -p "$APPI/fake/TableStudio.app/Contents/MacOS" "$APPI/home"
    printf '#!/bin/sh\n' >"$APPI/fake/TableStudio.app/Contents/MacOS/TableStudio"
    (cd "$APPI/fake" && ditto -c -k --keepParent TableStudio.app "$APPI/fake.zip")
    feed() { # feed <file> <build|version|channel>… — a Sparkle feed whose every item is the fake zip
        local file="$1" item build version channel
        shift
        {
            printf '<?xml version="1.0" standalone="yes"?>\n<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>\n'
            for item in "$@"; do
                IFS='|' read -r build version channel <<EOF
$item
EOF
                printf '<item><title>%s</title>' "$version"
                [ -n "$channel" ] && printf '<sparkle:channel>%s</sparkle:channel>' "$channel"
                printf '<sparkle:version>%s</sparkle:version><sparkle:shortVersionString>%s</sparkle:shortVersionString>' "$build" "$version"
                printf '<sparkle:minimumSystemVersion>11.0</sparkle:minimumSystemVersion><enclosure url="file://%s" type="application/octet-stream"/></item>\n' "$APPI/fake.zip"
            done
            printf '</channel></rss>\n'
        } >"$file"
    }
    install_app() { # install_app <feed> [env…] — install with the app missing, into a scratch path
        local feed="$1"
        shift
        env HOME="$APPI/home" TABLESTUDIO_INSTALL_APP=1 TABLESTUDIO_APPCAST_URL="file://$feed" \
            TABLESTUDIO_APP_PATH="$APPI/Applications/TableStudio.app" "$@" /bin/bash "$HOOK" install cursor 2>&1
    }

    feed "$APPI/mixed.xml" '8|2.0.0-beta.1|beta' '7|1.9.0|' '6|1.8.0|'
    out="$(install_app "$APPI/mixed.xml")"
    printf '%s' "$out" | grep -q 'Downloading TableStudio 1\.9\.0'
    report $((1 - $?)) "downloads the newest stable release, not a newer beta" "got: $out"
    printf '%s' "$out" | grep -q "isn't TableStudio's signed, notarized build" && [ ! -e "$APPI/Applications/TableStudio.app" ]
    report $((1 - $?)) "refuses a download that isn't TableStudio's notarized build" "got: $out"
    printf '%s' "$out" | grep -q 'Cursor' && [ -f "$APPI/home/.cursor/plugins/local/tablestudio/.cursor-plugin/plugin.json" ]
    report $((1 - $?)) "still installs the agent plugin when the app couldn't be" "got: $out"

    feed "$APPI/betas.xml" '5|1.0.0-beta.2|beta' '6|1.0.0-beta.3|beta'
    out="$(install_app "$APPI/betas.xml")"
    printf '%s' "$out" | grep -q 'Downloading TableStudio 1\.0\.0-beta\.3'
    report $((1 - $?)) "downloads the newest beta while there's no stable release" "got: $out"

    out="$(install_app "$APPI/mixed.xml" TABLESTUDIO_INSTALL_APP=0)"
    printf '%s' "$out" | grep -q "the app isn't installed" && ! printf '%s' "$out" | grep -q 'Downloading'
    report $((1 - $?)) "TABLESTUDIO_INSTALL_APP=0 leaves the app alone" "got: $out"

    mkdir -p "$APPI/Installed/TableStudio.app"
    cp "$PREFS" "$APPI/prefs.plist"
    /usr/bin/plutil -remove mcpServerEnabled "$APPI/prefs.plist"
    out="$(install_app "$APPI/mixed.xml" TABLESTUDIO_APP_PATH="$APPI/Installed/TableStudio.app" TABLESTUDIO_PREFS="$APPI/prefs.plist")"
    [ "$(/usr/bin/plutil -extract mcpServerEnabled raw -o - "$APPI/prefs.plist" 2>/dev/null)" = true ] && printf '%s' "$out" | grep -q 'MCP server on'
    report $((1 - $?)) "turns on the MCP server of an installed app that never set it" "got: $out"

    /usr/bin/plutil -replace mcpServerEnabled -bool false "$APPI/prefs.plist"
    out="$(install_app "$APPI/mixed.xml" TABLESTUDIO_APP_PATH="$APPI/Installed/TableStudio.app" TABLESTUDIO_PREFS="$APPI/prefs.plist")"
    [ "$(/usr/bin/plutil -extract mcpServerEnabled raw -o - "$APPI/prefs.plist" 2>/dev/null)" = false ] && printf '%s' "$out" | grep -q 'MCP server is off'
    report $((1 - $?)) "leaves a server the user turned off alone when nobody's there to ask" "got: $out"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
