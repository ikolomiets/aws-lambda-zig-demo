---
title: Define deployment migration and rollback
status: closed
assignee: codex
labels:
  - wayfinder:grilling
parent: ../map.md
blocked_by:
  - "[Define name-based routing and executor ownership](03-define-name-based-routing-and-executor-ownership.md)"
  - "[Define retry and failure taxonomy](09-define-retry-and-failure-taxonomy.md)"
  - "[Define Operation result contracts](10-define-operation-result-contracts.md)"
  - "[Define scale, batching, and concurrency bounds](11-define-scale-batching-and-concurrency-bounds.md)"
  - "[Define operational verification and reconciliation](12-define-operational-verification-and-reconciliation.md)"
---

## Question

What staged SAM deployment and rollback sequence adds the exact `seat_reservation_system` intake
route, Event control-plane storage and provisioner, dedicated four-day seat queue and fourteen-day
DLQ, and dedicated seat executor without changing or stranding the retained legacy route, queue,
and executor? How should the sequence create and validate resources before opening intake, preserve
already-`SUBMITTED` Operations during code and event-source replacement, distinguish rollback of an
unopened route from draining accepted seat work, and keep the generic query and shared Completion
paths available throughout?

Treat the decided deployment values as fixed: at most 32 sections; 32-KiB manifests and 64-KiB
Event items; ten seat records with zero batching window and partial batch responses; 256 MiB seat
memory; 15-second function timeout and 90-second visibility; seat reserved and event-source
concurrency eight; seat `maxReceiveCount = 12`; four-day source retention; fourteen-day DLQs;
1,024-byte seat Completions and 10,913-byte aggregate messages; and shared Completion batch size
one, concurrency 16, 15-second timeout, 90-second visibility, `maxReceiveCount = 8`, and its own
fourteen-day DLQ. Which preflight gates must prove the live TigerBeetle client-session budget,
queue/function bindings, least-privilege IAM, route registry, DynamoDB item and conditional-write
behavior, alarms, and drain capacity before traffic opens? Which exact disable-route, stop-poller,
drain/redrive, artifact rollback, and data-retention order is safe after traffic opens, given that
immutable Event manifests, Operation bodies and decisions, consumed transfer IDs, and accepted
TigerBeetle transfers may never be rewritten or rolled back?

Treat the operational-verification decision as a deployment contract. The staged plan must install
the read-only topology and authority auditors, bounded reconciliation runner, fixed-cardinality
metrics, zero-tolerance integrity/DLQ alarms, and retained-version result validators before opening
the route. It must decide and migrate an Operation/hidden-marker retention horizon longer than the
four-day source queue plus fourteen-day DLQ/redrive and rollback-drain horizon; the current 24-hour
Operation TTL is not admissible. Preflight must produce a clean redacted topology digest, clean
counter/claim/Event and result-marker audit, exact queue/owner/IAM proof, a live TigerBeetle session
budget including one reserved operator/auditor session, and maximum-size/fault-injected load proof
that Completion drain exceeds terminal production.

After traffic opens, rollback must keep every retained control/accounting/identifier and result
validator needed by existing Events and Operations, and must keep topology drift detection,
reconciliation, alarms, queues, DLQs, Event data, Operation decisions/markers, and the responsible
provisioner/executor available until all accepted work is completed or explicitly quarantined.
Specify where durable reconciliation cursors and applying-run manifests live, how unchanged
Operation enqueue, pending-phase replay, exact Completion republish, and low-rate DLQ redrive are
enabled and stopped, and how a canary or rollback proves no ID, manifest, intent, marker, transfer,
or completed result was rewritten.

## Resolution

[The TigerBeetle accounting research](../../../docs/research/seat-reservation-tigerbeetle-accounting.md)
sets the irreversible boundary for deployment: account and transfer IDs are cluster-global,
accepted objects are immutable, an uncertain request may have succeeded, and an exact replay is
safe only with the original ID and byte-for-byte-equivalent semantic fields. Deployment rollback
therefore never reverses TigerBeetle work, rewrites an Event manifest or Operation decision, or
returns to a binary that cannot validate retained seat contracts. It closes intake, selects a
previously proved compatible artifact, and drains or explicitly quarantines work through the same
owners.

### Add resources without replacing the legacy path

