# Changelog

## 0.5.9

- **A script written and run in one command is read before it runs.** `cat > fix.py <<'EOF' … EOF; python3 fix.py` was judged by the file on disk, which didn't exist yet, so it got through. The guard now reads what the heredoc writes.
- **A database named through a variable counts as named.** `psql "$DATABASE_URL" -c "CREATE TABLE …" && psql <production> -c "SELECT …"` was refused as a production write, because the first part's database couldn't be resolved. It now passes when `DATABASE_URL` points at a development database, and env files the command loads (`source app/.env`, `. ./.env`, `--env-file`) are read to find out.
- **License.** The plugin is back under the [MIT License](LICENSE) instead of PolyForm Shield 1.0.0.

## 0.5.8

- **The shell guard reads what a command runs.** `psql -f fix.sql`, `psql < fix.sql`, `python3 fix.py` and a script fed to an interpreter through a heredoc are judged by the SQL and driver calls inside them, and a script that connects with `DATABASE_URL` is matched through the project's environment. A `.sql` file the guard can't read counts as a write. Before, only the command line was read, so a file sent a write to production straight past it.
- **SQLite files are recognized however they're written.** A path with spaces (quoted, with `\ ` or `%20`), a `file:` URI, `~`, and, for a file set to Off or Structure only, its name alone, so a glob or a copy is caught too. `cat`, `strings` and `cp` on such a file are refused, since they read its rows as well.
- **Each part of a command is judged on its own.** A development write next to a production read passes; a part that writes without naming a database (SQL in a heredoc, `export DATABASE_URL=…; prisma migrate deploy`) still counts against every database the command names.
- The migration reminder no longer fires for text that only quotes a migration command, such as a report written with a heredoc.
- Skills: `statement_timeout`, a backfill and its `SET NOT NULL` checked together with `statements`, a local copy's login owning its tables, and `list_connections` without `shared_with`.

## 0.5.7

- **The shell guard follows TableStudio's settings, not names.** It knows the user's saved databases, so a command or script that reaches one is matched however it's addressed: a URL, a host or Unix socket with a port and database name, `psql`/`mysql` flags and variables, a Python or Node driver's connect call, or a SQLite file. A database set to Off or Structure only is refused outright, reads included; one tagged production refuses writes even when its name doesn't say so. Before, a production database called `shop` was unprotected, and nothing stopped a script or `sqlite3`.
- **OpenCode checks shell commands on the tool itself too.** Its permission hook alone didn't see every command, so the guard also runs before each shell call and stops a refused one. Each decision is logged to `~/Library/Logs/TableStudio/opencode-plugin.log`, never with the command.
- Skills: `preflight_statement` checks schema changes against the real data, `stage_migration` returns the same checks, hand-offs wait in the Inbox instead of opening windows, `er_diagram` returns a link (`open: true` to show it), `list_connections` takes filters, and `request_cleanup` asks the user to delete what an agent made. The local-databases skill says what agents may do with a sandbox: anything inside it, directly, while the source's own level decides what may be copied into one.

## 0.5.6

- **No second TableStudio, and the right one.** Finding TableStudio's MCP server not answering, the plugin opened the app with macOS's default copy, usually the one in /Applications. It did that even while TableStudio was open (busy, say) or restarting (an update, a rebuild in Xcode), so a second, often older copy started beside it and took the agents' port. The plugin now waits for a copy that's open, gives a restart two seconds to come back, and then opens the copy that last ran (TableStudio records where it lives), not just the one in /Applications.

## 0.5.5

- **Updates reach a running Cursor.** Cursor loads Claude Code's copy of this plugin as well as its own, and its one TableStudio MCP server could come from either: often Claude Code's, at whatever version Claude Code had, so Cursor kept running an old plugin after its own was updated, while every hook ran twice. Inside Cursor, any other copy now hands the MCP bridge to Cursor's own and stays out of the hooks. A Cursor that ran 0.5.4 or older needs quitting (⌘Q) and reopening once; closing its windows isn't enough.
- **The MCP bridge moves to an update by itself.** When an update replaces the plugin under a running bridge (Cursor, OpenCode), it finishes the calls in flight and carries on as the new copy at its next call, in the same session, with no restart.
- Installing into Cursor copies the plugin beside the old one and swaps it in whole, so a running Cursor never reads a half-written copy.
- Installing into Claude Code also updates older installs made for one repo only, which otherwise stay recorded at their old version.
- Doctor shows Cursor's plugin version, and says when Cursor also loads an older Claude Code copy.

