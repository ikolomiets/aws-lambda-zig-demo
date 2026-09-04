---
title: Define the end-to-end rollout and rollback test plan
status: closed
assignee: codex
labels:
  - wayfinder:grilling
parent: ../map.md
blocked_by:
  - "[Define deployment migration and rollback](13-define-deployment-migration-and-rollback.md)"
  - "[Define the compatibility-first implementation sequence](14-define-compatibility-first-implementation-sequence.md)"
---

## Question

What exact local, mocked-AWS, live TigerBeetle, SAM change-set, dark-canary, opening-canary, and
post-open rollback tests prove the complete design without mutating or deleting authoritative
facts? Build a phase-aligned matrix that covers old/new TTL compatibility and conditional
backfill, stable legacy physical identities, disabled route behavior before persistence, exact
queue/mapping/IAM ownership, Event allocation and both provisioning phases, Reserve and Confirm
outcomes, terminal-marker and Completion byte equality, retries after every external boundary,
four-day/14-day queue and DLQ behavior, one-redrive and seven-day recovery controls, session-budget
enforcement, WireGuard detach across every VPC-attached function/version, alarms, and the fixed
maximum/fault-load thresholds.

For each case, define setup, injected fault or race, observable evidence, pass/fail threshold,
cleanup or permanent canary-retention rule, and whether it is required before the dark deployment,
before opening, after opening, or before a compatible artifact rollback. The plan must prove that
replaying the retained canary changes only allowed monotone checkpoints/lifecycle state; no Event
ID, manifest, Operation body/hash, decision, terminal marker, transfer intent or timestamp, or
completed result may be rewritten, and no compensating or duplicate TigerBeetle transfer may be
created.

Align the matrix with the independently releasable increments in
[Define the compatibility-first implementation sequence](14-define-compatibility-first-implementation-sequence.md).
Prove the retained-contract fixture baseline; read-first dual-TTL deployment; the 30-day-writer
watermark and ineligibility of every 24-hour-writer rollback artifact; strict shared Completion
before any seat producer; the disabled exact two-entry route with both queue destinations present;
and the inert accounting, storage, provisioning, Reserve, Confirm, and seat-executor increments.
The strict new-only TTL case must prove both a clean conditional table migration and that no
old-form queued, in-flight, delayed, redrive, canary, or applying-run lineage can execute again;
time-based proof must cover four source-retention days plus two visibility windows without stopping
live new-form `echo` traffic. Any retained old-form quarantine must be demonstrably non-runnable
and readable by the retained compatibility artifact. A clean table scan alone is not sufficient.
Require each merge candidate to keep live `echo`, query, Completion, logical resource IDs, and
Function URLs unchanged, and require every new bootstrap, VPC attachment, package, helper, alarm,
and documented deployment behavior to appear with its matching tests.

## Resolution

[The TigerBeetle accounting research](../../../docs/research/seat-reservation-tigerbeetle-accounting.md)
sets the non-negotiable oracle for this plan. A Seat Section's credit balance bounds reservations;
accepted TigerBeetle objects are immutable; `created` and exact `exists` prove the same creation
fact; a supposedly transient result may permanently consume a transfer ID; a Lambda timeout does
not prove non-execution; and an expired pending transfer may remain visible after its deadline.
The vendored client is also a patched build, so mocks cannot replace the live-cluster cases for
`id_already_failed`, `AMOUNT_MAX`, expiry races, linked-chain results, timestamps, or dense result
vectors.

Every test case below produces a versioned evidence record containing its test ID, release and
configuration digests, retained-contract versions, setup identifiers, injected boundary, bounded
observations, and pass/fail result. Replay cases take canonical before/after snapshots of the Event
counter and claim, Event manifest and checkpoint, Operation body/hash/decision/terminal marker and
result, and every involved TigerBeetle account and transfer. They permit only these monotone
changes:

- an absent creation claim and Event may be atomically added under the one newly allocated ID;
- Event provisioning may move `accounts_pending -> capacity_pending -> ready` or make its one
  permitted transition to an immutable `failed` diagnostic;
- an Operation may be added as `SUBMITTED`, acquire its one immutable decision or terminal marker,
  and move once to `COMPLETED` with the marker's exact Completion bytes;
