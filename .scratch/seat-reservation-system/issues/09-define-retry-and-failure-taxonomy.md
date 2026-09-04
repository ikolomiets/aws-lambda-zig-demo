---
title: Define retry and failure taxonomy
status: closed
assignee: codex
labels:
  - wayfinder:grilling
parent: ../map.md
blocked_by:
  - "[Define name-based routing and executor ownership](03-define-name-based-routing-and-executor-ownership.md)"
  - "[Define atomic and replay-safe Event provisioning](05-define-atomic-event-provisioning.md)"
  - "[Define the reserve transaction and allocation protocol](07-define-reserve-transaction-and-allocation.md)"
  - "[Define the confirm action and transaction contract](08-define-confirm-action-and-transaction.md)"
---

## Question

Taking reserve-v1's strict validation, immutable `reserve-decision-v1`, and exact pending transfer,
plus confirm-v1's accepted-Reserve proof, one-transfer lookup preflight, and deterministic
`AMOUNT_MAX` post, which owned malformed requests and reserve/confirm outcomes are terminal
Operation failures and which return only their SQS record through partial batch failure? In
particular, what bounded retry policy waits for a referenced Reserve still in `SUBMITTED` without
consuming the Confirm ID, and when do a missing or terminally non-accepted reference, accepted
result/decision/Event/transfer disagreement, or a missing preflight transfer become terminal,
retryable, or quarantined? How are reserve no-capacity, direct `exceeds_credits`, accepted-but-late,
cause-unknown `id_already_failed`, and confirm `created`/exact `exists`,
`pending_transfer_already_posted`, `pending_transfer_expired`, impossible post-preflight
`pending_transfer_not_found`, `pending_transfer_already_voided`, and `exists_with_different_*`
classified without retrying a consumed ID or treating a local deadline as authoritative? What
redrive policy handles cross-name records the seat executor must neither execute nor complete, and
how do executor timeout, transport uncertainty, conditional writes, Completion publication,
duplicate delivery, persistence failure, and delayed expiry cleanup avoid premature Completion or
repair of a non-ready Event?

## Resolution

[The TigerBeetle accounting research](../../../docs/research/seat-reservation-tigerbeetle-accounting.md)
fixes the central distinction. An exact replay after an unknown client or transport outcome is
safe because it reuses the same immutable ID and byte-for-byte-equivalent semantic fields. A
definitive TigerBeetle result is different: even results described as transient can permanently
consume the transfer ID, so the same Operation must never reinterpret one as permission for a
fresh business attempt. The seat workflow therefore has exactly three record dispositions:

1. **Terminal Completion:** the Operation has a deterministic success or failure fact. Durably pin
   that fact, publish its exact Completion, and acknowledge the source record only after
   publication succeeds.
2. **Retry only:** the truth is not yet known because a dependency is within its explicit wait
   window or an allocation, service, transport, process, conditional-write, or publication result
   is uncertain. Publish no Completion and return only that SQS record in `batchItemFailures`.
3. **Quarantine:** the record cannot safely identify an owned Operation or the durable terminal
   marker itself is contradictory. Perform no TigerBeetle work, publish no Completion, return the
   record as a partial batch failure, and let the queue's redrive policy move it to its DLQ while
   alarming operators.

A definitive domain, reference, integrity, or TigerBeetle rejection for a trustworthy owned
Operation is a terminal failure, even when it also raises an operator alert. Quarantine is reserved
for records that cannot safely select an Operation or for contradictory durable outcome state; it
must not become a way to leave ordinary business failures permanently `SUBMITTED`.

### Establish ownership before classifying the body

- A generically valid queued Operation must strongly match the stored ID, name, hash,
  `SUBMITTED` state, absent result, and the seat executor's exact owned name before any seat side
  effect. A stored `COMPLETED` Operation is an acknowledged duplicate after its identity is
  verified; it does not publish again.
- A cross-name record, an envelope with no trustworthy canonical Operation ID, a missing stored
  Operation, or a queued/stored identity mismatch is quarantined. The seat executor neither
  forwards it, executes it, acknowledges it as harmless, nor manufactures a Completion for an
  unverified identity.
- Once the stored identity and owned name are established, a malformed, unknown-version,
  unknown-action, or otherwise invalid reserve-v1/confirm-v1 body is the terminal
  `invalid_request` failure. Intake intentionally owns only generic routing, so an owned domain
  error must complete rather than poison the queue.
