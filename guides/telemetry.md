# Telemetry

`nova_audit` emits telemetry events when the `telemetry` application is
loaded at runtime. The dependency is optional; calls without it no-op.

## Events

| Event                                 | Measurements        | Metadata                                              |
| ------------------------------------- | ------------------- | ----------------------------------------------------- |
| `[nova_audit, log, start]`            | `system_time`       | `log_name`, `adapter`, `op`                           |
| `[nova_audit, log, stop]`             | `duration`          | `log_name`, `adapter`, `op`, `result`                 |
| `[nova_audit, log, exception]`        | `duration`          | `log_name`, `adapter`, `op`, `kind`, `reason`, `stacktrace` |
| `[nova_audit, query, start]`          | `system_time`       | `log_name`, `adapter`, `op`                           |
| `[nova_audit, query, stop]`           | `duration`          | `log_name`, `adapter`, `op`, `result`                 |
| `[nova_audit, query, exception]`      | `duration`          | `log_name`, `adapter`, `op`, `kind`, `reason`, `stacktrace` |
| `[nova_audit, overflow]`              | `count` (1)         | `log_name`                                            |
| `[nova_audit, write_error]`           | `count` (1)         | `log_name`, `reason`                                  |

`result` is `ok | error | other`.

`duration` is in native units; convert with `erlang:convert_time_unit/3`.

## Alarming on overflow

The fallback worker drops events when the queue is saturated. The
`[nova_audit, overflow]` event fires on every drop. In production,
attach a handler that pages on sustained overflow:

```erlang
telemetry:attach(
    audit_overflow_pager,
    [nova_audit, overflow],
    fun(_Event, _Meas, #{log_name := L}, _) ->
        my_pager:alert(<<"nova_audit overflow on ", (atom_to_binary(L))/binary>>)
    end,
    no_state
).
```

If overflow is frequent, increase the log's `max_queue`, switch to
`log/2` (sync) for must-land events, or install `shigoto` so async
events route through a durable job queue instead of the in-process
worker.
