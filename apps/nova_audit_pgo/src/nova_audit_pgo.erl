-module(nova_audit_pgo).
-moduledoc """
pgo-backed adapter for `nova_audit`.

Writes events directly to a Postgres table via `pgo`, bypassing any ORM
layer. Useful for apps that already use pgo (or want to) and don't want
Kura as a transitive dependency.

## Configuration

```erlang
#{
    adapter => nova_audit_pgo,
    pool => default,
    table => <<"audit_events">>
}
```

The `pgo` pool must be started by the application; this adapter does NOT
manage pool lifecycle.

## Schema

Uses the same table shape as `nova_audit_kura`. See
`nova_audit_pgo:schema_sql/0` (identical to `nova_audit_kura:schema_sql/0`).

## Hardening

After applying the schema, REVOKE UPDATE and DELETE on the audit table
for your application role. See `nova_audit_pgo:hardening_sql/0` or use
the Kura adapter's helper interchangeably.

## pg_types configuration

For UUIDv7 round-tripping through pgo, configure `pg_types` with
`uuid_format=string` at startup so `event_id` arrives as a binary on
both write and read paths.
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
    pool :: atom(),
    table :: binary()
}).

start_link(Name, Opts) ->
    gen_server:start_link(?MODULE, {Name, Opts}, []).

write(Event, #handle{pool = Pool, table = Table}) ->
    SQL = <<
        "INSERT INTO ", Table/binary,
        " (event_id, schema_version, occurred_at, actor_type, actor_id, "
        " action, target_type, target_id, outcome, source, request_id, metadata) "
        "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12::jsonb)"
    >>,
    Params = event_to_params(Event),
    case erlang:function_exported(pgo, query, 3) of
        true ->
            case apply(pgo, query, [SQL, Params, #{pool => Pool}]) of
                #{command := insert} -> ok;
                #{error := Reason} -> {error, Reason};
                Other -> {error, {unexpected_pgo_result, Other}}
            end;
        false ->
            {error, pgo_not_loaded}
    end.

query(Filter, Opts, #handle{pool = Pool, table = Table}) ->
    Limit = maps:get(limit, Opts, 100),
    {Where, Params} = filter_to_where(Filter),
    Cursor = maps:get(cursor, Opts, undefined),
    {CursorClause, Params2} = cursor_clause(Cursor, Where, Params),
    SQL = iolist_to_binary([
        <<
            "SELECT event_id, schema_version, occurred_at, actor_type, actor_id, "
            " action, target_type, target_id, outcome, source, request_id, metadata "
            "FROM "
        >>,
        Table,
        Where,
        CursorClause,
        <<" ORDER BY occurred_at LIMIT $">>,
        integer_to_binary(length(Params2) + 1)
    ]),
    AllParams = Params2 ++ [Limit],
    case erlang:function_exported(pgo, query, 3) of
        true ->
            case apply(pgo, query, [SQL, AllParams, #{pool => Pool}]) of
                #{rows := Rows} ->
                    Events = [row_to_event(R) || R <- Rows],
                    {ok, Events, next_cursor(Events, Limit)};
                #{error := Reason} ->
                    {error, Reason};
                Other ->
                    {error, {unexpected_pgo_result, Other}}
            end;
        false ->
            {error, pgo_not_loaded}
    end.

init({Name, Opts}) ->
    Pool = maps:get(pool, Opts, default),
    Table = to_binary(maps:get(table, Opts, <<"audit_events">>)),
    Handle = #handle{name = Name, pool = Pool, table = Table},
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
    nova_audit_kura:schema_sql().

%% Internal

event_to_params(Event) ->
    Actor = maps:get(actor, Event),
    Target = maps:get(target, Event, undefined),
    [
        maps:get(event_id, Event),
        maps:get(schema_version, Event, 1),
        maps:get(occurred_at, Event),
        atom_to_binary(maps:get(type, Actor)),
        maps:get(id, Actor),
        maps:get(action, Event),
        target_field(Target, type),
        target_field(Target, id),
        outcome_to_binary(maps:get(outcome, Event, undefined)),
        maps:get(source, Event, null),
        maps:get(request_id, Event, null),
        iolist_to_binary(json:encode(maps:get(metadata, Event, #{})))
    ].

target_field(undefined, _) -> null;
target_field(T, F) -> maps:get(F, T, null).

outcome_to_binary(undefined) -> null;
outcome_to_binary(A) when is_atom(A) -> atom_to_binary(A).

filter_to_where(Filter) ->
    {Clauses, Params, _N} = maps:fold(
        fun
            (actor_id, V, {Cs, Ps, N}) ->
                {[clause(<<"actor_id">>, N) | Cs], [V | Ps], N + 1};
            (action, V, {Cs, Ps, N}) ->
                {[clause(<<"action">>, N) | Cs], [V | Ps], N + 1};
            (outcome, V, {Cs, Ps, N}) ->
                {[clause(<<"outcome">>, N) | Cs], [atom_to_binary(V) | Ps], N + 1};
            (target_id, V, {Cs, Ps, N}) ->
                {[clause(<<"target_id">>, N) | Cs], [V | Ps], N + 1};
            (target_type, V, {Cs, Ps, N}) ->
                {[clause(<<"target_type">>, N) | Cs], [V | Ps], N + 1};
            (request_id, V, {Cs, Ps, N}) ->
                {[clause(<<"request_id">>, N) | Cs], [V | Ps], N + 1};
            (occurred_after, V, {Cs, Ps, N}) ->
                C = <<"occurred_at >= $", (integer_to_binary(N))/binary>>,
                {[C | Cs], [V | Ps], N + 1};
            (occurred_before, V, {Cs, Ps, N}) ->
                C = <<"occurred_at < $", (integer_to_binary(N))/binary>>,
                {[C | Cs], [V | Ps], N + 1};
            (_, _, Acc) ->
                Acc
        end,
        {[], [], 1},
        Filter
    ),
    case Clauses of
        [] -> {<<>>, []};
        _ ->
            Joined = lists:join(<<" AND ">>, lists:reverse(Clauses)),
            {iolist_to_binary([<<" WHERE ">> | Joined]), lists:reverse(Params)}
    end.

clause(Field, N) ->
    <<Field/binary, " = $", (integer_to_binary(N))/binary>>.

cursor_clause(undefined, _Where, Params) -> {<<>>, Params};
cursor_clause(done, _Where, Params) -> {<<>>, Params};
cursor_clause(Cursor, Where, Params) when is_binary(Cursor) ->
    Connector =
        case Where of
            <<>> -> <<" WHERE ">>;
            _ -> <<" AND ">>
        end,
    N = length(Params) + 1,
    {<<Connector/binary, "occurred_at > $", (integer_to_binary(N))/binary>>,
        Params ++ [binary_to_integer(Cursor)]}.

next_cursor([], _) -> done;
next_cursor(Events, Limit) when length(Events) < Limit -> done;
next_cursor(Events, _) ->
    Last = lists:last(Events),
    integer_to_binary(maps:get(occurred_at, Last)).

row_to_event(
    {EventId, SchemaVersion, OccurredAt, ActorType, ActorId, Action,
     TargetType, TargetId, Outcome, Source, RequestId, Metadata}
) ->
    Base = #{
        event_id => EventId,
        schema_version => SchemaVersion,
        occurred_at => OccurredAt,
        actor => actor_from_row(ActorType, ActorId),
        action => Action,
        metadata => decode_metadata(Metadata)
    },
    Base1 = maybe_put(target, target_from_row(TargetType, TargetId), Base),
    Base2 = maybe_put(outcome, outcome_from_row(Outcome), Base1),
    Base3 = maybe_put(source, nullable(Source), Base2),
    maybe_put(request_id, nullable(RequestId), Base3).

actor_from_row(Type, Id) when is_binary(Type) ->
    #{type => binary_to_atom(Type), id => Id};
actor_from_row(Type, Id) when is_atom(Type) ->
    #{type => Type, id => Id}.

target_from_row(null, _) -> undefined;
target_from_row(_, null) -> undefined;
target_from_row(Type, Id) -> #{type => Type, id => Id}.

outcome_from_row(null) -> undefined;
outcome_from_row(<<"success">>) -> success;
outcome_from_row(<<"failure">>) -> failure;
outcome_from_row(O) -> O.

nullable(null) -> undefined;
nullable(V) -> V.

maybe_put(_K, undefined, M) -> M;
maybe_put(K, V, M) -> M#{K => V}.

decode_metadata(null) -> #{};
decode_metadata(M) when is_map(M) -> M;
decode_metadata(B) when is_binary(B) ->
    try json:decode(B) of
        M when is_map(M) -> M;
        _ -> #{}
    catch
        _:_ -> #{}
    end.

to_binary(B) when is_binary(B) -> B;
to_binary(A) when is_atom(A) -> atom_to_binary(A).