Keep the physical `OperationsTable`, `OperationsQueue`, `CompletionQueue`, `IntakeFunction`,
`QueryFunction`, `ExecutionFunction`, `CompletionFunction`, both Function URLs, both existing
event-source mappings, and all of their logical identities. A generated CloudFormation
change set must show no `Remove`, `Replacement: True`, or unresolved `Conditional` replacement for
any of those resources. `DeletionPolicy: Retain` and `UpdateReplacePolicy: Retain` are added to the
three existing stateful resources as a last-resort data guard, but they do not make replacement
acceptable: a retained old queue or table would still strand the active stack. CloudFormation
[change sets](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-updating-stacks-changesets.html)
are the mandatory deploy path for every migration phase, and both retain policies remain on all
new stateful resources.

Add these version-1 resources to the same SAM stack:

- `SeatEventsTable`, an on-demand DynamoDB table with one string partition key and no TTL or
  secondary index. It stores the Event-ID counter, durable creation-request claims, and one
  self-contained Event item per allocated ID, so the three-action allocation transaction remains
  atomic. Enable point-in-time recovery and retain the table indefinitely; Event and accounting
  identities do not expire with Operations.
- `SeatReconciliationTable`, an on-demand DynamoDB table with one string partition key, no indexes,
  no TTL, point-in-time recovery, and retain policies. It is the only home for per-auditor durable
  cursors and append-only applying-run manifests. A manifest contains its reason, exact bounded
  candidate set, retained contract and artifact digests, before/after cursor, permitted actions,
  per-action outcome, and stop reason. Neither cursors nor run manifests are stored on an Event or
  Operation.
- `SeatOperationsQueue` with a 90-second visibility timeout, four-day (`345600`) retention,
  `maxReceiveCount = 12`, and `SeatOperationsDeadLetterQueue`; and
  `CompletionDeadLetterQueue` attached in place to `CompletionQueue` with
  `maxReceiveCount = 8`. Set the shared Completion queue's retention explicitly to four days.
  Both DLQs retain for fourteen days (`1209600`) and use `byQueue` redrive-allow policies naming
  only their source. The legacy `OperationsQueue` stays a four-day standard queue with its current
  mapping and no newly inferred seat behavior. For standard queues, the DLQ retains the original
  enqueue timestamp, while an explicit redrive assigns a new message ID and enqueue time; the
  operational retention budget accounts for both behaviors. [AWS SQS retention](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/setting-up-dead-letter-queue-retention.html),
  [AWS SQS redrive](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-configure-dead-letter-queue-redrive.html)
- `SeatExecutionFunction` and its one `SeatExecutionFunctionSeatQueueMapping`. The function is
  ARM64 `provided.al2023`, 256 MiB, 15 seconds, reserved concurrency eight, and uses the same
  conditional VPC/subnet/security-group path to TigerBeetle as the legacy executor. Its mapping is
  created disabled, then uses batch size ten, zero batching window, `ReportBatchItemFailures`, and
  maximum concurrency eight. Disabling the mapping pauses polling without deleting the queue or
  changing its position. [AWS SAM SQS event source](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/sam-property-function-sqs.html)
- `SeatEventProvisionerFunction`, with no Function URL or event source, one-phase-per-invocation
  behavior, 256 MiB, a 15-second timeout, reserved concurrency one, and the same conditional
  TigerBeetle network path. Only the operator/reconciliation role may invoke it. An uncertain
  invocation leaves the durable phase unchanged and the next invocation replays that phase.
- The fixed-cardinality metrics, logs, dashboards, and alarms from
  [Define operational verification and reconciliation](12-define-operational-verification-and-reconciliation.md).
  Topology/integrity, any DLQ arrival, timeout, allocation-bound, and session-exhaustion alarms are
  zero-tolerance; queue-age, partial-failure, throttle, and Completion production-minus-drain
  alarms use the already-decided thresholds.

The intake environment contains distinct legacy and seat queue URLs and
`SEAT_RESERVATION_ROUTE_ENABLED=false`. The compile-time registry still knows exactly `echo` and
`seat_reservation_system`; the flag is an acceptance gate on the known seat entry, not another
route registry. While false, a seat request returns a bounded `503 Service Unavailable` before
persistence or enqueue. Unknown names remain `400`, and `echo` remains open. Reconciliation may
still enqueue an already-accepted exact seat Operation while this public gate is false.

