---
title: Define Operation result contracts
status: closed
assignee: codex
labels:
  - wayfinder:grilling
parent: ../map.md
blocked_by:
  - "[Define the reserve action contract](06-define-reserve-action-contract.md)"
  - "[Define the reserve transaction and allocation protocol](07-define-reserve-transaction-and-allocation.md)"
  - "[Define the confirm action and transaction contract](08-define-confirm-action-and-transaction.md)"
  - "[Define retry and failure taxonomy](09-define-retry-and-failure-taxonomy.md)"
---

## Question

What bounded, versioned success and failure payloads should the existing Operation query return for
strict reserve-v1 and the matching confirm contract? For reserve, which accepted request fields
must be echoed, which caller eligibility details must be omitted, and how should the payload expose
Event ID, the one selected section, quantity, the Reserve Operation ID as pending transfer ID, and
the accepted transfer's TigerBeetle cluster timestamp and checked absolute hold expiry? Which
stable, non-overlapping result forms distinguish no capacity at the validated snapshot, a selected
section losing the commit race, a previously consumed ID with unknown original cause, Event or
accounting drift, and a hold accepted only after its deadline had already passed, while keeping the
hidden reserve decision out of the public contract? For confirm, how should success by `created` or
exact `exists` expose the referenced Reserve/pending transfer ID, distinct Confirm/post transfer ID,
and original post timestamp, and which stable failures distinguish an invalid or non-accepted
Reserve reference, accepted-proof drift, already-posted-by-another-ID, authoritative expiry,
no-void topology violation, and a previously consumed Confirm ID? How should the result preserve
the fact that an accepted-but-locally-late Reserve may still be authoritatively posted, while a
Confirm waiting on a `SUBMITTED` Reserve has no terminal result yet? How should readers apply the
Reserve's absolute deadline to an initially live hold without overriding a later successful
Confirm, leaking internal service errors, or mistaking immutable transfer existence for live-hold
status?

Treat the retry taxonomy as fixed: this ticket maps only pinned terminal `seat-terminal-v1` facts
to exact public JSON and must not create payloads for retry-only or quarantined records. Its
failure variants must cover `invalid_request`, `event_reference_invalid`,
`event_integrity_mismatch`, `no_capacity`, `capacity_race_lost`, `accepted_but_late`,
`reserve_dependency_timeout`, the three distinct Reserve-reference failures,
`reserve_proof_mismatch`, `pending_transfer_missing_preflight`,
`pending_transfer_not_found_after_preflight`, `confirmed_elsewhere`, `hold_expired`,
`unexpected_void`, `transfer_id_failed_unknown`, `transfer_intent_conflict`, `accounting_drift`,
and residual `tigerbeetle_rejected` without exposing raw internal diagnostics. Define which
accepted-transfer proof fields
`accepted_but_late` retains so Confirm can validate it even though the Reserve result does not
claim a live hold, and require the canonical payload to be the exact Completion stored in the
terminal marker before publication.

## Resolution

[The TigerBeetle accounting research](../../../docs/research/seat-reservation-tigerbeetle-accounting.md)
fixes the public boundary: `created` and exact `exists` have the same accepted meaning and original
cluster timestamp, immutable pending-transfer existence does not prove current liveness, and only a
post-pending result decides confirmation versus expiry. The existing Operation Completion envelope
remains unchanged; seat reservation defines closed, action-specific payloads inside it.

Every seat result uses JSON integer `result_version = 1`. The complete compact Completion, including
the outer `type` and `payload`, must be at most 1,024 UTF-8 bytes, comfortably inside the existing
4,096-byte Operation result limit even when a 64-byte section ID requires worst-case JSON escaping.
All object field sets below are exact: no optional, `null`, diagnostic, or unknown fields are
allowed. Builders emit fields in the displayed order so the same facts always produce the same
compact bytes.

### Reserve success is accepted creation, not permanent liveness

A Reserve first observed before its checked deadline (`observed_now_ns < hold_expires_at_ns`) has
this exact Completion shape:

```json
{
  "type": "SUCCESS",
  "payload": {
    "result_version": 1,
    "action": "reserve",
    "outcome": "accepted",
    "event_id": 1000,
    "section_id": "orchestra",
    "quantity": 2,
    "hold_timeout_seconds": 300,
    "reserve_operation_id": "00112233-4455-6677-8899-aabbccddeeff",
    "transfer_timestamp_ns": "1720000000000000000",
    "hold_expires_at_ns": "1720000300000000000"
  }
}
```

