-module(nova_audit_pgo_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct.hrl").

all() ->
    [
        write_returns_error_when_pgo_not_loaded,
        query_returns_error_when_pgo_not_loaded,
        hardening_sql_returns_revoke_statements,
        schema_sql_returns_create_table,
        starts_via_supervisor
    ].

init_per_suite(Config) ->
    _ = application:load(nova_audit),
    application:set_env(nova_audit, logs, #{
        pgo_suite => #{adapter => nova_audit_pgo, pool => fake_pool, table => <<"audit_events">>}
    }),
    {ok, _} = application:ensure_all_started(nova_audit),
    Config.

end_per_suite(_) ->
    application:stop(nova_audit),
    ok.

starts_via_supervisor(_Config) ->
    %% Adapter starts even though pgo isn't loaded; calls will fail at write/query
    {ok, _, _, _} = nova_audit_registry:lookup(pgo_suite).

write_returns_error_when_pgo_not_loaded(_Config) ->
    {error, pgo_not_loaded} = nova_audit:log(pgo_suite, sample_event()).

query_returns_error_when_pgo_not_loaded(_Config) ->
    {error, pgo_not_loaded} = nova_audit:query(pgo_suite, #{}).

hardening_sql_returns_revoke_statements(_Config) ->
    {ok, [First | _]} = nova_audit_pgo:hardening_sql(),
    true = binary:match(First, <<"REVOKE">>) =/= nomatch.

schema_sql_returns_create_table(_Config) ->
    Sql = nova_audit_pgo:schema_sql(),
    true = binary:match(Sql, <<"CREATE TABLE">>) =/= nomatch,
    true = binary:match(Sql, <<"audit_events">>) =/= nomatch.

sample_event() ->
    #{
        actor => #{type => user, id => <<"alice">>},
        action => <<"x">>
    }.
