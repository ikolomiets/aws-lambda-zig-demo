---
title: Define the confirm action and transaction contract
status: closed
assignee: codex
labels:
  - wayfinder:grilling
parent: ../map.md
blocked_by:
  - "[Define the reserve transaction and allocation protocol](07-define-reserve-transaction-and-allocation.md)"
---

## Question

Given that reserve-v1 durably pins one exact transfer intent before submission and preserves the
accepted transfer's selected section, cluster timestamp, and derived expiry, what strict
contract-version-1 Operation body discriminates `confirm`, references that definitively accepted
Reserve Operation ID, and rejects unknown fields, duplicate keys, inadmissible or self-referential
IDs before execution? Which persisted reserve result and authoritative TigerBeetle transfer checks
must agree before the Confirm Operation ID is consumed, especially when a locally derived deadline
has passed or the reserve exists but is no longer live? How should the executor use the already
intake-admissible Confirm Operation ID as the distinct post-pending transfer ID, inherit matching
fields with zero, and post the full hold with `AMOUNT_MAX` exactly once, including exact-retry,
confirm-before-reserve, already-posted-by-another-ID, and expired-hold outcomes?

## Resolution

[The TigerBeetle accounting research](../../../docs/research/seat-reservation-tigerbeetle-accounting.md)
fixes the confirm boundary: the Confirm Operation ID is the unique resolver transfer ID, the
Reserve Operation ID is its `pending_id`, a full post uses `AMOUNT_MAX`, and an exact duplicate is
idempotent. A preflight lookup can prove that the immutable pending transfer exists with the
expected shape, but cannot prove that the hold is still unresolved or unexpired. Only the
post-pending result authoritatively resolves that race.

### Exact confirm-v1 body

For `Operation.name = "seat_reservation_system"`, confirm-v1 is this closed JSON object:

```json
{
  "contract_version": 1,
  "action": "confirm",
  "reserve_operation_id": "00112233-4455-6677-8899-aabbccddeeff"
}
```

All three fields are required and no others are allowed:

- `contract_version` is the JSON integer `1`, and `action` is the lowercase JSON string
  `"confirm"`. Alternate spellings, booleans, quoted or fractional numbers, and exponent form are
  invalid.
- `reserve_operation_id` is a canonical lowercase 36-byte UUID string that decodes to a `u128`.
  It must not be `0`, `2^128 - 1`, or in the high-24-bit `0x535253` provisioning family, and it
  must differ from the outer Confirm Operation ID.
- The body does not repeat an Event ID, section ID, quantity, timeout, account ID, ledger, code, or
  tenant. Those facts come from the accepted Reserve Operation; accepting caller copies would
  create two potentially conflicting sources of truth. Operation tenancy remains outside the seat
  business rules, so confirm does not require the referenced reserve to have the same tenant.

The shared 4,096-byte body limit still applies. Seat intake rejects duplicate keys at every level,
unknown fields, missing fields, wrong JSON kinds, noncanonical UUID text, a self-reference, and an
inadmissible referenced ID before persisting or enqueueing the Operation. The shared outer-ID rule
likewise establishes that the Confirm Operation ID is a legal, distinct TigerBeetle transfer ID
before persistence.

### Establish one accepted Reserve proof before consuming the Confirm ID

On every delivery, reparse confirm-v1 and strongly read the stored Confirm Operation, requiring the
same ID, name, hash, `SUBMITTED` state, absent result, and exact body before any TigerBeetle request.
Then strongly read `reserve_operation_id` and require all of the following to agree:

1. The referenced Operation exists under `seat_reservation_system`, its body is a valid reserve-v1
   body, and its outer ID equals the referenced pending-transfer ID.
2. It is `COMPLETED` with a result form that proves TigerBeetle accepted the pending transfer. Both
   an initially-live accepted hold and an accepted hold first reported after its derived deadline
   are acceptance proofs; no-capacity, concurrency-loss, prior-failed-ID, reference, integrity, and
   other non-acceptance results are not.
3. Its immutable `reserve-decision-v1` is `transfer_intent`, and the reserve body, decision, and
   accepted result agree on the Operation hash, Event ID and definition digest, selected section,
   quantity, pending transfer ID, section and Seats Reserved account IDs, timeout, cluster
   timestamp, and checked absolute expiry. A `no_capacity` decision can never be confirmed.
4. One strongly read `ready` Event still matches that definition digest and complete manifest, and
   exact `srs-packed-v1` rederivation reproduces the pinned account IDs. Confirm never repairs,
   reprovisions, reselects, or substitutes an Event or section.