- a migration may conditionally change only an old-form `expires_at` to
  `last_updated + 2592000`; and
- an applying-run record may append its bounded action outcome and advance its cursor as specified.

Any rewritten ID, manifest field, Operation body/hash, decision, terminal marker, transfer field or
timestamp, completed result byte, or previously recorded applying-run fact is a zero-tolerance
failure. An unexpected account or transfer, a different-ID replay, a compensating or void transfer,
and a synthesized terminal result are also failures.

The gate abbreviations in the matrices are: **BD**, before any dark seat artifact is deployed;
**BO**, before public seat intake opens; **AO**, immediately after opening; and **RB**, before a
compatible artifact is selected and allowed to drain during a post-open rollback. A row required
at more than one gate is rerun against the exact candidate artifact at each named gate.

### Align local and mocked-AWS proof with the fourteen increments

| ID | Increment and environment | Setup and injected fault or race | Evidence and exact pass threshold | Cleanup or retention | Gate |
| --- | --- | --- | --- | --- | --- |
| `I01` | Retained fixtures; local | Load byte-exact legacy Operation and Completion fixtures plus Event, reserve-v1, confirm-v1, `reserve-decision-v1`, result-v1, and `seat-terminal-v1` fixtures. Mutate every version, required field, tag, length, duplicate key, canonical integer/UUID form, and one byte of each digest. | Every retained fixture decodes and re-encodes byte-exactly; every unknown version/field, duplicate, over-bound value, or mutated digest is rejected before an adapter call. The existing `echo` fixture bytes and behavior are unchanged. | Fixtures remain versioned with the compatibility-floor artifact. Test state is ephemeral. | BD; rerun BO and RB |
| `I02` | Read-first TTL compatibility; local and mocked DynamoDB | Present exact 86,400-second and 2,592,000-second Operation forms to persistence, query, legacy execution, and Completion readback; also present zero, arbitrary positive, mixed, malformed, and overflow forms. Roll between the candidate and previous reader while writers still emit 24 hours. | All four reader paths accept exactly both retained forms and reject every other form. This increment writes no 30-day item, and rollback strands none. `echo`, query, and legacy Completion fixture results stay exact. | Retain both decoders in the compatibility floor. | BD |
| `I03` | Thirty-day writers and TTL-only migrator; local and mocked DynamoDB | Create and complete both `echo` and seat-shaped fixtures; migrate paged old-form `SUBMITTED` and `COMPLETED` rows. Inject a conditional loser, concurrent Completion, cursor restart, timeout, and asynchronous TTL deletion after the scan read. | Every new create and successful Completion uses `expires_at = last_updated + 2592000`. Migration changes only `expires_at` after a complete-snapshot condition; a loser is reread, a deleted item is never reconstructed, and restart resumes from its durable cursor. A full audit reports zero old form and zero unaudited loser. | Retain migration and audit evidence for 90 days; retain the dual reader and 30-day writer as the rollback floor. | BD; strict audit rerun BO and RB |
| `I04` | Strict shared Completion before a producer; local and mocked DynamoDB/SQS | Feed retained legacy results and every closed seat result at the 1,024-byte limit. Race two duplicate seat Completions; inject send uncertainty, conditional loss, missing marker, marker-byte mismatch, different completed bytes, and DynamoDB failure. | Legacy behavior is byte-identical. A seat Completion advances only a still-`SUBMITTED` Operation whose `seat-terminal-v1` stores those exact bytes; exact completed readback is acknowledged, transient failure retries, and every mismatch quarantines and alarms. No seat source message can yet be produced. | Exact fixture bytes and alarm evidence stay with the release; mock messages are discarded. | BD; rerun BO and RB |
| `I05` | Disabled closed route and transport shell; local and mocked AWS | Configure distinct legacy and seat queue destinations with `SEAT_RESERVATION_ROUTE_ENABLED=false`. Send valid `echo`, valid seat, unknown/case-variant names, missing/equal queue destinations, and IDs equal to zero, max, or in the `0x535253` family. Inject failure after persistence but before enqueue for `echo`. | The registry has exactly `echo` and `seat_reservation_system`. Disabled seat returns bounded `503` before DynamoDB/SQS; unknown name returns `400`; invalid IDs persist nothing; `echo` retains its exact queue and persist-before-send recovery. Missing/equal destinations fail cold start. Both queues exist and the seat queue has no live owner. | Preserve the registry/config digest with the compatibility floor. | BD; disabled-route probe rerun BO and RB |
| `I06` | Pure accounting kernel; local golden/property tests | Generate Events at IDs 1000 and `2^32-1`, every role, section ordinals 0 and 31, maximum bounded capacities, and invalid boundary values. Flip each flag/code/zero/inherited field and linked-chain position; vary retry input, timeout, and `AMOUNT_MAX`. | Golden values reproduce `srs-packed-v1` exactly and never enter zero/max or the Operation-ID namespace. The maximum Event produces exactly 34 accounts and 32 initial-capacity transfers; only nonfinal members are linked. Reserve is one exact pending transfer with stable nonzero timeout; Confirm is one distinct exact post with `AMOUNT_MAX` and inherited fields zero. Checked arithmetic traps overflow as an expected error, not mutation. | Golden fixtures remain with their retained contract implementation. | BO; rerun RB |
| `I07` | Event/control storage; local and mocked DynamoDB | Race matching and mismatching creation requests at counter start, an occupied candidate, and the exhaustion sentinel. Inject transaction cancellation/uncertainty, crash after each action, invalid 32-KiB manifest or 64-KiB Event boundary, and conditional checkpoint conflicts. | Allocation is one exact three-action transaction: counter, claim, complete Event. A matching retry resumes one Event; a digest mismatch conflicts; occupied/corrupt candidates stop rather than skip; `4294967296` allocates nothing. Only complete `1...32`-section Events pass. Checkpoints are conditional and monotone, and the first failure diagnostic is immutable. | Mock tables are ephemeral; canonical transaction/digest vectors remain versioned. | BO; rerun RB |
| `I08` | Replay-only provisioner; local and mocked adapters | Run accounts and capacity phases at 1 and 32 sections. Inject malformed manifest, occupied object, per-index rejection, incomplete/duplicate/misassociated result, client uncertainty, and process death before submission, after submission, and before checkpoint. | No request follows invalid input. Each invocation submits at most one exact linked phase and advances only on a complete `created`/exact-`exists` vector. Uncertainty leaves the checkpoint unchanged; replay uses the same IDs/fields; incompatible facts make the one stable `failed` transition. No second capacity-grant ID is built. | Fixtures stay versioned; live objects are governed by `T01`. | BO; rerun RB |
| `I09` | Immutable decision and terminal evidence; local and mocked DynamoDB | Race duplicate Reserve deliveries at first-fit and duplicate terminal classifications on opposite sides of the derived deadline. Inject a conditional loser or unknown write result for `reserve-decision-v1` and `seat-terminal-v1`, then return exact and conflicting readbacks. | Each delivery performs at most one write attempt and one strong readback per marker phase. An exact marker is reused; disagreement quarantines; uncertainty retries with no Completion. A decision never changes section, timeout, or tag, and terminal bytes are built and stored once. Bounds are 1 KiB decision, 4 KiB marker, 32 KiB Operation, and 1,024 bytes per Completion. | Evidence fixtures remain; mock rows are discarded. | BO; rerun RB |
| `I10` | Reserve action and execution; local and mocked adapters | Cover strict parsing, ordered first-fit, complete-snapshot no-capacity, a concurrent `exceeds_credits`, late `created`/`exists`, `id_already_failed`, every `exists_with_different_*`, account/Event drift, residual rejection, and every ambiguous adapter/result-vector outcome. Kill after each boundary listed below. | Exactly one section is pinned before one transfer; no same-ID fallback or resnapshot occurs. Expected terminal forms are `accepted`, `accepted_but_late`, `event_reference_invalid`, `event_integrity_mismatch`, `no_capacity`, `capacity_race_lost`, `transfer_id_failed_unknown`, `transfer_intent_conflict`, `accounting_drift`, or `tigerbeetle_rejected`. Ambiguity is retry-only and publishes nothing. Accepted results retain the original transfer timestamp and checked expiry; `exists` never asserts current liveness. | Mock state is ephemeral; canonical results remain fixtures. Live transfers follow `T02` and `T03`. | BO; rerun RB |
| `I11` | Confirm action and execution; local and mocked adapters | Cover the 900-second dependency boundary, missing/invalid/nonaccepted Reserve, both accepted Reserve forms, proof mismatch, missing preflight, a post/expiry race, `created`, exact `exists`, another-ID post, unexpected void, post-preflight not-found, `id_already_failed`, conflicts, residual rejection, and ambiguity. | Before the accepted-Reserve proof, no Confirm ID is submitted or consumed. After proof, exactly one deterministic full-post object is used. Expected terminal forms are `confirmed`, `reserve_dependency_timeout`, `reserve_reference_missing`, `reserve_reference_invalid`, `reserve_not_accepted`, `reserve_proof_mismatch`, `pending_transfer_missing_preflight`, `pending_transfer_not_found_after_preflight`, `confirmed_elsewhere`, `hold_expired`, `unexpected_void`, `transfer_id_failed_unknown`, `transfer_intent_conflict`, or `tigerbeetle_rejected`. Only ambiguity retries without Completion. | Mock state is ephemeral; canonical results remain fixtures. Live transfers follow `T04`. | BO; rerun RB |
| `I12` | Seat handler, build/package, and WireGuard lifecycle; local and mocked AWS | Supply 0, 1, 10, and 11 records; mixed successes/failures; 33-account Reserve snapshots and the 330-account batch ceiling; 10 transfer lookups/creates; 10 terminal entries; 4-MiB allocation edge; and 4.999/5.000 seconds remaining. Inspect every bootstrap/package and enumerate the legacy executor, seat executor, provisioner, all aliases/versions, and their ENIs during detach. | At most 10 records run on one application thread; only affected IDs enter `batchItemFailures`; no new blocking request starts below five seconds. Exact maxima are 10,913 aggregate Completion bytes, 4 MiB owned scratch, 256 MiB memory, 15-second timeout, 90-second visibility, batch 10/zero window, reserved and mapping concurrency eight, and `maxReceiveCount=12`. Build/package inspection finds every matching bootstrap. WireGuard teardown refuses while any applicable version or ENI remains. | Build products remain ordinary generated artifacts; test fixtures are ephemeral. | BO; rerun RB |
| `I13` | Operational proof and deploy support; local and mocked AWS/SAM | Feed topology/IAM/change-set/auditor mocks with one drift at a time: missing/extra owner, replacement/removal, wrong queue attribute, wildcard/cross-owner permission, missing package/output/alarm, wrong dimensions/missing-data behavior, incomplete scan, unsafe applying run, or undocumented helper behavior. | The helper fails closed on every drift and passes only exact resources, one owner per queue, the sole Completion owner, least privilege, retained physical IDs, complete packages, matching docs, and configured alarms. Applying runs are append-only, at most 100 candidates, two sends/second, ten minutes, one at a time, and stop on age growth, throttling, partial failure, integrity alarm, candidate mismatch, or insufficient drain. | Store passing manifests and synthetic-alarm evidence for 90 days. | BO; rerun AO and RB |
| `I14` | Strict new-only TTL candidate; local/mocked lineage model plus live gate `A06` | Model queued, in-flight, delayed, source-retained, DLQ, redrive, canary, quarantine, and applying-run old-form lineages while new-form `echo` continues. Attempt execution by strict and compatibility artifacts. | Strict code rejects every old form. No active or rollback-eligible writer emits 24 hours; no runnable source can reintroduce it; retained old-form quarantine is non-runnable and readable by the retained compatibility artifact. A clean table scan alone and elapsed time alone each fail the test. | Keep the dual-reader/30-day-writer artifact and offline decoder for all retained old-form evidence. | BO; rerun RB |

