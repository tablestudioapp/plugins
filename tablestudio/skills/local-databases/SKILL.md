---
name: local-databases
description: Set up and manage local development databases on the user's Mac through TableStudio. Use when a project needs a local Postgres, MySQL, ClickHouse or SQLite database, or a DATABASE_URL for one; when a local database refuses connections or is stopped (ECONNREFUSED, "connection refused", "could not connect to server", "Can't connect to MySQL server"); when the user wants a scratch or test database or a safe copy to experiment on; or when a PostgreSQL extension (pgvector, PostGIS, pg_trgm) needs installing.
---

# Local databases with TableStudio

TableStudio manages database servers on this Mac, including ones it adopted from Homebrew or Postgres.app. Prefer its tools over hand-rolled Docker commands or `initdb`, because the result shows up in the user's app as a saved connection.

## "Connection refused" on a local database

1. `connection_status` (no arguments reports every connection). It runs no query, so it works while the database is down, and it tells you whether a local server backs the connection and whether that server is running.
2. If the server is stopped, call `start_local_database` with the `instance_id` it returned. It's safe to call when the server is already running.
3. If the port is taken by something else, the error names the occupant. Tell the user rather than killing processes.
4. If it still won't start, `search_server_log` with its `instance_id` (and a pattern like `FATAL`) shows why, without reading the log file yourself.

`list_connections` already says, for each local database, whether its server is running (`local_server.running`) and which other saved databases share that server. `list_local_databases` adds what has no saved connection: adopted servers, SQLite files, and servers TableStudio doesn't manage that hold a port. Note the two ids: `instance_id` is the server (start and stop take it), and `connection_id` is the database you query. They aren't interchangeable, and a server holding several databases lists each one's `connection_id` under `connections`.

## A new database

`create_local_database` with a `name` and an `engine`:

- `sqlite` needs nothing installed and is instant. Prefer it when the user just wants somewhere to put data.
- `postgres`, `mysql` and `clickhouse` need that engine's server binaries already on the Mac. TableStudio bundles none, and the tool says so when they're missing. Pass the install hint on rather than installing software unasked.

It returns a `connection_id` that's ready to query through TableStudio's tools, and `env_line` (`DATABASE_URL=…`) for the project itself. Then:

1. Check that `.gitignore` covers the env file you'll use (`.env`, `.env.local`). If it doesn't, add it there first.
2. Put `env_line` in that file, using the variable name the project already reads (`DATABASE_URL`, or whatever its config expects).
3. Run the project's migrations (and seed, if it has one) against it.

Never repeat the connection string in chat, and never write it into code, docs or a commit.

Don't call `stop_local_database` as cleanup or to free a port unless the user asked. It disconnects everything using that server, including the user's own windows.

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

Run whatever you like against the sandbox's `connection_id`. The user discards it in one click; you can't delete it. Use `list_sandboxes` to reuse one you made earlier.

## PostgreSQL extensions

`list_extensions` shows what the server can install and what's already installed. `add_extension` installs one (`CREATE EXTENSION IF NOT EXISTS`). Treat it as a schema change: on a shared or production database, propose it rather than running it. And if the repo has a migration tool, add it there so other environments get it too.
