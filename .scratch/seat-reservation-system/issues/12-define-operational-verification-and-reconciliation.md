---
title: Define operational verification and reconciliation
status: closed
assignee: codex
labels:
  - wayfinder:grilling
parent: ../map.md
blocked_by:
  - "[Define the Event control-plane contract](02-define-event-control-plane-contract.md)"
  - "[Define name-based routing and executor ownership](03-define-name-based-routing-and-executor-ownership.md)"
  - "[Define atomic and replay-safe Event provisioning](05-define-atomic-event-provisioning.md)"
  - "[Define retry and failure taxonomy](09-define-retry-and-failure-taxonomy.md)"
  - "[Define Operation result contracts](10-define-operation-result-contracts.md)"
  - "[Define scale, batching, and concurrency bounds](11-define-scale-batching-and-concurrency-bounds.md)"
---

## Question

Which invariants, logs, metrics, operator queries, and bounded reconciliation procedures must verify
the closed intake route registry and deployed queue bindings, single-name executor ownership,
per-route queue age/redrive and completion backlog, and submitted Operations stranded between
persistence and enqueue? How should the same controls verify the exhaustion-safe Event ID counter;
one-to-one agreement among each durable creation-request claim, request-definition digest, and
atomically created self-contained Event manifest; immutable definition-digest and manifest
completeness; exact `srs-packed-v1` rederivation and canonical encoding of every materialized
provisioning ID; exclusion of the reserved family from Operation-derived TigerBeetle IDs; legal
monotone provisioning-state transitions and immutable first-failure diagnostics; exact agreement
of every `ready` Event with its linked TigerBeetle account chain and one linked initial-capacity
transfer chain; and traceability from reservation outcomes to Operations? How should it verify that
each persisted `reserve-decision-v1` value belongs to a still-matching Operation hash and Event
definition, that a transfer intent exactly matches any TigerBeetle transfer under the Reserve
Operation ID, and that a no-capacity decision produced no such transfer, without treating either
marker as reservation authority? How should it validate the closed result-v1 field sets and
1,024-byte bound, and prove that both `accepted` and `accepted_but_late` carry the exact Event,
section, quantity, timeout, Reserve/pending ID, original transfer timestamp, and checked expiry that
agree with the hidden intent and TigerBeetle transfer? For every Confirm, how should it verify that
the strict reference, either accepted Reserve proof, transfer-intent decision, ready Event
manifest, and immutable pending transfer agree before checking that the distinct Confirm
Operation/post ID names the exact full-post resolver with its original post timestamp or a
classified terminal non-post outcome? How should it surface different-ID resolvers, unexpected
voids, authoritative expiry, and a consumed-but-cause-unknown Confirm ID without inferring
liveness from the original pending record? How can reconciliation resume an unchanged pending
phase after uncertainty, quarantine a corrupt or occupied counter candidate rather than skipping
it, distinguish immutable transfer existence from live-hold status, tolerate delayed expiry
cleanup, and never treat DynamoDB as the reservation system of record?

Treat the terminal/retry/quarantine boundary as fixed. Define verification for exact
`seat-terminal-v1` agreement with the public completed result; exact duplicate Completion
readback; the 900-second Confirm dependency timeout; seat and Completion DLQ arrivals, retention,
and low-rate redrive; cross-name and untrusted-identity quarantine; and alerts for
`reserve_proof_mismatch`, `pending_transfer_missing_preflight`,
`pending_transfer_not_found_after_preflight`, `unexpected_void`, `transfer_id_failed_unknown`,
`transfer_intent_conflict`, `accounting_drift`, and contradictory terminal markers. The runbook
may redrive an unchanged record only after its dependency or routing fault is corrected; it must
never edit a pinned intent, synthesize a Completion from uncertainty, reset a consumed ID, or make
reservation execution repair a non-`ready` Event. It must also tell readers to stop presenting an
initially accepted Reserve as live at its absolute deadline without rewriting the immutable result,
and to let a later successful Confirm override that presentation even when the Reserve was
`accepted_but_late`.