All Zig increments run the repository formatting and build/test checks applicable to their changed
files. Every SAM or helper increment also runs shell syntax, dependency-free mocked deployment
tests, SAM validation, change-set inspection, and package-content checks. A candidate is not
mergeable when a new bootstrap, VPC attachment, package, helper flag, output, alarm, metric, or
documented operator action lacks a test in the same increment.

### Inject failure at every irreversible boundary

The `I03`, `I07` through `I11`, dark-canary, opening-canary, and rollback suites use deterministic
hooks immediately before the effect, after the remote system may have accepted it, and after
readback but before the next durable checkpoint. Each hook kills the process or returns an unknown
result, then redelivers the exact retained input:

| Boundary | Required recovery evidence |
| --- | --- |
| Operation persistence -> route enqueue | The same stored body/hash/30-day expiry is sent only to its closed owner; a duplicate creates no second Operation. |
| Event allocation transaction -> first readback | The matching request claim returns the one Event, or an unclaimed candidate is retried; the counter alone never proves success. |
| Linked account batch -> `capacity_pending` | Exact replay returns a complete exact vector and creates no new account ID. |
| Linked capacity batch -> `ready` | Exact replay creates no extra capacity transfer and never credits a section twice. |
| Account/transfer lookup -> decision/proof | An incomplete, duplicate, missing, or misassociated vector is uncertainty or integrity failure as classified; it is never partial evidence. |
| Reserve decision write -> pending transfer | Exact readback follows the pinned section and fields; absence/uncertainty submits nothing new until safely retried. |
| Pending transfer -> accepted timestamp/terminal marker | Replay uses the same timeout and zero timestamp input; `exists` returns the original timestamp and no fallback section is selected. |
| Confirm proof/preflight -> full post | No post occurs before the complete proof; after proof, replay uses the same Confirm ID, Reserve `pending_id`, `AMOUNT_MAX`, and inherited zeros. |
| Terminal-marker write -> Completion send | Replay publishes the marker's stored canonical bytes without reclassification or a new clock sample. |
| Completion send -> `SUBMITTED -> COMPLETED` | Unknown send returns the source record; exact duplicate readback succeeds and different bytes quarantine. |
| Applying-run manifest -> permitted repair/send | Only the manifest's unchanged candidate set and one allowed action run; restart appends outcomes without widening or rewriting the run. |

