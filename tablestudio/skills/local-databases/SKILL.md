---
name: local-databases
description: Set up and manage local development databases on the user's Mac through TableStudio. Use when a project needs a local Postgres, MySQL, ClickHouse or SQLite database, or a DATABASE_URL for one; when a local database refuses connections or is stopped (ECONNREFUSED, "connection refused", "could not connect to server", "Can't connect to MySQL server"); when the user wants a local copy of a remote or production database to develop against; when the user wants a scratch or test database or a safe copy to experiment on; or when a PostgreSQL extension (pgvector, PostGIS, pg_trgm) needs installing.
---

# Local databases with TableStudio

TableStudio manages database servers on this Mac, including ones it adopted from Homebrew or Postgres.app. Prefer its tools over hand-rolled Docker commands or `initdb`, because the result shows up in the user's app as a saved connection.

## "Connection refused" on a local database

1. `connection_status` (no arguments reports every connection). It runs no query, so it works while the database is down, and it tells you whether a local server backs the connection and whether that server is running.
2. If the server is stopped, call `start_local_database` with the `instance_id` it returned (several servers: `instance_ids`, in one call). It's safe to call when the server is already running.
3. If the port is taken by something else, the error names the occupant. Tell the user rather than killing processes.
4. If it still won't start, `search_server_log` with its `instance_id` (and a pattern like `FATAL`) shows why, without reading the log file yourself. It reads every file the server logs to, a Homebrew service's own log included, and `ERROR|FATAL` matches either.

`list_connections` already says, for each local database, whether its server is running (`local_server.running`), whether it's up on the wrong port (`local_server.warning`), and which other saved databases share that server. `list_local_databases` adds what has no saved connection: adopted servers, SQLite files, and servers TableStudio doesn't manage that hold a port. Note the two ids: `instance_id` is the server (start and stop take it), and `connection_id` is the database you query. They aren't interchangeable, and a server holding several databases lists each one's `connection_id` under `connections`.

## A new database

`create_local_database` with a `name` and an `engine`:

- `sqlite` needs nothing installed and is instant. Prefer it when the user just wants somewhere to put data.
- `postgres`, `mysql` and `clickhouse` need that engine's server binaries already on the Mac. TableStudio bundles none, and the tool says so when they're missing. Pass the install hint on rather than installing software unasked.
- When a local server of that engine is already running (`local_server` in `list_connections`, or `list_local_databases`), pass its `instance_id`: the database is created on it, instead of starting another server on another port.

It returns a `connection_id` that's ready to query through TableStudio's tools, and `env_line` (`DATABASE_URL=…`) for the project itself. Then:

1. Check that `.gitignore` covers the env file you'll use (`.env`, `.env.local`). If it doesn't, add it there first.
2. Put `env_line` in that file, using the variable name the project already reads (`DATABASE_URL`, or whatever its config expects).
3. Run the project's migrations (and seed, if it has one) against it.

Never repeat the connection string in chat, and never write it into code, docs or a commit.

Don't call `stop_local_database` as cleanup or to free a port unless the user asked. It disconnects everything using that server, including the user's own windows.

When you're done with local databases or backup files you made for a task, `request_cleanup` with their `connection_ids` and `backup_ids` asks the user to delete them: one request in TableStudio's Inbox, and nothing is removed until they confirm. Sandboxes go with `remove_sandbox` instead.

## A local copy of a remote or production database

When the user wants to develop against a copy of a real database ("make me a local copy of production"), make a real local database and restore a full backup into it. Not `create_sandbox`: a sandbox is a throwaway copy on TableStudio's shared sandbox server, capped at `rows` rows per table, for experiments.

1. The source: the connection the project's settings point at (the session note, or `list_connections`), or `add_connection` from the project's env file when TableStudio doesn't have it yet.
2. Before copying, say what it means: production data, customer data included, ends up on this Mac. If they'd rather have less, offer the schema only, or a sample (that's when a sandbox fits).
3. The local database: `create_local_database` named after the project, with the `instance_id` of a running local server of the same engine when there is one.
4. `backup_database` on the source (keep the default format), then `restore_backup` with that `backup_id` and the new database's `connection_id`. Into an empty database it runs best-effort and reports what the local server couldn't create (`left_out`, `skipped`): tell the user. A big database may come back `running`; `list_backups` shows when it's done. For a different engine, use `migrate_database_check`, then `migrate_database`, instead.
5. Point the project at it: `env_line` from `create_local_database` (or `get_connection_url`). Its login is the database's own and owns everything in it, the restored tables included, so the project's migration tool can change them; it can't read the server's other databases. Put it in the project's gitignored env file, under the variable the project reads. If that file holds the production URL, say you're replacing it and keep the old line commented out, or put the local one in the file the framework reads for local overrides.
6. The copy already has production's schema. Run the project's migrations only to bring it up to code that isn't deployed yet.

## The connection string of an existing local database

When the project needs to reach a local database TableStudio already knows (to fill in a missing `.env`, or to point tests at a sandbox), call `get_connection_url` with its `connection_id` and use `env_line` as above.

- Databases TableStudio created, sandboxes, and local databases without a password are always available.
- A local connection the user saved with their own password is shared only if they allowed it. Otherwise the refusal names the setting: pass that on, or let the user paste the value into the env file themselves. Never ask for a password in chat.
- Remote databases, SSH tunnels and anything tagged production are never shared. Use TableStudio's tools for those.

## A safe copy to experiment on

`create_sandbox` makes a throwaway local copy of any connection (the source is only read):

- `data: "none"` copies the schema only. Best for trying DDL.
- `data: "sample"` copies up to `rows` rows per table. Best for checking a data fix against realistic rows.
- `data: "fake"` generates rows.

Run whatever you like against the sandbox's `connection_id`. `remove_sandbox` deletes it when you're done (sandboxes only), and `list_sandboxes` finds one you made earlier. A sandbox isn't a project's local database: for that, see "A local copy of a remote or production database" above.

What you may do with a sandbox:

- **In it, anything.** A sandbox is Read & write for agents whatever its source is tagged: writes and DDL run directly with `execute_query`, with no staging and no review, even when it's a copy of production. Nothing you do there reaches the source.
- **What you may copy is the source's call.** From a database set to Read or Read & write, any `data`. From one set to Structure only, only `data: "none"`: its rows aren't for agents, so `sample` and `fake` (which learns the source's values) are refused. A database set to Off can't be copied at all.
- A `sample` of production is real data, customer data included, now on this Mac. Say so before making one, and offer `none` or `fake` when the schema is what matters.

## PostgreSQL extensions

`list_extensions` shows what's installed; `pattern: "vector"` answers whether one is available, and `include_available: true` lists the whole catalog. An extension marked `needs_preload` with `preloaded: false` is installed but doesn't work until its library is in `shared_preload_libraries` and the server restarts: tell the user. `add_extension` installs one, or several with `names` (`CREATE EXTENSION IF NOT EXISTS`). Treat it as a schema change: on a shared or production database, propose it rather than running it. And if the repo has a migration tool, add it there so other environments get it too.