Treat the settled scale envelope as fixed verification input. Reject or quarantine Events outside
`1...32` sections, manifests above 32 KiB, or complete Event items above 64 KiB; verify the exact
34-account, 32-transfer, and 33-account per-Event request ceilings. Verify that seat invocations
use at most 10 source records, 330 account lookups, 10 transfer lookups, 10 transfer creates, one
thread, 4 MiB of owned scratch memory, 256 MiB Lambda memory, 15-second timeout, 90-second
visibility, concurrency eight, and `maxReceiveCount = 12`. Also verify the five-second request
admission guard, the per-delivery one-attempt/one-readback rule for each conditional marker, the
4-KiB terminal-marker and 32-KiB Operation-item bounds, exact 10,913-byte maximum aggregate
Completion encoding, shared Completion concurrency 16, and the live TigerBeetle client-session
budget. Define load-test gates and alerts for any batch overflow, incomplete result vector,
allocation-bound failure, Lambda timeout, session eviction, throttle, terminal-production/drain
imbalance, or queue-age growth before an operator may raise a concurrency or size limit.

## Resolution

[The TigerBeetle accounting research](../../../docs/research/seat-reservation-tigerbeetle-accounting.md)
sets the reconciliation boundary. TigerBeetle accounts, balances, immutable transfers, and
transfer results are authoritative for capacity and reservation facts. DynamoDB is authoritative
for Operation identity and lifecycle, Event definitions and provisioning checkpoints, and the
immutable decisions and terminal evidence that make exact retries possible. SQS is transport, not
a work ledger. Reconciliation may compare those authorities and re-present an unchanged intent to
its existing owner; it may not manufacture a reservation fact, infer current hold liveness from an
immutable pending transfer, or repair disagreement by editing either side.

### Make every verifier produce bounded, correlatable evidence

Use one versioned structured-log envelope for intake, Event provisioning, seat execution,
Completion, topology checks, and reconciliation. It contains `event = "srs-operational-v1"`, the
component, deployed artifact/configuration digest, route, action and phase when known, disposition,
attempt and result counts, remaining-invocation-time bucket, and only the applicable correlation
keys: canonical Operation ID, Event ID, provisioning request ID, SQS message ID, section ordinal,
and symbolic plus numeric TigerBeetle result. Record before/after durable states and whether a
readback was exact. Do not log PASETOs, AWS credentials, tenant values, complete Operation bodies,
complete manifests, Completion JSON, queue URLs, or raw exception payloads. Bound every diagnostic
string and cardinality-bearing value; identifiers belong in logs, never metric dimensions.

Emit metrics with only fixed dimensions such as component, route, action, phase, disposition, and
stable result class. The required counters and gauges are:

- accepted/rejected intake by exact route, persisted-before-send successes, enqueue failures, and
  stale `SUBMITTED` candidates found or safely re-enqueued;
- per-route received, acknowledged, partial-failure, duplicate, retry-only, quarantine, and
  terminal-production counts, plus native visible/in-flight depth and oldest-message age for each
  source queue, the shared Completion queue, and every DLQ;
- provisioning claims, state transitions, exact replays, manifest/identifier failures, concrete
  TigerBeetle failures, and the age of the oldest Event in each nonterminal state;
- TigerBeetle request type, event count, latency, accepted/exact-`exists`/rejected/uncertain class,
  incomplete-result-vector count, live client sessions, and session acquisition or eviction;
- reserve decisions and terminal classes, Confirm dependency waits and terminal classes,
  conditional-marker attempts/readbacks/conflicts, Completion publish/complete/duplicate counts,
  and current terminal-production minus Completion-drain backlog; and
- invocation duration, timeout, throttle, owned scratch-memory high-water mark, allocation failure,
  and admission-guard deferral.

Alarm on the first integrity or topology occurrence in a five-minute period; aggregation must not
hide a single event. This includes route/binding drift, cross-name or untrusted-identity
quarantine, contradictory markers or completed results, manifest/digest/identifier drift,
`reserve_proof_mismatch`, `pending_transfer_missing_preflight`,
`pending_transfer_not_found_after_preflight`, `unexpected_void`,
`transfer_id_failed_unknown`, `transfer_intent_conflict`, `accounting_drift`, and an incomplete or
misassociated TigerBeetle result vector. Also alarm on any DLQ arrival, any Lambda timeout or
allocation-bound failure, session exhaustion/eviction, sustained throttle or partial-failure rate,
queue age approaching an Operation's configured retention horizon, a Confirm wait reaching 900
seconds, and sustained terminal-production greater than Completion drain. Warning thresholds for
throughput come from a measured healthy baseline. Initially warn when either source queue's oldest
message reaches 180 seconds and page at 900 seconds; warn when the Completion queue reaches 90
seconds and page at 450 seconds; and page when any queue reaches 75 percent of the shortest
retention horizon of the message and its durable Operation. The zero-tolerance integrity, DLQ,
timeout, and bound alarms are fixed. The Completion worker emits a drained count only after the
stored Operation and marker match, using the Operation's closed route name as a fixed dimension,
so per-route production-minus-drain is not inferred from queue depth.

