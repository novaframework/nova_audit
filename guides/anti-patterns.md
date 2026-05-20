# Anti-patterns

Mistakes that look reasonable in isolation but degrade the audit log
over time. Each entry has the wrong pattern, why it's wrong, and the
right pattern.

## 1. Logging payloads instead of references

**Wrong:**

```erlang
nova_audit:log(app_events, #{
    actor => Actor,
    action => <<"document.upload">>,
    metadata => #{<<"contents">> => DocBody}    %% the whole 4MB PDF
}).
```

**Why wrong:** the audit log is a trail, not a data lake. Payloads blow
up the table size, slow every query, and create GDPR liability — every
byte you store is something you'll have to redact, export, or delete on
request.

**Right:** store the reference, not the data.

```erlang
nova_audit:log(app_events, #{
    actor => Actor,
    action => <<"document.upload">>,
    target => #{type => <<"document">>, id => DocId},
    metadata => #{<<"size">> => byte_size(DocBody),
                  <<"content_type">> => <<"application/pdf">>}
}).
```

## 2. Free-for-all metadata keys

**Wrong:** every emitter invents its own metadata schema.

```erlang
%% Handler A
metadata => #{<<"ip">> => Ip, <<"ua">> => UserAgent}

%% Handler B (same kind of event)
metadata => #{<<"ip_address">> => Ip, <<"user_agent">> => UserAgent, <<"ua_string">> => UserAgent}

%% Handler C
metadata => #{<<"client">> => #{<<"ip">> => Ip, <<"agent">> => UserAgent}}
```

**Why wrong:** compliance queries can't slice. "How many events from IP
X?" is now three queries, one of which has to traverse nested JSON.

**Right:** document a metadata schema for your app, even informally,
and stick to it. A constant module or a typed helper keeps emitters
honest:

```erlang
-module(my_app_audit_meta).
-export([client_meta/2]).

client_meta(Ip, UserAgent) ->
    #{<<"ip">> => Ip, <<"user_agent">> => UserAgent}.
```

## 3. Using audit as debug logging

**Wrong:** an audit event for every state transition in your code.

```erlang
nova_audit:log_async(app_events, #{
    actor => Actor,
    action => <<"document.upload.parsing_started">>,  %% internal step
    ...
}),
nova_audit:log_async(app_events, #{
    actor => Actor,
    action => <<"document.upload.virus_scan_started">>,  %% internal step
    ...
}),
nova_audit:log_async(app_events, #{
    actor => Actor,
    action => <<"document.upload.completed">>,
    ...
}).
```

**Why wrong:** audit log volume explodes, compliance noise drowns
signal, retention costs balloon. `logger` exists for application
diagnostics.

**Right:** one audit event per business action.

```erlang
%% Internal steps go to logger
?LOG_DEBUG(#{event => parsing_started, doc_id => DocId}),
%% ... do the work ...

%% One audit event when the action completes
nova_audit:log_async(app_events, #{
    actor => Actor,
    action => <<"document.upload">>,
    target => #{type => <<"document">>, id => DocId},
    outcome => success
}).
```

## 4. Auditing every read

**Wrong:**

```erlang
%% In every GET handler
nova_audit:log_async(app_events, #{
    actor => Actor,
    action => <<"document.view">>,
    target => #{type => <<"document">>, id => DocId}
}).
```

**Why wrong:** reads outnumber writes by 100:1 in most apps. You will
fill the audit table with `view` events nobody queries. Access logging
is what your HTTP log shipper is for.

**Right:** audit reads only when the read itself is sensitive:

```erlang
%% Admin viewing another user's PII
nova_audit:log(admin_log, #{
    actor => AdminActor,
    action => <<"admin.user.view_pii">>,
    target => #{type => <<"user">>, id => OtherUserId}
}).

%% GDPR Article 15 export
nova_audit:log(app_events, #{
    actor => UserActor,
    action => <<"user.data.exported">>,
    target => #{type => <<"user">>, id => maps:get(id, UserActor)}
}).
```

## 5. Hoping the redactor catches secrets

**Wrong:**

```erlang
%% Pass everything; the redactor will sort it out.
nova_audit:log_async(app_events, #{
    actor => Actor,
    action => <<"user.login">>,
    metadata => #{<<"password">> => Password, <<"token">> => Token}
}).
```

**Why wrong:** the redactor is a safety net. If you misspell a key
(`Passw0rd`, `passwd`), the redactor lets it through. Secrets in
`metadata` is also a hot path bug magnet — one PR removes the redactor
on a refactor and your audit log starts collecting credentials.

**Right:** don't pass secrets. The redactor is the second line of
defence, not the first.

```erlang
nova_audit:log_async(app_events, #{
    actor => Actor,
    action => <<"user.login">>,
    metadata => #{<<"method">> => <<"password">>}
}).
```

## 6. Audit-after-act on destructive operations

**Wrong:**

```erlang
ok = nova_storage:delete(uploads, DocId),     %% destructive, irreversible
nova_audit:log_async(app_events, #{
    actor => Actor,
    action => <<"document.delete">>,
    target => #{type => <<"document">>, id => DocId}
}).
```

