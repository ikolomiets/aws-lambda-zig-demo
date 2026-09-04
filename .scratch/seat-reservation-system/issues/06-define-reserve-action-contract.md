---
title: Define the reserve action contract
status: closed
assignee: codex
labels:
  - wayfinder:grilling
parent: ../map.md
blocked_by:
  - "[Define the Event control-plane contract](02-define-event-control-plane-contract.md)"
  - "[Choose deterministic TigerBeetle provisioning identifiers](04-choose-deterministic-tigerbeetle-account-identifiers.md)"
---

## Question

Given that only a `ready` Event's immutable ordered section manifest may drive allocation, what
exact discriminated Operation body represents reserve, including Event ID, positive seat quantity,
eligible `section_id` semantics, caller-vs-manifest preference order, a stable nonzero whole-second
hold timeout, size limits, rejection of unknown, duplicate, or non-ready Event/section references,
and the shared pre-persistence rule that rejects Operation IDs `0`, `2^128 - 1`, and the entire
high-24-bit `0x535253` provisioning family for every Operation-derived TigerBeetle ID, while
guaranteeing that the full quantity is allocated from one section?

## Resolution

[The TigerBeetle accounting research](../../../docs/research/seat-reservation-tigerbeetle-accounting.md)
fixes the safety boundary for this contract: a reserve is one positive-amount, timed pending
transfer under the Reserve Operation ID; its timeout and all other transfer fields must be stable
on exact retry; the executor must choose one section before submission; and neither an
`exceeds_credits` result nor a same-ID replay permits a second-section attempt. Reserve-v1 makes
every caller-controlled input to that transfer explicit and immutable in the Operation body.

### Exact reserve-v1 body

For `Operation.name = "seat_reservation_system"`, reserve-v1 is this strict JSON object:

```json
{
  "contract_version": 1,
  "action": "reserve",
  "event_id": 1000,
  "quantity": 2,
  "eligible_section_ids": ["orchestra", "balcony"],
  "hold_timeout_seconds": 300
}
```

`contract_version`, `action`, `event_id`, `quantity`, and `hold_timeout_seconds` are required.
`eligible_section_ids` is the only optional field. The exact reserve-v1 rules are:

- `contract_version` is the JSON integer `1`, and `action` is the lowercase JSON string
  `"reserve"`. Booleans, strings containing numbers, fractional or exponent-form numbers, and
  other action spellings are invalid.
- `event_id` is a JSON integer in `1000...4294967295`. It names the Event and therefore its
  TigerBeetle ledger; callers do not supply a separate ledger or any TigerBeetle account ID.
- `quantity` is a JSON integer in `1...4294967295`. It is the entire amount of the one pending
  transfer. Callers cannot express partial allocation, a per-section quantity, or a split.
- `hold_timeout_seconds` is a JSON integer in `1...3600`. It is copied unchanged to the pending
  transfer's `u32` `timeout`; it is an interval from the TigerBeetle-assigned cluster timestamp,
  not an absolute deadline. Making it required avoids a deploy-time default changing the transfer
  shape, and the one-hour ceiling bounds abandoned holds in a design with no cancel action.
- When present, `eligible_section_ids` is a nonempty array of at most 32 unique strings. Each
  string is `1...64` UTF-8 bytes and is compared byte-for-byte with the Event manifest's public
  `section_id`; there is no trimming, Unicode normalization, or case folding. The array is an
  ordered eligibility-and-preference list: consider only its members, in caller order, and never
  append an unlisted manifest section.
- When `eligible_section_ids` is absent, every Seat Section is eligible in immutable manifest
  ordinal order. `null` and an empty array are invalid rather than alternate spellings for this
  default. The caller never supplies the selected section; selection is executor output.

The compact serialized Operation body retains the repository-wide 4,096-byte maximum in addition
to the field bounds above. Reserve-v1 is closed: reject unknown fields and duplicate object keys at
every level, missing required fields, duplicate eligible section IDs, and values of the wrong JSON
kind. These are contract errors, not invitations to coerce or ignore input.

### Resolve references before TigerBeetle submission

The seat executor resolves the body against one complete immutable Event manifest. Before any
account lookup or transfer submission, it must reject an unknown Event, an Event not in `ready`,
and a caller list containing any unknown section ID. It validates the whole list before selecting;
it must not silently discard an invalid or duplicate entry merely because an earlier entry might
be usable. A non-ready or invalidly referenced Event produces no TigerBeetle request and is never
repaired on the reservation path.

The resulting candidate order is stable: caller order when the list is present, otherwise manifest
ordinal order. The allocation protocol may use authoritative TigerBeetle account state to choose
one candidate, but it must submit exactly one pending transfer for exactly `quantity` against
exactly one section. No result permits splitting, submitting parallel section attempts, or falling
through to another section under the same Reserve Operation ID. A caller that wants a fresh
attempt submits a new Operation with a new admissible ID.

### Reserve the provisioning namespace before persistence

Extend the shared Operation intake validation, before the DynamoDB create and before enqueueing,
for every Operation whose ID is or may become a TigerBeetle ID. After decoding the existing UUID
representation to `u128`, require:

```text
id != 0
id != 2^128 - 1
id >> 104 != 0x535253
```

This rule covers the retained legacy path plus reserve and confirm; it is not seat-body validation
and must not be implemented only in the seat executor. Rejection is a bad request with no
Operation persisted or queued, allowing the caller to choose a new ID. The immutable Operation
hash continues to cover the exact body, so changing eligibility order, quantity, Event, timeout,
action, or contract version while reusing an accepted ID remains an Operation conflict.
