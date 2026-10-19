# Changelog

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
