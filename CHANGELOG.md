# Changelog

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
