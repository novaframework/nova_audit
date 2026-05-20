-module(nova_audit_kura).
-moduledoc """
Kura-backed adapter for `nova_audit`.

Writes events to a Postgres table via Kura. Schema is defined by the consumer
via `rebar3 kura compile` migrations; see this module's `schema_sql/0` for
the recommended shape.

## Configuration

```erlang
#{
    adapter => nova_audit_kura,
    repo => default,
    table => audit_events
}
```

## Hardening

After running the consumer's Kura migration, apply `hardening_sql/0` to
REVOKE UPDATE and DELETE privileges on the audit table for the application
role. The audit log is append-only by API contract; database-level
enforcement closes the gap.

```erlang
{ok, [Statement]} = nova_audit_kura:hardening_sql(),
%% Apply Statement with admin credentials, not from the application.
```
""".

-behaviour(gen_server).
-behaviour(nova_audit_adapter).

-export([start_link/2]).
-export([write/2, query/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export([hardening_sql/0, hardening_sql/1, schema_sql/0]).

-record(state, {name :: atom(), handle :: term()}).
-record(handle, {
    name :: atom(),
    repo :: atom(),
    table :: binary()
}).

start_link(Name, Opts) ->
    gen_server:start_link(?MODULE, {Name, Opts}, []).

write(Event, #handle{repo = Repo, table = Table}) ->
    Row = event_to_row(Event),
    case erlang:function_exported(kura_repo, insert, 3) of
        true ->
            apply(kura_repo, insert, [Repo, Table, Row]);
        false ->
            {error, kura_not_loaded}
    end.

query(Filter, Opts, #handle{repo = Repo, table = Table}) ->
    case erlang:function_exported(kura_query, query, 4) of
        true ->
            QFilter = filter_to_query(Filter),
            Limit = maps:get(limit, Opts, 100),
            apply(kura_query, query, [Repo, Table, QFilter, Limit]);
        false ->
            {error, kura_not_loaded}
    end.

init({Name, Opts}) ->
    Repo = maps:get(repo, Opts, default),
    Table = to_binary(maps:get(table, Opts, audit_events)),
    Handle = #handle{name = Name, repo = Repo, table = Table},
    {ok, Worker} = nova_audit_worker:start_link(Name, ?MODULE, Handle),
    ok = nova_audit_registry:register(Name, ?MODULE, Handle, Worker),
    {ok, #state{name = Name, handle = Handle}}.

handle_call(_, _, S) -> {reply, {error, unknown_call}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.

-spec hardening_sql() -> {ok, [binary()]}.
hardening_sql() ->
    hardening_sql(<<"audit_events">>).

-spec hardening_sql(binary()) -> {ok, [binary()]}.
hardening_sql(Table) ->
    {ok, [
        <<"REVOKE UPDATE, DELETE ON ", Table/binary, " FROM PUBLIC;">>,
        <<"-- Apply per-role grant separately, e.g.:">>,
        <<"-- REVOKE UPDATE, DELETE ON ", Table/binary, " FROM your_app_role;">>
    ]}.

-spec schema_sql() -> binary().
schema_sql() ->
    <<
        "CREATE TABLE IF NOT EXISTS audit_events (\n"
        "  event_id        UUID PRIMARY KEY,\n"
        "  schema_version  INTEGER NOT NULL DEFAULT 1,\n"
        "  occurred_at     BIGINT NOT NULL,\n"
        "  actor_type      TEXT NOT NULL,\n"
        "  actor_id        TEXT NOT NULL,\n"
        "  action          TEXT NOT NULL,\n"
        "  target_type     TEXT,\n"
        "  target_id       TEXT,\n"
        "  outcome         TEXT,\n"
        "  source          TEXT,\n"
        "  request_id      TEXT,\n"
        "  metadata        JSONB NOT NULL DEFAULT '{}'::jsonb\n"
        ");\n"
        "CREATE INDEX audit_events_occurred_at_idx ON audit_events (occurred_at);\n"
        "CREATE INDEX audit_events_actor_id_idx ON audit_events (actor_id);\n"
        "CREATE INDEX audit_events_action_idx ON audit_events (action);\n"
        "CREATE INDEX audit_events_target_id_idx ON audit_events (target_id) WHERE target_id IS NOT NULL;\n"
        "CREATE INDEX audit_events_request_id_idx ON audit_events (request_id) WHERE request_id IS NOT NULL;\n"
    >>.

%% Internal

event_to_row(Event) ->
    Actor = maps:get(actor, Event),
    Target = maps:get(target, Event, undefined),
    #{
        event_id => maps:get(event_id, Event),
        schema_version => maps:get(schema_version, Event, 1),
        occurred_at => maps:get(occurred_at, Event),
        actor_type => atom_to_binary(maps:get(type, Actor)),
        actor_id => maps:get(id, Actor),
        action => maps:get(action, Event),
        target_type => target_field(Target, type),
        target_id => target_field(Target, id),
        outcome => atom_or_null(maps:get(outcome, Event, undefined)),
        source => maps:get(source, Event, undefined),
        request_id => maps:get(request_id, Event, undefined),
        metadata => maps:get(metadata, Event, #{})
    }.

target_field(undefined, _) -> undefined;
target_field(T, F) -> maps:get(F, T, undefined).

atom_or_null(undefined) -> undefined;
atom_or_null(A) when is_atom(A) -> atom_to_binary(A).

filter_to_query(Filter) ->
    maps:fold(
        fun
            (actor_id, V, Acc) -> [{actor_id, eq, V} | Acc];
            (action, V, Acc) -> [{action, eq, V} | Acc];
            (outcome, V, Acc) -> [{outcome, eq, atom_to_binary(V)} | Acc];
            (target_id, V, Acc) -> [{target_id, eq, V} | Acc];
            (target_type, V, Acc) -> [{target_type, eq, V} | Acc];
            (request_id, V, Acc) -> [{request_id, eq, V} | Acc];
            (occurred_after, V, Acc) -> [{occurred_at, gte, V} | Acc];
            (occurred_before, V, Acc) -> [{occurred_at, lt, V} | Acc];
            (_, _, Acc) -> Acc
        end,
        [],
        Filter
    ).

to_binary(B) when is_binary(B) -> B;
to_binary(A) when is_atom(A) -> atom_to_binary(A).
