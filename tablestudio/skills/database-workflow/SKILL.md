---
name: database-workflow
description: How to read and change a project's database safely through TableStudio. Use for any task that touches a real database, such as looking at its schema or an ER diagram of it, querying or inspecting data, investigating a data bug, fixing or backfilling rows, seeding, adding or changing tables, columns, indexes or constraints, writing or reviewing a migration, or running SQL. Use it too whenever you'd otherwise reach for psql, mysql, sqlite3, wrangler d1 execute, a DATABASE_URL or a one-off script that opens its own connection.
---

# Working with databases through TableStudio

TableStudio is the user's database app on their Mac. Its MCP tools reach their saved connections without credentials, and they come with safety nets a raw `psql` session doesn't have: an exact dry run of a write against the real rows, throwaway sandbox copies, and a review inbox where the user approves changes. Use them for database work instead of `psql`, `mysql`, `sqlite3`, or a script that opens its own connection.

The tool names below are TableStudio's. Your client may show them with a prefix (in Claude Code: `mcp__plugin_tablestudio_tablestudio__list_connections`). If they're deferred, load them by that name before the first call.

## 1. Find the right database before doing anything

The session's **Database context** note, from the TableStudio plugin, usually names the TableStudio connection behind each of the repo's database settings, with its id and environment. Call `use_database` with that id first: it makes it this chat's working database, so later calls can leave `connection_id` out, and it returns what you need to start (environment, `agent_access`, whether the server is running, the tables with row estimates, and links). The note also says when TableStudio's tools aren't available and what the user should do about it.

Without a project database, nothing is chosen for you, and a production database is never picked by default. When the user names a database ("my todo-app database", "the analytics one"), it's almost always one of their TableStudio connections, even when it isn't this repo's: find it with `list_connections` rather than searching the repo for a file. `use_database` it when the chat is about it; pass `connection_id` explicitly for a one-off call to another database, and call `use_database` again to switch.

Without the note, or for a database it doesn't name:

