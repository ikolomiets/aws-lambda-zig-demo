# Seat Reservation contracts, Event metadata and global ledgers

The pure [seat domain module](../src/seat_reservation.zig) defines typed commands,
Context, public Results, native input serialization, and pre-effect size admission.
The [shared persistence module](../src/seat_reservation_persistence.zig) reads and
inserts tenant-owned Event metadata. The host `events` utility uses these modules.
The independent [ledger counter](../src/ledger_counter.zig) and host
`ledger-counter` utility initialize, inspect and allocate global ledgers.
The [submission](../src/seat_reservation_processor.zig) and
[completion](../src/seat_reservation_completion_processor.zig) handlers implement
local rejections, native Event creation and availability observations through
authenticated intake and query. Reservation and confirmation execution, and SAM
provisioning of the two handlers, remain separate slices.

## Rejection workflow

When configured with `SeatReservationQueue`, intake routes the exact name
`SeatReservation` through its existing name-based mechanism. It persists a
`SUBMITTED` Operation with the verified PASETO subject as tenant, then publishes
the original Body and null Context. The current SAM template still provisions
the existing four functions; it does not configure this seat route.

Each seat invocation accepts exactly one SQS record. Submission rejects incoming
Result Queue overrides and non-null incoming Context. Whole-request schema and
size admission precedes any allocation, Event write or native dispatch. Invalid
requests produce `invalid_request`. Missing and foreign Events both produce
`event_unavailable`; only owned Events disclose `event_not_ready`, `event_failed`
or, when ready, `unknown_class`. Transient reads remain retryable.

A local failure goes only to the configured `SeatReservationCompletionQueue`:

```json
{
  "operation_id": "00000000-0000-0000-0000-000000000001",
  "tenant": "theatre",
  "body": { "code": "event_not_ready" },
  "context": {
    "command": "reserve_seats",
    "event_id": "00000000-0000-0000-0000-000000000002",
    "class": "general",
    "quantity": 2
  }
}
```

The original input becomes arbitrary Context, including invalid scalar or null
input. It must fit the shared 4 KiB Context bound. An internal message whose input
cannot be carried within that bound is diagnosed as unusable. No local rejection
allocates a ledger, writes an Event or dispatches native work. Admitted creation
and availability checks dispatch native work as described below. Admitted reserve
and confirm commands remain retryable pending their native implementations.

Completion rejects Result Queue overrides. Local completion accepts an unambiguous
admission-failure Body containing exactly `code`. Native three-list and mixed
Bodies do not become local failures. Local completion preserves the admission code without
decoding Context as a command or reading the Event again. Thus a delayed
`event_not_ready` remains that failure even after the Event becomes ready.

Operation-only finalization guards UUID, tenant, exact name `SeatReservation`,
`SUBMITTED` state and absent Result, with normal timestamps and 24-hour TTL and
without comparing the input hash. A conflict or uncertain write requires a
strongly consistent readback. Only a matching identity with a valid terminal seat
Result proves a winner; that Result remains unchanged even when it differs from
the incoming rejection. Submitted readback and transient write/readback failures
remain retryable. Identity or stored-state inconsistencies are diagnosed.

Submission acknowledges after successful publication; completion acknowledges
after durable finalization or validated winner readback. A lost send response can
produce duplicate completions. A lost write response can resolve through readback.
Response-encoding failure after effects also permits redelivery under the same
guards. Authenticated query exposes the code-only `FAILURE` Result only to the
owning tenant; an earlier query can still observe `SUBMITTED`.

Diagnosed unrecoverable inputs acknowledge without Event or Operation mutation.
Structured ERROR output includes stage, reason, SQS ID, available UUID/tenant,
original body length, escaped preview and explicit `truncated` boolean within
8 KiB. Non-ASCII/control bytes in previews use visible byte escapes. Diagnostic
delivery does not determine acknowledgement and creates no public Result.

The submission runtime uses `EVENTS_TABLE_NAME`, `LEDGER_COUNTER_TABLE_NAME`,
optional `LEDGER_COUNTER_ID` (default `global`), `TigerBeetleQueue` and
`SeatReservationCompletionQueue`. Completion uses `EVENTS_TABLE_NAME` and
`OPERATIONS_TABLE_NAME` in the same account and Region.
Both use the existing SDK configuration and SQS/persistence mechanics.

```sh
zig build build-seat-processors test-seat-workflow
```

