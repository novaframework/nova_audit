# Adapters

Adapters implement the `nova_audit_adapter` behaviour. They own their
own process. The `State` returned at registration is opaque to
`nova_audit`.

## Dependency model — pull only what you use

Three sibling OTP apps ship in this umbrella:

- `nova_audit` — core. Only runtime dep: `jhn_stdlib` (for UUIDv7).
- `nova_audit_kura` — Kura/Postgres adapter. Depends on `nova_audit`. Calls into `kura_repo` and `kura_query` via runtime `erlang:function_exported/3` checks.
- `nova_audit_pgo` — pgo/Postgres adapter. Depends on `nova_audit`. Calls into `pgo` via runtime checks.

What this means when you take a dep on `nova_audit`:

| You add to your rebar.config       | You actually need                                |
| ---------------------------------- | ------------------------------------------------ |
| `nova_audit` only                  | `jhn_stdlib`. Adapters compile but only `nova_audit_log` works without extra deps. |
| `nova_audit` + use `nova_audit_kura` | Add `kura` to your own deps. Without it, `write/2` returns `{error, kura_not_loaded}`. |
| `nova_audit` + use `nova_audit_pgo`  | Add `pgo` to your own deps. Without it, `write/2` returns `{error, pgo_not_loaded}`.   |
| `nova_audit` + a custom adapter      | Whatever your adapter needs. Nothing else.                                          |

The adapter modules ship as ~30KB of compiled `.beam` per adapter
regardless. They sit dead in your build until you configure a log to
use them. There is no runtime cost for adapters you don't configure.

If you only want the core and write your own adapter, that's the
default — no Kura, no pgo, no transitive deps you didn't ask for.

## `nova_audit_log`

OTP-logger adapter. Writes events as structured JSON at a configurable
log level. Useful for dev environments and deployments without a
database.

| Option   | Default | Notes                                       |
| -------- | ------- | ------------------------------------------- |
| `level`  | `info`  | OTP logger level.                           |

Does **not** support `query/3`; calls return
`{error, query_not_supported}`.

## `nova_audit_kura`

Postgres adapter via Kura.

| Option   | Required | Notes                                       |
| -------- | -------- | ------------------------------------------- |
| `repo`   | yes      | Kura repo atom.                             |
| `table`  | no       | Default `<<"audit_events">>`.               |

The consumer manages the schema via `rebar3 kura compile` migrations.
See `nova_audit_kura:schema_sql/0` for the recommended shape (UUID
primary key, indexes on `occurred_at`, `actor_id`, `action`,
`target_id`, `request_id`).

After applying the migration, lock down updates and deletes:

```erlang
{ok, Statements} = nova_audit_kura:hardening_sql(),
%% Apply via admin credentials with REVOKE privileges, not from the app role.
```

## `nova_audit_pgo`

Postgres adapter that talks to `pgo` directly, bypassing Kura.

| Option   | Required | Notes                                       |
| -------- | -------- | ------------------------------------------- |
| `pool`   | no       | pgo pool atom; defaults to `default`.       |
| `table`  | no       | Default `<<"audit_events">>`.               |

The schema is identical to the Kura adapter's; use whichever migration
tooling you prefer (`pgo_migrations`, raw `psql` scripts, Flyway, etc.).
For convenience the SQL is mirrored at `nova_audit_pgo:schema_sql/0`
(it just delegates to `nova_audit_kura:schema_sql/0` so there's one
source of truth).

```erlang
nova_audit_pgo:schema_sql().      %% same table shape
nova_audit_pgo:hardening_sql().   %% same REVOKE pattern
```

The pgo pool must be started by your application; this adapter does not
manage pool lifecycle. For UUIDv7 round-tripping, configure `pg_types`
with `uuid_format=string` so `event_id` arrives as a binary on both
read and write.

## Writing your own adapter

The behaviour is small:

```erlang
-callback start_link(Name :: atom(), Opts :: map()) -> {ok, pid()} | {error, term()}.
-callback write(Event :: event(), State :: term()) -> ok | {error, term()}.
-callback query(Filter, Opts, State) -> {ok, [event()], Cursor} | {error, term()}.
```

A minimal skeleton:

```erlang
-module(my_audit_adapter).
-behaviour(gen_server).
-behaviour(nova_audit_adapter).

-export([start_link/2, write/2, query/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(handle, {name :: atom(), conn :: my_db:connection()}).

start_link(Name, Opts) ->
    gen_server:start_link(?MODULE, {Name, Opts}, []).

write(Event, #handle{conn = Conn}) ->
    my_db:insert(Conn, audit_events, event_to_row(Event)).

query(Filter, Opts, #handle{conn = Conn}) ->
    Rows = my_db:select(Conn, audit_events, filter_to_where(Filter), Opts),
    {ok, [row_to_event(R) || R <- Rows], cursor_from(Rows, Opts)}.

init({Name, Opts}) ->
    {ok, Conn} = my_db:connect(maps:get(connection, Opts)),
    Handle = #handle{name = Name, conn = Conn},
    {ok, Worker} = nova_audit_worker:start_link(Name, ?MODULE, Handle),
    ok = nova_audit_registry:register(Name, ?MODULE, Handle, Worker),
    {ok, Handle}.

handle_call(_, _, S) -> {reply, {error, unknown_call}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.

%% event_to_row/1, filter_to_where/1, row_to_event/1 are mechanical;
%% see nova_audit_pgo for a full example.
```

Required wiring inside `init/1`:

1. Build your opaque adapter state (a record or map).
2. Spawn `nova_audit_worker:start_link(Name, ?MODULE, AdapterState)` for the async fallback (used by `log_async/2` when shigoto isn't loaded).
3. Register via `nova_audit_registry:register(Name, ?MODULE, AdapterState, WorkerPid)`.

`write/2` is called from BOTH the caller's process (for sync `log/2`)
and the worker process (for async). The adapter state must be safe to
share — a pool name, a connection pid, an ETS table id, etc.

`query/3` returns `{ok, Events, Cursor}` where `Cursor` is either an
adapter-defined opaque binary or `done`. Adapters that don't support
querying may return `{error, query_not_supported}`.

If the adapter naturally batches writes, you can collect events
internally and flush on size or timer; the worker will keep handing
you one event at a time.

## Soft-dep pattern

If your adapter wraps a library that consumers may or may not have
installed, use the same runtime-check pattern as `nova_audit_kura` and
`nova_audit_pgo`:

```erlang
write(Event, #handle{...}) ->
    case erlang:function_exported(my_lib, insert, 2) of
        true -> my_lib:insert(...);
        false -> {error, my_lib_not_loaded}
    end.
```

And in the umbrella's `rebar.config`:

```erlang
{xref_ignores, [
    {my_lib, '_', '_'}    %% or list specific MFAs
]}.
```

This lets the adapter compile and ship without forcing the underlying
library on consumers who don't use it.