1. Call `list_connections` (with `project`, `environment`, `location` or `search` when the inventory is long). Each connection may carry what the user told TableStudio about it:
   - `project`: the project it belongs to. Prefer connections whose project matches the repo you're working in.
   - `environment`: `development`, `staging` or `production`. Absent means untagged, not development.
   - `read_only`: TableStudio refuses writes to it. Staging still works.
   - `location`: `local` (this Mac), `remote`, or `sandbox` (a throwaway copy: you read and write it directly, even when its source is production).
   - `agent_writes`: `direct` means execute_query may write there (when writes are on); `review` means every change goes through `stage_migration` for the user to apply. TableStudio decides this, not you: production, and any remote database the user hasn't tagged development or staging, are `review`.
   - `notes`: the user's notes on the database's conventions (soft deletes, money in cents, naming). Follow them.
   - `agent_access`: what the user lets agents do there. `structure`: schema, plans and counts, never row values. `read`: reads only; every change goes to review. `read_write`: writes follow `agent_writes`. A database set to Off isn't listed at all; don't go looking for it.
   - `agent_changes`: the finer rule, which wins over `agent_writes`: for each kind of change (`data`, `schema`, `destructive`), `direct`, `review` (stage it) or `never` (don't stage it either).
   - `local_server`: for a database on this Mac, its server, and whether that server is `running` (connections with the same `instance_id` are databases on one server). A `warning` means its connections won't reach it: the server is up on a different port (`listening_port`), or it's stopped and another server holds its port. Pass the warning on. The list ends with `summary` counts, so "what databases do I have, and which are running?" is this one call: don't add `connection_status` to answer it. `list_local_databases` is only for servers with no saved database.
2. Match the project first, then confirm with `host`, `port` and `database` against the project's own settings (`.env`, config).
3. If two connections could be the one the user means, or you can't tell whether one is production, **ask**. Don't guess.

Then:

- `agent_writes` and `agent_changes` in `list_connections` already say where each kind of change may go. Call `describe_capabilities` only when you need to know whether staging or sandboxes are turned on, or which setting allows something.
- `agent_writes: review` (production, or remote and untagged) means never write to it directly: stage changes for review. TableStudio refuses a direct write there anyway, so plan for staging from the start.
- Check `engine` (postgres, mysql, sqlite, d1, clickhouse) before writing SQL, and write that dialect.
- A database that isn't saved in TableStudio: add it with `add_connection`, passing the project folder as `project_path` (plus `env_file` and `env_var` when it lists several). TableStudio reads the settings and the password from the file itself, and saves the connection only if it connects. Don't copy a password out of a file into `connection_string`: pass the project instead. Never ask for a password in chat. A remote database you add is saved untagged (or `production` if you say so); only the user marks one development or staging.
- To tidy a saved connection, `update_connection`: rename it, file it under a project (pick one from `list_connections`' `projects`; `create_project: true` only for a genuinely new one), tag it, or make it read-only. Changes that let agents do the same or less happen at once (tagging production, filing, renaming, read-only on). One that would let agents do more (a production or remote database tagged development or staging, a production tag removed, read-only off) is asked of the user in TableStudio, who allows it with Touch ID, and the call waits for the answer: `updated`, `denied` (leave it and don't ask again), or `waiting_for_user` (tell them it's waiting in TableStudio; calling again with the same change checks without asking twice). Only ask for what the user asked you to do. Agent access and the user's notes are theirs alone.
- If a call fails because the database is unreachable, call `connection_status`. When it says a local server is stopped, call `start_local_database` with the `instance_id` it gives you (several stopped servers: `instance_ids`, one call).

**One call, not one per thing.** The tools take lists. Use them instead of calling a tool once per table, database, word or query:

| Instead of | Call |
|---|---|
| `get_table_ddl` once per table | `get_table_ddl` with `tables: [...]` (and `row_counts: "exact"` for exact counts) |
| a hand-written `count(*)` or size query for every table | `list_tables` with `exact_counts: true` (it has sizes too), or `get_schema` with `row_counts: "exact"` |
| `cancel_query` once per pid | `cancel_query` with `pids: [...]`, or `min_seconds` for every query over that age |
| `search_schema` once per word | `search_schema` with `patterns: [...]` |
| several separate SELECTs | `read_query` with `queries: [...]` (up to 10) |
| one write per call for a multi-step change | `execute_query` with `statements: [...]` and `expected_rows: [...]`: one transaction |
| `preflight_statement` once per step of one change | `preflight_statement` with `statements: [...]`, in order |
| `database_health`, `database_overview` and `schema_issues` per database | `database_health` with `include: ["overview", "schema_issues"]`, plus `connection_ids: [...]` or `scope: "local"` |
| `schema_issues` once per table | `schema_issues` with `tables: [...]` (up to 20) |
| `optimize_query` once per statement | `optimize_query` with `queries: [...]` (up to 10) |
| `start_local_database` once per server | `start_local_database` with `instance_ids: [...]` |
| `add_extension` once per extension | `add_extension` with `names: [...]` |

## 2. Reading and investigating

- **The whole schema:** `get_schema` returns every table with its columns, keys and foreign keys in one call. Use it for "what's the schema?" and to orient yourself; never call `get_table_ddl` once per table to build the same picture.
- **Tables in depth:** `get_table_ddl` gives indexes, defaults, foreign keys, `referenced_by` and a row estimate. Use it on the tables you're about to change, all of them in one call with `tables`.
- **Row counts:** `list_tables` gives estimates; `exact_counts: true` (or `get_table_ddl` with `row_counts: "exact"`) counts them exactly, skipping tables too big to count cheaply and saying so.
- **A table or column by name:** `search_schema` finds them by fragment (`patterns` for several). Look names up instead of guessing.
- **An ER diagram, or "show me how the tables relate":** call `er_diagram`. It returns `diagram_url`, a link that opens TableStudio's own interactive diagram; give it to the user. Pass `open: true` as well only when they asked to see it now: nothing opens on their screen otherwise. Don't draw a diagram yourself (no Mermaid, ASCII, image or artifact): TableStudio's is live, complete and explorable. `focus_table` centres it on one table.
- Run reads with `read_query` (several independent ones at once with `queries`). It can never change anything, so clients run it without asking; keep `execute_query` for writes. Select the columns you need, filter, aggregate, and `LIMIT`. Results are capped (`max_rows`, default 100; 50 per query in `queries`), so a `truncated` result is not the whole answer.
- **What's running right now** ("why is it slow?", "what's holding the lock?"): `active_queries`. To stop stuck queries on a development or local database, `cancel_query` with their `pids`, or `min_seconds: 60` for every query over a minute in one step. On production it's refused: tell the user the pid and the query.
- Reads run in a read-only transaction with a 30-second limit, on production too, so a read can't change data even through a function. Keep them cheap anyway: on a big production table, filter on an indexed column or use `database_overview` row estimates instead of `count(*)`.
- **A data bug:** reproduce it in the data first. Find the bad rows, count them, and find when they started (`min(created_at)`). Then read the code that writes them. Show the user the query that proves it. Fix the code, and if rows need repairing, that's a data change (section 3).
- Never paste secrets, passwords or connection strings into SQL, code, docs or chat. The one place a connection string belongs is the project's gitignored env file, for a local database (the local-databases skill covers `get_connection_url`).

## 3. Changing data (INSERT, UPDATE, DELETE)

On **PostgreSQL**:

1. Write the statement, then call `preflight_statement` with it. You get a `verdict` (`looks_fine`, `review` or `would_fail`), `dry_run.rows` (exactly how many rows it would change, read-only), cascades into other tables, and what would make it fail. A change made of several statements (delete the children, then the parents) goes in one call as `statements`, in order: `sequence_notes` says when a later statement fails alone only because an earlier one hasn't removed the rows that block it yet.
   If the request names something the data doesn't have (no `status` column for "cancelled orders", no flag for "test accounts"), stop and ask the user what it means. Don't invent a definition and stage it.
2. Tell the user what it will do in plain words: "This updates 142 rows in `invoices`; nothing cascades." If the verdict is `would_fail`, fix the statement first. If it's `review`, explain why.
3. Then either:
   - **`agent_writes: direct`, and direct writes are allowed:** `execute_query` with `expected_rows` set to `dry_run.rows`. It commits only if exactly that many rows change, and rolls back otherwise. On a remote PostgreSQL database, TableStudio refuses a data change without `expected_rows`. A change of several statements goes in one call as `statements`, with `expected_rows` as a list (each statement's `dry_run.rows`, in order): they run as one transaction, and any count that moved rolls back all of them. If a statement uses `now()`, pin the cutoff to a literal timestamp first, so the count can't drift between the dry run and the write.
   - **`agent_writes: review`, writes not allowed, or anything the user should see first:** `stage_migration` with a clear `title`, the SQL, and a `rationale` that includes the dry-run count ("Voids the 142 duplicate invoices found by …"). It goes to the user's review queue in TableStudio's Agent Center and does **not** run.

On **other engines** there's no dry run: first run a `SELECT count(*)` with the same `WHERE`, report the count, then follow the same execute-or-stage rule.

Before anything destructive on a database that matters (a large DELETE, a DROP, a TRUNCATE), call `create_restore_point` when sandboxes are enabled, and tell the user you did. `restore_backup` with its `restore_point_id` puts the database back (see section 6).

## 4. Changing the schema

**If the repo uses a migration tool** (Prisma, Drizzle, Rails, Django, Alembic, Laravel, Supabase, Knex, Ecto, TypeORM, Wrangler D1, or plain numbered SQL files; the session context names it when the plugin detected one), the change belongs in that tool:

1. Make the change the tool's way: edit the schema and generate a migration, or write the migration file. When TableStudio watches the project's migrations, the file shows up as pending in its Migrations window, where the user applies it with the project's CLI: `use_database` lists it under `pending_repo_migrations`, with the link to give the user.
2. Apply it to the **local development** database with the tool's dev command. For plain numbered SQL files with no runner, run the file's SQL on the local development database with `execute_query` (`statements` keeps it one transaction), and say you did.
3. Check it against real data (below).
4. Leave applying it anywhere else to the user's normal deploy process. Never run the tool's deploy command against production yourself.

Running `ALTER TABLE` directly when a migration tool owns the schema leaves the tool's history out of sync with the database, which breaks the next deploy.

**If there's no migration tool**, or the user asks for a one-off change to an existing database:

1. Read the table first with `get_table_ddl`. Check `referenced_by` before dropping or renaming anything.
2. Try it on a copy: `create_sandbox` (`data`: `none` for schema only, `sample` for a slice of real rows), run the DDL on the sandbox's connection with `execute_query`, and check it does what you meant. A sample copies at most 100,000 rows per table: when the result says `partial: true`, counts on the sandbox aren't the real database's, so take exact counts from `preflight_statement` on the source.
3. Show the difference with `compare_schemas` (sandbox as `source_connection_id`, the real database as `target_connection_id`), and give the user its `compare_url` to see the diff in TableStudio.
4. Propose it with `stage_migration` on the real connection. The user applies it from TableStudio.
5. `remove_sandbox` when you're done with the copy.

### Check a migration against real data

A migration that passes on the local database can still fail, or lock the app, where the real rows are. Before you call a migration done, check it read-only against the database it will deploy to (usually staging or production, from the session note or `list_connections`):

1. `get_table_ddl` with `tables` set to every table it alters (one call): its row estimate, its indexes, and what references it.
2. `preflight_statement` each schema change on that database: for a schema change it runs the same read-only checks the user's review does and says `would_fail` with the reason (duplicates under a new UNIQUE, NULLs under SET NOT NULL, rows under a NOT NULL column with no default, orphans under a foreign key). A backfill and the constraint it allows go together as `statements: [...]`, checked as one change. `not_checked` means it doesn't know that kind of statement: check it yourself. `stage_migration` runs them again and returns `checked`: when its verdict is `would_fail`, fix the SQL with `update_staged_migration` before telling the user it's ready.
   For anything it didn't cover, `read_query` the SELECT that finds rows that would break it (all of them in one call with `queries`):
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
- `schema_issues` with `table` (or `tables`) returns fix SQL with a `lock_impact` for each issue. Read it before proposing a fix. The database-wide scan (no table) has fix SQL but no `lock_impact`: for that, run the per-table analysis on the tables you'd change.

## 5. After you stage something

- Tell the user it's waiting for their review in TableStudio and **has not run**, and give them the `review_url` from the result as a link. It opens the review with the change's impact (rows it touches, locks, what would fail), a diagram of the schema after it, and an undo plan. Never say a staged change was applied.
- If the user asks for changes, `list_staged_migrations` shows `status: changes_requested` with their note in `review_feedback`. Revise it with `update_staged_migration` (same `migration_id`) rather than staging a second copy, then tell them it's ready to look at again. To withdraw it, use `remove_staged_migration`.
- `list_staged_migrations` also shows whether the user applied, ignored or failed it.

When the user asks what's waiting for them ("what did you stage?", "did my migration run?"), call `list_staged_migrations` for this repo's connections. Report the **pending** ones first, newest first: the title, the connection, when it was staged, its `review_url`, and one line on what it does and how risky it is (does it lock or rewrite a large table, delete data, or lack a `WHERE`?). Then any with **changes requested**, with the user's note, and any that **failed**, with the error. Say plainly that the user applies, sends back or ignores them in TableStudio's Agent Center; you can't apply them yourself.

## 6. Backups, restores and copies

- **Back up** with `backup_database` when the user asks for a backup, or wants a file before a big change: the whole database by default, or `contents: "schema"` or `"data"`, `tables`, `schemas`, and on PostgreSQL a `format` (keep the default `custom`: it's the one `restore_backup` restores). It only reads the database. The file goes to the user's backups folder and shows in TableStudio's Backup window. For a quick undo point before a risky change, `create_restore_point` is lighter.
- **Restore** with `restore_backup` only when the user asks: a `backup_id` from `list_backups`, a backup `file`, or a `restore_point_id` from `list_restore_points`. It replaces data, so TableStudio runs it only into a sandbox or a database on this Mac you may write to, after saving a restore point of it. Anywhere else it waits for the user in TableStudio's Inbox and Agent Center (no window opens on its own) and returns `status: handed_to_user` with a `link`: tell the user it's waiting for them there. Never say it ran.
- **Copy one database into another**, same engine or across engines: first `migrate_database_check`, the pre-check, which changes nothing. Show the user its blockers, warnings and estimate. The schema script it would run isn't included; `include_script: true` adds it for reviewing, but never paste it back or run it yourself: `migrate_database` runs it. A sandbox can't be copied back over the database it was made from. Only once they want it, `migrate_database`, adding `acknowledge_warnings: true` if the check had warnings. It runs or opens the Migrate window by the same rule as a restore. Indexes beyond primary keys, triggers and check constraints aren't copied: offer to recreate the ones the target needs.
- **A local copy of production** to develop against: a real local database (`create_local_database`, with the `instance_id` of a running local server of that engine when there is one), then `backup_database` on production and `restore_backup` into it. Not `create_sandbox`, which is a capped throwaway copy for experiments. The local-databases skill has the steps, including what to tell the user first.
- **Sync rows** between two databases of the same engine with `sync_data_check`, then `sync_data`, by the same rule. `mirror` (the default) deletes target rows the source doesn't have; `upsert` keeps them. Never use a sandbox as the source of a mirror: a sandbox usually holds only a sample, so mirroring it deletes every row it left out. From a sandbox the mode is `upsert`, and `mirror` is refused (`sandbox_mirror_source`).
- A backup, restore or copy still going after 45 seconds returns `status: running`. It carries on in TableStudio; `list_backups` shows how it ended.

## 7. Links to give the user

TableStudio returns `tablestudio://` links that open the right place in the app. Give them to the user as clickable links whenever they'd help, rather than describing where to click:

| Link | Opens |
|---|---|
| `review_url` (stage_migration, list_staged_migrations) | The review of a proposed change, where the user approves it, asks for changes or ignores it |
| `diagram_url` (get_schema, er_diagram) | TableStudio's interactive ER diagram |
| `compare_url` (compare_schemas) | The diff between two databases in Compare Schemas |
| `app_url` (get_table_ddl, create_sandbox) | That table, or the sandbox, in TableStudio |
| `links` (use_database) | The database, its diagram, and this chat's activity |
| `this_chat_activity` (list_connections, use_database, stage_migration) | Everything this chat did, in the Agent Center |
| `repo_migrations` (use_database) | The project's pending Drizzle or Prisma migration files, in the Migrations window |
| `link` (restore_backup, migrate_database, when handed to the user) | The Restore or Migrate window, filled in for the user to run |

## 8. When TableStudio says no

- A refusal that names a setting (for example, writes are off) is the user's choice. Tell them which setting would allow it, offer to stage the change instead, and stop. Don't route around it.
- If TableStudio's tools aren't available at all, the session note says why: the app is closed, its MCP server is off (Settings → MCP), or the client isn't connected to it yet. Pass on the fix it gives. In Claude Code, the user can reconnect with `/mcp` once TableStudio is open.
- A refusal with `blocked: production_review_required` or `review_required` means that connection only takes changes through review: stage it. `dry_run_required` means run `preflight_statement` first and pass `expected_rows`. `side_effect_function` means the statement calls something that acts outside a transaction; show the user the SQL instead.
- `agent_access_structure` or `agent_access_read` is the user's limit for that database: say what it allows, offer what fits (the schema, or a staged change), and don't look for another way to the data. `write_in_read_query` means use `execute_query` for that write. `statement_timeout` means the read ran 30 seconds and was stopped, once: narrow it rather than retrying it as is. `rate_limited` means slow down: use the list forms instead of one call per item.
- `user_denied` means the user turned the request down in TableStudio: leave it as it is, and don't ask again unless they bring it up.
- `restore_point_failed` on a restore or copy means TableStudio couldn't save the restore point it takes first, so nothing ran: tell the user why. `migration_blockers` and `warnings_not_acknowledged` mean show the user the pre-check before anything else. `sandbox_mirror_source` and `sandbox_onto_its_source` mean a sandbox can't replace the real database's rows: use `upsert`, or stage the change.
- A local database whose server is stopped fails at once with the `instance_id` to pass to `start_local_database`. Start it only if the user wants to work on it.
- The plugin's shell guard knows the user's TableStudio databases. It blocks a shell command or script that writes to one tagged production, and any that opens one set to Off or Structure only, however it's addressed (a URL, a socket, flags, a driver, a SQLite file). Treat a block as a signal to use the steps above, not as something to work around: never read or change a database's files, or use its credentials, outside TableStudio.
- Everything you do through TableStudio is shown to the user in its Agent Center, grouped by this conversation.