### Verify the route and queue topology before accepting traffic

One read-only topology command loads the retained compile-time route registry and the deployed SAM
stack, resolves configured queue URLs to ARNs, and fails unless all of these statements are true:

- the registry is closed and contains exactly one binding for `echo` and one for
  `seat_reservation_system`, with no duplicate, catch-all, prefix, or empty destination;
- intake's environment binds each registry entry to that entry's expected queue and its role may
  send only to the bound queues;
- each source queue has exactly one enabled event-source mapping and exactly one executor owner;
  the legacy executor owns only `echo`, the seat executor owns only
  `seat_reservation_system`, and neither can receive/delete from the other's queue;
- both executors can send only to the shared Completion queue, whose sole enabled consumer is the
  generic Completion function; and
- the deployed queue, mapping, function, DLQ, redrive-allow, IAM, concurrency, memory, timeout,
  visibility, retention, batch-size, batching-window, and partial-batch-response values exactly
  match the versioned deployment contract.

The command prints and logs a redacted topology digest and an exact diff, exits nonzero on any
unknown resource or extra owner, and performs no repair. Intake performs the subset available at
cold start—closed registry, nonempty distinct queue destinations, and route/config digest—and
refuses to accept work on a configuration failure. Run the full command before opening the route,
after every deployment, and periodically as drift detection.

### Find stranded Operations without treating SQS as a database

A `SUBMITTED` row does not prove that a matching SQS message exists, and SQS cannot answer a
message-by-Operation-ID query. The bounded repair is therefore safe duplicate enqueue, not queue
inspection. A reconciliation pass scans the Operation table in pages with an explicit item/RCU
limit and durable `LastEvaluatedKey` cursor, projecting only identity, name, hash, body, state,
timestamps, decisions, and terminal marker. The scan is not a snapshot: before any action, strongly
reread the candidate and require an exact, structurally valid, still-`SUBMITTED` Operation.

Operational contract version 1 uses a 180-second enqueue grace, a DynamoDB scan `Limit` of 100,
at most ten pages or 1,000 evaluated items, and at most five minutes per read-only run. The cursor
makes repeated runs eventually cover the table without raising those limits.

For a stale candidate older than the configured enqueue-grace interval:

- an exact supported name is reserialized using the retained Operation contract and sent once to
  that route's one queue; a concurrent Completion makes the resulting duplicate harmless;
- an unsupported name, malformed identity, mismatched hash, or contradictory marker is reported
  and quarantined, never guessed or forwarded; and
- an exact `seat-terminal-v1` candidate is sent only as its already-stored Completion bytes to the
  Completion queue, not back through reservation execution.

Each applying run acts on at most 100 candidates at two sends per second for at most ten minutes,
records a run manifest and next cursor, and visits a candidate at most once per full pass. It never
refreshes `last_updated` or TTL, writes an "enqueued" claim, or declares SQS delivery proven. The
retention horizon for `SUBMITTED` Operations and hidden markers must exceed the maximum source-queue,
DLQ/redrive, and rollback-drain horizon; the current 24-hour Operation TTL is incompatible with a
four-day source queue and fourteen-day DLQ and must be migrated before the seat route opens.

### Reconcile Event allocation and provisioning from the durable claim outward

Audit the counter and Event control plane in cursor-bounded, strongly reread pages. Require the
wide `next_event_id` to be an integer in `1000...4294967296`; `4294967296` is the exhausted
sentinel. Every allocated value below it must participate in exactly one atomic triple: one
request claim, one matching `request_definition_digest`, and one self-contained Event item with
the same Event ID. Recompute the request digest from the retained versioned creation-intent
encoding and the Event definition, and reject duplicate request IDs, mismatched Event IDs, missing
partners, holes, or extra Event items. If the current candidate Event ID is already occupied
without its matching claim, quarantine the candidate and stop allocation; never increment past it.

For every Event, independently enforce `1...32` sections, a manifest at most 32 KiB, a complete
item at most 64 KiB, canonical order and positive capacities, supported retained versions, an
exact definition digest, canonical lowercase 32-digit IDs, and exact `srs-packed-v1` rederivation.
Also require every Operation-derived TigerBeetle ID in retained legacy, Reserve, and Confirm data
to be nonzero, non-max, and outside the high-24-bit `0x535253` family. Provisioning state must be
exactly one of `accounts_pending`, `capacity_pending`, `ready`, or `failed`; every emitted
transition record must show only the two forward edges to `ready` or a pending-state-to-`failed`
edge, and the first failure diagnostic is immutable and complete.

