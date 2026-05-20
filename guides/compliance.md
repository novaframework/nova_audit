# Compliance Notes

`nova_audit` is a generic primitive. Compliance frameworks layer on top.

## What this library gives you

- Append-only event log with `event_id`, `schema_version`, `actor`,
  `action`, `occurred_at` (microseconds), and optional `target`,
  `outcome`, `source`, `request_id`, `metadata`.
- Sync and async write paths. Sync blocks until the adapter returns.
- Query API with eight filter keys.
- Write-time redaction hook.
- Telemetry events.
- `nova_audit_kura:hardening_sql/0` to REVOKE UPDATE and DELETE on the
  audit table.

## What this library deliberately does NOT give you

- **Retention policies.** Operator's job. Compliance modules layer this
  on top.
- **Tamper-evidence / chain hashing.** v0.2+ or downstream lib (think
  `nova_audit_signed` wrapping the adapter).
- **Cryptographic signatures.** Same as above.
- **Forensic chain-of-custody.** Same as above.
- **Query-time access control.** Caller's job; `query/2,3` returns raw
  events.
- **PII detection / auto-redaction.** Caller supplies the `redactor`.
- **Logger / metrics / traces.** Use `logger`, `telemetry`, OTel.

## Mapping to common frameworks

These mappings are guidance, not certification. Consult a qualified
auditor for the specifics of your environment.

### DORA Article 28 (ICT-related incident reporting)

- Required: incident actor, action, timestamp, outcome. All native fields.
- Retention: 5 years for major incidents. Operator's archival job.

### NIS2 Article 21

- Required: security event audit trail with attribution.
- `actor` + `action` + `target` cover the required attribution.

### GDPR Article 30 (records of processing)

- Required: who accessed personal data, when, for what purpose.
- `actor`, `action`, `target` (data subject id), `metadata.purpose`.
- The `redactor` hook can strip the personal data itself from the log
  payload — log the access, not the contents.

### EU AI Act (high-risk system logs)

- Required: input/output recording, operator/user attribution,
  timestamp, decision outcome.
- `actor`, `action` (e.g. `<<"model.predict">>`), `outcome`, `metadata`
  for model version + input hash.

## Recommended operator hardening

1. Apply `nova_audit_kura:hardening_sql/0` after the Kura migration to
   prevent UPDATE and DELETE from the application role.
2. Ship audit-table backups to immutable storage (S3 Object Lock, etc.).
3. Monitor `[nova_audit, overflow]` telemetry — if it fires, increase
   `max_queue` or switch the log to `mode => sync` for must-land events.
4. Monitor `[nova_audit, write_error]` — adapter write failures should
   page someone.