## 0.5.4

- **Cursor loads the database-workflow skill again.** Its description had an unquoted colon, which strict YAML readers (Cursor's) reject, so Cursor listed only the other two skills while the rules told agents to follow this one.
- The skills match what the tools now do: `describe_capabilities` only when `list_connections` doesn't already answer it, a `local_server.warning` for a stopped server whose port another server holds, `already_fast` only when no index is proven, hypopg installed only on development databases, and log search across a Homebrew service's own log.

## 0.5.3

- **When TableStudio is slow, agents still connect.** The header script and session note used to take a slow answer from TableStudio (a busy Mac) for a closed app, then open it and wait, long enough that Claude Code gave up on the token and showed an OAuth "Dynamic Client Registration" error instead. A slow app now gets the token straight away, and the session note says TableStudio is busy rather than missing.
- **No folder open.** From the home folder or `/` (Cursor's empty window, a terminal in `~`), the session note no longer reports a project a few levels down as this one, and it's fast again. When TableStudio's saved databases can't be read, the note still says when its tools aren't reachable and how to fix it.
- **The Cursor bridge runs calls side by side**, so a long check no longer holds up the calls behind it.
- The session note only says to `use_database` "with the id shown" when it shows one.
- Skills and rules cover the new list arguments (`schema_issues` `tables`, `optimize_query` `queries`, `start_local_database` `instance_ids`, `add_extension` `names`), never mirroring a sandbox, opt-in migrate scripts, `pg_stat_statements` and `hypopg` blocked answers, `agent_changes`, and a server on the wrong port. Reads are `read_query` everywhere, including the rules and the migration reminder. The Cursor rule says what to do when Cursor starts a chat before the session note arrives.

## 0.5.2

- **One command installs everything.** `curl -fsSL https://tablestudio.sh/install | bash` now installs TableStudio itself when it isn't on the Mac: the newest release from its update feed (the newest beta until there's a stable one), checked to be TableStudio's own signed, notarized build before it's put in `/Applications`. It turns the MCP server on, asks which of the agents it found to install into (Enter for all), and opens TableStudio, so the agent has its tools from the first session. Without a terminal to ask, it goes ahead with all of them, and never turns back on an MCP server the user turned off. `TABLESTUDIO_INSTALL_APP=0` skips the app.
- When TableStudio isn't installed, doctor and the session note give that command instead of the website.
- **After the trial**, the session note and doctor say TableStudio's free trial has ended, with where to buy and how to enter a key, instead of offering tools that only return that notice. Needs the TableStudio update that keeps its MCP server answering after the trial (it reports the license at `/license`); with an older app nothing changes.

## 0.5.1

- Every call carries the plugin's version, so TableStudio's Agent Center shows each agent's plugin version and offers an update only to the agents that need one.
- After writing a Drizzle or Prisma migration file, agents give the user the link to it in TableStudio's Migrations window (`pending_repo_migrations` from `use_database`).
- **`update_connection`.** Agents can rename a connection, file it under an existing project (`list_connections` now lists `projects`; a new one needs `create_project: true`), tag it, or make it read-only. Changes that let agents do the same or less happen at once. One that would let them do more (a production or remote database tagged development, a production tag removed, read-only off) becomes a permission request in TableStudio, which the user allows with Touch ID while the call waits. Agent access and the user's notes stay theirs.
- **`add_connection`.** When a database the project uses isn't in TableStudio, agents add it from the project's settings: TableStudio reads the env file and its password itself, and saves the connection only if it connects. The session note and skill point to it instead of asking the user.
- **A local copy of production** is a real local database, not a sandbox: the local-databases skill (the one agents load for "make me a local copy") now walks through it. Create the database on the local server that's already running (`create_local_database` with `instance_id`), back up production, restore into it (best-effort into an empty database, reporting what the local server couldn't create), and point the project's env file at it, keeping the production line commented out. It says first that a full copy puts production data on the Mac. Sandboxes are for experiments: capped per table, on TableStudio's sandbox server.
- **Backups, restores and copies.** The skill covers TableStudio's new `backup_database`, `list_backups`, `restore_backup`, `migrate_database_check` and `migrate_database`: agents back up with the Backup window's options, and restore or copy a database themselves only into a sandbox or a database on this Mac they may write to, after a restore point. Anything else opens the Restore or Migrate window for the user to run.
- **License.** From this version the plugin is under the [PolyForm Shield License 1.0.0](LICENSE) instead of MIT: use, change and share it for anything except a product that competes with TableStudio.