Use table- and queue-scoped roles:

- intake may `PutItem` only in `OperationsTable` and send only to the legacy and seat queues;
- query may only read `OperationsTable`;
- the legacy executor retains polling rights only for `OperationsQueue` and send rights only for
  `CompletionQueue`;
- the seat executor may poll only `SeatOperationsQueue`, read Operations and Events, conditionally
  write only Operation decision/terminal attributes, send only to `CompletionQueue`, and contact
  TigerBeetle;
- the provisioner may transact/read/update only `SeatEventsTable` and contact TigerBeetle; it has
  no Operation, source-queue, or Completion permission;
- Completion may poll only `CompletionQueue` and read/update only `OperationsTable`; and
- the operator reconciliation role may read Operations and Events, write only its cursor/run
  records, invoke only the provisioner, send unchanged bodies only to the seat or Completion
  queue, and receive/delete only from the matching DLQ during an approved bounded redrive. It has
  no `PurgeQueue`, Event mutation, Operation mutation, or direct TigerBeetle mutation permission
  outside the audited read client.

The shared execution security group can serve the legacy executor, seat executor, and provisioner,
but each VPC-attached role needs the retained ENI-management policy. The WireGuard detach helper
must enumerate all three functions and every published version, then require every VPC
configuration and every Lambda ENI on that group to disappear before removing the EIGW, IPv6
route, group, or ENI permissions. A route rollback does not disable the gateway while accepted
seat work still needs TigerBeetle.

### Migrate compatibility and retention before opening intake

Set `operation_retention_seconds = 2592000` (30 days) for every newly created Operation and every
successful `SUBMITTED -> COMPLETED` transition, regardless of route. The terminal marker is an
attribute of the Operation and shares that expiry. Thirty days exceeds the conservative
version-1 recovery budget of four source-queue days, fourteen DLQ/redrive days, and a seven-day
rollback drain/quarantine window. A message lineage receives at most one approved DLQ redrive; if
it fails again, it is explicitly quarantined rather than granted another retention reset.

Migrate existing items in three steps:

1. Deploy a compatibility reader/writer while the seat gate is false. It reads both the old
   24-hour TTL form and the new 30-day form, but all creates and Completions write 30 days.
2. Scan the extant table in bounded pages and conditionally change only `expires_at` to
   `last_updated + 2592000` when the complete identity, state, hash, result/absence, prior
   `expires_at`, and any hidden marker still match the read snapshot. Do not change
   `last_updated`, body, result, decision, or marker. A conditional loser is reread, never
   overwritten. This one-time TTL-only migration is the explicit exception to ordinary completed
   item immutability.
3. Repeat a read-only full pass until it finds no retained old-form item, then deploy strict
   new-form validation. Any item already removed by asynchronous TTL cannot be recreated from an
   inferred queue record; that is a preflight integrity failure requiring quarantine or operator
   recovery before opening the seat route.

The current generic Completion behavior is replaced in the compatibility release before a seat
message can exist. It continues to accept the retained legacy result contract, but requires exact
`seat-terminal-v1` agreement and duplicate readback for a seat result. Query remains backward
compatible with retained legacy and seat result versions. Validators and reconstructors for every
contract version referenced by a retained Operation or Event are part of the compatibility floor
and cannot be removed by an artifact rollback.

### Roll out in seven gated phases

1. **Capture and package.** Record a redacted baseline topology digest, physical-resource IDs,
   queue counts/ages, stack parameters, artifact/configuration digests, and the current
   TigerBeetle client-session limit. Store the template and every Lambda/CLI artifact under an
   immutable content-addressed release manifest for at least 90 days. The manifest names both the
   pre-seat compatibility floor and the proposed release; rollback consumes these stored bytes
   and never rebuilds from a moving branch.
2. **Install the compatibility floor.** In place, add retain policies, 30-day writers and dual-form
   readers, the strict seat Completion/result validators, gate-aware intake, topology/audit
   commands, metrics, and alarms. Keep the seat route false and seat mapping absent or disabled.
   Preserve the existing Function URLs and keep the legacy and Completion mappings enabled.