`build-seat-processors` compiles the host runtime entry points without installing
or packaging Lambda artifacts. The composed deterministic tests exercise real
authenticated handlers, domain codecs and persistence builders with external
effects faked, including invocation restarts and ambiguous outcomes. They run in
the ordinary offline suite. The separate [SDK transaction probe](SEAT_TRANSACTIONS.md)
establishes executable persistence composition evidence. The
[consistency ADR](adr/0007-seat-completion-consistency.md) records the recovery decision.

## Event creation workflow

`create_event` uses its Operation UUID as Event ID and the verified tenant as owner.
After whole-command admission, submission first reads that Event. A missing Event
requires one allocation from the trusted configured physical counter table/ID
binding and fresh Capacity, Allocation and Availability account IDs. Native cluster
identity does not select the counter. Submission inserts all identities, ledger,
class totals, timeout and `creating` state before sending native work. Concurrent
insertions and lost insert responses resolve to the saved winner; a losing candidate
never supplies dispatch identities. Allocation and insertion uncertainty may leave
gaps. Unresolved writes do not authorize dispatch.

Retries reconstruct the saved complete chains and exact fields. Account creation
orders Capacity (code 3, `credits_must_not_exceed_debits`), Allocation (code 2,
`debits_must_not_exceed_credits`), then Availability accounts (code 1,
`debits_must_not_exceed_credits`) in unsigned class-tag byte order. Aliases are
`capacity`, `allocation`, then the class tags. A separate linked funding chain
debits Capacity and credits each Availability account with its configured total,
code 1, no transfer flags, and alias `available-${tag}` in the same class order.
Each funding transfer reuses its Availability ID in the separate transfer namespace.
The native processor supplies linked flags within each complete family. Initialization
contains `N+2` accounts, `N` transfers and no lookups: `2N+2`, at most 64 commands.
Account creation and funding execute in separate native phases.

Submission sends to `TigerBeetleQueue` with `SeatReservationCompletionQueue` as
Result Queue. Context contains exactly the flat original creation request; the
native adapter preserves UUID, trusted tenant and Context and sends its three-list
Body to that completion queue. Completion validates Context against the saved Event,
then checks every family, count, position, alias and per-entry field. A successful
chain is all `created`, or first `exists` followed entirely by `linked_event_failed`
(including singleton `exists`). Account success requires complete funding evidence.
Rejected accounts require the complete deliberately skipped funding list. Generated
account conflicts and invalid server configuration are internal failures; they leave
both records unchanged. Funding `id_already_failed` with failed-link entries at all
other positions establishes permanent `operation_rejected`. Unknown, mixed,
late-exists, truncated, skipped-success or diagnostic evidence never establishes readiness.

Valid evidence finalizes both records through one `TransactWriteItems`: the Event
changes from `creating` to `ready` with a `SUCCESS` Result containing only `event_id`,
or to `failed` with a `FAILURE` Result containing only `code: operation_rejected`.
The Event condition covers its tenant/Event key and every saved configuration field,
including account IDs and the entire classes Map. The Operation condition covers
UUID, tenant, exact name `SeatReservation`, `SUBMITTED` and absent Result, without
checking its hash. Normal timestamps and 24-hour Operation TTL apply. No readiness
write occurs separately from the Result write.

After conflicts or lost transaction responses, one `TransactGetItems` reads the
coherent pair. Matching ready/success or failed/failure identifies the immutable
winner, even when incoming valid evidence proposes a different outcome. A matching
creating/submitted pair stays retryable with the same evidence. Missing records,
configuration or identity mismatches, and contradictory states are diagnosed without
mutation. Transient errors retain retry eligibility. Failed Events never restart
initialization; creating Events retain uncertainty until valid evidence completes
them. A failed Event requires a new creation Operation/Event. There is no repair
transition, separate-write fallback, outbox, or automatic recovery after Operation deletion.

The composed offline workflow checks races, duplicate/competing completions,
allocation gaps, lost dispatch/transaction responses, partial initialization and
contradictory pairs. The separate local SDK probe exercises runtime finalization
and winner readback. `TIGERBEETLE_ADDRESSES=127.0.0.1:3000 zig build test-tigerbeetle`
proves native funding, intact replay and the three account bounds against the local
replica; the offline fakes do not establish those native guarantees.

## Availability workflow

