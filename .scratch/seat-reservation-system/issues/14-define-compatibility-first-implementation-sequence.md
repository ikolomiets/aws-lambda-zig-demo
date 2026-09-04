---
title: Define the compatibility-first implementation sequence
status: closed
assignee: codex
labels:
  - wayfinder:grilling
parent: ../map.md
blocked_by:
  - "[Define deployment migration and rollback](13-define-deployment-migration-and-rollback.md)"
---

## Question

What exact implementation and merge sequence turns the completed seat-reservation decisions into
independently buildable, rollback-compatible increments while preserving the live `echo`, query,
and shared Completion path at every step? Define the dependency order for retained contract
decoders and validators; 30-day Operation writers and dual-form TTL migration tooling; route gate
and exact two-entry registry; Event/control and reconciliation storage; deterministic identifiers
and provisioning; Reserve/Confirm decisions and terminal markers; dedicated seat queue/executor;
strict shared Completion behavior; operational auditors/reconciliation; alarms; and deployment
helper support.

The sequence must identify which increments form the pre-seat compatibility floor, which artifacts
may be deployed dark with the seat route and poller disabled, and when strict new-only TTL
validation may replace the migration reader. It must preserve existing logical resource and
Function URL identities, keep every increment within the repository's small-module and Tiger Style
constraints, and update `deploy.sh`, `wireguard-gateway-setup.sh`, `template.yaml`, build/package
outputs, tests, and deployment documentation together where their behavior changes. No increment
may require a later migration to reconstruct an immutable Event, decision, marker, Completion, or
TigerBeetle request from fields that were not durably present when it was written.

## Resolution

[The TigerBeetle accounting research](../../../docs/research/seat-reservation-tigerbeetle-accounting.md)
sets the ordering rule: account and transfer IDs are cluster-global, accepted objects are
immutable, exact replay requires the original ID and semantically identical fields, and an
uncertain request may already have succeeded. Implementation must therefore put compatible
readers before new writers and put every immutable intent before the external effect it can
replay. A rollback may select an older artifact only when that artifact retains every decoder,
validator, and request builder needed by the durable data already written.

### Treat each increment as a complete compatibility step

Every numbered increment below is one reviewable merge and one independently buildable release
candidate. It must keep authenticated `echo` intake, the legacy queue and executor, tenant-scoped
query, the shared Completion worker, and both existing Function URLs working. A change that alters
a build output, SAM resource, deployment parameter, package, WireGuard attachment, operator
command, or documented behavior updates its tests and the matching `build.zig`, `template.yaml`,
`deploy.sh`, `wireguard-gateway-setup.sh`, and deployment documentation in that same increment.
Ignored zip artifacts are refreshed only for an authorized deployable package; the build and
helper must nevertheless know every required bootstrap and package as soon as its Lambda lands.

Do not create a generic workflow framework or schema abstraction. Put a versioned decoder or
validator beside the persisted or wire contract it owns, keep one explicit parent function in
control of each state machine, pass effects as adapters, and keep bounded leaf calculations pure.
New modules are justified only when the Event store, seat executor, provisioner, or reconciliation
runner first needs a dependency boundary. Each Zig increment applies the bounds, assertions,
explicit error handling, and validation commands in `docs/TIGER_STYLE_AGENT.md` without refactoring
the retained path merely for style.

The exact merge order is:

1. **Freeze retained contracts and add read-only version dispatch.** Capture fixtures for the
   currently persisted and queued Operation shape, the current legacy Completion/result shape,
   and the current physical-resource and Function URL identities. Add explicit retained decoders
   and validators for those shapes plus the already-decided Event, reserve-v1, confirm-v1,
   `reserve-decision-v1`, result-v1, and `seat-terminal-v1` contracts. Version dispatch must be a
   closed switch over known versions, not a permissive fallback, and this increment writes no new
   form. Add the shared Operation-ID admissibility predicate for `0`, `2^128 - 1`, and the
   `0x535253` family, but do not yet enable any Event provisioning.