- An unknown, non-`ready`, or failed Event is terminal `event_reference_invalid`; a malformed,
  digest-mismatched, or non-rederivable Event is terminal `event_integrity_mismatch`. Reservation
  execution does not wait for, resume, or repair Event provisioning. Only the dedicated
  provisioner may replay an unchanged pending provisioning phase under the already-defined
  provisioning state machine.

### Bound Confirm's wait without consuming its transfer ID

`confirm_reference_wait_seconds` is fixed at 900 seconds for contract version 1. Its deadline is
the Confirm Operation's immutable intake `last_updated + 900`, computed with checked arithmetic;
it is not reset by SQS duplicates, redrive, executor restarts, or another message for the same
Operation.

On every delivery, strongly read the referenced Reserve before any preflight lookup or post:

- If the Reserve is still `SUBMITTED` and the deadline has not passed, return only the Confirm
  record for retry. Do not create a terminal marker and do not submit the Confirm transfer.
- At or after the deadline, strongly read once more. If the Reserve is still `SUBMITTED`, pin and
  publish terminal `reserve_dependency_timeout`. The Confirm ID remains unused, so a caller may
  create a new Confirm Operation after the Reserve eventually reaches a terminal accepted result.
- A definitively missing reference, wrong service name or action, malformed Reserve contract, or
  terminally non-accepted Reserve is an immediate terminal reference failure. Preserve distinct
  `reserve_reference_missing`, `reserve_reference_invalid`, and `reserve_not_accepted` classes;
  none consumes the Confirm ID.
- A DynamoDB read or decode whose result is not definitive is retry-only. It must not be converted
  to a missing reference.
- Disagreement among an accepted Reserve result, `reserve-decision-v1`, Operation hash, Event
  definition, rederived IDs, or the looked-up pending transfer is terminal
  `reserve_proof_mismatch`, emits a high-severity integrity signal, and submits no post. A
  definitive empty or malformed one-ID preflight lookup is the narrower
  `pending_transfer_missing_preflight` form of that failure. The Confirm ID remains unused in both
  cases. Lookup transport or result allocation uncertainty remains retry-only.

The 900-second wait is an application deadline for dependency ordering, not a claim about the
Reservation Hold's TigerBeetle expiry. It is sampled only before the Confirm ID has been used.
Once the accepted-Reserve proof succeeds, a locally derived expiry must never suppress the post;
TigerBeetle alone decides the post-versus-expiry race.

### Classify every definitive Reserve result

- A pinned `no_capacity` decision is the terminal business failure `no_capacity`; it proves that
  no transfer was submitted for this Operation.
- `created` and exact `exists` both prove that the one pinned pending transfer was accepted. A
  first observed result before the checked derived deadline is terminal Reserve success. A first
  observed result at or after that deadline is terminal `accepted_but_late`, not a retry and not a
  live-hold claim. It must retain the accepted transfer's identity, original cluster timestamp,
  and derived expiry so Confirm can still treat it as acceptance proof and let TigerBeetle decide
  resolution.
- Direct `exceeds_credits` is terminal `capacity_race_lost`: the selected section lost the commit
  race and the Reserve ID is consumed. Do not re-read capacity and do not try another section.
- `id_already_failed` is terminal `transfer_id_failed_unknown`. It proves the Reserve ID cannot
  succeed but does not justify inventing the earlier cause; alert on it separately from a directly
  observed capacity race.
- Any `exists_with_different_*` is terminal `transfer_intent_conflict` and an integrity alert. A
  definitive missing/closed account, overflow, shape, flag, ledger, code, amount, or other
  rejection is terminal `accounting_drift` or `tigerbeetle_rejected` according to whether it
  contradicts the verified Event/account contract. If TigerBeetle consumed the ID, a new business
  attempt requires a new Operation ID.
- Client/request error, Lambda timeout, process death, allocation failure, or a missing,
  duplicate, truncated, or otherwise ambiguous result vector is retry-only. Redelivery follows
  the pinned decision and exact transfer intent; it never returns to section selection.

Delayed expiry cleanup is not a failure to repair. It may conservatively reduce snapshot
availability and therefore contribute to a valid `no_capacity` result, but the executor must not
void a hold, adjust balances, ignore pending counters, or retry under a new transfer ID.

### Classify every definitive Confirm result

- `created` and exact `exists` are terminal Confirm success by this Confirm Operation ID. Preserve
  the original post timestamp returned by TigerBeetle.
- `pending_transfer_already_posted` is terminal `confirmed_elsewhere`: another resolver ID won. It
  is not success for this Operation and is not retryable.