For a locally valid pending Event, reconciliation invokes the dedicated provisioner once for the
unchanged current phase. The provisioner revalidates the item, reconstructs the one account chain
of at most 34 events or capacity chain of at most 32 events, and relies on `created` or exact
`exists` before its conditional checkpoint. Unknown results leave the phase unchanged. A manifest
failure, occupied object, consumed ID, or concrete incompatible result follows the already-defined
terminal failure transition; the auditor never edits the manifest, advances the checkpoint, skips
an Event ID, or submits a replacement object.

For `ready`, perform a read-only TigerBeetle comparison in bounded Event batches. Lookup exactly
the Event's 2 singleton plus section accounts and all initial-capacity transfers, associate every
reply by ID, and require the retained role, ledger, code, flags, zero fields, endpoints, amount,
and linked-chain shape. Seat Supply posted debits and each Section's posted credits must equal the
immutable capacity grant; each Section must satisfy
`debits_posted + debits_pending <= credits_posted`; and the sum of all Section pending and posted
debits must respectively equal the Seats Reserved pending and posted credits. All other Supply,
Section-credit, and Seats-Reserved-debit counters must remain zero. Delayed expiry cleanup may
leave an expired quantity in both pending totals and is not drift. A missing,
duplicate, unexpected, or mismatched object makes the Event nonconforming and pages an operator,
but does not demote `ready` or authorize a compensating transfer.

One run audits at most ten Events, with no more than 340 account IDs and 320 initial-capacity
transfer IDs across its lookup requests. Operation reconciliation audits at most 100 Reserve or
Confirm transfer IDs per run. The runner owns one of the explicitly budgeted operator sessions,
issues only one TigerBeetle request at a time, and persists its cursor before releasing that
session.

### Reconcile Reserve facts without promoting DynamoDB to reservation authority

For each seat Reserve, revalidate the Operation ID/name/hash/body and the still-matching retained
Event definition before interpreting either hidden marker. `reserve-decision-v1` must be absent or
exactly one immutable tagged value no larger than 1 KiB:

- `no_capacity` must match the Operation's Event and definition digest. One lookup by the Reserve
  Operation ID must currently return no transfer. Any transfer is a critical contradiction. The
  absence verifies that the pinned decision has not created a transfer; it is not an availability
  or reservation fact.
- `transfer_intent` must match the Operation hash, Event and definition digest, section identity
  and ordinal, rederived account IDs, quantity, timeout, ledger, code `2`, exact `pending` flag,
  zero fields, and Reserve Operation ID. If a transfer exists under that ID, every immutable field
  and original timestamp must match exactly. If it is absent and the Operation has no terminal
  marker, the only repair is to re-enqueue the unchanged Operation so its owner can retry that
  pinned intent. Never reselect a section.

An accepted or `accepted_but_late` terminal result requires an exact immutable pending transfer and
the same Event, section, quantity, timeout, Reserve/pending ID, original transfer timestamp, and
checked expiry in the intent, terminal marker, and public Completion. A terminal no-capacity,
capacity-race, consumed-ID, conflict, drift, or residual-rejection result must agree with the
pinned decision and its stored evidence; it must never be converted to acceptance from a later
snapshot. An expired deadline does not make an existing pending transfer disappear and its
continuing existence does not prove a live hold.

### Reconcile Confirm facts through the complete accepted-Reserve proof

For every Confirm, require its strict reference and distinct admissible Confirm ID to match the
stored Operation. Re-run the same proof used before submission: the referenced completed Reserve
must be a valid `accepted` or `accepted_but_late` form; its Operation, hash, transfer-intent
decision, ready Event and digest, rederived accounts, and immutable pending transfer must agree
field for field. Only then interpret the Confirm terminal evidence.

A `confirmed` result requires a transfer under the Confirm Operation ID with the exact full-post
shape: distinct ID, Reserve ID as `pending_id`, `AMOUNT_MAX`, exactly `post_pending_transfer`, all
inherited fields zero, and the original post timestamp equal in the marker and Completion. A
pre-submission dependency/reference/proof/preflight failure requires that no Confirm-ID transfer
exists. Exact `exists` remains success by this Confirm ID.