2. **Deploy dual-form Operation readers before changing TTL writers.** Every existing place that
   decodes a stored or queued Operation—persistence, query, the legacy executor, and Completion
   readback—must accept exactly the retained 86,400-second form and the new 2,592,000-second form;
   the later seat executor and operator tooling must call that same retained validator.
   It must still validate all identity, state, hash, result/absence, and timestamp relationships;
   “dual form” is not permission for an arbitrary positive TTL. Writers remain at 24 hours in this
   read-first increment, so rolling it back cannot strand a new form.
3. **Switch all Operation writers to 30 days and land the TTL-only migrator.** Intake creates and
   every successful Completion write `expires_at = last_updated + 2,592,000`, for both `echo` and
   future seat work. Add a bounded, cursor-based tool that strongly rereads each candidate and
   conditionally changes only `expires_at` when the complete snapshot still matches; a loser is
   reread and an asynchronously deleted item is never reconstructed. Include a read-only full-pass
   audit. Once this writer is deployed, no rollback artifact that can write the 24-hour form is
   eligible. Preserve this release and all later releases as the 30-day-writer floor.
4. **Harden shared Completion before a seat message can exist.** Retain the exact legacy result
   decoder and behavior. Add the closed seat result-v1 and `seat-terminal-v1` validators, bounded
   canonical Completion bytes, marker-aware conditional persistence, and exact duplicate
   readback. A seat Completion is accepted only after a strong Operation read proves the stored
   marker and bytes agree; the generic `SUBMITTED -> COMPLETED` worker remains the sole public
   lifecycle writer. Query reads both retained legacy results and strict seat results. No seat
   producer is enabled in this increment.
5. **Install the closed route and transport shell with the route disabled.** Add the retained
   policies and the seat source queue/DLQ and Completion DLQ needed by the deployment decision,
   then give intake two distinct configured queue URLs. Deploy the exact compile-time registry
   `echo -> OperationsQueue` and `seat_reservation_system -> SeatOperationsQueue` together with
   `SEAT_RESERVATION_ROUTE_ENABLED=false`. A known disabled seat request returns bounded `503`
   before persistence, an unknown name remains `400`, and `echo` retains its current destination.
   Both destinations are required and validated at cold start; the new queue has no event-source
   mapping yet. Activate the shared Operation-ID exclusions before persistence. This avoids a
   temporary registry entry with a missing destination and reserves the provisioning family before
   any object in it can be created.

The artifact produced after increment 5 is the **pre-seat compatibility floor**. It includes the
30-day writer, both TTL readers, every retained legacy decoder, strict seat Completion validation,
the exact gated registry, and the global Operation-ID exclusions. Capture it by content digest and
retain it for rollback. A release after this point may roll back to this floor, but never to the
original four-function artifact set or any 24-hour writer.

6. **Land the pure seat accounting kernel.** Implement `srs-packed-v1`, the retained Event
   definition and request-digest encoders, exact account and transfer builders, and checked
   timestamp/expiry calculations behind the strict contracts from increment 1, without a runtime
   caller. Extend the existing TigerBeetle wrapper only with the translated symbolic
   flags/statuses, `AMOUNT_MAX`, result timestamps, and bounded account/transfer lookup operations
   the decided protocols require. Golden tests must reproduce every materialized ID and every
   zero, inherited, flag, code, amount, timeout, and linked-chain field; no numeric C flag or
   result code is copied into business logic.
7. **Add Event/control and reconciliation storage before any accounting call.** Add the retained,
   point-in-time-recovered Event and reconciliation tables without replacing `OperationsTable`.
   Implement the wide counter, creation-request claim, and self-contained Event manifest as one
   exact three-action transaction, plus conditional monotone provisioning checkpoints. Implement
   durable reconciliation cursors and append-only applying-run manifests. A newly claimed Event
   already contains all contract versions, ordered sections, capacities, materialized IDs, and
   both digests; an applying run already contains its exact candidate set, permitted actions, and
   artifact/contract digests. No TigerBeetle request or repair action is reachable yet.
