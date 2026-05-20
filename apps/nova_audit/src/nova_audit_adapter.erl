-module(nova_audit_adapter).
-moduledoc """
Behaviour for nova_audit adapters.

Adapters own their own process. The `State` returned at registration time is
opaque to `nova_audit` and passed back to every callback.

## Append-only contract

Adapters MUST NOT expose update or delete operations through this behaviour.
The audit log is append-only by API contract. Storage-level enforcement
(database privileges, immutable buckets) is the operator's responsibility;
see `nova_audit_kura:hardening_sql/0` for the Kura-backed pattern.
""".

-type log_name() :: atom().
-type event() :: nova_audit:event().
-type filter() :: nova_audit:filter().
-type query_opts() :: #{cursor => binary() | done, limit => pos_integer()}.
-type cursor() :: binary() | done.

-export_type([log_name/0, query_opts/0, cursor/0]).

-callback start_link(Name :: log_name(), Opts :: map()) -> {ok, pid()} | {error, term()}.
-callback write(Event :: event(), State :: term()) -> ok | {error, term()}.
-callback query(Filter :: filter(), Opts :: query_opts(), State :: term()) ->
    {ok, [event()], cursor()} | {error, term()}.
