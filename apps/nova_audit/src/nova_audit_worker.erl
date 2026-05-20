-module(nova_audit_worker).
-moduledoc """
Per-log async worker for `nova_audit`.

Backbone for `nova_audit:log_async/2` when `shigoto` is not loaded.
Bounded mailbox; on overflow, the oldest queued event is kept and the
newest is dropped. Drops emit `[nova_audit, overflow]` telemetry events
so consumers can alarm.

In-flight events are lost on process crash. For "must land" events use
the synchronous `nova_audit:log/2` path.
""".

-behaviour(gen_server).

-export([start_link/3, write/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(DEFAULT_MAX_QUEUE, 10_000).

-record(state, {
    name :: atom(),
    adapter :: module(),
    adapter_state :: term(),
    max_queue :: non_neg_integer()
}).

start_link(Name, Adapter, AdapterState) ->
    gen_server:start_link(?MODULE, {Name, Adapter, AdapterState}, []).

write(Worker, Event) ->
    Max = max_queue_for(Worker),
    case erlang:process_info(Worker, message_queue_len) of
        {message_queue_len, N} when N >= Max ->
            {message_queue_len, _} = {message_queue_len, N},
            overflow(Worker),
            ok;
        _ ->
            Worker ! {nova_audit_write, Event},
            ok
    end.

init({Name, Adapter, AdapterState}) ->
    Logs = application:get_env(nova_audit, logs, #{}),
    MaxQueue =
        case maps:get(Name, Logs, #{}) of
            #{max_queue := M} -> M;
            _ -> ?DEFAULT_MAX_QUEUE
        end,
    erlang:put(nova_audit_worker_name, Name),
    erlang:put(nova_audit_worker_max_queue, MaxQueue),
    {ok, #state{
        name = Name,
        adapter = Adapter,
        adapter_state = AdapterState,
        max_queue = MaxQueue
    }}.

handle_call(get_max_queue, _From, S = #state{max_queue = M, name = N}) ->
    {reply, {M, N}, S};
handle_call(_, _, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_, S) ->
    {noreply, S}.

handle_info(
    {nova_audit_write, Event},
    S = #state{adapter = A, adapter_state = AS, name = Name}
) ->
    case A:write(Event, AS) of
        ok -> ok;
        {error, Reason} -> nova_audit_telemetry:write_error(Name, Reason, Event)
    end,
    {noreply, S};
handle_info(_, S) ->
    {noreply, S}.

%% Internal

max_queue_for(Worker) ->
    {M, _Name} = gen_server:call(Worker, get_max_queue),
    M.

overflow(Worker) ->
    {_M, Name} = gen_server:call(Worker, get_max_queue),
    nova_audit_telemetry:overflow(Name).