8. **Add the replay-only Event provisioner.** Build one phase-per-invocation provisioning engine
   over the storage and accounting adapters, then add its dedicated Lambda artifact, role, and
   conditional TigerBeetle network attachment. It revalidates the complete manifest before each
   linked account or capacity batch, leaves the checkpoint unchanged on uncertainty, and advances
   only after a complete `created`/exact-`exists` vector. Update build/package validation,
   deployment outputs, helper parameters, and docs in this merge. Its bootstrap remains
   multithread-capable for the TigerBeetle native callback thread while its application control
   flow admits one phase at a time. Extend WireGuard discovery, detach, and published-version
   checks to the provisioner before it is VPC-attached. Deploy it dark with no URL or event source;
   only the operator/reconciliation role may invoke it.
9. **Add conditional reservation evidence writes.** Extend Operation persistence with one-attempt,
   one-readback operations for immutable `reserve-decision-v1` and `seat-terminal-v1`. Conditions
   include the complete Operation identity, owned name, hash, `SUBMITTED` state, absent public
   result, and absent target marker. An exact loser is reusable; a mismatch is quarantine. This
   increment has no TigerBeetle or Completion send after either write and therefore proves the
   durable substrate independently.
10. **Add Reserve execution behind an inert adapter.** Implement complete Operation/Event
    revalidation, one bounded coherent account snapshot, first-fit selection, the pre-effect
    `no_capacity` or exact `transfer_intent` decision write, one exact pending transfer attempt,
    timestamp/expiry preservation, terminal classification, and the pre-publication terminal
    marker. Tests inject uncertainty after every read, conditional write, TigerBeetle submission,
    readback, and Completion send. There is no same-ID fallback, re-selection, or live queue owner.
11. **Add Confirm execution behind the same inert boundary.** Implement the full accepted-Reserve
    proof, immutable pending-transfer lookup, dependency-not-ready wait without consuming the
    Confirm ID, one exact `AMOUNT_MAX` post, distinct result classification, and terminal-marker
    publication. The deterministic Confirm object comes entirely from the immutable Confirm body
    and accepted Reserve proof, so no redundant confirm-decision marker is introduced. The two
    actions now share only the small versioned contracts and bounded execution adapters, not a new
    generic workflow layer.
12. **Add the dedicated seat Lambda and disabled poller.** Wrap the two tested actions in one SQS
    handler with one application execution thread, batch size ten, zero batching window, partial
    batch responses, 256 MiB memory, 15-second timeout, reserved concurrency eight, maximum
    event-source concurrency eight, and the five-second admission guard. Its bootstrap remains
    multithread-capable for the TigerBeetle native callback thread. Add the seat bootstrap/package,
    least-privilege role, conditional VPC attachment, and exactly one disabled mapping to the
    already-created seat queue. Update `build.zig`, both deployment helpers, package inspection,
    outputs, shell mocks, documentation, and WireGuard detach/version enumeration in the same
    merge. The legacy executor and mapping are neither renamed nor shared.
13. **Add operational proof before enabling the poller.** Land the read-only topology and
    authority auditors, bounded reconciliation runner, fixed-cardinality structured logs and
    metrics, applying-run gates, dashboards, and zero-tolerance alarms decided by
    [Define operational verification and reconciliation](12-define-operational-verification-and-reconciliation.md).
    Add deployment-helper change-set inspection, stable physical-ID checks, artifact manifests,
    finite legacy/session-budget parameters, dark/open route controls, and exact drain/quarantine
    commands. Runtime components emit their final metric names in the same merge that creates the
    alarms; the helper refuses a missing alarm, unexpected owner, replacement, unbounded legacy
    concurrency, or incomplete package set.
14. **Replace the dual-form reader only after the old form is unreachable.** This final code
    increment may make 30-day TTL validation strict only after all cutover gates below pass. Keep
    the dual-form 30-day-writer compatibility-floor artifact available; strict code may roll back
    to it, not to a 24-hour writer. Removing any other retained contract implementation waits for
    the last Operation, Event, marker, queue lineage, quarantine record, and rollback artifact that
    references it to pass its separately decided retention horizon.