`check_seats` accepts exactly `command` and `event_id`. Submission reads the
tenant-owned Event and authorizes readiness before native dispatch. Missing and
foreign Events both return `event_unavailable`; creating and failed Events return
`event_not_ready` and `event_failed` only to their owner. Callers cannot select a
subset. Submission looks up every configured Availability Account in unsigned
class-tag byte order, with each class tag as its alias, preserving the original
command as Context and routing native output to seat completion.

Completion requires empty creation lists and exactly one found lookup per class,
in the same order. It checks every alias and all native account fields: the saved
account ID and ledger, code 1, `debits_must_not_exceed_credits`, zero user data,
reserved and pending credits, and a positive native creation timestamp. The
persisted `linked` flag is required on every class except the last, matching the
complete initialization chain; no other flags are permitted. Canonical
decimal strings preserve the native u128/u64 fields. Posted credits must equal
the configured total. Total is `credits_posted`; available is
`credits_posted - debits_posted - debits_pending`, using checked subtraction.
Missing, wrong or closed accounts, impossible balances, null placeholders,
diagnostics, incomplete evidence and extra entries are unrecoverable
inconsistencies. They acknowledge with a bounded diagnostic and leave both the
Event and Operation unchanged; no zero balances or partial Result are invented.

Valid evidence finalizes only the matching Operation, using the same guarded
identity/state/absent-Result update and authoritative valid-winner readback as
local rejection. Its `SUCCESS` payload contains exactly `event_id` and `classes`,
mapping every tag to integer `total` and `available` in class order. A delayed or
duplicate completion cannot replace the first valid saved observation. Checks
allocate no ledger or native identity and never change Event state.

Availability is an observation, not a hold or a reservation guarantee. Concurrent
reservations can change supply after a lookup. Native expiry cleanup can lag the
hold's deadline; a lookup may still subtract expired pending debits until cleanup
reclaims them. Completion and query can deliver an older observation later.

`zig build test-seat-workflow` exercises authenticated intake, submission, the
native adapter, completion and owner query with one and 31 classes, reordered
native replies, invalid evidence, tenant isolation and competing observations.
The separate local native suite runs the real adapter and domain projection after
funding, holds, full posting and eventual expiry cleanup:

```sh
TIGERBEETLE_ADDRESSES=127.0.0.1:3000 zig build test-tigerbeetle
```

These checks establish local behavior; they do not establish AWS delivery or
service configuration.

## Commands

Every public Body is exactly one object with these required fields. There are no
optional fields, tenant overrides, routes, flags, ledger or native account IDs.

| `command` | Other required fields |
| --- | --- |
| `create_event` | `classes`: tag-to-capacity object; `timeout_seconds`: positive u32 |
| `reserve_seats` | `event_id`: canonical UUID; `class`: one tag; `quantity`: positive u32 |
| `confirm_seats` | `event_id`: canonical UUID; `class`: one tag; `pending_id`: native ID string |
| `check_seats` | `event_id`: canonical UUID |

Unknown or missing fields, wrong types, nulls and decoded duplicate keys are
errors. Reserve and confirm accept one scalar class, never arrays or class Maps.
Create accepts 1–31 classes; check serializes every configured class.

Tags contain 1–54 decoded UTF-8 bytes. U+0000–U+001F and U+007F–U+009F, invalid
UTF-8, and the exact decoded names `capacity` and `allocation` are rejected.
Case, spaces, punctuation, combining marks and format characters are preserved.
Equality and ordering use unsigned decoded bytes without normalization. Equivalent
JSON escapes are the same key; composed and decomposed Unicode tags are distinct.

Capacities, quantities and timeout are integers in 1–4,294,967,295. Integral
spellings normalized to these values are accepted; remaining fractions, zero,
negative zero, strings, negatives and overflow are rejected. Supply is summed
with checked u64 arithmetic, at most 133,143,986,145. UUIDs are lowercase,
hyphenated canonical strings, including zero and any version/variant. Native IDs
are canonical ASCII decimal Strings from 1 through 2^128−2, with no leading zeros,
signs, whitespace, exponent notation or numeric JSON form.

## Context, native inputs and Results

Context is the flat command object. Reserve additionally requires
`reservation_id`, naming that attempt's pending transfer. Confirm carries
`pending_id` and no posting ID. Creation uses its enclosing Operation UUID as the
Event identity. These codecs reject unknown and decoded duplicate keys.

