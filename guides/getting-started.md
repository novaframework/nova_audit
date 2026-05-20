# Getting Started

## Installation

```erlang
{deps, [
    {nova_audit, {git, "https://github.com/novaframework/nova_audit.git", {branch, "main"}}}
]}.
```

For the Kura adapter, also depend on `nova_audit_kura` (sibling app in the
same umbrella) and have `kura` started in your application.

## Configure logs

```erlang
{nova_audit, [{logs, #{
    app_events => #{
        adapter => nova_audit_kura,
        repo => default,
        table => audit_events,
        redactor => fun my_app:redact_pii/1
    },
    access_log => #{adapter => nova_audit_log, level => info}
}}]}.
```

## Logging

The minimum event:

```erlang
Event = #{
    actor  => #{type => user, id => <<"alice">>},
    action => <<"document.delete">>
}.
```

The library auto-assigns `event_id`, `schema_version`, and `occurred_at`.
Caller can override `occurred_at` for backfill scenarios.

```erlang
ok = nova_audit:log(app_events, Event).
ok = nova_audit:log_async(app_events, Event).
```

`log/2` blocks until the adapter returns. `log_async/2` returns immediately
and dispatches via Shigoto if loaded, otherwise via the per-log fallback
worker.

## Querying

```erlang
Filter = #{
    actor_id => <<"alice">>,
    action => <<"document.delete">>,
    occurred_after => 1_700_000_000_000_000
},
{ok, Events, Cursor} = nova_audit:query(app_events, Filter, #{limit => 100}).
```

Cursor pagination:

```erlang
case Cursor of
    done -> ok;
    Next -> nova_audit:query(app_events, Filter, #{cursor => Next, limit => 100})
end.
```

Note: `nova_audit_log` does not support querying; query returns
`{error, query_not_supported}`.

## Redaction

Define a function from `event()` to `event()`:

```erlang
redact_pii(Event = #{actor := Actor}) ->
    Event#{actor => maps:without([attributes], Actor)}.
```

The library applies the redactor immediately before the adapter writes.
Query results are NOT redacted — historical events surface with their
original payload. Access control on `query/2,3` is the caller's job.

## Append-only

There is no `update` or `delete` in the API. For database-backed adapters,
also apply storage-level enforcement:

```erlang
{ok, Statements} = nova_audit_kura:hardening_sql(<<"audit_events">>),
%% Apply Statements via admin credentials, not from your application role.
```
