---
name: query-performance
description: Find and fix slow database queries with TableStudio, proving each fix with measurements, and check a database's overall health. Use when a query, page or endpoint is slow, when asked which queries are slow or what's wrong with the database, when adding, reviewing or dropping indexes, when an ORM query needs tuning, or when deciding whether a SQL rewrite is faster.
---

# Making queries faster with TableStudio

TableStudio can measure, not just guess. Never recommend an index or a rewrite on intuition when you can prove it with the tools below. Most of them are PostgreSQL-only; on other engines use `explain_query` and reason from the plan.

Pick the connection first, as described in the database-workflow skill. Prefer running analysis against a database with realistic data. A near-empty development database gives misleading plans.

## Find what's slow

- **The user names a query or an endpoint:** find the SQL it runs (from the code or the ORM's logging), then go to "Diagnose one statement".
- **"Why is the database slow?"** Call `slow_queries`. It ranks statements by total time from `pg_stat_statements`. Keep each row's `query_id`; the other tools accept it. If the extension isn't installed, the tool explains what enabling it involves, so pass that on rather than installing it unasked.
- **Broad tuning:** `workload_index_advisor` finds the fewest indexes that cover the most database time, and lists existing indexes that are never used.

## A health check

When the user asks what's wrong with a database, or wants a general review, change nothing and report:

1. `database_health`. Read its `unavailable` list before summarizing: an empty findings list with entries there means checks were skipped, not that everything is fine.
2. `database_overview` for size, the biggest and busiest tables, and connection counts.
3. `schema_issues` (no `table`) for design problems across the database.

Put the findings that matter most first, in plain language: what's wrong, what it costs if ignored, and the fix. Include each finding's `verify_sql` so the user can check the number, and any fix's `lock_impact`. Offer to put the fixes the user picks through "Ship it" below.

## Diagnose one statement

1. `optimize_query` with the SQL (and `query_id` if it came from `slow_queries`). For a read-only statement, pass `analyze: true` so the measured checks can run. It executes once inside a rolled-back transaction. It reports `already_fast` when there's nothing worth doing; say so instead of inventing an improvement.
2. For more detail, use `explain_query` (`analyze: true` for reads only). Compare `actual_rows` with `estimated_rows` on each node. A large gap means stale statistics (`ANALYZE` the table), which is often the real bug rather than a missing index.
3. A statement with `$1, $2` placeholders needs real values to plan honestly. `suggest_parameter_values` finds them from history, live sessions and statistics.

## Prove the fix

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
