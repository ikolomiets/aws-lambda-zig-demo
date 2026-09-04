---
title: Design the seat reservation system
status: open
labels:
  - wayfinder:map
---

# Design the seat reservation system

## Destination

A decision-complete design for extending the current asynchronous Operation workflow with a
name-routed seat reservation service whose reserve and confirm actions use TigerBeetle as the
authoritative store for Event section capacity and reservation state.

The design must be precise enough to hand off for implementation without reopening its domain,
accounting, API-contract, routing, concurrency, or failure-handling decisions.

## Notes

- Preserve the existing `SUBMITTED -> COMPLETED` Operation lifecycle and immutable tagged result.
- `Operation.name = "seat_reservation_system"` routes to one dedicated queue and executor; each
  Operation body selects either the reserve or confirm action.
- A reserve and its confirmation are separate Operations with independent Operation lifecycles.
- An Event ID is globally unique, allocated monotonically from 1000 through 2^32-1 by a persisted
  DynamoDB counter, and is also the Event's TigerBeetle ledger ID.
- Each Event ledger has one Seat Supply Account, one Seats Reserved Account, and one capacity
  account per Seat Section. Event creation credits section capacity from the Seat Supply Account.
- A reservation requests a quantity, never exact seats, and receives its entire allocation from
  one eligible Seat Section. Allocations never split across sections.
- Reserve creates a timed pending transfer from the selected section account to the Seats Reserved
  Account. Confirm posts that pending transfer. There is no cancellation or void action; an
  unconfirmed hold expires in TigerBeetle.
- The reserve Operation ID is its pending transfer ID. The confirm Operation ID is its distinct
  post-pending transfer ID, and the confirm payload references the pending transfer ID.
- DynamoDB remains the Operation store and Event control plane. Seat capacity and reservation
  lifecycle facts remain authoritative in TigerBeetle.
- Operation tenancy remains an authentication and Operation-query concern; the seat reservation
  executor does not introduce tenant-aware business rules.
- The existing `GET /<operation-id>` endpoint remains the public read model for reserve and confirm
  steps.
- Use `grilling` and `domain-modeling` for decision tickets, `prototype` for concrete identifier or
  concurrency models, and `tigerbeetle-docs` plus primary sources for TigerBeetle facts.
- Any later Zig implementation must follow `docs/TIGER_STYLE_AGENT.md` and the repository's
  validation guidance.

## Decisions so far

<!-- Empty when charted. Closed-ticket resolutions are indexed here by linked ticket name. -->

- [Validate TigerBeetle seat-capacity accounting](issues/01-validate-tigerbeetle-seat-capacity-accounting.md):
  Section credit balances with bounded pending debits enforce capacity, with
  single-section-per-reserve-ID, confirm-ordering, and expiry-liveness constraints carried into the
  dependent design tickets.
- [Define the Event control-plane contract](issues/02-define-event-control-plane-contract.md):
  DynamoDB keeps a lossless immutable Event provisioning manifest, an exhaustion-safe ID counter,
  and a monotone readiness checkpoint while TigerBeetle remains authoritative for capacity and
  reservation lifecycle facts.
- [Define name-based routing and executor ownership](issues/03-define-name-based-routing-and-executor-ownership.md):
  Intake resolves exact supported names before persistence into single-owner queues, with a
  dedicated seat executor and the existing generic persistence, query, and completion path.
- [Choose deterministic TigerBeetle provisioning identifiers](issues/04-choose-deterministic-tigerbeetle-account-identifiers.md):
  A collision-free, versioned packed namespace derives and verifies every Event provisioning ID
  while reserving the full seat-provisioning family from Operation-derived TigerBeetle IDs.
- [Define atomic and replay-safe Event provisioning](issues/05-define-atomic-event-provisioning.md):
  An atomic durable creation claim feeds two exact-replay linked TigerBeetle phases, with stable
  terminal diagnostics and `ready` as the sole publication barrier.
- [Define the reserve action contract](issues/06-define-reserve-action-contract.md):
  Reserve-v1 strictly bounds Event, quantity, eligibility order, and timeout inputs while reserving
  the provisioning ID family and requiring one whole-quantity, single-section transfer attempt.
- [Define the reserve transaction and allocation protocol](issues/07-define-reserve-transaction-and-allocation.md):
  One coherent account snapshot feeds a first-fit decision pinned before one exact pending-transfer
  attempt, separating no-capacity, concurrency loss, uncertainty, drift, and expiry.
- [Define the confirm action and transaction contract](issues/08-define-confirm-action-and-transaction.md):
  Confirm-v1 gates one deterministic full-post transfer on an exact accepted-Reserve proof, while
  TigerBeetle—not a local deadline or immutable lookup—decides the expiry and resolution race.
- [Define retry and failure taxonomy](issues/09-define-retry-and-failure-taxonomy.md):
  Exact-intent uncertainty retries without Completion, definitive owned outcomes pin one terminal
  fact, and untrusted records redrive to bounded DLQs without consuming or repurposing IDs.
- [Define Operation result contracts](issues/10-define-operation-result-contracts.md):
  Closed, bounded action-specific Completions expose only stable result and acceptance-proof facts,
  preserve late Reserve acceptance without claiming liveness, and are pinned byte-exactly before
  publication.
- [Define scale, batching, and concurrency bounds](issues/11-define-scale-batching-and-concurrency-bounds.md):
  Events and grouped I/O stay small under a 32-section contract, ten-record batches, eight-way
  seat concurrency, single-threaded execution, and bounded exact Completion fan-in.
- [Define operational verification and reconciliation](issues/12-define-operational-verification-and-reconciliation.md):
  Versioned topology, authority, integrity, and scale audits permit only bounded unchanged replay
  or redrive, with byte-exact Completion repair and no inferred reservation facts.
- [Define deployment migration and rollback](issues/13-define-deployment-migration-and-rollback.md):
  A dark compatibility-first rollout and 30-day Operation migration precede opening; post-open
  rollback closes intake and drains or quarantines through retained compatible owners without
  rewriting authoritative state.
- [Define the compatibility-first implementation sequence](issues/14-define-compatibility-first-implementation-sequence.md):
  Compatible readers and 30-day writers establish the rollback floor before dark seat artifacts;
  every replay fact precedes its external effect, and strict TTL waits for old data and queue
  lineage to disappear.
- [Define the end-to-end rollout and rollback test plan](issues/15-define-end-to-end-rollout-and-rollback-test-plan.md):
  Cumulative local, mocked-AWS, live TigerBeetle, canary, load, and recovery gates prove exact
  replay and immutable rollback while retaining every authoritative accounting fact.

## Not yet specified

<!-- No remaining fog. All decision tickets are closed. -->

## Out of scope

- Individually identified seats or seat maps.
- Splitting one reservation across multiple Seat Sections.
- Explicit cancellation or void operations.
- Changing Event capacity or Seat Sections after Event provisioning.
- Waitlists, exchanges, reservation transfers, payments, and refunds.
- A separate public availability or reservation lookup API beyond Operation queries.
- Tenant-aware Event ownership or capacity rules inside the seat reservation executor.