An expected process kill is not counted as a Lambda-timeout pass. Any actual Lambda timeout,
allocation-bound failure, incomplete result vector, or session loss fails the release gate.

### Require the live TigerBeetle suite

Run these cases against the exact proposed client artifact and target-cluster version in an
isolated, permanently attributable canary namespace. Negative cases consume real IDs; record them
and never reuse them. Use short nonzero test hold durations chosen in the evidence manifest, but do
not turn those durations into a production default.

| ID | Setup and injected fault or race | Evidence and exact pass threshold | Cleanup or retention | Gate |
| --- | --- | --- | --- | --- |
| `T01` | Provision a 32-section Event: one 34-account linked batch and one 32-transfer linked capacity batch. Kill after each submission and before each checkpoint; replay exact fields. Inject one isolated linked-member failure and one same-ID/different-field collision. | Each successful vector is complete and ID-associated; every member of a failing linked chain rolls back; replay returns exact `exists`; each section has exactly one capacity grant; no extra account/transfer exists. The checkpoint alone moves monotonically. | Retain the Event claim/manifest, allocated ID, accounts, transfers, and negative IDs indefinitely; evidence 90 days. | BO; replay RB |
| `T02` | On a bounded section, race duplicate and distinct Reserve Operations whose total request exceeds capacity, including batches of ten and concurrent invocations. | For every accepted `q`, `debits_pending + debits_posted + q <= credits_posted`; totals never oversell. The losing pinned request receives direct `exceeds_credits`; repeating that ID yields `id_already_failed`; it never attempts another section. | Retain all TigerBeetle objects/IDs indefinitely and Operations for 30 days. | BO |
| `T03` | Submit one exact pending Reserve, kill after submission, replay before and after its deadline, and attempt isolated same-ID mutations of account, amount, timeout, flag, code, and ledger. | First response is `created`; exact replay is `exists` with the original timestamp. Mutations are `exists_with_different_*`; the accepted transfer fields never change. After the deadline, existence is not presented as liveness and no cleanup deadline is asserted. | Retain transfer and Event indefinitely; Operation/marker 30 days; evidence 90 days. | BO; exact replay RB |
| `T04` | For valid accepted Reserves, race exact duplicate Confirms, two different Confirm IDs, and Confirm versus expiry. In isolated negative fixtures submit Confirm before Reserve and exercise inherited-field mismatch, full-post `AMOUNT_MAX`, unexpected void, and expiry statuses. | An exact Confirm retry is `exists` with its original post timestamp and creates one resolver. Different IDs yield exactly one winner and `confirmed_elsewhere` for the loser. The expiry race yields either this ID's exact post or authoritative `pending_transfer_expired`. Pre-reserve submission yields `pending_transfer_not_found` and then `id_already_failed`. Production code proves it never submits that case. | All resolver, void, expired, and failed IDs remain attributable indefinitely; evidence 90 days. | BO; winning replay RB |
| `T05` | Exercise maximum-size request vectors and shuffle, truncate, duplicate, omit, or misassociate returned indices/IDs in the harness while killing the client process after native submission. | Complete native responses associate every item with exactly one requested ID/index. Any harness-corrupted vector becomes uncertainty for all affected records. Recovery uses exact replay; process/Lambda loss never produces a negative business assertion. | Retain any accepted objects indefinitely; evidence 90 days. | BO; rerun RB |

