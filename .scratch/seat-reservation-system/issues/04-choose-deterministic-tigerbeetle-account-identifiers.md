---
title: Choose deterministic TigerBeetle provisioning identifiers
status: closed
assignee: codex
labels:
  - wayfinder:prototype
parent: ../map.md
blocked_by:
  - "[Validate TigerBeetle seat-capacity accounting](01-validate-tigerbeetle-seat-capacity-accounting.md)"
  - "[Define the Event control-plane contract](02-define-event-control-plane-contract.md)"
---

## Question

What concrete, versioned derivation should populate the Event manifest's materialized TigerBeetle
IDs for the Seat Supply Account, Seats Reserved Account, every ordered Seat Section account, and
each section's one initial-capacity transfer, using Event ID, object role, and stable section
identity so values are cluster-wide unique, neither zero nor `2^128 - 1`, separated from present
and future namespaces, stable across retries and code upgrades, and independently re-derivable to
verify the persisted manifest without any per-reservation mapping?

## Resolution

[The TigerBeetle accounting research](../../../docs/research/seat-reservation-tigerbeetle-accounting.md)
establishes that account and transfer IDs are client-defined `u128` values, unique across their
respective cluster-wide namespaces, that `0` and `2^128 - 1` are invalid, and that provisioning
must replay the same IDs exactly. Use an injective packed identifier scheme rather than a hash so
uniqueness is proved by the existing globally unique Event ID and immutable section ordinal and
does not depend on collision probabilities or text canonicalization.

### Identifier scheme `srs-packed-v1`

Interpret every ID below as one unsigned 128-bit integer. Version 1 is:

```text
id = (0x535253 << 104) |
     (0x01     <<  96) |
     (event_id <<  64) |
     (role     <<  56) |
     section_slot
```

The fields, from most to least significant, are:

| Bits | Field | Version 1 rule |
| --- | --- | --- |
| `127..104` | family | `0x535253`, the ASCII bytes `SRS`, reserved cluster-wide for seat-reservation provisioning |
| `103..96` | version | `0x01`; `0x00` is invalid and other values are reserved for future schemes |
| `95..64` | Event | the Event ID, which is already globally unique and is in `1000...2^32-1` |
| `63..56` | role | a registered nonzero object role from the table below |
| `55..0` | section slot | `0` for Event-singleton roles; otherwise immutable zero-based section ordinal plus one |

Version 1 registers these roles:

| Role | Object | Section slot |
| --- | --- | --- |
| `0x01` | Seat Supply Account | `0` |
| `0x02` | Seats Reserved Account | `0` |
| `0x03` | Seat Section account | `section.ordinal + 1` |
| `0x81` | initial-capacity transfer | `section.ordinal + 1` |

Account roles occupy `0x01...0x7f`; provisioning-transfer roles occupy `0x80...0xff`. Unassigned
roles are reserved and must not be improvised. Keeping the numeric values distinct even across
TigerBeetle's separate account and transfer namespaces follows the research recommendation and
avoids ambiguity in systems that later use one namespace for both.

The section ordinal is the derivation's stable section identity. It is immutable, unique, and
already fixes manifest and linked-batch order. The public `section_id` remains the API identity and
must map to exactly one ordinal in the immutable, definition-digested manifest, but it is not hashed
into a TigerBeetle ID. This avoids both hash collisions and changes caused by text encoding or
canonicalization. The structural version-1 bound is therefore `section.ordinal <= 2^56 - 2`; the
scale decision must choose a much smaller operational section-count bound.

For example, Event `1000` has these canonical 32-digit lowercase hexadecimal IDs:

```text
Seat Supply Account:                 53525301000003e80100000000000000
Seats Reserved Account:              53525301000003e80200000000000000
Seat Section account, ordinal 0:     53525301000003e80300000000000001
Initial-capacity transfer, ordinal 0: 53525301000003e88100000000000001
```

### Namespace and compatibility rules

- Reserve the entire high-24-bit `0x535253` family for all present and future seat-reservation
  provisioning schemes. Every Operation ID that may become a TigerBeetle account or transfer ID,
  including the retained legacy path and reserve and confirm Operations, must be rejected before
  persistence when `id >> 104 == 0x535253`, in addition to rejecting `0` and `2^128 - 1`. A caller
  can safely generate a different Operation ID. Any future TigerBeetle ID producer must register a
  disjoint family rather than assuming that a ledger separates IDs.
- The family constant makes every generated value nonzero and strictly below `2^128 - 1` by
  construction. Distinct Event IDs, roles, or section slots differ in disjoint bit fields, so the
  derivation is injective. IDs for later Events also sort after IDs for earlier Events within this
  family, retaining useful locality without pretending these immutable foreign IDs are
  TigerBeetle-generated time-based IDs.
- `identifier_scheme_version` is immutable per Event and dispatches to an exact retained
  implementation. A future version may change the layout only for newly created Events; recovery
  and reconciliation of an existing Event must never silently upgrade it. The three-byte family
  remains reserved even if all one-byte versions are eventually retired.

### Materialization, replay, and verification

Event creation computes the IDs once from the allocated Event ID and canonical ordered sections,
stores them as the already-decided 32-digit lowercase hexadecimal manifest fields, and includes
them in the definition digest. Before any provisioning replay or reconciliation, version-specific
code must validate the Event-ID range, contiguous unique ordinals, public-section-ID-to-ordinal
mapping, known role/slot combinations, and canonical hex encoding; rederive every ID; and require
exact equality with the materialized values.

A mismatch is manifest corruption or an unsupported contract, never a reason to mint a replacement
ID or submit a best-effort repair. The provisioning decision must define its terminal failure and
diagnostic behavior. Once verified, retries use the materialized IDs and the Event's immutable
accounting-contract fields byte-for-byte. Per-reservation mappings remain unnecessary: reserve and
confirm transfers continue to use their admissible Operation IDs, while only Event provisioning
uses `srs-packed-v1`.
