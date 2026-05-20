# Operations runbook

Written for whoever gets paged. Concrete queries, concrete commands, no
abstract advice. Assumes Postgres + Kura adapter; logger-adapter ops is
trivial (your log shipper owns it).

## Quick reference

| Symptom                                  | First action                                        |
| ---------------------------------------- | --------------------------------------------------- |
| `[nova_audit, overflow]` firing          | [§ Overflow](#overflow---queue-saturated)          |
| `[nova_audit, write_error]` firing       | [§ Write errors](#write-errors)                    |
| Audit query slow / dashboard timing out  | [§ Slow queries](#slow-queries)                    |
| Disk filling up                          | [§ Retention](#retention)                          |
| Compliance auditor on the phone          | [§ Compliance exports](#compliance-exports)        |
| Audit data corruption suspected          | [§ Tamper investigation](#tamper-investigation)    |

## Alerts you must have

Attach these at app startup. Without them, you will not know about the
failure modes the library has.

### 1. Overflow

```erlang
telemetry:attach(
    nova_audit_overflow_alarm,
    [nova_audit, overflow],
    fun(_E, _M, #{log_name := L}, _) ->
        my_pager:warn(<<"nova_audit overflow on ", (atom_to_binary(L))/binary>>)
    end,
    no_state
).
```

**Threshold:** any sustained overflow is a problem. Page on
`rate(events) > 1/min for 5min`. A single overflow event under load is
informational; sustained overflow means events are being dropped.

### 2. Write errors

```erlang
telemetry:attach(
    nova_audit_write_error_alarm,
    [nova_audit, write_error],
    fun(_E, _M, #{log_name := L, reason := R}, _) ->
        my_pager:page(<<"nova_audit write_error on ",
                       (atom_to_binary(L))/binary,
                       ": ",
                       (iolist_to_binary(io_lib:format("~p", [R])))/binary>>)
    end,
    no_state
).
```

**Threshold:** ANY write error pages. Audit writes failing means events
are being silently lost (the async worker can't retry) or your DB is
down (synchronous writes will start failing too).

### 3. Audit-table append-only enforcement broken

This isn't a telemetry event — it's a periodic check.

```sql
-- Run nightly:
SELECT has_table_privilege('your_app_role', 'audit_events', 'UPDATE'),
       has_table_privilege('your_app_role', 'audit_events', 'DELETE');
```

If either returns `true`, someone restored a permission. Page. Investigate.

### 4. Audit-write latency

Sync `log/2` calls block the caller. Latency on the write path tells you
DB health from the application's perspective.

Telemetry: `[nova_audit, log, stop]` has `duration` in native units. Convert
and histogram. Alert on p99 > 100ms sustained for 5 minutes (sync only;
async stop times are misleading because they include adapter work in the
worker).

## Dashboards

Minimum viable dashboard:

1. **Events/sec** by log name and outcome (success vs failure)
2. **Top actions** in the last 1h / 24h
3. **Write latency** p50 / p95 / p99 (from `[nova_audit, log, stop]`)
4. **Overflow rate** by log name
5. **Write error rate** by log name + reason
6. **Audit table size** (rows + bytes)

SQL helpers:

```sql
-- Events per hour, last 24h
SELECT
    date_trunc('hour', to_timestamp(occurred_at / 1000000)) AS hour,
    count(*) AS events
FROM audit_events
WHERE occurred_at > extract(epoch from now() - interval '24 hours') * 1000000
GROUP BY 1
ORDER BY 1;

-- Top actions, last 24h
SELECT action, count(*) AS n
FROM audit_events
WHERE occurred_at > extract(epoch from now() - interval '24 hours') * 1000000
GROUP BY 1
ORDER BY n DESC
LIMIT 20;

-- Failed events by action
SELECT action, count(*) AS n
FROM audit_events
WHERE outcome = 'failure'
  AND occurred_at > extract(epoch from now() - interval '24 hours') * 1000000
GROUP BY 1
ORDER BY n DESC;
```

## Overflow — queue saturated

You got paged for `[nova_audit, overflow]`. The async worker dropped one
or more events. The dropped events are gone — by API contract.

**Triage:**

1. Which log? `meta.log_name`.
2. How sustained? Look at the overflow event rate in your monitoring.
3. Is the DB up? `psql -c 'SELECT count(*) FROM audit_events;'`
   responds promptly?
4. Look for `[nova_audit, write_error]` events in the same window —
   they often precede overflow (slow DB → queue backs up → overflow).

**Fixes, in escalating order:**

1. **Raise `max_queue`.** Default is 10_000. For high-traffic logs,
   bump to 100_000.
   ```erlang
   {nova_audit, [{logs, #{
       app_events => #{adapter => ..., max_queue => 100_000}
   }}]}.
   ```
   Restart the log: `nova_audit_sup:stop_log(app_events)` then start
   again. (No hot config in v0.1.)
2. **Install `shigoto`.** Async events route through a durable job queue
   instead of the in-process worker. Events survive node restarts and
   benefit from `shigoto`'s retry semantics. No code change in the
   audit call sites.
3. **Move must-land events to `log/2` (sync).** Failed logins, admin
   deletes, GDPR-relevant writes. These now block the caller but cannot
   drop. The hot path stays async.
4. **Audit your throughput.** If you're emitting 10_000 audit events
   per second from a single node, the issue is probably upstream: are
   you logging every cache hit? Every health check? Every `GET /static/*`?
   Tighten the call sites.

## Write errors

`[nova_audit, write_error]` fires when an adapter's `write/2` returned
`{error, _}`. The async worker continues. For sync writes, the error
surfaces to the caller of `nova_audit:log/2`.

**Common reasons and fixes:**

| Reason                          | Cause                              | Fix                                       |
| ------------------------------- | ---------------------------------- | ----------------------------------------- |
| `{kura, connection_refused}`    | DB down or netsplit                | Bring DB back up; events in async are lost |
| `{kura, {syntax, _}}`           | Schema drift                       | Re-apply the latest migration             |
| `{kura, {constraint, _}}`       | Duplicate `event_id` (rare; UUIDv7 collision is essentially impossible) | Investigate; could indicate a retry loop in upstream code |
| `kura_not_loaded`               | Kura app not started               | Add `kura` to `applications` in your `.app.src` |

If sync writes are failing, the application is rejecting the action
that triggered the audit (because `ok = nova_audit:log(...)` raises).
That's the design — but it means a DB outage halts privileged operations.
Document this behaviour for your operators; some shops will want sync
log calls behind a circuit breaker (`seki`).

## Slow queries

`query/2,3` should be near-instant for the eight indexed filter keys.
If it's slow:

1. **`EXPLAIN` the query** by reaching into the adapter directly.
   Compliance queries that scan months of data without `occurred_after`
   will be slow regardless of indexes — bound them.
2. **Check the indexes exist.** Migration drift can drop them.
   ```sql
   SELECT indexname FROM pg_indexes WHERE tablename = 'audit_events';
   ```
   Expect: `audit_events_pkey`, `audit_events_occurred_at_idx`,
   `audit_events_actor_id_idx`, `audit_events_action_idx`,
   `audit_events_target_id_idx`, `audit_events_request_id_idx`.
3. **`VACUUM` + `ANALYZE`** if statistics are stale.
4. **Partition by month** if the table is > 100M rows (see Retention).

## Retention

`nova_audit` does not delete. You need a retention policy.

**Recommended pattern: monthly partitions, archive cold partitions to
immutable storage.**

```sql
-- Switch the existing table to declarative partitioning.
-- BEFORE production data — do this at migration time.
CREATE TABLE audit_events (
    -- columns as before
) PARTITION BY RANGE (occurred_at);

-- Create each month's partition explicitly:
CREATE TABLE audit_events_2026_05
    PARTITION OF audit_events
    FOR VALUES FROM
        (extract(epoch from '2026-05-01'::timestamp) * 1000000)
        TO (extract(epoch from '2026-06-01'::timestamp) * 1000000);
```

Automate partition creation with `pg_partman` or a monthly `pg_cron`
job. The application role still cannot DELETE; an archival role can:

```sql
CREATE ROLE audit_archival;
GRANT DELETE ON audit_events TO audit_archival;
-- Use this role from a job that runs `pg_dump` on the cold partition,
-- ships the dump to S3 (Object Lock for WORM), then DROPs the partition.
```

**Retention windows (suggestion; consult your auditor):**

| Framework      | Minimum                              |
| -------------- | ------------------------------------ |
| GDPR Art 30    | 5 years for records of processing    |
| DORA Art 28    | 5 years for major ICT incidents      |
| NIS2 Art 21    | 2-5 years depending on member state  |
| AI Act Art 12  | 6 months minimum (10 years for some) |
| SOX            | 7 years                              |

When in doubt, retain longer than the longest framework you operate
under.

## Compliance exports

Your compliance officer needs a report. Three common shapes:

### "All actions by user X" — GDPR Article 15

```sql
\copy (
    SELECT
        to_timestamp(occurred_at / 1000000)::timestamptz AS at,
        action,
        target_type,
        target_id,
        outcome,
        source,
        request_id,
        metadata
    FROM audit_events
    WHERE actor_id = :user_id
    ORDER BY occurred_at
) TO 'user_x_audit.csv' WITH (FORMAT csv, HEADER true);
```

Apply your `redactor`-equivalent logic on export if PII may have leaked
into `metadata` — `nova_audit`'s write-time redactor only protects
events going forward.

### "Activity by date range" — annual audit

```sql
\copy (
    SELECT
        to_timestamp(occurred_at / 1000000)::timestamptz AS at,
        actor_type,
        actor_id,
        action,
        target_type,
        target_id,
        outcome
    FROM audit_events
    WHERE occurred_at >= extract(epoch from '2026-01-01'::date) * 1000000
      AND occurred_at  < extract(epoch from '2027-01-01'::date) * 1000000
    ORDER BY occurred_at
) TO 'audit_2026.csv' WITH (FORMAT csv, HEADER true);
```

### "Admin actions, last quarter" — privileged access review

```sql
\copy (
    SELECT
        to_timestamp(occurred_at / 1000000)::timestamptz AS at,
        actor_id,
        action,
        target_type,
        target_id,
        outcome,
        source
    FROM audit_events
    WHERE action LIKE '%.delete'
       OR action LIKE 'admin.%'
       OR action LIKE '%permission%'
    AND occurred_at >= extract(epoch from now() - interval '90 days') * 1000000
    ORDER BY occurred_at
) TO 'admin_actions_q.csv' WITH (FORMAT csv, HEADER true);
```

Build a consistent action-naming convention early. `admin.user.suspend`
is much easier to filter than `user_suspended_by_admin`.

## Tamper investigation

You suspect the audit log has been tampered with.

1. **Check the hardening.** Run the privilege query in [§ Alert 3](#3-audit-table-append-only-enforcement-broken).
   If UPDATE or DELETE are granted to the app role, that's the entry
   point — find when the grant was issued (Postgres logs).
2. **Compare against backups.** If you ship immutable backups to S3
   Object Lock or equivalent, restore the latest pre-suspicion backup
   and diff against the live table:
   ```sql
   SELECT event_id, occurred_at FROM audit_events_backup
   EXCEPT
   SELECT event_id, occurred_at FROM audit_events;
   ```
   Any row in the backup but not in live is evidence of a DELETE.
3. **Check `pg_stat_*` and Postgres logs** for UPDATE/DELETE statements
   in the relevant window. If hardening was in place, these will have
   failed and been logged as errors. If they succeeded, hardening was
   bypassed.
4. **v0.1 does not provide cryptographic tamper evidence.** A wrapper
   adding cryptographic anchoring is planned for v0.2+. Until then,
   immutable backups + DB-level hardening + monitoring of the grant
   table are the defence.

## Capacity planning

Rough sizing (one node, modest hardware):

- **Async worker throughput:** ~50k events/sec for `nova_audit_log`,
  ~5-15k events/sec for `nova_audit_kura` (DB-bound).
- **Per-event size on disk:** ~500 bytes typical, up to a few KB with
  generous `metadata`.
- **One row per audit event.** A SaaS doing 100 actions/user/day with
  10k DAUs produces ~1M events/day → ~30M/month → ~360M/year.
- **Index overhead:** the five indexes roughly double the table size on
  disk.

If you expect > 10M events/month, partition from day one. If you expect
> 100M events/month, plan for read replicas (queries hit the replica,
writes hit the primary).

## Backup and restore

Audit data is the data you cannot afford to lose.

**Backup:**

1. `pg_dump` the partition daily; ship to S3 with Object Lock (WORM) or
   equivalent. The application's storage bucket is NOT acceptable — an
   attacker with app-role credentials can delete from it. Use a
   dedicated backup bucket with separate IAM.
2. Verify backups by restoring monthly to a staging DB and running
   a `SELECT count(*)` check.

**Restore:**

1. Restore to a staging DB first; never overwrite production.
2. Replay any events from since-the-backup using the application's
   forward log if you keep one (most don't — accept the gap).
3. Document the restore in a separate operational log; the audit table
   itself cannot be tampered with to hide a restore.

## Schema migrations

Evolve the schema without breaking append-only:

- **Adding a column:** safe. New events use the column; old events have NULL.
  Bump nothing — `schema_version` only changes when the event-shape
  contract changes (rare).
- **Removing a column:** never. The data is immutable. If a column is
  obsolete, stop writing to it; leave the historical column in place.
- **Renaming a column:** never directly. Add a new column, write to
  both for a deprecation period, then stop writing to the old one
  (leave it).
- **Changing a column type:** never directly. Add a new column with
  the new type, write to both, eventually stop writing to the old.

In short: only additive migrations. Old events keep their original
shape forever — that's what append-only means.

## When something is on fire

1. Disable async paths that don't need to land: switch logs from
   `log_async/2` to no-op temporarily. Sync paths keep working;
   business-critical operations continue.
2. If the DB is down and sync calls are failing, you have a choice:
   stop accepting actions that require sync audit (preferred), or
   wrap them in a circuit breaker via `seki` and degrade gracefully
   (acceptable for some compliance frameworks, not all — check before
   shipping the toggle).
3. Drain any pending shigoto jobs before declaring recovery; check
   the worker queues are empty before unsuppressing alerts.
4. Run a sample query against `audit_events` to confirm read path is
   healthy.
5. Post-incident: pull `request_id`s from the incident and trace the
   actual user impact via the audit log. That's literally what it's
   for.
