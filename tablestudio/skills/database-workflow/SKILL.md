---
name: database-workflow
description: How to read and change a project's database safely through TableStudio. Use for any task that touches a real database: looking at its schema or an ER diagram of it, querying or inspecting data, investigating a data bug, fixing or backfilling rows, seeding, adding or changing tables, columns, indexes or constraints, writing or reviewing a migration, or running SQL. Use it too whenever you'd otherwise reach for psql, mysql, sqlite3, wrangler d1 execute, a DATABASE_URL or a one-off script that opens its own connection.
---

# Working with databases through TableStudio

TableStudio is the user's database app on their Mac. Its MCP tools reach their saved connections without credentials, and they come with safety nets a raw `psql` session doesn't have: an exact dry run of a write against the real rows, throwaway sandbox copies, and a review inbox where the user approves changes. Use them for database work instead of `psql`, `mysql`, `sqlite3`, or a script that opens its own connection.

The tool names below are TableStudio's. Your client may show them with a prefix (in Claude Code: `mcp__plugin_tablestudio_tablestudio__list_connections`). If they're deferred, load them by that name before the first call.

## 1. Find the right database before doing anything

The session's **Database context** note, from the TableStudio plugin, usually names the TableStudio connection behind each of the repo's database settings, with its id and environment. Use that id as `connection_id`. The note also says when TableStudio's tools aren't available and what the user should do about it.

Without the note, or for a database it doesn't name:

1. Call `list_connections`. Each connection may carry what the user told TableStudio about it:
   - `project`: the project it belongs to. Prefer connections whose project matches the repo you're working in.
   - `environment`: `development`, `staging` or `production`. Absent means untagged, not development.
   - `read_only`: TableStudio refuses writes to it. Staging still works.
   - `location`: `local` (this Mac), `remote`, or `sandbox` (a throwaway copy, safe to experiment on).
   - `agent_writes`: `direct` means execute_query may write there (when writes are on); `review` means every change goes through `stage_migration` for the user to apply. TableStudio decides this, not you: production, and any remote database the user hasn't tagged development or staging, are `review`.
   - `notes`: the user's notes on the database's conventions (soft deletes, money in cents, naming). Follow them.
2. Match the project first, then confirm with `host`, `port` and `database` against the project's own settings (`.env`, config).
3. If two connections could be the one the user means, or you can't tell whether one is production, **ask**. Don't guess.

Then:

- Call `describe_capabilities` once before planning anything beyond a read. It says whether direct writes, staging and sandboxes are allowed right now, and names the setting behind each. Plan around it rather than finding a limit by being refused.
- `agent_writes: review` (production, or remote and untagged) means never write to it directly: stage changes for review. TableStudio refuses a direct write there anyway, so plan for staging from the start.
- Check `engine` (postgres, mysql, sqlite, d1, clickhouse) before writing SQL, and write that dialect.
- A database that isn't saved in TableStudio can't be reached through its tools. Ask the user to add it in TableStudio. Never ask for a password in chat.
- If a call fails because the database is unreachable, call `connection_status`. When it says a local server is stopped, call `start_local_database` with the `instance_id` it gives you.

## 2. Reading and investigating

- **The whole schema:** `get_schema` returns every table with its columns, keys and foreign keys in one call. Use it for "what's the schema?" and to orient yourself; never call `get_table_ddl` once per table to build the same picture.
- **One table in depth:** `get_table_ddl` gives indexes, defaults, foreign keys and `referenced_by`. Use it on the table you're about to change.
- **A table or column by name:** `search_schema` finds them by fragment. Look names up instead of guessing.
- **An ER diagram, or "show me how the tables relate":** call `er_diagram`. It opens TableStudio's own interactive diagram on the user's screen and returns `diagram_url`; tell them it's open and give them the link. Don't draw a diagram yourself (no Mermaid, ASCII, image or artifact): TableStudio's is live, complete and explorable. `focus_table` centres it on one table.
- Run reads with `execute_query`. Select the columns you need, filter, aggregate, and `LIMIT`. Results are capped (`max_rows`, default 200), so a `truncated` result is not the whole answer.
- Reads run in a read-only transaction with a 30-second limit, on production too, so a read can't change data even through a function. Keep them cheap anyway: on a big production table, filter on an indexed column or use `database_overview` row estimates instead of `count(*)`.
- **A data bug:** reproduce it in the data first. Find the bad rows, count them, and find when they started (`min(created_at)`). Then read the code that writes them. Show the user the query that proves it. Fix the code, and if rows need repairing, that's a data change (section 3).
- Never paste secrets, passwords or connection strings into SQL, code, docs or chat. The one place a connection string belongs is the project's gitignored env file, for a local database (the local-databases skill covers `get_connection_url`).

## 3. Changing data (INSERT, UPDATE, DELETE)

On **PostgreSQL**:

1. Write the statement, then call `preflight_statement` with it. You get a `verdict` (`looks_fine`, `review` or `would_fail`), `dry_run.rows` (exactly how many rows it would change, read-only), cascades into other tables, and what would make it fail.
2. Tell the user what it will do in plain words: "This updates 142 rows in `invoices`; nothing cascades." If the verdict is `would_fail`, fix the statement first. If it's `review`, explain why.
3. Then either:
   - **`agent_writes: direct`, and direct writes are allowed:** `execute_query` with `expected_rows` set to `dry_run.rows`. It commits only if exactly that many rows change, and rolls back otherwise. On a remote PostgreSQL database, TableStudio refuses a data change without `expected_rows`.
   - **`agent_writes: review`, writes not allowed, or anything the user should see first:** `stage_migration` with a clear `title`, the SQL, and a `rationale` that includes the dry-run count ("Voids the 142 duplicate invoices found by …"). It goes to the user's review queue in TableStudio's Agent Center and does **not** run.