### Require an explicit TTL cutover watermark

Increment 14 is allowed only when all of the following are recorded against one deployment and
writer watermark:

- every active and rollback-eligible intake and Completion artifact writes 30 days, and no alias,
  version, operator tool, or reconciliation action can write the 24-hour form;
- the conditional migration completes and a subsequent full read-only pass from the start cursor
  finds zero retained old-form DynamoDB items and no conditional loser left unaudited;
- every Operation body enqueued before the 30-day-writer watermark has been drained, expired, or
  explicitly quarantined. Because the standard queue has no per-Operation inventory, the default
  proof waits four full source-retention days plus two visibility windows after the last possible
  old-form writer; an earlier cutover requires an equivalent immutable enqueue inventory. Live
  new-form `echo` traffic need not stop;
- no applying run or DLQ/redrive source can reintroduce an old serialized Operation, and all
  runnable canary and applying/redrive manifests identify only the new form. Any retained old-form
  quarantine is permanently non-runnable and remains readable only by the retained compatibility
  artifact or an offline retained decoder; and
- the legacy `echo`, query, and shared Completion canaries pass with the strict candidate while the
  seat route remains false and the seat poller remains disabled.

A clean table scan by itself is insufficient because an old-form Operation may still be queued or
in flight and later redelivered. Conversely, waiting by time alone is insufficient if a retained
redrive or old writer can recreate that form.

### Deploy the completed sequence dark, then open by configuration only

Increments 1–5 change shared compatibility behavior and are deployed in order while `echo`, query,
and Completion stay live. Run the TTL migration after increment 3, but keep the dual reader until
the cutover watermark passes. Increments 6–13 may all be deployed dark: the tables, queues, strict
Completion logic, provisioner, seat executor, auditors, alarms, and deployment support are useful
with the public seat gate false and the seat mapping disabled. Controlled provisioning and direct
invocation may create the permanently retained canary described by
[Define deployment migration and rollback](13-define-deployment-migration-and-rollback.md).

After increment 13, exercise that canary first with direct invocation, then briefly through the
mapping. Disable the mapping again for inspection, pass the full preflight and TTL cutover gates,
deploy increment 14, and re-enable the drained seat mapping while the route is still false. Opening
is a final reviewed configuration-only change from `SEAT_RESERVATION_ROUTE_ENABLED=false` to
`true`; it does not deploy a new contract, writer, queue owner, or accounting builder. Existing
logical resource IDs and both Function URL resources remain unchanged throughout.

Before opening, rollback keeps the compatibility floor and may remove only idle seat compute by a
forward change set. After opening, rollback follows the already-decided close-route, stop-poller,
select-compatible-artifact, canary, drain-or-quarantine sequence; it never removes retained data or
reverses TigerBeetle work.

### Persist every replay input before its irreversible boundary

| Boundary | Durable fact that must exist first | Later behavior |
| --- | --- | --- |
| Route enqueue | Immutable Operation name, body, hash, and 30-day expiry | Re-enqueue the same Operation only to the name's one registered owner. |
| Event provisioning | Atomic request claim and complete versioned Event manifest with all materialized IDs and digests | Rebuild only the manifest's current exact linked phase. |
| Reserve transfer | Immutable reserve-v1 body and pinned `reserve-decision-v1` with the chosen section and complete transfer intent | Retry the one transfer; never resnapshot or choose another section. |
| Confirm transfer | Immutable confirm-v1 body plus the complete, durably accepted Reserve proof | Rebuild the one full-post object; never consume the ID before the proof. |
| Completion send | `seat-terminal-v1` with the exact canonical Completion bytes and evidence | Republish stored bytes; never reclassify or resample time. |
| Reconciliation write or send | Append-only applying-run manifest naming the exact candidate, action, versions, and artifact digest | Apply only the listed unchanged action within its fixed bounds. |

This ordering is the compatibility guarantee. No later migration is allowed to infer a missing
section choice, timeout, Event version, identifier, TigerBeetle field, result timestamp, terminal
class, Completion byte sequence, or reconciliation intent from current state.
