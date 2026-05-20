-module(nova_audit_telemetry).
-moduledoc false.

-export([span/4, overflow/1, write_error/3]).

span(Op, LogName, Adapter, Fun) ->
    Start = erlang:monotonic_time(),
    Meta = #{log_name => LogName, adapter => Adapter, op => Op},
    emit([nova_audit, Op, start], #{system_time => erlang:system_time()}, Meta),
    try Fun() of
        Result ->
            Duration = erlang:monotonic_time() - Start,
            emit(
                [nova_audit, Op, stop],
                #{duration => Duration},
                Meta#{result => result_tag(Result)}
            ),
            Result
    catch
        Class:Reason:Stack ->
            Duration = erlang:monotonic_time() - Start,
            emit(
                [nova_audit, Op, exception],
                #{duration => Duration},
                Meta#{kind => Class, reason => Reason, stacktrace => Stack}
            ),
            erlang:raise(Class, Reason, Stack)
    end.

overflow(LogName) ->
    emit([nova_audit, overflow], #{count => 1}, #{log_name => LogName}).

write_error(LogName, Reason, Event) ->
    logger:error(#{
        event => nova_audit_write_error,
        log_name => LogName,
        reason => Reason,
        audit_event => Event
    }),
    emit(
        [nova_audit, write_error],
        #{count => 1},
        #{log_name => LogName, reason => Reason}
    ).

emit(Event, Measurements, Meta) ->
    case code:is_loaded(telemetry) of
        {file, _} ->
            try
                M = telemetry,
                F = execute,
                apply(M, F, [Event, Measurements, Meta])
            catch
                _:_ -> ok
            end;
        false ->
            ok
    end.

result_tag(ok) -> ok;
result_tag({ok, _}) -> ok;
result_tag({ok, _, _}) -> ok;
result_tag({error, _}) -> error;
result_tag(_) -> other.
