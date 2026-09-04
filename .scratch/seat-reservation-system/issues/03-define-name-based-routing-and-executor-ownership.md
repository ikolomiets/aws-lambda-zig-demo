---
title: Define name-based routing and executor ownership
status: closed
assignee: codex
labels:
  - wayfinder:grilling
parent: ../map.md
blocked_by: []
---

## Question

How should intake map the `seat_reservation_system` Operation name to its dedicated SQS queue and
executor while preserving generic Operation persistence, completion processing, unknown-name
handling, retry isolation, and the existing public intake and query contracts?

## Resolution

[The TigerBeetle accounting research](../../../docs/research/seat-reservation-tigerbeetle-accounting.md)
shows that a TigerBeetle request may remain in flight beyond a Lambda invocation and that every
redelivery must reconstruct the same semantic request under the same Operation-derived transfer
ID. Routing must therefore establish one durable owner before an Operation can enter execution; an
executor must never forward an Operation to another executor or reinterpret a non-owned name.

### Intake owns a closed, exact route registry

- Add one compile-time route registry to intake. It maps the exact, case-sensitive Operation name
  `echo` to the existing operations queue and `seat_reservation_system` to a new, dedicated seat
  reservation operations queue. Each entry binds one name to one configured queue; there is no
  catch-all, default queue, prefix match, or runtime forwarding hop.
- Authenticate and parse the generic Operation input first, resolve its name in that registry
  second, and only then call the unchanged generic Operation persistence API. An unsupported name
  is `400 Bad Request` and creates neither a DynamoDB item nor an SQS message. A missing or invalid
  configured destination for a supported route is a service configuration failure, not an unknown
  name, and must prevent the intake runtime from accepting work.
- Preserve the existing persist-before-send order. After the generic DynamoDB create succeeds,
  enqueue the same bounded submitted-Operation message to the selected route. If sending fails,
  return `503 Service Unavailable`; the submitted item remains queryable, and an exact client retry
  recreates-or-reads the same item and re-enqueues it. A retry with the same ID but different
  tenant, name, or body remains a conflict. Duplicate messages are expected and must be harmless.
- Do not put route state in DynamoDB. `Operation.name` is the stable route key, while the table
  continues to store the generic Operation contract. Intake remains ignorant of reserve and
  confirm body semantics; the seat reservation executor owns that discriminated body contract.

### Each execution queue has exactly one owner

- Keep the current execution Lambda as the sole consumer of the existing `echo` queue. Add one seat
  reservation execution Lambda as the sole consumer of the seat reservation queue. Give each
  function exactly one event-source mapping and SQS receive/delete permissions only for its own
  queue. Do not attach both executors to one queue and do not select an executor inside a generic
  execution handler.
- Every executor validates that each decoded Operation has its one owned name before performing
  side effects. A cross-name record is an ownership/configuration fault: the receiving executor
  performs no TigerBeetle work, emits no Operation completion, and returns that record as a partial
  batch failure for the retry/redrive policy to quarantine and alert on. A malformed body for the
  executor's owned name is instead an owned domain input whose terminal/retry classification is
  decided by the failure-taxonomy ticket.
- The seat reservation executor alone parses `reserve` versus `confirm`, reads Event control-plane
  data, and submits the corresponding TigerBeetle requests. Its queue, event-source concurrency,
  timeout, networking, and retry/redrive settings are independent of the legacy executor, so a
  TigerBeetle stall or seat backlog cannot consume or redrive `echo` records.

### Completion and public reads stay generic

- Both executors publish bounded `{operation_id, result}` entries to the existing shared completion
  queue. The one generic completion Lambda remains the only writer that moves an Operation from
  `SUBMITTED` to `COMPLETED`; it needs no knowledge of the originating route or seat action.
- Keep the authenticated `POST` intake schema and the authenticated tenant-scoped
  `GET /<operation-id>` query contract. The only deliberate intake behavior change is that an
  unsupported Operation name is rejected before persistence instead of becoming permanently
  unowned work. Reserve and confirm remain separate Operations with independent lifecycle and
  results.
