---
title: Define the reserve transaction and allocation protocol
status: closed
assignee: codex
labels:
  - wayfinder:prototype
parent: ../map.md
blocked_by:
  - "[Validate TigerBeetle seat-capacity accounting](01-validate-tigerbeetle-seat-capacity-accounting.md)"
  - "[Choose deterministic TigerBeetle provisioning identifiers](04-choose-deterministic-tigerbeetle-account-identifiers.md)"
  - "[Define atomic and replay-safe Event provisioning](05-define-atomic-event-provisioning.md)"
  - "[Define the reserve action contract](06-define-reserve-action-contract.md)"
---

## Question

Given a strict reserve-v1 body whose ordered candidates are either at most 32 caller-listed
`section_id` values or every section in immutable manifest order, how should the executor fully
revalidate the `ready` Event, batch-read the candidates' TigerBeetle accounts, preserve that fixed
preference order, and deterministically select exactly one section before submission? What exact
account-snapshot rule distinguishes no candidate with `quantity` available from the selected
section losing a concurrency race, and how should the executor rederive the selected
`srs-packed-v1` account ID and create one pending transfer with the Reserve Operation ID,
reserve-v1's exact quantity and timeout, and accounting-contract-v1 reserve code `2`? How should it
preserve the cluster timestamp and derived expiry so retries reuse exact fields, neither
`exceeds_credits` nor an uncertain or late `exists` result can move the same reservation to another
section, and definitive no-capacity is distinguishable from infrastructure uncertainty, manifest
drift, and an already-expired hold?

## Resolution

[The TigerBeetle accounting research](../../../docs/research/seat-reservation-tigerbeetle-accounting.md)
fixes the governing constraints: a Seat Section's credit balance is its capacity; one Reserve
Operation ID can be used for only one pending-transfer attempt; a transient
`exceeds_credits` result permanently consumes that ID; exact retries must preserve every semantic
transfer field; and `exists` proves creation but not current hold liveness. The reserve executor
therefore makes and durably pins one allocation decision before its first TigerBeetle submission.

### Revalidate the Operation and Event before accounting

For every delivery, reparse the queued Operation as the strict reserve-v1 contract and require its
name, ID, hash, `SUBMITTED` state, absent result, Event ID, quantity, eligibility list, and timeout
to satisfy the intake and reserve-contract decisions. Strongly read the stored Operation and
require the same ID, name, and hash before creating or following its reserve decision.

Strongly read one complete Event item and run the same retained-version verification used before
provisioning: require `provisioning_state = ready`; supported control-schema, accounting-contract,
and identifier-scheme versions; a complete canonical section manifest; the declared section
count; unique IDs and contiguous ordinals; canonical capacities and materialized IDs; an exact
definition digest; and exact `srs-packed-v1` rederivation of every provisioning ID. Resolve the
entire caller list before considering capacity. An unknown, non-ready, incomplete, unsupported,
noncanonical, digest-mismatched, or non-rederivable Event is an Event-reference or integrity
failure and produces no TigerBeetle request; reserve execution never repairs it.

The immutable candidate sequence is caller order when `eligible_section_ids` is present and
manifest ordinal order otherwise. Keep that sequence separately from TigerBeetle's reply; never
sort candidates by account ID, balance, or lookup-result position.

### Take one coherent account snapshot and select first-fit

When no reserve decision is already pinned, issue one `lookup_accounts` request containing the
candidates' rederived Seat Section account IDs plus the Event's rederived Seats Reserved account
ID. The eventual Event section-count bound must keep this within one TigerBeetle lookup batch; do
not split it, because multiple lookups permit read skew. Treat the reply as a set keyed by account
ID, since missing accounts produce no result. Require exactly one result for every requested ID and
no duplicate or unexpected result.

Validate each returned account against the retained accounting contract: exact ID, Event ledger,
role code and immutable base flags, zero user data and reserved fields, and the expected role. For
each section additionally require `credits_posted` to equal its immutable manifest capacity,
`credits_pending = 0`, and the bounded-account invariant
`debits_posted + debits_pending <= credits_posted`. Any missing or mismatched account or impossible
counter shape is accounting drift, not no-capacity. The Seats Reserved account's balances are
dynamic aggregates and do not participate in section choice.

For each candidate in the fixed sequence, compute with checked `u128` subtraction:

```text
available = credits_posted - debits_posted - debits_pending
```

Select the first candidate whose snapshot has `available >= quantity`. Do not use a balancing
transfer and do not split the amount. If every fully validated candidate has less than `quantity`,
the coherent snapshot establishes `no_capacity` for this Operation. This says only that the
Operation made no allocation at that snapshot; it does not promise future Events or new Operations
will see the same availability.

