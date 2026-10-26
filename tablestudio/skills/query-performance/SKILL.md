---
name: query-performance
description: Find and fix slow database queries with TableStudio, proving each fix with measurements, and check a database's overall health. Use when a query, page or endpoint is slow, when asked which queries are slow or what's wrong with the database, when adding, reviewing or dropping indexes, when an ORM query needs tuning, or when deciding whether a SQL rewrite is faster.
---

# Making queries faster with TableStudio

TableStudio can measure, not just guess. Never recommend an index or a rewrite on intuition when you can prove it with the tools below. Most of them are PostgreSQL-only; on other engines use `explain_query` and reason from the plan.

Pick the connection first, as described in the database-workflow skill. Prefer running analysis against a database with realistic data. A near-empty development database gives misleading plans.

## Find what's slow

- **The user names a query or an endpoint:** find the SQL it runs (from the code or the ORM's logging), then go to "Diagnose one statement".
- **"Why is the database slow?"** Call `slow_queries`. It ranks statements by total time from `pg_stat_statements`. Keep each row's `query_id`; the other tools accept it. When `pg_stat_statements` can't be read, `slow_queries`, `workload_index_advisor` and `index_what_if` (without `sql`) all return the same `blocked` answer: `pg_stat_statements_not_installed`, or `pg_stat_statements_not_preloaded` (installed, but its library isn't in `shared_preload_libraries`), with `restart_required` and `how_to_enable`. Pass that on rather than installing or restarting anything unasked. When `fixable_in_tablestudio` is true, the user can do it from the database's Dashboard in one click.
- **Broad tuning:** `workload_index_advisor` finds the fewest indexes that cover the most database time, and lists existing indexes that are never used.

## What's running right now

"Why is it slow right now?" or "what's holding the lock?": `active_queries` lists each session's query, how long it has run, what it waits on and which pids block it (`min_seconds` to filter). On a development or local database, `cancel_query` stops one by pid (its transaction rolls back; `terminate: true` ends the session). On production it's refused: tell the user the pid and the query.

## A health check

When the user asks what's wrong with a database, or wants a general review, change nothing and make **one** call: `database_health` with `include: ["overview", "schema_issues"]`. That's the health findings, the size, biggest tables and connection counts, and the database-wide design scan together.

- **Several databases** ("check my local databases"): add `connection_ids: [...]`, or `scope: "local"` for every database on this Mac. Server settings every database shares are reported once under `servers`; stopped local servers are listed under `skipped` (say so, don't call them healthy). With several databases each section is summarized, so for `verify_sql` and fixes on the one that matters, call `database_health` again with just its `connection_id`.
- Read each `unavailable` list before summarizing: an empty findings list with entries there means checks were skipped, not that everything is fine.

Put the findings that matter most first, in plain language: what's wrong, what it costs if ignored, and the fix. For the findings you lead with, include `verify_sql` so the user can check the number, and any fix's `lock_impact`. A single-database result has them; a several-database summary doesn't, so for those call `database_health` with that one `connection_id` first. Offer to put the fixes the user picks through "Ship it" below.

## Diagnose one statement

1. `optimize_query` with the SQL (and `query_id` if it came from `slow_queries`). For a read-only statement, pass `analyze: true` so the measured checks can run. It executes once inside a rolled-back transaction. It reports `already_fast` (under 2 ms a run, and no index proven to help) when there's nothing worth doing; say so instead of inventing an improvement. Several statements, such as the top rows of `slow_queries`, go in one call as `queries`: each comes back with its verdict, findings and `proven_indexes`, and `verdicts` counts them.
2. For more detail, use `explain_query` (`analyze: true` for reads only). Compare `actual_rows` with `estimated_rows` on each node. A large gap means stale statistics (`ANALYZE` the table), which is often the real bug rather than a missing index.
3. A statement with `$1, $2` placeholders needs real values to plan honestly. `suggest_parameter_values` finds them from history, live sessions and statistics.

## Prove the fix

Proving an index without building it needs the `hypopg` extension. When it's missing, `optimize_query` lists the index checks under `checks.needs_hypopg` (they didn't run, so `already_fast` or `healthy` says nothing about indexes), and `index_what_if` and the index variants of `benchmark_query_variants` return `blocked: hypopg_not_installed`. Unlike pg_stat_statements it needs no restart: `add_extension` with `hypopg` installs it on a development database; on a database tagged production, propose it with `stage_migration` instead. Or test on a sandbox: there `benchmark_query_variants` builds each hypothetical index for real inside a rolled-back transaction, so it needs no hypopg. A sample's timings aren't the real table's, so compare plans more than milliseconds.

Use `benchmark_query_variants` (the Query Lab) before recommending anything:

- Give it the baseline SQL and the candidates as `variants`: a rewritten `sql`, `hypothetical_indexes` (planned with hypopg, never built), `hide_indexes`, or planner `settings`. Or leave `variants` out and let `find_faster` propose its own.
- It reports medians over several runs for each parameter set, and checks that every rewrite returns the same rows as the baseline.
- Only recommend a variant whose `same_rows` is yes. Prefer the variant in `recommendation`. Quote the measured before and after, not percentages from intuition.

Before **dropping** an index (unused or duplicate), run `index_what_if` with it in `hide`. Any statement that gets more expensive, or uses the index today, would be hurt.

## Ship it

Indexes and rewrites go through the normal change flow from the database-workflow skill:

- Index changes are schema changes. If the repo has a migration tool, add the index there. Otherwise propose it with `stage_migration`, with the measured numbers in the `rationale`.
- On PostgreSQL, use `CREATE INDEX CONCURRENTLY` for any table that sees traffic, and don't wrap it in a transaction.
- A query rewrite is a code change: edit the code that issues it, and mention the benchmark result in your summary.