On **other engines** there's no dry run: first run a `SELECT count(*)` with the same `WHERE`, report the count, then follow the same execute-or-stage rule.

Before anything destructive on a database that matters (a large DELETE, a DROP, a TRUNCATE), call `create_restore_point` when sandboxes are enabled, and tell the user you did.

## 4. Changing the schema

**If the repo uses a migration tool** (Prisma, Drizzle, Rails, Django, Alembic, Laravel, Supabase, Knex, Ecto, TypeORM, Wrangler D1, or plain numbered SQL files; the session context names it when the plugin detected one), the change belongs in that tool:

1. Make the change the tool's way: edit the schema and generate a migration, or write the migration file.
2. Apply it to the **local development** database with the tool's dev command.
3. Check it against real data (below).
4. Leave applying it anywhere else to the user's normal deploy process. Never run the tool's deploy command against production yourself.

Running `ALTER TABLE` directly when a migration tool owns the schema leaves the tool's history out of sync with the database, which breaks the next deploy.

**If there's no migration tool**, or the user asks for a one-off change to an existing database:

1. Read the table first with `get_table_ddl`. Check `referenced_by` before dropping or renaming anything.
2. Try it on a copy: `create_sandbox` (`data`: `none` for schema only, `sample` for a slice of real rows), run the DDL on the sandbox's connection with `execute_query`, and check it does what you meant.
3. Show the difference with `compare_schemas` (sandbox as `source_connection_id`, the real database as `target_connection_id`).
4. Propose it with `stage_migration` on the real connection. The user applies it from TableStudio.

### Check a migration against real data

A migration that passes on the local database can still fail, or lock the app, where the real rows are. Before you call a migration done, check it read-only against the database it will deploy to (usually staging or production, from the session note or `list_connections`):

1. `get_table_ddl` for each table it alters: how many rows, its indexes, and what references it.
2. For each constraint it adds, `execute_query` the SELECT that finds rows that would break it:
   - `NOT NULL`: `SELECT count(*) FROM t WHERE col IS NULL`
   - `UNIQUE`: `SELECT col, count(*) FROM t GROUP BY col HAVING count(*) > 1 LIMIT 20`
   - a foreign key: child rows whose parent doesn't exist (`LEFT JOIN … WHERE parent.id IS NULL`)
   - a `CHECK`, or a narrower type or length: rows outside the new range

   Any rows means the deploy would fail. Add a backfill or cleanup step to the migration, and say so.
3. On PostgreSQL, flag steps that lock or rewrite a large table (see below) and switch to the safe pattern.
4. When the change is tricky, run it for real on a copy: `create_sandbox` from that connection with `data: "sample"`, `execute_query` the migration's SQL on the sandbox, then `compare_schemas`.

Tell the user what you checked and what you found ("`orders.status` has 0 NULLs across 1.2M rows, so `SET NOT NULL` is safe"). All of this is read-only: never apply the migration anywhere but the local development database.

### Locks on PostgreSQL

- Building an index on a big, busy table: use `CREATE INDEX CONCURRENTLY`. It can't run inside a transaction, so don't wrap that statement in `BEGIN … COMMIT`.
- Adding a `NOT NULL` column with a volatile default, changing a column type, or adding a foreign key can rewrite or lock the table. Say so in the rationale, and consider splitting it into safe steps (add the column nullable, backfill in batches, then `SET NOT NULL`; add a foreign key `NOT VALID`, then `VALIDATE CONSTRAINT`).
- `schema_issues` returns fix SQL with a `lock_impact` for each issue. Read it before proposing a fix.

## 5. After you stage something

- Tell the user it's waiting for their review in TableStudio and **has not run**, and give them the `review_url` from the result as a link. It opens the review with the change's impact (rows it touches, locks, what would fail), a diagram of the schema after it, and an undo plan. Never say a staged change was applied.
- If the user asks for changes, `list_staged_migrations` shows `status: changes_requested` with their note in `review_feedback`. Revise it with `update_staged_migration` (same `migration_id`) rather than staging a second copy, then tell them it's ready to look at again. To withdraw it, use `remove_staged_migration`.
- `list_staged_migrations` also shows whether the user applied, ignored or failed it.

When the user asks what's waiting for them ("what did you stage?", "did my migration run?"), call `list_staged_migrations` for this repo's connections. Report the **pending** ones first, newest first: the title, the connection, when it was staged, its `review_url`, and one line on what it does and how risky it is (does it lock or rewrite a large table, delete data, or lack a `WHERE`?). Then any with **changes requested**, with the user's note, and any that **failed**, with the error. Say plainly that the user applies, sends back or ignores them in TableStudio's Agent Center; you can't apply them yourself.

## 6. When TableStudio says no

- A refusal that names a setting (for example, writes are off) is the user's choice. Tell them which setting would allow it, offer to stage the change instead, and stop. Don't route around it.
- If TableStudio's tools aren't available at all, the session note says why: the app is closed, its MCP server is off (Settings → MCP), or the client isn't connected to it yet. Pass on the fix it gives. In Claude Code, the user can reconnect with `/mcp` once TableStudio is open.
- A refusal with `blocked: production_review_required` or `review_required` means that connection only takes changes through review: stage it. `dry_run_required` means run `preflight_statement` first and pass `expected_rows`. `side_effect_function` means the statement calls something that acts outside a transaction; show the user the SQL instead.
- The plugin's shell guard blocks shell commands that write to production. Treat a block as a signal to use the steps above, not as something to work around.
- Everything you do through TableStudio is shown to the user in its Agent Center, grouped by this conversation.
