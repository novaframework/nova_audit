-module(nova_audit_log).
-moduledoc """
OTP-logger adapter for `nova_audit`.

Writes events as structured JSON via `logger:log/3` at a configurable level.
Useful for dev environments and deployments without a database. Does NOT
support `query/3` — events are not retained for read-back.

## Configuration

```erlang
#{adapter => nova_audit_log, level => info}
```
""".

-behaviour(gen_server).
-behaviour(nova_audit_adapter).

-export([start_link/2]).
-export([write/2, query/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {name :: atom(), level :: logger:level()}).
-record(handle, {name :: atom(), level :: logger:level()}).

start_link(Name, Opts) ->
    gen_server:start_link(?MODULE, {Name, Opts}, []).

write(Event, #handle{level = Level, name = Name}) ->
    logger:log(Level, #{event => nova_audit, log_name => Name, audit_event => Event}),
    ok.

query(_Filter, _Opts, _State) ->
    {error, query_not_supported}.

init({Name, Opts}) ->
    Level = maps:get(level, Opts, info),
    Handle = #handle{name = Name, level = Level},
    {ok, Worker} = nova_audit_worker:start_link(Name, ?MODULE, Handle),
    ok = nova_audit_registry:register(Name, ?MODULE, Handle, Worker),
    {ok, #state{name = Name, level = Level}}.

handle_call(_, _, S) -> {reply, {error, unknown_call}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
