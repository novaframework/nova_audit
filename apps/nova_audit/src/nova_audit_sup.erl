-module(nova_audit_sup).
-moduledoc false.

-behaviour(supervisor).

-export([start_link/0, init/1, start_log/2, stop_log/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 60},
    Registry = #{
        id => nova_audit_registry,
        start => {nova_audit_registry, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },
    Logs = configured_logs(),
    {ok, {SupFlags, [Registry | Logs]}}.

start_log(Name, Spec) ->
    supervisor:start_child(?MODULE, child_spec(Name, Spec)).

stop_log(Name) ->
    case supervisor:terminate_child(?MODULE, Name) of
        ok -> supervisor:delete_child(?MODULE, Name);
        Error -> Error
    end.

configured_logs() ->
    Logs = application:get_env(nova_audit, logs, #{}),
    maps:fold(fun(Name, Spec, Acc) -> [child_spec(Name, Spec) | Acc] end, [], Logs).

child_spec(Name, Spec) ->
    Adapter = maps:get(adapter, Spec),
    #{
        id => Name,
        start => {Adapter, start_link, [Name, Spec]},
        restart => permanent,
        shutdown => 5000,
        type => worker
    }.