- `pending_transfer_expired` is terminal `hold_expired`, regardless of the local clock before
  submission.
- `pending_transfer_already_voided` is terminal `unexpected_void`, contradicts the no-void
  topology, and raises an integrity alert.
- A post-submission `pending_transfer_not_found` despite the exact successful preflight is
  terminal `pending_transfer_not_found_after_preflight`, consumes the Confirm ID, and raises an
  invariant alert. Never retry that ID hoping the Reserve will appear. This remains distinct from
  `pending_transfer_missing_preflight`, which consumes no Confirm ID.
- `id_already_failed` is terminal `transfer_id_failed_unknown`; it does not recover or relabel the
  unobserved original transient result.
- Any `exists_with_different_*` is terminal `transfer_intent_conflict`. Pending-field mismatch,
  invalid flags, an invalid amount, or another definitive shape rejection is terminal
  `tigerbeetle_rejected` and an implementation alert.
- Only a client/request, transport, process, allocation, or result-vector uncertainty is
  retry-only. Redelivery repeats the complete accepted-Reserve proof and submits the same full-post
  transfer; exact `exists` recovers a prior success.

### Pin one deterministic terminal fact before Completion

Before publishing any terminal seat result, conditionally write a hidden `seat-terminal-v1`
marker on the still-`SUBMITTED` Operation. It contains the exact taxonomy class, the bounded facts
needed by the result contract, and the canonical Completion JSON. The condition requires the
stored ID, owned name, hash, state, absent public result, and an absent marker. It does not change
the public Operation state or refresh its timestamps.

An exact existing marker is followed and republished; a different existing marker is quarantined
as deterministic-outcome corruption. An uncertain marker write is retry-only. This pins the local
`accepted_but_late` observation as well as every other outcome, so concurrent duplicates on
opposite sides of the derived deadline cannot publish different terminal results. The generic
completion worker remains the sole writer of `SUBMITTED -> COMPLETED`.

Completion publication and persistence follow these rules:

- A Completion-queue send failure or unknown send result returns every represented source record
  for retry. Redelivery publishes the already-pinned exact Completion; it does not recompute the
  terminal class.
- The completion worker conditionally accepts a seat result only when it exactly matches the
  stored `seat-terminal-v1` Completion and the Operation is still `SUBMITTED`. A transient
  DynamoDB failure returns the Completion message for retry.
- On a conditional conflict, strongly read the Operation. An already-`COMPLETED` item with the
  exact same result is an acknowledged duplicate. A missing item, mismatched terminal marker, or
  different completed result quarantines the Completion message and alerts; it is not silently
  acknowledged as an ordinary duplicate.

These rules preserve the existing immutable Operation lifecycle while removing the race in which
two duplicate executions could publish different time-sensitive outcomes.

### Use bounded source retries and explicit quarantine queues

Keep `ReportBatchItemFailures` and return only affected record IDs. Add a dedicated seat-operations
DLQ to the dedicated seat queue and a Completion DLQ to the shared Completion queue. Both source
queues retain messages for four days; both DLQs retain them for fourteen days and use source-scoped
redrive-allow policies. Alarm on any DLQ arrival, oldest-message age approaching retention, and a
nonzero sustained partial-failure rate.

For the seat source queue, set:

```text
maxReceiveCount = max(5, ceil(900 / visibility_timeout_seconds) + 2)
```

With the current 90-second visibility timeout this is `12`. The scale decision may change the
function and visibility timeouts together, but must preserve both Lambda's six-times-function-
timeout visibility guidance and this two-delivery margin beyond the 900-second dependency window.
Use `maxReceiveCount = 8` for the Completion queue, which has no intentional dependency wait.
[AWS Lambda SQS configuration](https://docs.aws.amazon.com/lambda/latest/dg/services-sqs-configure.html);
[AWS partial batch responses](https://docs.aws.amazon.com/lambda/latest/dg/services-sqs-errorhandling.html);
[AWS SQS dead-letter queues](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html)

Cross-name and untrusted-identity records repeatedly return as failures and reach the seat DLQ;
they never produce a seat Completion. General infrastructure uncertainty can reach the same DLQ
after the bounded receive count, leaving the Operation `SUBMITTED` for operator diagnosis rather
than inventing a terminal fact. Redrive only after verifying the durable Operation identity and
fixing the dependency or routing fault; use a low bounded redrive rate. Never edit an immutable
TigerBeetle intent, advance a non-ready Event, or reset a consumed transfer ID as part of redrive.
