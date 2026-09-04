---
title: Define atomic and replay-safe Event provisioning
status: closed
assignee: codex
labels:
  - wayfinder:grilling
parent: ../map.md
blocked_by:
  - "[Validate TigerBeetle seat-capacity accounting](01-validate-tigerbeetle-seat-capacity-accounting.md)"
  - "[Define the Event control-plane contract](02-define-event-control-plane-contract.md)"
  - "[Choose deterministic TigerBeetle provisioning identifiers](04-choose-deterministic-tigerbeetle-account-identifiers.md)"
---

## Question

Given the wide `next_event_id` counter, immutable versioned Event manifest, collision-free
`srs-packed-v1` IDs, definition digest, and monotone
`accounts_pending -> capacity_pending -> ready` publication barrier, how should Event creation
atomically claim an Event ID and durably assemble a complete manifest, reject any noncanonical or
non-rederivable materialized ID before submission, run the linked all-or-none account batch and
separately linked all-or-none initial-capacity transfer batch, conditionally advance each state,
classify a terminal `failed` transition and stable diagnostic for manifest or TigerBeetle
incompatibility, and recover from crashes or uncertain replies by exact replay without exposing an
incomplete Event or minting capacity twice?

## Resolution

[The TigerBeetle accounting research](../../../docs/research/seat-reservation-tigerbeetle-accounting.md)
establishes both the safe replay mechanism and its atomicity boundary: stable object IDs make each
TigerBeetle phase idempotent, and linked chains make each phase all-or-none, but account creation
and transfer creation cannot share one TigerBeetle request. Event provisioning is therefore a
durable state machine with an atomic DynamoDB claim, two separately atomic TigerBeetle phases, and
`ready` as the only publication barrier. It is not a distributed transaction across DynamoDB and
TigerBeetle.

### Claim the creation intent and Event ID together

Every Event-creation intent carries a globally unique, stable `provisioning_request_id`. Before
allocation, canonicalize and validate the caller-owned definition, including unique section IDs,
canonical ordinal order, positive capacities, supported contract versions, and the currently
deployed size bounds. Compute a `request_definition_digest` over that definition without an Event
ID or any derived IDs. Reusing a request ID with the same digest means "return or resume the same
Event"; reusing it with a different digest is a stable idempotency conflict and must not create or
modify an Event.

`request_definition_digest` is SHA-256 over a separate `srs-event-create-intent-v1`
length-prefixed encoding of the three requested contract versions and the canonical ordered
sections' public IDs and capacities. It deliberately excludes the later Event ID and derived IDs,
so every allocator contender and long-delayed retry identifies the same caller intent.

Use a strongly consistent lookup of the request claim first. If none exists, strongly read the
wide counter value as candidate `event_id`, require `1000 <= event_id < 2^32`, derive every
`srs-packed-v1` ID, assemble the full immutable Event manifest, and compute its
`definition_digest`. One DynamoDB `TransactWriteItems` call then:

1. conditionally advances the counter from that exact candidate to `candidate + 1`;
2. conditionally puts the request claim `{ provisioning_request_id,
   request_definition_digest, event_id }`; and
3. conditionally puts one self-contained Event item containing the complete immutable manifest and
   `provisioning_state = accounts_pending`.

The Event item is the completeness boundary; do not publish a root item and fill section items in
later. Its immutable definition and mutable provisioning checkpoint are distinct attributes, and
the definition digest excludes the checkpoint and failure diagnostic. The scale decision must set
a manifest-size bound below DynamoDB's 400 KB item limit and bounds that let the complete account
and capacity chains fit their respective TigerBeetle requests. The three-action transaction is
well within DynamoDB's 100-action and 4 MB transaction limits. [AWS
`TransactWriteItems`](https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_TransactWriteItems.html);
[AWS DynamoDB constraints](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Constraints.html)]

A transaction attempt uses a deterministic `ClientRequestToken` derived from the creation request,
candidate Event ID, and request digest. Retry an uncertain attempt with the identical transaction
and token. The token's ten-minute idempotency window is only a short-term aid; the durable request
claim is the long-term idempotency record. After a definitive conditional cancellation, strongly
read the request claim: resume its matching Event, reject a digest mismatch, or, if no claim
exists, reread the counter and retry with the new candidate and a new candidate-specific token.
Never infer success from the counter alone. A candidate Event item that exists without its atomic
request claim, or a counter that points at an occupied Event ID, is control-plane corruption: stop
and reconcile rather than skipping the ID. At the `2^32` sentinel, reject creation without writing
an Event. Claimed IDs are never reused, including for Events that later fail provisioning.

### Verify before every TigerBeetle submission

Before either phase, load the whole Event item and validate it independently of its stored digest:

- require a supported control schema, accounting contract, and identifier scheme;
- require the Event-ID range, `ledger == event_id`, the declared section count, nonempty canonical
  section order, contiguous unique ordinals, unique public section IDs, and positive canonical
  capacities;
- require every materialized ID to be canonical 32-digit lowercase hexadecimal, decode to a valid
  TigerBeetle `u128`, rederive it with the manifest's retained `srs-packed-v1` implementation, and
  compare for exact equality; and
- recompute the definition digest with the retained control-schema encoder and compare it in
  constant time.

`event-definition-v1` uses SHA-256 over an unambiguous length-prefixed binary encoding of every
immutable field in manifest order: its domain/version tag; the Event ID; the three contract
versions; both singleton account IDs; the section count; and, for each ordinal, its UTF-8 public
section ID, capacity, section-account ID, and initial-capacity transfer ID. Integers and decoded
`u128` IDs use fixed-width unsigned big-endian bytes; text is prefixed by its unsigned big-endian
byte length. Request identity, provisioning state, and failure fields are excluded. A retained
schema implementation, not the current default serializer, owns this encoding.

Any local verification failure forbids TigerBeetle submission. It conditionally moves the current
pending state to terminal `failed` with `failure_phase = manifest` and one stable code from
`unsupported_control_schema`, `unsupported_accounting_contract`,
`unsupported_identifier_scheme`, `manifest_incomplete_or_noncanonical`,
`definition_digest_mismatch`, or `provisioning_id_mismatch`.

### Replay the two TigerBeetle phases exactly

The accounting-contract version owns every request field. In version 1, start from zeroed structs,
use nonzero role-specific account and transfer codes, set the research-selected balance flags, and
leave history, imported, closed, user-data, reserved, balances, and timestamps zero. The concrete
version-1 code registry is: Seat Supply Account `1`, Seats Reserved Account `2`, Seat Section
Account `3`, initial-capacity transfer `1`, and reserve transfer `2`; confirm inherits the reserve
code from its pending transfer.

For `accounts_pending`, submit exactly one `create_accounts` batch ordered as Seat Supply, Seats
Reserved, then Seat Sections by ordinal. Set `linked` on every account except the final section
account. Advance to `capacity_pending` with a DynamoDB conditional update only when every result is
`created` or exact `exists`.

For `capacity_pending`, submit exactly one `create_transfers` batch ordered by section ordinal.
Each posted transfer uses its materialized initial-capacity ID, debits Seat Supply, credits that
section account, uses the manifest capacity, Event ledger, initial-capacity code, zero pending ID
and timeout, and zero user data and timestamp. Set `linked` on every transfer except the final one.
Advance to `ready` only when every result is `created` or exact `exists`.

An uncertain client/transport outcome, executor crash, malformed or incomplete result vector, or
DynamoDB checkpoint-write failure leaves the durable state unchanged. The next attempt first
revalidates the manifest and resubmits that state's byte-for-byte-equivalent full batch with the
same IDs. A crash after TigerBeetle success but before the checkpoint therefore observes exact
`exists`; replay never derives a fresh ID. Conditional checkpoint failure means another worker may
have advanced or failed the Event, so reread and follow the observed monotone state. `ready` and
`failed` are terminal; states never move backward. Concurrent provisioners are safe because they
can submit only the same immutable objects and race only on conditional state transitions.

### Terminal failure and stable diagnostics

A structurally valid TigerBeetle reply containing any result other than `created` or exact
`exists` is terminal for this immutable Event. This includes `exists_with_different_*`, validation
and overflow results, missing-account results, and `id_already_failed`; even a TigerBeetle result
described as transient cannot be repaired here because it permanently consumes the fixed transfer
ID and provisioning may not mint a replacement. For a linked failure, ignore companion
`linked_event_failed` entries and identify the first concrete failing result.

Conditionally transition only the currently executing pending state to `failed`, preserving the
first diagnostic forever. Store `failure_phase = accounts` or `capacity` and a stable
`failure_code = tigerbeetle_rejected`, plus the failing batch index, object role, optional section
ordinal, and the pinned client's symbolic and numeric result. If the result vector does not contain
one unambiguous concrete cause, retain the pending state and escalate the protocol uncertainty;
do not guess a terminal diagnosis.

The `failed` transition means the immutable Event is incompatible with the retained contract or
with TigerBeetle state. It never authorizes rewriting the manifest, reusing the Event ID, changing
an object shape, or replacing a capacity-transfer ID. Only `ready` Events may be discovered or used
by reserve execution, so the unavoidable accounts-before-capacity gap, failed chains, and uncertain
replies never expose partial capacity or mint it twice.