TigerBeetle expiry cleanup has no maximum documented lag. Tests may require no removal before
expiry and may verify eventual observation diagnostically, but they must not fail because expired
pending counters remain temporarily present. They do fail if debit/credit symmetry or the bounded
section invariant is violated.

### Gate the deployed rollout

| ID | Environment, setup, and injected fault or race | Evidence and exact pass threshold | Cleanup or retention | Gate |
| --- | --- | --- | --- | --- |
| `A01` | Baseline and SAM change set: record redacted topology, physical IDs, queue counts/ages, parameters, artifact/config digests, Function URLs, and live TigerBeetle session limit. Generate each phase change set with one deliberate replacement/removal variant. | The real change set contains no removal, `Replacement: True`, or unresolved conditional replacement for a retained table, queue, mapping, function URL, or logical identity. The negative variant is refused. Both proposed and compatibility-floor bytes are fetchable and digest-exact. | Content-addressed template, bootstrap/CLI packages, parameters, topology, and evidence remain at least 90 days. | BD; BO; AO; RB |
| `A02` | Compatibility floor on the live dark stack: deploy increments 1 through 5 in order with seat gate false and poller absent/disabled; run `echo`, query, and Completion canaries during each update. Run the conditional TTL migration with conflicts and restarts. | Existing Function URLs and physical identities do not change; legacy mapping and Completion never stop; canaries have exact retained results. All active writers emit 30 days, all readers remain dual-form, and migration/audit meets `I03`. Every 24-hour-writer artifact becomes ineligible immediately after the writer watermark. | Preserve the captured compatibility-floor artifact and its decoders; no authoritative row is deleted for the test. | BD |
| `A03` | Dark resources, topology, IAM, and queues: deploy increments 6 through 13 with route false and mapping disabled. Probe cross-queue access, Event writes from execution, Operation writes from provisioner/reconciliation, runtime purge, extra owner, and wrong queue/mapping attributes. Redrive one canary message to each DLQ. | Topology shows exactly two routes, distinct destinations, one owner per source when enabled, and the sole shared Completion owner. Negative IAM actions are denied. Seat and Completion source retention is exactly 345600 seconds; both DLQs are 1209600; redrive allow is source-scoped. Seat is batch 10/zero window/partial response, concurrency eight, 15/90 seconds, and `maxReceiveCount=12`; Completion is batch one/zero window, concurrency 16, 15/90 seconds, and `maxReceiveCount=8`. A redriven standard-queue message gets its documented new lineage and at most one approved redrive. | Drain exact test messages or quarantine unchanged ones; never purge. Retain queues/tables and evidence. A literal 14-day soak is not required: live attributes plus the real redrive/timestamp probe and mocked expiry tests prove the contract. | BO; rerun RB |
| `A04` | Session budget and WireGuard/VPC proof: measure cluster limit `C`, configure finite legacy cap `L`, enable seat concurrency eight, provisioner one, one test client, and reserve one operator/auditor slot. Attempt one over-budget client. Exercise detach while each VPC-attached function, alias/version, and ENI remains. | `8 seat + L legacy + 1 provisioner + 1 test + 1 reserved operator/auditor <= C`; no normal traffic can consume the reserved slot; any unbounded `L`, eviction, or observed session loss fails. Detach refuses until every discovered VPC attachment/version and Lambda ENI is gone, and does not remove gateway resources while accepted seat work needs TigerBeetle. | Record observed `C` and chosen `L` per deployment; they are not protocol constants. Retain gateway until recovery is complete. | BO; rerun RB |
| `A05` | Retained dark canary: create one real Event through the provisioner, direct-invoke first, then briefly enable the actual seat mapping for Reserve and Confirm through both queues and shared Completion. Run the complete boundary-kill table and replay the same accepted IDs. | Counter/claim/Event, Operations, decisions, markers, results, and TigerBeetle snapshots meet the universal invariant. Only allowed monotone transitions occur; every replay is exact `exists`/duplicate behavior; no extra transfer appears. Query returns the exact closed results while public seat intake remains `503`. | The canary Event, claim, allocated ID, accounts, transfers, and test-ID ledger remain permanent. Operations/markers use 30-day TTL; evidence remains 90 days. | BO; replay RB |
| `A06` | Strict-TTL live gate: after the final possible 24-hour writer, keep new-form `echo` live while auditing active/rollback artifacts, aliases, versions, tools, table rows, source/in-flight/delayed messages, DLQs, redrive manifests, canaries, quarantines, and applying runs. Unless an equivalent immutable enqueue inventory exists, wait four full source-retention days plus two 90-second visibility windows. | Every writer is 30-day; a complete conditional migration and later scan find zero old row and no unaudited loser; no runnable lineage can reintroduce old form. Retained old quarantine is demonstrably non-runnable and readable by the compatibility artifact/offline decoder. Strict `echo`, query, and Completion canaries pass with seat route false and poller disabled. Neither a clean scan nor elapsed time alone passes. | Retain compatibility artifact/decoder and quarantine evidence through all applicable horizons. Do not delete an old row to make the audit pass. | BO; recheck RB |
| `A07` | Fixed maximum/fault load: for 30 minutes run live new-form `echo` plus duplicate-heavy maximum seat batches over 32-section/max-size Events, boundary kills, conditional losers, delayed expiry cleanup, and exact replays. Stop input and observe drain. Exercise alarms in a separate synthetic namespace. | Zero oversell, timeout, allocation/bound failure, incomplete/misassociated vector, integrity drift, unexpected DLQ, unplanned throttle, or session loss. All non-quarantined backlog drains within ten minutes. During the last 15 minutes, age does not grow for five consecutive one-minute samples. Measured Completion drain is at least 125% of seat terminal production plus measured legacy peak. Synthetic notifications fire; production alarms remain clear. | Test Events and TigerBeetle objects remain permanent and attributable; messages drain normally; Operations expire after 30 days; evidence remains 90 days. | BO; reduced safety sample AO and RB |
| `A08` | Alarm thresholds: inject one event at a time into the synthetic namespace and one safe topology drift into a disposable fixture. | Integrity/topology, any-DLQ, timeout, allocation-bound, and session exhaustion/eviction alarm on the first event in five minutes. Source age warns/pages at 180/900 seconds; Completion age at 90/450; every queue pages at 75% of the shortest applicable message/Operation retention; terminal-production-over-drain and sustained partial failure/throttle use the measured baseline. Actions, dimensions, and missing-data behavior are exact and aggregation hides nothing. | Remove only synthetic metric data/fixtures where the service permits; retain notification evidence 90 days. Never manufacture a production DLQ arrival merely to test wiring. | BO; verify clear AO and RB |
| `A09` | Opening canary: create a reviewed change set whose intended difference is only `SEAT_RESERVATION_ROUTE_ENABLED=false -> true`; wait for the new intake configuration digest, then submit authenticated Reserve and distinct Confirm Operations through the existing Function URL while continuously probing `echo`, query, and Completion. | No contract, writer, owner, resource identity, URL, or accounting builder changes. Reserve and Confirm reach exact terminal results through their dedicated queue and shared Completion; tenant-scoped queries work; legacy canaries remain exact. Any failure starts `R01` immediately. | Retain the opening canary under the same permanent accounting, 30-day Operation, and 90-day evidence rules. | AO |