**Why wrong:** the async log can drop on overflow. If it drops, you
have a document deleted with no audit record. From the auditor's
perspective, the deletion never happened. From the user's perspective,
their document is gone.

**Right:** sync log BEFORE the destructive action.

```erlang
ok = nova_audit:log(app_events, #{          %% sync — must land
    actor => Actor,
    action => <<"document.delete">>,
    target => #{type => <<"document">>, id => DocId}
}),
ok = nova_storage:delete(uploads, DocId).
```

If the audit write fails, the destructive call never runs.

## 7. Querying without a time window

**Wrong:**

```erlang
{ok, Events, _} = nova_audit:query(app_events, #{actor_id => UserId}).
```

**Why wrong:** at 100M+ events, this scans most of the table. The
actor_id index helps, but for users with years of activity it's still
slow. In a busy app it'll time out.

**Right:** bound by time. If the call is interactive, also limit.

```erlang
Now = erlang:system_time(microsecond),
ThirtyDaysAgo = Now - (30 * 24 * 60 * 60 * 1_000_000),
{ok, Events, _} = nova_audit:query(
    app_events,
    #{actor_id => UserId, occurred_after => ThirtyDaysAgo},
    #{limit => 100}
).
```

For full-history exports (GDPR right-of-access), use cursor pagination
in a background job, not an interactive call.

## 8. Reusing one action across domains

**Wrong:**

```erlang
%% In document handler
action => <<"update">>

%% In user handler
action => <<"update">>

%% In permission handler
action => <<"update">>
```

**Why wrong:** `WHERE action = 'update'` returns updates of any kind.
Compliance reports can't separate "the admin updated a permission"
from "a user updated their bio."

**Right:** namespace.

```erlang
action => <<"document.update">>
action => <<"user.update">>
action => <<"permission.update">>
```

A consistent dotted naming scheme also makes `LIKE 'admin.%'` queries
straightforward.

## 9. Omitting actor for system work

**Wrong:**

```erlang
%% In a background job that purges expired sessions
nova_audit:log_async(app_events, #{
    actor => undefined,            %% nobody did this!
    action => <<"session.purge">>,
    ...
}).
```

**Why wrong:** events without an actor break the "who" pillar. The
filter `actor_id => _` won't find them. The trail looks like actions
happen spontaneously.

**Right:** the system IS an actor. Identify it.

```erlang
nova_audit:log_async(app_events, #{
    actor => #{
        type => system,
        id => <<"my_app.session_purger">>,
        attributes => #{<<"node">> => atom_to_binary(node())}
    },
    action => <<"session.purge">>,
    metadata => #{<<"purged_count">> => N}
}).
```

For shigoto jobs, set the actor to the job module. For Nova plugins, the
plugin name. For migrations, the migration id.

## 10. Audit-then-fire-and-forget destructive chain

**Wrong:**

```erlang
%% Log first, then act. But what if the act fails?
ok = nova_audit:log(app_events, DeleteEvent),
catch nova_storage:delete(uploads, DocId).      %% might fail silently
```

**Why wrong:** the audit record says the action happened, but it
didn't. False audit trail — worse than no trail.

**Right:** propagate failure.

```erlang
ok = nova_audit:log(app_events, DeleteEvent),
case nova_storage:delete(uploads, DocId) of
    ok ->
        ok;
    {error, Reason} ->
        %% Action failed AFTER we logged success.
        %% Either: (a) compensate by writing a failure event
        ok = nova_audit:log(app_events, DeleteEvent#{
            action => <<"document.delete.rollback">>,
            outcome => failure,
            metadata => #{<<"reason">> => atom_to_binary(Reason)}
        }),
        {error, Reason}
end.
```

## 11. `outcome => failure` for every retry

**Wrong:**

```erlang
%% In a retry loop
retry_loop(N, Action) when N < 5 ->
    case Action() of
        ok -> ok;
        {error, R} ->
            nova_audit:log_async(app_events, #{
                actor => Actor,
                action => <<"payment.charge">>,
                outcome => failure,
                metadata => #{<<"attempt">> => N, <<"reason">> => R}
            }),
            retry_loop(N + 1, Action)
    end.
```

**Why wrong:** five audit events per payment that eventually succeeds.
Compliance views think every payment failed at least once.

**Right:** log the final outcome.

```erlang
case retry_loop(5, Action) of
    ok ->
        nova_audit:log_async(app_events, #{
            actor => Actor,
            action => <<"payment.charge">>,
            outcome => success
        });
    {error, R} ->
        nova_audit:log(app_events, #{    %% sync — failed payments must land
            actor => Actor,
            action => <<"payment.charge">>,
            outcome => failure,
            metadata => #{<<"reason">> => R, <<"attempts">> => 5}
        })
end.
```

Intermediate retry telemetry belongs in `[my_app, payment, retry]` via
`telemetry`, not in the audit log.

## 12. Atom keys in metadata

**Wrong:**

