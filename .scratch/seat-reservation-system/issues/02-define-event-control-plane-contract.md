---
title: Define the Event control-plane contract
status: closed
assignee: codex
labels:
  - wayfinder:grilling
parent: ../map.md
blocked_by: []
---

## Question

What immutable Event and Seat Section metadata must DynamoDB store in addition to the global Event
ID counter so Event ID allocation, Event-to-ledger lookup, section discovery, provisioning state,
stable account and initial-capacity transfer identities, idempotent recovery across the
accounts-before-capacity gap, and counter exhaustion are unambiguous without making DynamoDB
authoritative for seat availability or reservation state?

## Resolution

[The TigerBeetle accounting research](../../../docs/research/seat-reservation-tigerbeetle-accounting.md)
requires DynamoDB to hold one durable Event provisioning manifest and its provisioning progress,
not a second copy of TigerBeetle balances or reservation lifecycle state.

### Event ID counter

- Store `next_event_id` as an integer in a domain wider than `u32`, initialized to `1000`. An
  allocation claims the current value and advances it by one. The value `4294967296` (`2^32`) is
  the exhausted sentinel; it is never allocated and no allocation is allowed at or beyond it.
- Event IDs are never reused, including after failed provisioning, and gaps are acceptable. Event
  creation must couple claiming an ID with creating the corresponding immutable Event definition
  so an allocated ledger cannot be mistaken for a reusable value; the provisioning ticket decides
  the exact DynamoDB transaction and retry protocol.

### Immutable Event provisioning manifest

The logical Event aggregate is keyed by `event_id`; `ledger` is not an independently mutable field
because it is always exactly `event_id`. Its immutable definition contains:

- `control_schema_version`, `accounting_contract_version`, and `identifier_scheme_version`, so old
  Events always reconstruct the same TigerBeetle request shapes after code changes;
- the materialized Seat Supply and Seats Reserved account IDs;
- `section_count`, the canonical ordered section manifest, and a digest of the complete canonical
  definition to detect truncated or drifted recovery input; and
- for every Seat Section, a stable public `section_id`, a unique zero-based `ordinal`, its positive
  initial `capacity`, its materialized section-account ID, and its one materialized
  initial-capacity transfer ID.

TigerBeetle account and transfer IDs are stored losslessly as canonical 32-digit lowercase
hexadecimal strings rather than DynamoDB Numbers. Capacity is stored as a canonical positive
base-10 integer string, preserving the exact TigerBeetle `u128` amount independently of the later
operational bound. Section IDs and ordinals are immutable and unique within the Event; ordinal
order is the stable account/transfer batch order.

The accounting contract version fixes every remaining replay-sensitive field: account and transfer
codes, base flags, user data, zero fields, and linked-chain placement. The persisted IDs, ordered
sections, capacities, and version therefore reconstruct byte-for-byte-equivalent linked account
and initial-capacity transfer batches. A newer identifier or accounting version applies only to a
new Event; recovery never silently upgrades an existing manifest.

The logical aggregate may be physically stored as one Event item or an Event item plus Seat Section
items. In either layout, `section_count` and the definition digest must make completeness
verifiable, and no incomplete or mismatched manifest may become reservable.

### Provisioning state and authority boundary

Store a mutable, conditionally advanced `provisioning_state` beside the immutable manifest:

1. `accounts_pending` is the initial state and means the exact linked account batch is the next
   required TigerBeetle action.
2. `capacity_pending` means every account result was `created` or exact `exists`, and the exact
   linked initial-capacity transfer batch is next.
3. `ready` means every initial-capacity transfer result was `created` or exact `exists`; only this
   state may be used for reserve section discovery or execution.
4. `failed` is a non-reservable terminal provisioning state for a deterministic incompatible or
   invalid result, with stable `failure_phase` and `failure_code` diagnostics. The later failure
   taxonomy decides the exact result-to-code mapping.

Transitions are monotone and conditional. A crash or uncertain reply leaves the last durable state
unchanged, so recovery resubmits that state's exact batch under the same IDs. It advances only
after the entire linked batch is known to be `created` or exact `exists`; it never generates a new
ID to escape uncertainty. This makes the unavoidable accounts-before-capacity gap safe and keeps
partially provisioned Events unavailable.

DynamoDB is authoritative only for Event identity, immutable section definition, provisioning
progress, and whether an Event has crossed the `ready` publication barrier. It must not maintain
available-seat counters, selected sections for reservations, pending/confirmed reservation state,
or hold liveness. TigerBeetle accounts, balances, transfers, and transfer outcomes remain
authoritative for all of those facts.