`confirmed_elsewhere`, `unexpected_void`, authoritative `hold_expired`,
`pending_transfer_not_found_after_preflight`, and `transfer_id_failed_unknown` are preserved only
from their pinned, directly observed TigerBeetle result. The immutable pending record does not name
a different post/void resolver or reveal whether it is live, and `id_already_failed` cannot recover
its original cause; reconciliation reports those facts as unknown rather than inventing an ID or
cause. A transfer found under a supposedly unused Confirm ID, a different full-post shape, or any
contradiction between evidence and public result is a critical integrity finding. It is not
repaired by retrying a consumed ID.

### Validate terminal results and Completion delivery byte for byte

Retained strict validators must accept only the closed result-v1 field sets and codes, reject
duplicates and unknown fields, recompute checked timestamps/expiry, and require the complete
canonical Completion to be at most 1,024 UTF-8 bytes. `seat-terminal-v1` is at most 4 KiB, the
whole Operation item at most 32 KiB, and the marker's stored canonical Completion bytes must equal
both its taxonomy evidence and, for `COMPLETED`, the immutable public result byte for byte.

The only safe repairs are:

- a still-`SUBMITTED` Operation with an exact terminal marker republishes those stored bytes to the
  Completion queue; and
- an exact duplicate Completion for an already-`COMPLETED` Operation is acknowledged only after a
  strong read proves exact result equality.

A terminal marker mismatch, different completed result, seat Completion without its marker, or
contradictory terminal evidence is quarantined and alerted. Uncertainty never synthesizes a
Completion. At most ten 1,024-byte entries may be assembled into the exact 10,913-byte aggregate;
publication uncertainty returns every represented source record for retry.

Operational readers apply the absolute Reserve deadline without mutating data. At or after the
deadline they stop presenting an initially `accepted` Reserve as live and show resolution unknown
unless a terminal Confirm is available. They never rewrite it to `accepted_but_late` or
`hold_expired`. A later successful Confirm overrides that conservative presentation even when the
Reserve was `accepted_but_late`.

### Keep every repair and scale change behind explicit gates

Run reconciliation read-only by default. An applying run requires an operator-supplied reason,
records its exact candidate set and retained contract versions, strongly rereads each candidate,
and permits only four rate-limited actions: enqueue an unchanged supported `SUBMITTED` Operation,
invoke one unchanged pending provisioning phase, republish exact stored Completion bytes, or
redrive unchanged DLQ records after the dependency/routing fault is fixed. Seat and Completion DLQ
redrive is capped at 100 messages per approved run and two messages per second, must stay below
measured healthy drain capacity, and stops automatically on renewed
age growth, throttle, partial failures, or any integrity alarm. Never edit an intent or terminal
marker, reset a consumed ID, create a compensating transfer, make reservation execution provision
an Event, purge a queue as repair, or acknowledge a quarantined record merely to clear an alarm.

The following are release and load-test gates for the fixed envelope:

- reject Events outside 1...32 sections or their 32/64-KiB bounds; observe no request above 34
  provisioning accounts, 32 provisioning transfers, 33 accounts per Reserve, 330 accounts/10
  transfers/10 creates per seat invocation, or 10 Completion entries/10,913 encoded bytes;
- observe at most ten source records, one execution thread, 4 MiB owned scratch memory, one
  marker-write attempt plus one readback per marker phase and delivery, and no TigerBeetle request
  admitted with less than five seconds remaining;
- deploy 256 MiB/15-second/90-second seat execution with both concurrency controls at eight and
  `maxReceiveCount = 12`, plus 15-second/90-second shared Completion at batch one, concurrency 16,
  and `maxReceiveCount = 8`;
- prove `8 + legacy + provisioner + test + reserved operator` live client sessions does not exceed
  the actual cluster limit, with at least one reserved operator/auditor session represented; and
- at maximum-size, duplicate-heavy and fault-injected load, observe zero oversell, incomplete
  result vector, bound violation, allocation failure, Lambda timeout, session eviction, unplanned
  throttle, contradictory marker, or growing queue age, and prove Completion drain remains above
  terminal production.

The load gate runs maximum-size traffic for 30 minutes, including duplicate delivery, killed
invocations after each external boundary, conditional-write losers, delayed expiry cleanup, and
TigerBeetle `created`/exact-`exists` recovery. During the final 15 minutes, queue age may not grow
for five consecutive one-minute samples, and measured Completion drain capacity must be at least
125 percent of seat terminal production plus the measured legacy peak. After input stops, all
non-quarantined source and Completion backlog must reach zero within ten minutes without redrive.

No concurrency, batch, item, or memory limit may increase from load results alone. The change must
also update the versioned contract, repeat topology and session-budget checks, rerun the maximum
and fault-injection suite, and pass a canary while all integrity and backlog alarms remain clear.
