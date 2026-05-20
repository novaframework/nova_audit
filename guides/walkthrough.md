# Walkthrough: audit a Nova web app end-to-end

A worked example. We start with a small document-management SaaS and add
a complete audit trail covering logins, uploads, deletes, and admin
actions. Every code block is real Erlang you can paste in.

The example app has:

- Users who log in (`nova_auth`)
- Users who upload PDFs (`nova_storage`)
- Admins who can delete any document
- A compliance officer who needs reports on "what did user X do" and
  "which admin actions happened this week"

## 1. Dependencies

In `rebar.config`:

```erlang
{deps, [
    nova,
    nova_auth,
    kura,
    nova_audit,
    nova_audit_kura
]}.
```

In `sys.config`:

```erlang
[
    {nova_audit, [{logs, #{
        app_events => #{
            adapter => nova_audit_kura,
            repo => default,
            table => audit_events,
            redactor => fun my_app_audit:redact/1
        },
        access_log => #{
            adapter => nova_audit_log,
            level => info
        }
    }}]},
    {my_app, [
        %% your app config
    ]}
].
```

Two logs:

- `app_events` writes to Postgres for queryable compliance reporting.
- `access_log` writes to OTP `logger` — picked up by your log shipper
  alongside everything else for ops dashboards.

You can have more. A common split is `app_events` for domain actions,
`access_log` for HTTP access patterns, `admin_log` for privileged
operations (with stricter `mode => sync`).

## 2. Apply the schema

Create the migration:

```erlang
%% priv/kura/migrations/001_audit_events.sql
%% Generated from nova_audit_kura:schema_sql/0
CREATE TABLE IF NOT EXISTS audit_events (
    event_id        UUID PRIMARY KEY,
    schema_version  INTEGER NOT NULL DEFAULT 1,
    occurred_at     BIGINT NOT NULL,
    actor_type      TEXT NOT NULL,
    actor_id        TEXT NOT NULL,
    action          TEXT NOT NULL,
    target_type     TEXT,
    target_id       TEXT,
    outcome         TEXT,
    source          TEXT,
    request_id      TEXT,
    metadata        JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX audit_events_occurred_at_idx ON audit_events (occurred_at);
CREATE INDEX audit_events_actor_id_idx ON audit_events (actor_id);
CREATE INDEX audit_events_action_idx ON audit_events (action);
CREATE INDEX audit_events_target_id_idx ON audit_events (target_id) WHERE target_id IS NOT NULL;
CREATE INDEX audit_events_request_id_idx ON audit_events (request_id) WHERE request_id IS NOT NULL;
```

Apply it: `rebar3 kura migrate`.

Then harden the table. **Use admin credentials**, not your application
role:

```erlang
1> {ok, Stmts} = nova_audit_kura:hardening_sql(<<"audit_events">>).
2> [io:format("~s~n", [S]) || S <- Stmts].
REVOKE UPDATE, DELETE ON audit_events FROM PUBLIC;
-- Apply per-role grant separately, e.g.:
-- REVOKE UPDATE, DELETE ON audit_events FROM your_app_role;
```

Then in a `psql` session as the DB owner:

```sql
REVOKE UPDATE, DELETE ON audit_events FROM PUBLIC;
REVOKE UPDATE, DELETE ON audit_events FROM my_app_role;
```

The application can now INSERT and SELECT but not UPDATE or DELETE. If
your app role tries to UPDATE, Postgres rejects it — the API contract is
backed by storage-level enforcement.

## 3. Actor extraction

Read the actor from the current Nova request. This helper lives in your
app, not in `nova_audit`:

```erlang
-module(my_app_audit).

-export([actor_from/1, redact/1]).

-spec actor_from(cowboy_req:req()) -> nova_audit:actor().
actor_from(Req) ->
    case nova_auth:current_user(Req) of
        {ok, User} ->
            #{
                type => user,
                id => maps:get(id, User),
                attributes => #{
                    <<"role">> => maps:get(role, User, <<"member">>)
                }
            };
        not_authenticated ->
            #{type => anonymous, id => <<"-">>}
    end.

-spec redact(nova_audit:event()) -> nova_audit:event().
redact(Event = #{metadata := Meta}) ->
    %% Strip anything that looks like a secret. The list is yours to maintain.
    Sensitive = [<<"password">>, <<"token">>, <<"api_key">>, <<"secret">>],
    Cleaned = maps:without(Sensitive, Meta),
    Event#{metadata => Cleaned};
redact(Event) ->
    Event.
```

## 4. Request ID propagation

A Nova plugin that ensures every request has an `X-Request-Id`, then
exposes it for downstream code:

```erlang
-module(my_app_request_id_plugin).
-behaviour(nova_plugin).

-export([plugin_info/0, pre_http_request/2, post_http_request/2]).

plugin_info() ->
    #{title => <<"Request ID">>, version => <<"1.0.0">>, url => <<>>,
      authors => [<<"...">>], description => <<>>}.

pre_http_request(Req, _Opts) ->
    Rid = case cowboy_req:header(<<"x-request-id">>, Req) of
        undefined -> generate_request_id();
        Existing -> Existing
    end,
    %% Stash on the req so handlers and audit can read it.
    Req1 = cowboy_req:set_resp_header(<<"x-request-id">>, Rid, Req),
    {ok, Req1#{request_id => Rid}}.

post_http_request(Req, _Opts) ->
    {ok, Req}.

generate_request_id() ->
    iolist_to_binary(jhn_uuid:gen(v7)).
```

Register it in `nova.config` so it runs on every request:

```erlang
{plugins, [
    {pre_http_request, my_app_request_id_plugin, #{}, []}
]}.
```

Now `cowboy_req:get(request_id, Req)` returns the id everywhere — and
your `X-Request-Id` response header lets clients quote it in support
tickets.

## 5. Login auditing

In your authentication handler:

```erlang
-module(my_app_auth_handler).

-export([login/2]).

login(#{json := #{<<"email">> := Email, <<"password">> := Password}} = Req, _) ->
    Rid = maps:get(request_id, Req, undefined),
    Source = peer_address(Req),
    case my_app_users:authenticate(Email, Password) of
        {ok, User} ->
            ok = nova_audit:log_async(app_events, #{
                actor => #{type => user, id => maps:get(id, User)},
                action => <<"user.login">>,
                outcome => success,
                source => Source,
                request_id => Rid,
                metadata => #{<<"email">> => Email}
            }),
            {ok, Token} = nova_auth:issue_token(User),
            {200, #{}, #{token => Token}};
        {error, Reason} ->
            %% Synchronous: a failed login is a security-sensitive event,
            %% we want it on disk before the response goes out.
            ok = nova_audit:log(app_events, #{
                actor => #{type => anonymous, id => Email},
                action => <<"user.login">>,
                outcome => failure,
                source => Source,
                request_id => Rid,
                metadata => #{<<"reason">> => atom_to_binary(Reason)}
            }),
            {401, #{}, #{error => invalid_credentials}}
    end.

peer_address(Req) ->
    {Ip, _} = cowboy_req:peer(Req),
    iolist_to_binary(inet:ntoa(Ip)).
```

Notes:

- We use `log_async/2` on success — the response shouldn't wait on the
  audit write.
- We use `log/2` on failure — for compliance the failed-login record
  must land. If shigoto were absent and the worker queue overflowed,
  async would drop; sync blocks until written.
- We never log the password. The redactor would strip it if it slipped
  into `metadata`, but the right move is to not pass it in the first
  place.

## 6. Upload auditing

```erlang
-module(my_app_documents_handler).

-export([upload/2, delete/2]).

upload(Req, _) ->
    Actor = my_app_audit:actor_from(Req),
    Rid = maps:get(request_id, Req, undefined),
    {ok, [{file, _, FileName, Body}], Req1} = cowboy_req:read_part(Req),
    DocId = generate_doc_id(),
    {ok, _} = nova_storage:put(uploads, DocId, Body, #{
        content_type => <<"application/pdf">>,
        user_meta => #{<<"original_name">> => FileName}
    }),
    nova_audit:log_async(app_events, #{
        actor => Actor,
        action => <<"document.upload">>,
        target => #{type => <<"document">>, id => DocId,
                    attributes => #{<<"name">> => FileName}},
        outcome => success,
        request_id => Rid,
        metadata => #{<<"size">> => byte_size(Body)}
    }),
    {201, #{}, #{id => DocId}}.

generate_doc_id() ->
    iolist_to_binary(jhn_uuid:gen(v7)).
```

## 7. Admin deletion — sync mode

Privileged operations get the synchronous path. The audit row must be on
disk before the destructive operation runs:

```erlang
delete(Req, _) ->
    Actor = my_app_audit:actor_from(Req),
    Rid = maps:get(request_id, Req, undefined),
    #{id := DocId} = cowboy_req:bindings(Req),
    case is_admin(Actor) of
        false ->
            %% Audit the denied attempt, then 403.
            ok = nova_audit:log(app_events, #{
                actor => Actor,
                action => <<"document.delete.denied">>,
                target => #{type => <<"document">>, id => DocId},
                outcome => failure,
                request_id => Rid,
                metadata => #{<<"reason">> => <<"not_admin">>}
            }),
            {403, #{}, #{error => forbidden}};
        true ->
            %% Sync log BEFORE the delete. If the audit write fails, the
            %% delete is never attempted.
            ok = nova_audit:log(app_events, #{
                actor => Actor,
                action => <<"document.delete">>,
                target => #{type => <<"document">>, id => DocId},
                outcome => success,
                request_id => Rid,
                source => <<"admin_panel">>
            }),
            ok = nova_storage:delete(uploads, DocId),
            {204, #{}, <<>>}
    end.

is_admin(#{type := user, attributes := #{<<"role">> := <<"admin">>}}) -> true;
is_admin(_) -> false.
```

