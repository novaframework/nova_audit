# nova_audit

Append-only audit-event log for the Nova ecosystem.

`nova_audit` is **not** a dependency of Nova core and must never become one.

## Quick start

```erlang
%% sys.config
{nova_audit, [{logs, #{
    app_events => #{
        adapter => nova_audit_kura,
        repo => default,
        table => audit_events,
        redactor => fun my_app:redact_pii/1
    },
    access_log => #{adapter => nova_audit_log, level => info}
}}]}.

%% application code
Event = #{
    actor  => #{type => user, id => <<"alice">>},
    action => <<"document.delete">>,
    target => #{type => <<"document">>, id => <<"doc-42">>},
    outcome => success
},
ok = nova_audit:log(app_events, Event),
ok = nova_audit:log_async(access_log, Event).
```

## Adapters

| Adapter            | Storage     | Status |
| ------------------ | ----------- | ------ |
| `nova_audit_log`   | OTP logger  | v0.1   |
| `nova_audit_kura`  | Postgres    | v0.1   |

`nova_audit_storage` (uses `nova_storage`) lands in v0.2.

## Scope

- Append-only by API contract.
- Required: `actor`, `action`. Library auto-assigns `event_id` (UUIDv7),
  `schema_version`, and `occurred_at` (microseconds).
- Sync (`log/2`) or async (`log_async/2`, via Shigoto if loaded else
  per-log worker with bounded queue).
- Per-log write-time `redactor` hook.
- Query API in v0.1 with 8 filter keys (actor_id, action, occurred_after,
  occurred_before, outcome, target_id, target_type, request_id).

Out of scope: retention/archival, tamper-evidence/chain hashing,
application logging (use `logger`), metrics (use `telemetry`/OTel),
tracing (OTel), encryption-at-rest (`nova_vault`'s job).

## Build & test

```sh
rebar3 compile
rebar3 ct
rebar3 dialyzer
rebar3 xref
```

## Documentation

See the [guides](guides/) directory.

## License

Apache-2.0.
