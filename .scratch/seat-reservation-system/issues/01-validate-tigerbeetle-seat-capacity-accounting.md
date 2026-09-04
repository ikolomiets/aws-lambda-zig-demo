---
title: Validate TigerBeetle seat-capacity accounting
status: closed
assignee: codex
labels:
  - wayfinder:research
parent: ../map.md
blocked_by: []
research_branch: research/tigerbeetle-seat-capacity-accounting
research_artifact: ../../../docs/research/seat-reservation-tigerbeetle-accounting.md
research_agent: Bohr
---

## Question

Which TigerBeetle account flags, balance orientation, transfer fields, timeout semantics, and error
results make the Event topology—Seat Supply Account to section accounts, then timed pending and
posted transfers from a section to the Seats Reserved Account—enforce section capacity without
overbooking under retries, concurrency, expiry, and uncertain replies?

## Resolution

[The TigerBeetle accounting research](../../../docs/research/seat-reservation-tigerbeetle-accounting.md)
validates the topology, subject to the constraints below and runtime integration tests against the
repository's exact TigerBeetle client and cluster pair.

- Model capacity as a posted credit balance on each Seat Section: initial capacity is a posted
  transfer from the Event's Seat Supply Account to the section, and every section account has
  `debits_must_not_exceed_credits`. TigerBeetle then rejects a pending reserve whenever
  `debits_pending + debits_posted + quantity > credits_posted`, so concurrent holds cannot
  overbook the section. Use `credits_must_not_exceed_debits` on Seat Supply and
  `debits_must_not_exceed_credits` on Seats Reserved as role-preserving safeguards.
- Create a reserve as one timed pending transfer from the selected section to Seats Reserved, with
  the reserve Operation ID as the transfer ID, a positive quantity, a stable nonzero whole-second
  timeout, and `pending` as its only transfer flag. Create a confirm under its distinct Operation
  ID with `post_pending_transfer`, `pending_id` set to the reserve Operation ID, and
  `amount = AMOUNT_MAX`; set inheritable account, ledger, code, and user-data fields to zero.
- Retries must reuse the same ID and exact semantic fields. Treat `created` and exact `exists` as
  idempotent creation success, but do not treat a reserve's `exists` as proof that its hold is
  still live. `exceeds_credits` permanently consumes that reserve transfer ID, so one reserve
  Operation can submit against only one selected section and cannot fall back to another section.
  Likewise, `pending_transfer_not_found` permanently consumes a confirm transfer ID, so confirm
  execution must be gated on a definitively accepted reserve.
- Derive the hold deadline from TigerBeetle's returned transfer timestamp plus the submitted
  timeout. Expiry prevents later confirmation, but pending-balance cleanup is best effort with no
  documented maximum delay or notification; balance reads near expiry may therefore be
  conservatively stale.
- Provision accounts and initial capacity with stable, globally unique IDs. Linked chains can make
  the account batch and the capacity-transfer batch independently all-or-none, but TigerBeetle
  cannot atomically combine those two event types, so the Event control plane must make the gap
  recoverable and must never mint capacity with a fresh transfer ID on replay.
