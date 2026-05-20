-module(nova_audit).
-moduledoc """
Public API for the nova_audit library.

Append-only domain-event log. "Who did what when" trail. Compounds the
compliance story for DORA, NIS2, GDPR, AI Act audit-trail requirements.

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
    actor => #{type => user, id => <<"alice">>},
    action => <<"document.delete">>,
    target => #{type => <<"document">>, id => <<"doc-42">>},
    outcome => success
},
ok = nova_audit:log(app_events, Event).
```

## Append-only

The public API has no update or delete. Storage-level enforcement is the
operator's responsibility; see `nova_audit_kura:hardening_sql/0` for the
Postgres-revoke pattern.

## Redaction

Per-log `redactor => fun((event()) -> event())` is applied before the
adapter sees the event. Write-time only. Query-time access control is the
caller's responsibility; this library exposes raw events from `query/2,3`.
""".

-export([log/2, log_async/2, query/2, query/3]).

-type log_name() :: atom().
-type actor_type() :: user | service | system | anonymous.
-type actor() :: #{
    id := binary(),
    type := actor_type(),
    attributes => #{binary() => binary()}
}.
-type target() :: #{
    id := binary(),
    type := binary(),
    attributes => #{binary() => binary()}
}.
-type event() :: #{
    actor := actor(),
    action := binary(),
    occurred_at => non_neg_integer(),
    event_id => binary(),
    schema_version => pos_integer(),
    target => target(),
    outcome => success | failure,
    source => binary(),
    request_id => binary(),
    metadata => #{binary() => term()}
}.
-type filter() :: #{
    actor_id => binary(),
    action => binary(),
    occurred_after => non_neg_integer(),
    occurred_before => non_neg_integer(),
    outcome => success | failure,
    target_id => binary(),
    target_type => binary(),
    request_id => binary()
}.

-export_type([log_name/0, actor/0, target/0, event/0, filter/0]).

-spec log(log_name(), event()) -> ok | {error, term()}.
log(LogName, Event0) ->
    Event = nova_audit_event:build(Event0),
    with_log(LogName, fun(Adapter, State, _Worker, Spec) ->
        Redacted = apply_redactor(Spec, Event),
        nova_audit_telemetry:span(log, LogName, Adapter, fun() ->
            Adapter:write(Redacted, State)
        end)
    end).

-spec log_async(log_name(), event()) -> ok | {error, term()}.
log_async(LogName, Event0) ->
    Event = nova_audit_event:build(Event0),
    with_log(LogName, fun(Adapter, _State, Worker, Spec) ->
        Redacted = apply_redactor(Spec, Event),
        dispatch_async(LogName, Worker, Adapter, Redacted)
    end).

-spec query(log_name(), filter()) ->
    {ok, [event()], nova_audit_adapter:cursor()} | {error, term()}.
query(LogName, Filter) ->
    query(LogName, Filter, #{}).

-spec query(log_name(), filter(), nova_audit_adapter:query_opts()) ->
    {ok, [event()], nova_audit_adapter:cursor()} | {error, term()}.
query(LogName, Filter, Opts) ->
    with_log(LogName, fun(Adapter, State, _Worker, _Spec) ->
        nova_audit_telemetry:span(query, LogName, Adapter, fun() ->
            Adapter:query(Filter, Opts, State)
        end)
    end).

%% Internal

with_log(LogName, Fun) ->
    case nova_audit_registry:lookup(LogName) of
        {ok, Adapter, State, Worker} ->
            Spec = log_spec(LogName),
            Fun(Adapter, State, Worker, Spec);
        {error, _} = E ->
            E
    end.

log_spec(LogName) ->
    case application:get_env(nova_audit, logs, #{}) of
        #{LogName := Spec} -> Spec;
        _ -> #{}
    end.

apply_redactor(#{redactor := F}, Event) when is_function(F, 1) ->
    F(Event);
apply_redactor(_, Event) ->
    Event.

dispatch_async(LogName, Worker, Adapter, Event) ->
    case shigoto_available() of
        true -> shigoto_enqueue(LogName, Adapter, Event);
        false -> nova_audit_worker:write(Worker, Event)
    end.

shigoto_available() ->
    case code:is_loaded(shigoto) of
        {file, _} -> true;
        false -> false
    end.

shigoto_enqueue(LogName, Adapter, Event) ->
    try
        M = shigoto,
        F = enqueue,
        apply(M, F, [#{
            queue => nova_audit,
            module => nova_audit_shigoto_job,
            args => #{log_name => LogName, adapter => Adapter, event => Event}
        }])
    catch
        _:_ -> ok
    end.