3. **Finish data migration.** Run the TTL migration and the clean counter/claim/Event,
   Operation/result/marker, and stranded-Operation audits. Safely re-enqueue only unchanged stale
   legacy Operations or republish an exact existing Completion; do not use this phase to create
   seat traffic.
4. **Create the dark seat path.** Add the two control tables, seat queue/DLQ, Completion DLQ,
   provisioner, disabled seat mapping, roles, and alarms. Deploy the seat executor and provisioner
   artifacts but keep public intake closed. Verify that the change set only adds resources or
   performs permitted in-place changes.
5. **Exercise a retained canary.** Allocate one real canary Event through the provisioner, keeping
   its manifest and TigerBeetle objects permanently attributable. With intake still closed,
   direct-invoke the seat executor and then enable the mapping to send one reserve and one confirm
   through the actual seat and shared Completion queues. Replay each accepted intent under the
   same IDs and inject termination after every external boundary. Compare before/after digests for
   the counter claim, Event, Operation body/hash, decisions, terminal marker, transfer fields and
   timestamps, and completed result. Only the allowed monotone provisioning/lifecycle transitions
   may differ; no ID or immutable bytes may change and no extra transfer may appear.
6. **Pass preflight.** Complete every gate below with the route false and the seat mapping enabled
   but its canary backlog drained. Preserve the signed/redacted evidence in the release and
   reconciliation tables.
7. **Open once.** Change only `SEAT_RESERVATION_ROUTE_ENABLED` to true through a reviewed change
   set, wait for the new intake configuration digest, submit an authenticated end-to-end canary
   through the existing Function URL, and rerun topology/result checks. A failure immediately
   executes the post-open rollback below; success leaves both exact routes open.

At no phase is the legacy mapping disabled or pointed at a different queue. Old queued `echo`
records retain their decoder and sole executor; newly persisted `echo` records keep the same
destination. SQS buffers during compatible Lambda code/configuration updates, and shared
Completion remains enabled throughout. A stale `SUBMITTED` record is recovered only by a strong
read and duplicate enqueue to its already-decided owner.

### Require explicit preflight evidence

The route cannot open until one bounded preflight bundle proves all of the following:

- **Change safety:** no replacement/removal of any retained table, queue, Function URL, or legacy
  mapping; stable physical IDs; all stateful resources have retain policies; and both the proposed
  and compatibility-floor artifact manifests are fetchable and digest-exact.
- **Topology and ownership:** the redacted topology command reports exactly the two closed routes,
  distinct queue bindings, one enabled owner per source queue, only the generic Completion owner,
  exact function/mapping timeout, visibility, retention, batch, partial-response, memory, reserved
  concurrency, and maximum-concurrency values, plus no unexpected mapping or queue policy.
- **Least privilege:** IAM policy simulation and negative probes establish the permissions above,
  including denial of cross-queue receive/delete, Event writes by seat execution, Operation writes
  by provisioning/reconciliation, and every runtime `PurgeQueue` attempt.
- **Data and conditionals:** the TTL audit is clean; the Event counter is in
  `1000...4294967296`; every request claim/Event triple, definition digest, materialized ID,
  provisioning checkpoint, Operation hash, result, and hidden marker is exact; maximum 32-KiB
  manifests, 64-KiB Events, 32-KiB Operations, one-attempt/one-readback conditional conflicts, and
  transaction cancellation/replay behave as specified.
- **TigerBeetle sessions:** read the live cluster limit `C`, configure and measure a finite legacy
  executor cap `L`, and prove `8 seat + L legacy + 1 provisioner + 1 test + 1 reserved
  operator/auditor <= C`. The reserved operator/auditor slot is unavailable to normal traffic.
  Any unbounded legacy concurrency or observed session eviction fails the gate.
- **Alarms:** all required alarms exist with actions, dimensions, and missing-data behavior
  validated; production alarms are clear; a separate synthetic namespace proves notification
  wiring; topology/integrity and any-DLQ conditions cannot be hidden by aggregation.
- **Maximum and fault load:** the decided 30-minute duplicate-heavy suite stays within all item,
  request, memory, concurrency, and five-second admission bounds, produces no oversell, timeout,
  incomplete vector, drift, or session loss, and drains all non-quarantined backlog within ten
  minutes. During the last 15 minutes age does not grow for five consecutive samples and measured
  Completion drain is at least 125 percent of seat terminal production plus measured legacy peak.

