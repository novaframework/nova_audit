-module(nova_audit_event).
-moduledoc false.

-export([build/1, schema_version/0]).

-define(SCHEMA_VERSION, 1).

schema_version() -> ?SCHEMA_VERSION.

-spec build(map()) -> map().
build(Event0) ->
    require_field(actor, Event0),
    require_field(action, Event0),
    Event1 = ensure_event_id(Event0),
    Event2 = Event1#{schema_version => ?SCHEMA_VERSION},
    ensure_occurred_at(Event2).

require_field(K, M) ->
    case maps:is_key(K, M) of
        true -> ok;
        false -> error({missing_required_field, K})
    end.

ensure_event_id(E = #{event_id := _}) -> E;
ensure_event_id(E) -> E#{event_id => generate_uuidv7()}.

ensure_occurred_at(E = #{occurred_at := _}) -> E;
ensure_occurred_at(E) -> E#{occurred_at => erlang:system_time(microsecond)}.

generate_uuidv7() ->
    case erlang:function_exported(jhn_uuid, gen, 1) of
        true -> iolist_to_binary(jhn_uuid:gen(v7));
        false -> roll_our_own_uuidv7()
    end.

roll_our_own_uuidv7() ->
    Ms = erlang:system_time(millisecond),
    <<R1:12, R2:62, _:6>> = crypto:strong_rand_bytes(10),
    Bin = <<Ms:48, 7:4, R1:12, 2:2, R2:62>>,
    <<A:32, B:16, C:16, D:16, E:48>> = Bin,
    iolist_to_binary(
        io_lib:format(
            "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
            [A, B, C, D, E]
        )
    ).