### Prove post-open rollback as a recovery drill

The drill uses accepted canary work and safe injected backlog; it never deletes or rewrites a live
user fact.

| ID | Setup and injected fault or race | Evidence and exact pass threshold | Cleanup or retention | Gate |
| --- | --- | --- | --- | --- |
| `R01` | Close acceptance first. Set the seat gate false, wait for the new configuration digest, freeze applying/redrive runs, and race new authenticated seat intake with live `echo` and query. | Every new seat request returns bounded `503` before persistence/enqueue; `echo` and query remain live; the closure watermark and frozen run set are durable. | Keep all accepted pre-watermark work; the flag stays false through recovery. | RB |
| `R02` | Stop the owner. Disable the seat mapping while messages are visible, delayed, and in flight; leave shared Completion enabled. | Mapping reaches `Disabled`, current seat invocations reach zero, no second owner appears, source messages remain retained, and Completion continues to drain already-published markers. | Never delete or purge either queue. | RB |
| `R03` | Artifact selection. Audit every accepted Operation, queued body, Event/version/digest, decision, marker, transfer, and applying run; offer a 24-hour writer, legacy-only artifact, compatible floor, and newest compatible artifact. | Only the newest retained artifact whose validators cover every observed version and whose builders reproduce every pinned request is eligible. The 24-hour and legacy-only artifacts are refused. If none qualifies, polling remains stopped and work is quarantined for operator recovery. | Retain all candidate artifact bytes and audit evidence at least 90 days. | RB |
| `R04` | Compatible switch and retained-canary replay. Apply a forward change set changing only selected compatible compute/configuration, with stateful logical IDs fixed and gate false; direct-invoke the retained canary and inject each boundary kill. | The change set has no stateful replacement/removal. Canary replay yields exact `exists`/duplicate behavior and byte-equal immutable state with no extra transfer before the mapping may be enabled. | Keep canary and authoritative facts permanently; evidence 90 days. | RB |
| `R05` | Bounded drain/redrive. Enable one append-only applying-run manifest at a time; exercise unchanged Operation enqueue, one pending provisioning phase, exact Completion republish, and at most 100 matching DLQ bodies at two messages/second. Inject queue-age growth, throttle, partial failure, integrity alarm, candidate mismatch, and drain below production. | Only listed unchanged actions run. Each injected stop condition halts automatically. A lineage is redriven at most once; a second DLQ arrival, unrepairable mismatch, or unsafe work is immutably quarantined without a public terminal result. No section, timeout, ID, body, intent, marker, manifest, or Completion is changed. | Finish or quarantine within seven days of the closure watermark; retain quarantine bodies/evidence and responsible owner. | RB and drain acceptance |
| `R06` | Recovery completion. Stop input and observe source, delayed, in-flight, Completion, and DLQ state across two visibility windows. Include one exact stored-but-unpublished terminal marker and one quarantined `SUBMITTED` Operation. | Before the poller stops again, every accepted Operation is exact `COMPLETED` or immutably quarantined, no marker remains unrepublished, per-route terminal production equals Completion drain, and seat visible/in-flight/delayed counts are zero for two full 90-second windows. Query remains available for retained/quarantined records. | Retain queues/DLQs, tables, validators, alarms, topology checks, and responsible executors until all work is completed/quarantined and both the latest 30-day Operation expiry and 90-day evidence horizon pass. Events, claims, IDs, and TigerBeetle objects remain indefinitely. | Rollback exit |

An unopened-route rollback is the smaller negative case: keep the route false, disable the mapping,
wait for zero invocations, drain the known canary Completion, and prove no non-canary seat Operation
or queue entry exists. A forward change set may then remove only idle compute, its mapping, and
runtime roles. It retains tables, queues, canary Operations, Event data, evidence, the compatibility
floor, and every TigerBeetle object. Stateful deletion, queue purge, Event-ID reuse, compensating
transfer, manifest/decision/marker editing, and disabling WireGuard while accepted work remains are
never rollback steps.

This is a cumulative release proof, not a one-time end-to-end happy path. Failure of any required
row blocks its named gate. The route opens only after `I01...I14`, `T01...T05`, and `A01...A08`
pass for the exact release; it remains open only after `A09`; and a compatible rollback artifact
may drain only after `R01...R04`, with `R05...R06` governing the bounded recovery run.