If the audit `log/2` returns `{error, _}`, you get the error from `ok =
nova_audit:log(...)`, which raises and short-circuits the handler before
any destructive call.

## 8. Compliance queries

### "All events about user X" — GDPR Article 15 right-of-access

```erlang
list_user_events(UserId) ->
    list_user_events(UserId, done, []).

list_user_events(_UserId, done, Acc) ->
    {ok, lists:reverse(Acc)};
list_user_events(UserId, Cursor, Acc) ->
    Opts = case Cursor of
        done -> #{limit => 500};
        C -> #{limit => 500, cursor => C}
    end,
    {ok, Page, Next} = nova_audit:query(
        app_events,
        #{actor_id => UserId},
        Opts
    ),
    list_user_events(UserId, Next, [Page | Acc]).
```

The actor filter hits the `audit_events_actor_id_idx` index. For very
active users you may want to also bound by `occurred_after` / `occurred_before`.

### "All admin actions in the last 7 days"

```erlang
list_admin_actions() ->
    Now = erlang:system_time(microsecond),
    SevenDaysAgo = Now - (7 * 24 * 60 * 60 * 1_000_000),
    {ok, Events, _} = nova_audit:query(
        app_events,
        #{
            action => <<"document.delete">>,
            occurred_after => SevenDaysAgo,
            outcome => success
        },
        #{limit => 1000}
    ),
    Events.
```

For broader admin reporting you'll want to either prefix admin actions
consistently (`admin.*`) and filter on a prefix at the adapter level, or
issue multiple queries.

### "Trace a request" — incident response

```erlang
trace_request(RequestId) ->
    {ok, Events, _} = nova_audit:query(
        app_events,
        #{request_id => RequestId},
        #{limit => 100}
    ),
    Events.
```

Hits the partial `audit_events_request_id_idx`. Pair with the
`X-Request-Id` your plugin echoes back: a user reporting a problem
quotes their request id, you pull the full trail in one call.

## 9. A Liveboard panel (optional)

A short Arizona view that streams the last 50 events:

```erlang
-module(my_app_audit_view).
-behaviour(arizona_view).

-export([mount/2, render/1]).

mount(_Bindings, _Req) ->
    {ok, refresh(#{})}.

render(View) ->
    Events = maps:get(events, View),
    arizona:render(View, fun() -> ?html_template("audit.html") end, #{
        events => Events
    }).

refresh(View) ->
    {ok, Events, _} = nova_audit:query(
        app_events,
        #{},
        #{limit => 50}
    ),
    View#{events => Events}.
```

Refresh on a timer; or hook into a telemetry handler that re-fetches on
`[nova_audit, log, stop]` for near-live updates.

## 10. Alerting on overflow

The async worker drops events when its queue is saturated. In
production, attach a handler:

```erlang
%% At app startup:
telemetry:attach(
    audit_overflow_alarm,
    [nova_audit, overflow],
    fun(_E, _M, #{log_name := L}, _) ->
        my_app_pager:alert(<<"nova_audit overflow on ", (atom_to_binary(L))/binary>>)
    end,
    no_state
).
```

If overflow fires sustainedly, you have three options:

1. Raise `max_queue` in the log spec.
2. Install `shigoto` — async events route through the durable job queue
   instead of the in-process worker.
3. Move sensitive events to `mode => sync` (i.e. `log/2`). They block
   the caller but never drop.

For most apps, option 2 is the right answer once you outgrow a single
node.

## 11. What we did NOT do

Things you might expect that nova_audit deliberately leaves to the
caller or another library:

- **Retention.** Decide your retention window, then periodically partition
  the table by month and archive old partitions to object storage. Or
  set up `pg_cron` with the right credentials (the application role
  can't DELETE; an archival role can).
- **PII detection.** The redactor is mechanical — it strips fields you
  list. Detecting PII in arbitrary `metadata` values is out of scope;
  use it for structural redaction (drop `password`, drop `card_number`)
  and require domain code to not put PII in `metadata` in the first
  place.
- **Tamper evidence.** No chain-hashes or signed envelopes in v0.1. A
  wrapper library (likely `nova_audit_signed`) will land later and
  layers cryptographic anchoring on top of the same adapter behaviour.
- **Cross-service correlation.** Pass `request_id` between services
  yourself (HTTP header propagation, message metadata in your queue).
  `nova_audit` records it; carrying it is your job.

## 12. Summary

You shipped:

- A unified event shape across login, uploads, deletes, permission
  changes.
- Sync mode for must-land events (failed login, admin delete).
- Async mode for the hot path.
- DB-level append-only enforcement.
- GDPR right-of-access, admin reporting, and incident-response queries
  in a few lines each.
- Alarms on the only failure mode the library has (overflow).

The library itself is a primitive — actors, actions, timestamps, an
adapter. Everything else (auth, storage, jobs, dashboards, alarms,
retention) is in the consuming app, where it belongs.