`L` and `C` are recorded deployment observations, not new protocol constants. The template and
deploy helper require a finite chosen `L`; a missing value fails closed rather than relying on the
account's unreserved Lambda pool. Maximum concurrency must not exceed its function's reserved
concurrency. [AWS Lambda SQS scaling](https://docs.aws.amazon.com/lambda/latest/dg/services-sqs-scaling.html)

### Roll back differently before and after opening

Before phase 7, rollback is an **unopened-route rollback**. Keep the seat gate false, disable the
seat mapping, wait for `Disabled` and zero in-flight seat invocations, and drain the known canary's
exact Completion. If audits prove there is no non-canary seat Operation and both seat queues are
empty, a forward change set may remove idle seat compute, its mapping, and runtime roles. Retain
the tables, queues, canary Operations, Event manifest, run evidence, and all TigerBeetle objects;
never reuse their IDs. The compatibility floor, legacy path, query, and Completion stay deployed.

After phase 7, rollback is a **route closure and recovery run**, never a return to the original
four-function template:

1. Set the seat acceptance gate false first. Wait for and record the new intake configuration
   digest, then prove authenticated seat requests fail before persistence while `echo` and query
   still work. Record the closure watermark and freeze all applying reconciliation/redrive runs;
   read-only audits and alarms continue.
2. Disable the seat event-source mapping and wait for `Disabled` plus zero current invocations.
   Do not disable the shared Completion mapping. This creates a stable source-queue cut before any
   code switch. If the current executor is already the proved safe artifact and only intake is at
   fault, this stop may be brief, but the same watermark/audit is still required.
3. Strongly audit accepted seat Operations, queued bodies, decisions, terminal markers, Events,
   and known TigerBeetle objects. Choose the newest retained artifact whose validators cover every
   observed contract version and whose request builders reproduce every pinned intent. If none
   exists, keep polling stopped and quarantine for operator recovery; never deploy a legacy-only
   executor or Completion binary.
4. Redeploy only the selected compatible function artifacts/configuration with stateful logical
   IDs unchanged and the seat gate false. Direct-invoke the retained canary and require exact
   `exists`/duplicate behavior and byte-equal state before re-enabling the seat mapping.
5. Re-enable the mapping solely to drain accepted work. Enable one applying-run manifest at a
   time. It may enqueue an unchanged strongly reread `SUBMITTED` Operation, invoke one unchanged
   pending provisioning phase, republish stored canonical Completion bytes, or move at most 100
   unchanged matching DLQ bodies at two messages per second. Stop automatically on queue-age
   growth, throttling, partial failures, any integrity alarm, a candidate-set mismatch, or drain
   falling below measured production. Never reselect a section, change a timeout, reset an ID,
   synthesize a result, compensate, void, purge, or edit a manifest/decision/marker.
6. Finish within seven days of the closure watermark. A lineage gets one approved DLQ redrive; a
   second DLQ arrival, an unrepairable identity/integrity failure, or work that cannot safely drain
   is recorded as explicitly quarantined with its unchanged body, reason, authoritative evidence,
   and responsible owner. The Operation remains `SUBMITTED` unless an exact pinned Completion
   exists; quarantine does not manufacture a public terminal result.
7. Stop the seat poller again only when every Operation accepted before the watermark is either an
   exact `COMPLETED` item or appears in an immutable quarantine manifest, there is no unrepublished
   terminal marker, seat visible/in-flight/delayed counts are zero for at least two visibility
   windows, and per-route terminal production equals Completion drain. Shared Completion and query
   remain available for retained and quarantined records.

Finally, retain seat and Completion queues/DLQs, both control tables, all validators, artifacts,
alarms, topology checks, and the responsible provisioner/executor until the last accepted
Operation has completed or been quarantined and the latest applicable 30-day Operation expiry and
90-day deployment/run-evidence retention have both passed. Events, their creation claims, allocated
IDs, and TigerBeetle accounts/transfers are retained indefinitely. Only a later explicit
decommission plan may remove dormant compute or transport resources; deletion, queue purge,
compensating transfers, Event reuse, and data rewriting are not rollback operations.