The native input serializer emits all three family lists. Creation orders
Capacity, Allocation and Availability Accounts by tag bytes, then funds those
classes in the same order, without lookups. Funding reuses each Availability
Account ID as the transfer ID. Reserve serializes one pending transfer with the
Event's ledger/timeout and class quantity. Confirm serializes one full posting
with amount 2^128−1, explicit Availability debit, Allocation credit, ledger and
code 2, and no timeout. Linked flags belong to the native processor's list framing.
Check serializes all Availability lookups in class order. These are pure serializers;
they perform no native calls or ledger allocation.

Public Results contain the existing `type`/`payload` wrapper:

| Success | Exact payload fields |
| --- | --- |
| Create | `event_id` |
| Reserve | `event_id`, `class`, `quantity`, `reservation_id` |
| Confirm | `event_id`, `class`, `reservation_id` (the input pending ID) |
| Check | `event_id`, `classes` mapping every tag to `total` and `available` integers |

Failure payloads contain only `code`: `invalid_request`, `event_unavailable`,
`unknown_class`, `event_not_ready`, `event_failed`, `insufficient_seats`,
`reservation_expired`, `invalid_reservation`, or `operation_rejected`.
Serializing a Result does not interpret or certify native execution evidence.

`admit` validates the complete command and measures its actual public Body,
Context, native input, compact shared envelope, complete public success Result,
and logical Event before external effects. Creation uses maximum-width synthetic
IDs and ledger for this proof, then discards them. Other commands need matching
tenant/Event identity; authorization precedes readiness and class disclosure.
Creating and failed Events reject these requests; only ready Events reach class
lookup. Persistence independently proves typed-item admission before insertion.

## Persistent Event contract

An Event has exactly these logical fields:

- `tenant`: the owning tenant, 1–64 UTF-8 bytes.
- `event_id`: canonical UUID, separate from the tenant key.
- `ledger`, `timeout_seconds`: positive u32 values.
- `capacity_account_id`, `allocation_account_id`: native ID Strings.
- `state`: `creating`, `ready`, or `failed`.
- `classes`: 1–31 tags, each mapping exactly `total` and `tb_account_id`.

Account IDs are distinct within an Event. Classes retain sorted tag bytes and
positive u32 totals. DynamoDB uses separate String partition/sort keys `tenant`
and `event_id`; ledger, timeout and class totals are Numbers, native IDs are
Strings, and classes are nested Maps. There is no Event TTL or history field.

Reads use strongly consistent tenant/Event keys and validate the complete stored
item, including returned identity. Missing and foreign Events return the same
`EventUnavailable` error. Unknown, missing, duplicate or wrongly typed attributes,
malformed IDs, invalid states, duplicate accounts, and invalid class Maps return
`InvalidItem`. Decoded Events own tenant and class storage in the caller's arena.

Creation accepts only validated `creating` metadata and uses
`attribute_not_exists(#tenant) AND attribute_not_exists(#event_id)`. It never
replaces an existing item. A conflict or lost put response triggers a strongly
consistent read. Matching classes and timeout return the saved winner, preserving
its ledger, IDs and state even when the losing candidate generated other IDs.
Different classes/totals or timeout produce `EventConflict`. Missing readback
produces `InsertionUncertain`; failed or malformed readback produces an error.
No unresolved insertion returns a dispatchable candidate. Request Strings and
nested Maps remain owned by the request arena through the SDK call; service
error diagnostics remain internal and are released before returning.

## Global ledger allocator

A DynamoDB LedgerCounter table supports independent records, each with exactly
String partition key `counter_id` and Number `high_water`, an integer u32 from
1000 through 4,294,967,295. The physical table and selected ID define the binding.
IDs contain 1–128 ASCII bytes: the first is a letter or digit, and subsequent
bytes are letters, digits, `.`, `_`, or `-`. Equality is case-sensitive without
trimming or normalization. Invalid or explicitly empty IDs fail before effects;
only omitted selection defaults to `"global"`.

Tenants and deployments requiring one sequence use the same binding, including
those using different native clusters. Different IDs in one table and different
tables define independent sequences that may allocate equal numeric values.
`cluster_id` appears in neither counter storage, API nor allocation configuration.
Existing `"global"` records retain their high-water values. The partition-key
schema is unchanged; selection needs no table replacement or data conversion.

Explicit first-time `initialize` inserts 1000 absent-only. A conditional conflict
reads and validates the selected record without replacing it. `read` uses the
selected key with strong consistency. Every returned record must match the
requested ID. Setup and failures for one ID leave other IDs untouched. Neither
read nor allocation initializes a missing record. Missing or corrupt established
state requires operator investigation;
there is no automatic repair, reset, decrement, recycling or restore reconciliation.

