-module(nova_audit_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct.hrl").

all() ->
    [
        log_sync_writes_via_logger_adapter,
        log_async_writes_via_worker,
        event_gets_event_id_assigned,
        event_gets_schema_version_assigned,
        event_gets_occurred_at_assigned,
        missing_required_field_errors,
        redactor_applied_before_write,
        query_returns_not_supported_for_log_adapter,
        unknown_log_returns_error
    ].

init_per_suite(Config) ->
    _ = application:load(nova_audit),
    application:set_env(nova_audit, logs, #{
        suite => #{adapter => nova_audit_log, level => info},
        red_suite => #{
            adapter => nova_audit_log,
            level => info,
            redactor => fun(Event) -> Event#{metadata => #{<<"redacted">> => true}} end
        }
    }),
    {ok, _} = application:ensure_all_started(nova_audit),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(nova_audit),
    ok.

log_sync_writes_via_logger_adapter(_Config) ->
    ok = nova_audit:log(suite, sample_event()).

log_async_writes_via_worker(_Config) ->
    ok = nova_audit:log_async(suite, sample_event()),
    timer:sleep(50).

event_gets_event_id_assigned(_Config) ->
    Built = nova_audit_event:build(sample_event_no_id()),
    Id = maps:get(event_id, Built),
    true = is_binary(Id),
    %% UUIDv7 string length 36 (8-4-4-4-12)
    36 = byte_size(Id).

event_gets_schema_version_assigned(_Config) ->
    Built = nova_audit_event:build(sample_event_no_id()),
    1 = maps:get(schema_version, Built).

event_gets_occurred_at_assigned(_Config) ->
    Built = nova_audit_event:build(sample_event_no_id()),
    T = maps:get(occurred_at, Built),
    true = is_integer(T),
    true = T > 1_700_000_000_000_000.

missing_required_field_errors(_Config) ->
    try
        nova_audit:log(suite, #{action => <<"x">>}),
        ct:fail(should_have_errored)
    catch
        error:{missing_required_field, actor} -> ok
    end.

redactor_applied_before_write(_Config) ->
    %% Just verify it doesn't crash; redactor returns event with replaced metadata
    ok = nova_audit:log(red_suite, sample_event()).

query_returns_not_supported_for_log_adapter(_Config) ->
    {error, query_not_supported} = nova_audit:query(suite, #{}).

unknown_log_returns_error(_Config) ->
    {error, not_found} = nova_audit:log(no_such_log, sample_event()).

sample_event() ->
    #{
        actor => #{type => user, id => <<"alice">>},
        action => <<"doc.upload">>,
        target => #{type => <<"document">>, id => <<"doc-1">>}
    }.

sample_event_no_id() -> sample_event().
