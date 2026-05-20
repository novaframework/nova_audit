# Adapters

Adapters implement the `nova_audit_adapter` behaviour. They own their
own process. The `State` returned at registration is opaque to
`nova_audit`.

## `nova_audit_log`

OTP-logger adapter. Writes events as structured JSON at a configurable
log level. Useful for dev environments and deployments without a
database.

| Option   | Default | Notes                                       |
| -------- | ------- | ------------------------------------------- |
| `level`  | `info`  | OTP logger level: `debug | info | notice ...`. |

Does **not** support `query/3`; calls return
`{error, query_not_supported}`.

## `nova_audit_kura`

Postgres adapter via Kura. Ships in the sibling app
`nova_audit_kura` (in the same umbrella as `nova_audit`).

| Option   | Required | Notes                                       |
| -------- | -------- | ------------------------------------------- |
| `repo`   | yes      | Kura repo atom.                             |
| `table`  | no       | Default `<<"audit_events">>`.               |

The consumer manages the schema via `rebar3 kura compile` migrations.
See `nova_audit_kura:schema_sql/0` for the recommended shape (UUID
primary key, indexes on `occurred_at`, `actor_id`, `action`,
`target_id`, `request_id`).

After applying the migration, lock down updates and deletes:

```erlang
{ok, Statements} = nova_audit_kura:hardening_sql(),
%% Apply via admin credentials with REVOKE privileges, not from the app role.
```

## Writing a new adapter

1. `-behaviour(nova_audit_adapter).`
2. Implement `start_link/2`, `write/2`, `query/3`.
3. In `init/1`:
   - Build your opaque adapter state (record/map).
   - Spawn a `nova_audit_worker:start_link(Name, ?MODULE, AdapterState)` for the async fallback.
   - Register via `nova_audit_registry:register(Name, ?MODULE, AdapterState, WorkerPid)`.
4. `write/2` is called from BOTH the caller's process (for sync `log/2`) and the worker process (for async). The adapter state must be safely shared.
5. `query/3` returns `{ok, Events, Cursor}` or `{error, _}`. Adapters that don't support querying may return `{error, query_not_supported}`.

If the adapter doesn't naturally batch, the worker queues events
serially. Adapters that benefit from batching may collect events
internally and flush on size or timer.