`allocate` first validates the complete record, then conditionally increments its
number atomically with an exact-value, Number-type and range guard, requesting
`ALL_NEW`. The read protects against incrementing fractional or malformed storage;
it never supplies an allocated value. Only a validated returned update equal to
the guarded value plus one supplies a ledger. First allocation is 1001, and the
maximum u32 value is the final allocation. Up to four attempts retry only definite
conditional rejections from concurrent updates; exhaustion, persistent contention,
service rejection and response uncertainty are explicit errors.

The SDK uses one HTTP attempt per call and caps response bodies at 8 KiB.
Transport errors, server errors, missing/malformed update output and mismatched
updated values make allocation uncertain. No failed update triggers readback or
retry to infer its value. A later read reports only current state. Retrying a
fresh allocation may consume another value. Lost responses, manual allocations
and losing Event-creation races may leave permanent gaps.

The shared `initialize_selected`, `read_selected` and `allocate_selected` APIs
accept a `Binding` containing `table_name` and `id`; omitted `id` uses `"global"`.
Existing `initialize`, `read` and `allocate` calls retain that default.
`Counter.init` selects `LEDGER_COUNTER_ID` or `"global"`; `init_with_id` gives an
explicit ID precedence over environment configuration. Its `setup_selected`,
`read_selected` and `allocate_selected` methods override the retained ID for
one call. Invalid selected IDs fail before persistence effects.

`Counter` owns copies of both table and ID text; the AWS configuration outlives
its client. Request arrays, table/ID text and numeric expression values belong
to the caller's arena through serialization and the SDK call. Returned high-water
values are owned integers without borrowed response storage. The table can be
owned by a deployment or explicitly referenced; tooling performs no table
lifecycle actions. Counter data has no TTL, and only the owning deployment may
clean up its table. Deleting an owned table deletes every counter in it;
referenced tables and their counters remain the owner's responsibility.
Selecting another ID establishes another binding, rather than repairing or
resetting the existing sequence. Public SeatReservation contracts are unchanged;
trusted seat-runtime selection and SAM wiring remain separate implementation work.

## Size bounds and deterministic evidence

| Boundary | Bytes |
| --- | ---: |
| Public Body / compact Context | 4,096 each |
| Processor Body / complete Result | 98,304 each |
| Decoded Result Queue | 2,048 |
| Compact shared envelope | 115,328 |
| Logical Event JSON | 16,384 |
| Typed DynamoDB item JSON | 32,768 |

Compact sizing uses the same domain serializers as output. Typed-item sizing uses
the pinned SDK's actual uppercase `S`/`N`/`M` serializer. Oversized inputs are
rejected whole, without truncation or prefix admission. Raw command, Context and
metadata readers check their bounds before parsing, including whitespace.

Tests cover 31 escaped 54-byte tags, maximum u32 numbers, distinct 39-digit native
IDs, maximum UUIDs, 64-byte escaped tenants and 2,048-byte escaped routes. Accepted
metadata and public Results remain below the larger caps; those caps do not
require reducing the class ceiling. Constructible exact/one-byte-over fixtures
cover raw Body/Context/Event input and compact generic Body/Context, complete
Results and typed-item serialization. Artificial item-size fixtures isolate the
size gate and do not make extra Event attributes valid. Shared envelope tests
also cover raw exact/over bounds and separate SDK SQS and Lambda event escaping;
the existing native serializer tests prove the generic complete-Result bound.

Run the focused credential-free checks:

```sh
zig build build-events test-seat-reservation test-seat-persistence test-events-cli test-events-wrapper
zig build build-ledger-counter test-ledger-counter test-ledger-counter-cli test-ledger-counter-wrapper
zig build fmt-check
```

All deterministic suites also run in `zig build test`; the wrapper uses mocked
AWS credentials and resource resolution. These checks establish local contracts,
ownership and recovery behavior. The composed workflow suite establishes local
seat handler integration; these tests do not establish live AWS IAM, DynamoDB
service behavior or native accounting guarantees.

The [deployment guide](DEPLOY_AWS_LAMBDA_WITH_SAM.md#seat-event-metadata-utility)
owns utility invocation, environment, permissions and deployment prerequisites.
The [global ledger ADR](adr/0005-global-ledger-allocation.md) records the allocator scope.
The [Event identity ADR](adr/0004-seat-event-identities.md) records the durable
identity decision.