```erlang
metadata => #{ip => Ip, user_agent => UserAgent}
```

**Why wrong:** the Erlang atom table is bounded. If `metadata` keys are
derived from external input (request headers, user-provided field
names), atom-keyed metadata is a DoS vector. Even with internal keys,
mixing atoms and binaries in JSON-decoded reads creates a footgun.

**Right:** binary keys everywhere in `metadata`.

```erlang
metadata => #{<<"ip">> => Ip, <<"user_agent">> => UserAgent}
```

`actor.type` is the only metadata-ish atom in the event shape — it's a
small closed set (`user | service | system | anonymous`) and safe to
keep as an atom.

## 13. Using audit_events as the analytics warehouse

**Wrong:**

```erlang
%% A weekly job that runs against the live audit table
SELECT action, count(*) FROM audit_events GROUP BY action;

%% A dashboard polling every 30 seconds
SELECT * FROM audit_events
WHERE occurred_at > extract(epoch from now() - interval '1 hour') * 1000000;
```

**Why wrong:** heavy reads compete with the application's writes (DB
pool contention, lock contention, I/O contention). The compliance
officer's monthly report taking 20 minutes is fine; that same query
running on the live primary is not.

**Right:**

- Run analytics against a read replica.
- ETL audit events to a separate analytics store nightly.
- For live dashboards, use the per-event telemetry (`[nova_audit, log,
  stop]`) instead — Liveboard / Prometheus consume those without
  hitting the audit table.

## 14. Bumping `schema_version` on every change

**Wrong:**

```erlang
%% v0.1: actor + action + occurred_at
%% v0.2: someone added 'source' optional field, bumped schema_version to 2
%% v0.3: someone added a request_id, bumped to 3
```

**Why wrong:** consumers of the audit log now have to understand four
versions to read history. The whole point of optional fields is that
they don't change the contract.

**Right:** only bump `schema_version` when the *shape* contract
changes (required fields added, existing field semantics change). Adding
optional fields is not a contract change.

## 15. Mixing logs and audit events in the same destination

**Wrong:**

```
all logs → fluentbit → loki
all audit events (via nova_audit_log) → fluentbit → loki
```

**Why wrong:** audit data has different retention requirements
(typically 5+ years), different access controls (compliance officer
yes, ops engineer no), and different deletion semantics (never delete).
A unified log destination violates all three.

**Right:**

- Use `nova_audit_kura` (Postgres) for the queryable audit log.
- Use `nova_audit_log` only when you genuinely have a separate log
  shipper feeding a separate destination with separate ACLs and
  retention.
- Don't pipe `[nova_audit, log, stop]` telemetry events to the same
  log aggregator as your access logs. They're metrics, not logs.

## 16. Treating overflow telemetry as an event bus

**Wrong:**

```erlang
telemetry:attach(my_handler, [nova_audit, overflow], fun(_, _, _, _) ->
    %% "An event happened somewhere, do something!"
    cache:invalidate_all()
end, no_state).
```

**Why wrong:** overflow is a failure alarm — events were LOST. Treating
it as a signal that something happened is precisely backwards.

**Right:** alert on it, then act to prevent recurrence (raise queue,
install shigoto, move to sync). Use it as a paging signal, not a
domain event.

## 17. Querying via `metadata` for things that should be top-level

**Wrong:**

```erlang
%% Stored:
target => undefined,
metadata => #{<<"document_id">> => DocId}

%% Queried (JSON path):
WHERE metadata->>'document_id' = '...';
```

**Why wrong:** `target_id` is an indexed top-level filter. JSON path
queries fall back to seq scans.

**Right:** use the schema's purpose-built fields.

```erlang
target => #{type => <<"document">>, id => DocId}

%% Queried via the eight filter keys:
nova_audit:query(app_events, #{target_id => DocId}).
```

`metadata` is for context that doesn't fit the schema — not for things
the schema already supports.

## 18. Forgetting the `nova_audit_kura:hardening_sql/0` step

**Wrong:** apply the schema migration, ship to prod, never harden.

**Why wrong:** the API contract says append-only, but Postgres lets the
app role UPDATE and DELETE. A compromised app credential — or a careless
intern with a psql session — can rewrite history.

**Right:** apply hardening as part of the release process, with a
periodic check that hardening is still in place:

```sql
-- Nightly check: any privileges granted that shouldn't be?
SELECT has_table_privilege('your_app_role', 'audit_events', 'UPDATE'),
       has_table_privilege('your_app_role', 'audit_events', 'DELETE');
-- Both must be false. Alert if either is true.
```

## Summary

If the audit log is doing its job, you should be able to:

- Answer "what did user X do, ever" in one query.
- Answer "who deleted this document, when, from where" without
  digging through application logs.
- Hand a compliance officer a CSV they can read.
- Restore from immutable backups and prove the live table matches.
- Tell on-call exactly when a stream of failures started, and with
  which request.

The anti-patterns above all degrade one of those capabilities. Most
look harmless one event at a time; they show up six months later when
the table has 200 million rows and the compliance officer needs an
export by Friday.