## 0.5.0

- **A working database per chat.** Agents call `use_database` once they know which database the user means; later calls can leave `connection_id` out, and TableStudio's Agent Center shows each chat's working database. Without one, nothing defaults to production.
- **Agent access per database.** Off, Structure only, Read, or Read & write, set in the Agent Center. The skills and session note follow it, and a database set to Off never appears in the session note.
- **`read_query` for reads.** Annotated read-only, so clients that ask before non-read-only tools (Codex) run reads without asking. Dry runs and Query Lab tools are read-only too.
- **New tools:** `active_queries` and `cancel_query` (refused on production), `remove_sandbox`, `search_server_log`, and `execute_query` with `statements` for one transaction held to each statement's count.
- **Links:** `compare_url` opens a schema diff in TableStudio, `app_url` opens a table or sandbox, and `this_chat_activity` opens the chat's activity in the Agent Center.
- **Always a session note.** In a folder with no database settings, the note lists the user's databases (production marked, Off ones left out) and says to choose one with `use_database`.
- **Hooks report before the call** (Claude Code, Codex, and OpenCode's new before-hook), so the call knows its chat while it runs, and Codex chats are attributed reliably.
- **Claude Code installs for every project.** `install.sh claude` installs and enables the plugin at user scope; doctor flags an install enabled for one repo only.
- OpenCode chat titles no longer start with a stray quote.
- The skill covers `cancel_query` with several pids or `min_seconds`, sizes in `list_tables`, exact counts in `get_schema`, and partial sandbox copies.

## 0.4.2

- **One call, not one per thing.** The skills, Cursor rules and session note send agents to TableStudio's list forms instead of a call per item: `get_table_ddl` with `tables` (and `row_counts: "exact"`), `list_tables` with `exact_counts`, `search_schema` with `patterns`, `execute_query` with `queries` (reads), `preflight_statement` with `statements`, and a whole health check, for one database or every local one, as a single `database_health` call with `include` and `connection_ids` / `scope: "local"`. In test chats these turned 59 calls into about 30. Needs the TableStudio update that adds the list forms.
- "What databases do I have, and which are running?" is one `list_connections` call: it now reports each local database's server and whether it's running.

## 0.4.1

- The skill, Cursor rule and session note use TableStudio's `get_schema` and `er_diagram` (below), so a schema question is one call and an ER diagram is TableStudio's own, with a link.

## 0.4.0

- **OpenCode.** One plugin entry gives OpenCode everything the other clients get: TableStudio's MCP server (no token to copy), the skills, the database note in the system prompt, and the shell guard as OpenCode permission rules, so a remote write gets OpenCode's own approval prompt and a production write is denied. Install with `opencode plugin add git+https://github.com/tablestudioapp/plugins.git` or `./install.sh opencode`.
- **Cursor connects on its own.** The Cursor plugin now registers TableStudio's MCP server itself, through a small stdio bridge that reads the token from the app, so there's no `mcp.json` entry with a token to add.
- **One-command install and a doctor.** `install.sh` installs into every agent on the Mac (or the ones you name) and ends with a check of TableStudio and each agent, with the fix for anything missing. `./install.sh --doctor` runs just the check.
- **The Agent Center.** Each TableStudio call is reported with the conversation that made it, so TableStudio's new Agent Center shows activity by chat, links a staged change to the conversation that proposed it, and can reopen it. Needs the TableStudio update that adds the Agent Center.
- **Reviews and revisions.** The skill tells the agent to share the `review_url` it gets from `stage_migration`, to read `review_feedback` when you ask for changes, and to revise in place with `update_staged_migration`.
- **Safety the app enforces.** The skill now plans around `agent_writes` from `list_connections` (production and untagged remote databases take changes only through review) and knows that reads run read-only in the database. Needs the TableStudio update that adds them.
- **Schemas and ER diagrams.** "What's the schema?" is one `get_schema` call instead of a `get_table_ddl` per table, and "show me an ER diagram" opens TableStudio's interactive diagram (`er_diagram`) with a link for the chat, instead of the agent drawing one. Needs the TableStudio update that adds both tools.
- **Fewer false alarms.** The shell guard and the CLI reminder ignore text that's only searched, printed or written: a `grep` pattern, a `git commit` message, `find` without `-exec`.
- **`mcp-stdio` bridge** for any MCP client that launches a command (Claude Desktop, VS Code, Windsurf, Zed, Gemini CLI).


## 0.3.0

- **Codex support.** The same plugin now installs in Codex: the skills, TableStudio's MCP server (no token to copy, read from the app like in Claude Code), the session note, the shell guard and the migration and CLI reminders. Codex can't ask you to approve a command, so writes to remote databases that would ask in Claude Code are stopped in Codex, and the agent asks you to run them yourself. Codex plugins have no settings, so it connects to TableStudio's default port, 7432.

## 0.2.1

- **Local connection strings.** When the agent creates a local database, it gets the connection string and writes it into the project's gitignored `.env`. For other local databases it uses TableStudio's new `get_connection_url`: databases TableStudio created and passwordless ones are always shared, ones you saved with your own password only if you allow it (Settings → MCP → Security), and remote, tunnelled or production ones never. Needs the TableStudio update that adds the tool.
- Removed the slash commands (`/tablestudio:review`, `/tablestudio:health`, `/tablestudio:optimize`). The skills cover them and load on their own; ask "what's waiting for my review?" in your own words.

## 0.2.0

- **No token to copy.** Claude Code reads TableStudio's MCP token from the app each time it connects (a `headersHelper`), so installing the plugin is the whole setup, and a regenerated token is picked up on its own. The `mcp_token` setting is gone.
- **The session note names the connection.** Each database setting in the repo, and each D1 database in its `wrangler` config, is matched to the TableStudio connection that is that database, with its id and environment. Settings with no saved connection are marked, and connections in a TableStudio project named like the repo are listed.
- **The session note diagnoses setup.** It tells the agent exactly what's wrong when TableStudio's tools aren't available (not installed, MCP off, port mismatch, token refused, not registered in Cursor) and how to fix it, and spots a duplicate `claude mcp add` entry.
- **TableStudio opens itself.** In a repo with a database, a closed TableStudio with its MCP server turned on is opened hidden in the background. `TABLESTUDIO_OPEN_APP=0` turns this off.
- **Check migrations against real data.** After the agent writes a migration or runs a migration generator, it's reminded (once per session) to check it read-only against the database it will deploy to. New skill section and a Cursor rule for migration files.
- **Fewer raw CLI calls.** The first `psql`, `mysql` or `sqlite3` call in a session points the agent at TableStudio's tools.
- Cursor: `connect-cursor` opens Cursor's install prompt for TableStudio's MCP server.
- Shell guard: text inside a heredoc that's written to a file is no longer read as a command, and read-only `wrangler d1 execute --command` and `turso db shell` queries pass without asking.

## 0.1.0

- First release for Claude Code and Cursor.
- Skills: `database-workflow`, `query-performance`, `local-databases`.
- Commands: `/tablestudio:review`, `/tablestudio:health`, `/tablestudio:optimize`.
- Session note describing the repo's databases and migration tooling (credentials never included).
- Shell guard: blocks writes to production databases, asks before writes to other remote databases.
- Claude Code: registers TableStudio's local MCP server, with the token kept in the system keychain.