`event_id`, `quantity`, and `hold_timeout_seconds` echo the validated reserve-v1 integers and retain
their existing `u32` bounds. `section_id` is the single selected public section ID, still bounded to
1 through 64 UTF-8 bytes. `reserve_operation_id` is the canonical lowercase UUID for both the
Reserve Operation and the pending transfer; a second `pending_transfer_id` alias is forbidden
because two names for the same value could disagree. `transfer_timestamp_ns` is TigerBeetle's
original cluster timestamp for the accepted transfer, and `hold_expires_at_ns` is the checked sum
of that timestamp and `hold_timeout_seconds * 1_000_000_000`.

Both nanosecond values are canonical unsigned decimal strings of 1 through 20 digits, with no sign
or leading zero unless the value is zero. Strings avoid precision loss in JSON implementations
whose numeric type cannot represent a `u64` nanosecond timestamp. The accepted timestamp is
nonzero, and the checked expiry is strictly greater than it.

The result never echoes `eligible_section_ids`, whether omitted or caller supplied, and never
exposes candidate order, section ordinal, account IDs, Event definition digest, Operation hash,
`reserve-decision-v1`, TigerBeetle `created` versus `exists`, retries, balances, tenant metadata, or
raw service diagnostics. Those are validation and audit facts, not public reservation results.

### Reserve failures have closed field sets

An owned body that cannot establish a strict reserve-v1 or confirm-v1 action uses the one
action-neutral malformed-request form:

```json
{"type":"FAILURE","payload":{"result_version":1,"code":"invalid_request"}}
```

It does not echo an unvalidated action or body value. After strict reserve-v1 validation, every
non-acceptance failure has exactly this field set, with `code` replaced by one of the codes below:

```json
{
  "type": "FAILURE",
  "payload": {
    "result_version": 1,
    "action": "reserve",
    "code": "no_capacity",
    "event_id": 1000,
    "quantity": 2,
    "reserve_operation_id": "00112233-4455-6677-8899-aabbccddeeff"
  }
}
```

The exact Reserve non-acceptance codes and meanings are:

| Code | Pinned terminal meaning |
| --- | --- |
| `event_reference_invalid` | The Event is missing, not `ready`, failed, or the complete eligibility list names an unknown section. |
| `event_integrity_mismatch` | The persisted Event or manifest is malformed, unsupported, digest-mismatched, noncanonical, or not exactly rederivable. |
| `no_capacity` | One complete validated account snapshot had no eligible section with the requested quantity; no transfer was submitted. |
| `capacity_race_lost` | The one pinned section returned direct `exceeds_credits`; the ID is consumed and no fallback was attempted. |
| `transfer_id_failed_unknown` | `id_already_failed` proves this Reserve ID was consumed, but the original cause is unknowable. |
| `transfer_intent_conflict` | The ID exists with different semantic transfer fields. |
| `accounting_drift` | Authoritative account or transfer facts contradict the verified ready Event/accounting topology. |
| `tigerbeetle_rejected` | A definitive residual TigerBeetle rejection fits no more specific public code. |

These forms intentionally omit the hidden selected section and transfer intent. The result code
distinguishes snapshot exhaustion from a commit-race loss without publishing
`reserve-decision-v1`. Raw TigerBeetle statuses, mismatched field names, counters, account IDs,
exception text, and alert details remain in bounded operator telemetry only.

`accepted_but_late` is the sole Reserve failure that proves transfer acceptance. It uses the exact
same proof fields and bounds as Reserve success, replacing `outcome` with `code`:

```json
{
  "type": "FAILURE",
  "payload": {
    "result_version": 1,
    "action": "reserve",
    "code": "accepted_but_late",
    "event_id": 1000,
    "section_id": "orchestra",
    "quantity": 2,
    "hold_timeout_seconds": 300,
    "reserve_operation_id": "00112233-4455-6677-8899-aabbccddeeff",
    "transfer_timestamp_ns": "1720000000000000000",
    "hold_expires_at_ns": "1720000300000000000"
  }
}
```

This means the exact pending transfer was accepted but was first classified at or after its
derived deadline. It deliberately makes no live-hold claim. Its Event, section, quantity, timeout,
pending-transfer ID, original cluster timestamp, and checked expiry are nevertheless the complete
public accepted-transfer proof that Confirm admits. The hidden decision and rederived account
facts must also agree before Confirm submits, but do not enter the public payload.

### Confirm success names both immutable transfers

TigerBeetle `created` and exact `exists` for the deterministic full post produce the same success:

```json
{
  "type": "SUCCESS",
  "payload": {
    "result_version": 1,
    "action": "confirm",
    "outcome": "confirmed",
    "reserve_operation_id": "00112233-4455-6677-8899-aabbccddeeff",
    "confirm_operation_id": "ffeeddcc-bbaa-9988-7766-554433221100",
    "post_timestamp_ns": "1720000010000000000"
  }
}
```