5. One TigerBeetle `lookup_transfers` for the Reserve Operation ID returns exactly one transfer.
   Missing, duplicate, or unexpected lookup results are protocol or reconciliation failures. The
   returned transfer must exactly match the accepted intent: reserve ID; selected section debit
   account; Event Seats Reserved credit account; requested quantity; `pending_id = 0`; original
   nonzero timeout; Event ledger; accounting-contract-v1 reserve code `2`; exactly the `pending`
   flag; zero user data and reserved fields; and the same cluster timestamp. Recomputing
   `timestamp + timeout * 1_000_000_000` with checked arithmetic must reproduce the persisted
   expiry.

These checks establish existence and identity, not liveness. TigerBeetle transfers are immutable:
the original record keeps its `pending` flag after a post, void, or timeout, and a lookup does not
report its resolution state.

If the referenced Operation is still `SUBMITTED`, confirm is dependency-not-ready: issue no
TigerBeetle post and return the SQS record for retry. A missing, wrong-action, malformed, or
terminally non-accepted Reserve is a confirm-reference failure without consuming the Confirm ID.
Any contradiction among an accepted result, its decision, the Event, and the TigerBeetle lookup is
an integrity/reconciliation failure and also produces no post. The retry and failure decision
assigns the bounded retry and terminal-public policy to these classes.

In particular, a local wall-clock comparison with the derived expiry must not suppress the post.
It remains a conservative presentation guard for Reserve readers, but only TigerBeetle cluster
ordering can decide a confirm-versus-expiry race. This also preserves exact recovery: a winning
Confirm retried after the deadline must be able to receive `exists` for its already-created post.

### Submit one deterministic full-post transfer

After the accepted-Reserve proof succeeds, zero-initialize one transfer and set exactly:

| Field | Confirm-v1 value |
| --- | --- |
| `id` | Confirm Operation ID |
| `debit_account_id` | `0`, inherited from the pending transfer |
| `credit_account_id` | `0`, inherited from the pending transfer |
| `amount` | `AMOUNT_MAX` (`2^128 - 1`), meaning the full pending amount |
| `pending_id` | Reserve Operation ID |
| `timeout` | `0` |
| `ledger` | `0`, inherited from the pending transfer |
| `code` | `0`, inherited from the pending transfer |
| `flags` | exactly `post_pending_transfer` |
| `user_data_*`, `reserved`, `timestamp` | `0`, with user data inherited as zero |

There is no linked, pending, void, balancing, closing, or imported flag. Zero inheritance avoids
duplicating matching fields in the resolver, and `AMOUNT_MAX` avoids an accidental zero or partial
post under TigerBeetle 0.16+ semantics. The Confirm Operation's immutable ID and body determine the
complete transfer, so no separate confirm-decision marker is needed.

Every retry resubmits this exact object. TigerBeetle's unique transfer ID makes concurrent duplicate
deliveries create at most one post:

- `created` and exact `exists` are successful confirmation by this Confirm Operation ID. Preserve
  the returned original post timestamp for the result; duplicate-ID precedence makes an exact
  retry successful even after the pending transfer has since become resolved or expired.
- Any `exists_with_different_*` result is a Confirm-ID/intent integrity failure, not a retry or
  permission to adopt the conflicting transfer.
- `pending_transfer_already_posted` means a different Confirm Operation ID resolved the hold. It is
  a terminal already-confirmed-elsewhere outcome, not success for this Operation; simultaneous
  different-ID confirms may race, but TigerBeetle accepts only one.
- `pending_transfer_expired` is the authoritative terminal expired-hold outcome, regardless of the
  application clock comparison made before submission.
- `pending_transfer_already_voided` contradicts the no-void topology and is an integrity outcome.
- `pending_transfer_not_found` is prevented by the immutable-transfer preflight. If nevertheless
  returned, it consumes this Confirm ID and is an integration/invariant failure; never retry that
  ID as though it could later succeed. `id_already_failed` likewise means a prior transient result
  consumed the ID without retaining its cause.
- Shape and pending-field rejections are implementation defects. Client, transport, process, or
  Completion-publication uncertainty produces no terminal Completion; redelivery repeats the
  preflight and the identical post, allowing `created` or `exists` to recover the truth.

The dependent retry and result decisions assign stable error codes and payloads to these distinct
protocol outcomes. They must not collapse accepted-by-this-ID, already-posted-by-another-ID,
expired, accepted-but-locally-late, preflight drift, and cause-unknown consumed-ID cases.
