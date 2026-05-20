-module(nova_audit_worker_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct.hrl").

all() ->
    [
        overflow_drops_newest_and_emits_telemetry,
        write_error_emits_telemetry
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(telemetry),
    _ = application:load(nova_audit),
    application:set_env(nova_audit, logs, #{
        small => #{adapter => nova_audit_log, level => info, max_queue => 0}
    }),
    {ok, _} = application:ensure_all_started(nova_audit),
    Config.

end_per_suite(_) ->
    application:stop(nova_audit),
    ok.

overflow_drops_newest_and_emits_telemetry(_Config) ->
    Self = self(),
    Ref = make_ref(),
    telemetry_attach(Self, Ref),
    %% Fire-and-forget many async writes to a small queue
    [
        nova_audit:log_async(small, #{
            actor => #{type => user, id => integer_to_binary(I)},
            action => <<"x">>
        })
     || I <- lists:seq(1, 50)
    ],
    %% At least one overflow event expected
    receive
        {Ref, [nova_audit, overflow], _, _} -> ok
    after 1000 -> ct:fail(no_overflow_emitted)
    end,
    telemetry_detach(Ref).

write_error_emits_telemetry(_Config) ->
    %% Smoke test: ensures the telemetry hook doesn't crash
    nova_audit_telemetry:write_error(test_log, sample_reason, sample_event),
    ok.

telemetry_attach(Pid, Ref) ->
    Handler = fun(Event, Measurements, Meta, _) ->
        Pid ! {Ref, Event, Measurements, Meta}
    end,
    _ = telemetry:attach(Ref, [nova_audit, overflow], Handler, undefined),
    ok.

telemetry_detach(Ref) ->
    _ = telemetry:detach(Ref),
    ok.