`reserve_operation_id` is both the referenced Reserve Operation ID and `pending_id`.
`confirm_operation_id` is both the current Confirm Operation ID and the distinct post-pending
transfer ID. Both are canonical lowercase UUIDs and must differ. `post_timestamp_ns` is the
created post's original nonzero TigerBeetle timestamp, recovered unchanged by exact `exists`, and
uses the same canonical unsigned-decimal-string rule. Confirm does not copy Event, section,
quantity, timeout, or Reserve expiry into its result; the referenced Reserve result is their one
public source.

### Confirm failures remain distinguishable without diagnostics

After strict confirm-v1 validation, every Confirm failure has exactly this field set:

```json
{
  "type": "FAILURE",
  "payload": {
    "result_version": 1,
    "action": "confirm",
    "code": "hold_expired",
    "reserve_operation_id": "00112233-4455-6677-8899-aabbccddeeff",
    "confirm_operation_id": "ffeeddcc-bbaa-9988-7766-554433221100"
  }
}
```

The exact Confirm codes are:

| Code | Pinned terminal meaning |
| --- | --- |
| `reserve_dependency_timeout` | The referenced Reserve remained `SUBMITTED` at the final strong read at or after the fixed dependency deadline; the Confirm ID was not submitted. |
| `reserve_reference_missing` | No referenced Operation exists; the Confirm ID was not submitted. |
| `reserve_reference_invalid` | The reference names the wrong service/action or a malformed Reserve contract; the Confirm ID was not submitted. |
| `reserve_not_accepted` | The referenced Reserve is terminal but neither `accepted` nor `accepted_but_late`; the Confirm ID was not submitted. |
| `reserve_proof_mismatch` | Accepted public proof, hidden intent, Operation hash, Event, rederived identifiers, or immutable transfer disagree; the Confirm ID was not submitted. |
| `pending_transfer_missing_preflight` | The one-ID transfer preflight definitively returned missing, duplicate, or malformed data; the Confirm ID was not submitted. |
| `pending_transfer_not_found_after_preflight` | TigerBeetle returned `pending_transfer_not_found` after an exact successful preflight; the Confirm ID is consumed and an invariant alert is required. |
| `confirmed_elsewhere` | `pending_transfer_already_posted` proves a different resolver ID won; this Confirm Operation is not a success. |
| `hold_expired` | `pending_transfer_expired` authoritatively rejected this post. |
| `unexpected_void` | `pending_transfer_already_voided` contradicts the no-void topology. |
| `transfer_id_failed_unknown` | `id_already_failed` proves this Confirm ID was consumed, but the original cause is unknowable. |
| `transfer_intent_conflict` | This Confirm ID exists with different post intent. |
| `tigerbeetle_rejected` | A definitive residual TigerBeetle rejection fits no more specific public code. |

The ordered classification is body validation; Reserve wait/reference classification; accepted
proof and preflight classification; then exact post result. This precedence prevents one fact from
matching multiple codes. In particular, a missing preflight never consumes the Confirm ID, while
`pending_transfer_not_found_after_preflight` does; exact `exists` wins as this Confirm's success
before another-resolver statuses are considered. Public failures never include the referenced
Reserve's failure code, another resolver ID that TigerBeetle did not return, raw statuses, or
internal mismatch details.

### Readers use the deadline conservatively and Confirm authoritatively

Reserve `accepted` means the hold was accepted and was initially observed before its deadline; it
is not an immutable claim that the hold is still live whenever the Operation is later read. Before
`hold_expires_at_ns`, readers may present it as an accepted hold subject to concurrent
confirmation. At or after that deadline, readers must stop presenting it as live and describe its
resolution as unknown unless they also have a terminal Confirm result. They must not rewrite the
immutable Reserve result to `accepted_but_late` or `hold_expired`, and must not infer liveness from
the continuing existence of the pending transfer or from delayed pending-counter cleanup.

`accepted_but_late` is still valid acceptance proof for Confirm. A later `confirmed` result wins
for presentation regardless of either the local deadline or whether the Reserve result was
`accepted` or `accepted_but_late`; `hold_expired` is authoritative only when a Confirm attempt
returned that TigerBeetle result. A Confirm whose referenced Reserve is still `SUBMITTED` before
the dependency deadline remains `SUBMITTED` itself and has no result payload at all.

### Pin the exact Completion before publication

For every terminal form, the seat executor constructs and validates the bounded canonical
Completion once, then conditionally stores those exact compact JSON bytes inside the matching
`seat-terminal-v1` marker before sending them to the Completion queue. Redelivery republishes the
stored bytes; it does not rebuild fields, resample time, reclassify the outcome, or attach a
message. The completion worker accepts only that exact Completion for the still-`SUBMITTED`
Operation, and duplicate readback requires exact equality with the immutable completed result.

Retry-only uncertainty and quarantine never construct `seat-terminal-v1`, never publish a
Completion, and therefore have no public JSON form. This keeps internal availability failures out
of the API and preserves the fixed terminal/retry/quarantine taxonomy.