### Pin the allocation decision before any side effect

Store a hidden, immutable `reserve-decision-v1` value on the persisted `SUBMITTED` Operation before
publishing a terminal no-capacity result or submitting a transfer. It is a tagged union:

- `no_capacity` records the Event ID and verified Event definition digest; or
- `transfer_intent` records the Event ID and definition digest, selected public section ID and
  ordinal, selected section and Seats Reserved account IDs, and the complete canonical transfer
  fields described below. IDs use canonical 32-digit lowercase hexadecimal strings and the amount
  uses canonical decimal text, matching the Event manifest's lossless DynamoDB representation.

Create it with one conditional update requiring the stored Operation to remain `SUBMITTED`, to
have the queued name and hash, and to have no reserve decision. A conditional loser strongly
rereads and follows the already-pinned value; an exact duplicate is accepted, while any mismatch
is integrity failure. The marker does not add an Operation lifecycle state and cannot be exposed as
proof of a reservation. It exists only to make duplicate delivery, concurrent execution, process
death, and an uncertain TigerBeetle reply reuse one decision. TigerBeetle remains authoritative
for transfer existence, balances, and hold liveness.

This pin is required because re-running first-fit against a later mutable account snapshot could
select another section. Stable transfer IDs alone prevent two accepted holds, but without the pin
they do not make retry input exact or preserve the first no-capacity decision while its Completion
message is pending.

### Submit one exact pending transfer

For a pinned `transfer_intent`, zero-initialize one transfer and populate exactly:

| Field | Reserve-v1 value |
| --- | --- |
| `id` | Reserve Operation ID |
| `debit_account_id` | pinned, rederived selected Seat Section account ID |
| `credit_account_id` | pinned, rederived Event Seats Reserved account ID |
| `amount` | reserve-v1 `quantity` |
| `pending_id` | `0` |
| `timeout` | reserve-v1 `hold_timeout_seconds`, unchanged |
| `ledger` | Event ID |
| `code` | accounting-contract-v1 reserve code `2` |
| `flags` | exactly `pending` |
| `user_data_*`, `reserved`, `timestamp` | `0` |

Before every submission, revalidate the pinned IDs and fields against the queued Operation and the
verified Event manifest. Never recompute section choice or remaining timeout. Submit only this one
transfer; no linked flag, parallel candidate attempt, or same-ID fallback is permitted.

`created` and exact `exists` are idempotent acceptance outcomes. Preserve the result timestamp—new
for `created`, original for `exists`—and calculate
`hold_expires_at_ns = timestamp + timeout * 1_000_000_000` with checked arithmetic. Carry the
timestamp and derived deadline unchanged into the Completion entry and eventual immutable
Operation result. A retry after failed Completion publication resubmits the pinned transfer and
recovers the same timestamp from exact `exists`; the timestamp is never copied into the submitted
transfer, whose input field remains zero.

Sample current Unix time after receiving or recovering acceptance. If the derived deadline has
already passed, report an accepted-but-already-expired hold outcome rather than presenting a live
hold, and never select another section. If the result is initially visible before the deadline,
the result contract must still expose the absolute deadline so later readers stop treating it as
live. Only TigerBeetle's confirm result is authoritative at the expiry boundary; a local clock
comparison is a conservative presentation guard, not a substitute for posting the pending
transfer.

### Preserve distinct outcome classes

- `no_capacity` is a terminal business decision made only from a complete, validated, single-batch
  snapshot, before any transfer submission.
- A direct `exceeds_credits` after the selected account appeared sufficient means that the pinned
  section lost a concurrency race. It terminally consumes this Reserve Operation ID; do not retry
  it as a fresh attempt and do not fall through to another candidate.
- `id_already_failed` also means the pinned ID cannot succeed, but does not recover which earlier
  transient result consumed it. Keep it distinct from a directly observed capacity race and route
  it to the retry/failure taxonomy without inventing a cause.
- Exact `exists` is accepted creation with the original timestamp, subject to the derived-expiry
  guard. Any `exists_with_different_*` result is an ID/intent integrity failure, never permission
  to adopt or overwrite the conflicting transfer.
- Missing or mismatched accounts, Event-definition drift, and impossible account counters are
  integrity/reconciliation failures, not capacity results. A definitive TigerBeetle shape,
  overflow, closed-account, or other rejection remains distinct from them and consumes the pinned
  transfer ID according to TigerBeetle's result contract.
- Client, transport, allocation, malformed-result-vector, or decision-write uncertainty produces
  no terminal Completion. Return only that SQS record for retry; the next delivery follows the
  same pinned decision and exact transfer intent.

The dependent failure and result tickets assign the bounded public error codes and final payload
shapes to these already-distinct protocol outcomes.
