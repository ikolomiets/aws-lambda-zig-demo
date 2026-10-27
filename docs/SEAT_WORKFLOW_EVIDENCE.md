# Seat workflow recovery evidence

The [composed suite](../tests/seat_rejection_workflow.zig) exercises authenticated
intake, seat submission, the native invocation adapter, seat completion and
authenticated query. It uses real handlers, codecs, domain interpretation and
DynamoDB request builders. External persistence, allocation, generated IDs,
native replies, queue sends and diagnostic delivery are controlled effects.

```sh
zig build test-seat-workflow --system zig-pkg
```

Restart cases release each invocation's arena before the next handler runs.
The external-effect fake owns stored Operation attributes, Event configuration,
published messages and applied native records independently of those arenas.
Native records capture applied requests and scripted outcomes; they do not
simulate native balance enforcement, expiry or concurrency.

## Failure boundaries

Each row has failure-before-effect and effect-followed-by-lost-response cases.
Assertions combine emitted requests, retained state, source disposition and the
authenticated public Result where an Operation can complete.

| Boundary | Observable recovery |
| --- | --- |
| Intake Operation write | No queue send follows a failed write. A lost response can leave a submitted record; only a matching caller retry requeues it. Changed input conflicts, and a completed retry returns the saved winner without another send. |
| Intake queue send | The submitted Operation survives send failure. An uncertain send may already have delivered a duplicate; caller retry uses the same UUID, verified tenant, Body and null Context. |
| Ledger allocation | Failure dispatches no candidate. An applied increment with a lost response permits a gap; retry obtains a new returned ledger rather than inferring or recycling one. |
| Event insertion | No unpersisted candidate reaches native execution. Conflicts and lost responses resolve to saved identities; transient authoritative readback failure retries without replacing those identities. |
| Native or local-rejection dispatch | Submission acknowledges after publication. Failed and uncertain sends retain source retry eligibility; a delivered duplicate can compete with later attempts. |
| Native account and transfer execution | Incomplete execution publishes no success. Initialization retries reconstruct complete saved chains; accepted account replay still requires complete funding evidence. Applied records survive request release. |
| Native result publication | Sends follow source order. A failed or uncertain send stops the suffix and retains earlier acknowledgements. Competing reservation attempts may all have effects even when only one Result wins. |
| Operation finalization | Failure or uncertainty requires authoritative readback. A transient readback error retries; only a valid matching terminal Result establishes a winner. |
| Creation transaction | Event readiness/failure and the creation Result commit together. Coherent readback distinguishes a terminal winner, retryable creating/submitted pair and diagnosed contradictory pair. |

Seat submission and completion also inject final invocation-response allocation
failure after publication or persistence. Redelivery preserves durable winners.
The [native processor tests](../src/tiger_beetle_processor.zig) separately cover
response allocation failure, unfinished sources, different destinations and
successful-prefix acknowledgements. Diagnosed unrecoverable seat inputs emit
bounded escaped ERROR output and acknowledge without durable mutation, including
when diagnostic delivery itself fails.

## Contract coverage by owner

Focused tests remain beside their owning modules; interaction cases run through
the composed suite. The ordinary `zig build test` includes all these offline suites.

| Contract | Focused evidence | Composed interaction |
| --- | --- | --- |
| Four command schemas and admission | [Seat domain](../src/seat_reservation.zig): exact fields, decoded duplicate keys, numeric/UUID/native-ID limits, Unicode tags, class ordering and 31-class ceiling. | Invalid requests allocate nothing, insert no Event and dispatch no native work; intake normalization reaches domain admission. |
| Actual serialization limits | [Domain](../src/seat_reservation.zig), [Event items](../src/seat_reservation_persistence.zig), [messages](../src/processor_message.zig), [native Results](../src/tiger_beetle_processor.zig): exact/over limits, worst escaping and identifiers; separate SQS request and Lambda event wrapping. | 31-class creation executes 64 commands; availability returns every escaped class with maximum totals. No prefix admission or output truncation. |
| Trusted metadata and ownership | [Messages](../src/processor_message.zig), [intake](../src/intake_lambda.zig), [query](../src/query_lambda.zig): verified tenant, explicit Context, routing and owner-only reads. | Missing/foreign Events are indistinguishable; authorization precedes state/class disclosure; normal and diagnostic hops preserve tenant and Context. |
| Durable identities and allocator binding | [Counters](../src/ledger_counter.zig), [Event persistence](../src/seat_reservation_persistence.zig): selected IDs, guarded bounds, owned bindings, saved insertion winners. | Allocation gaps, insertion races/readback failures and complete-chain retry use only saved Event identities. |
| Native construction and evidence | [Domain](../src/seat_reservation.zig): exact accounts, funding, singleton pending/full-post transfers and public projections. | Success/rejection/replay for all four commands; truncated, unknown, mixed, contradictory or mismatched evidence cannot invent Results. |
| Immutable completion | [Operation updates](../src/operation_persistence.zig), [Event transactions](../src/seat_reservation_persistence.zig): identity/state/absent-Result and full configuration guards. | Competing completions preserve the first valid Result; delayed local rejection retains its admission decision; contradictory creation pairs are diagnosed without repair. |
| Cache and memory ownership | [Ready cache](../src/seat_event_cache.zig): complete 1 MiB accounting, LRU, bypass, tenant isolation and arena independence. | Warm submission/completion reuses only ready metadata, observes uncached transitions and fresh balances, and excludes foreign cache hits. |
| Host utilities | [Events](../src/seat_events_cli.zig), [counter CLI](../src/ledger_counter_cli.zig), [queue CLI](../src/queue_cli.zig) and their deterministic tests: bounded I/O, shared persistence/codec behavior, conflicts, precedence, sanitized errors and credential-free help. | Utilities expose metadata and transport; they do not establish readiness or substitute for native completion evidence. |
| Deployment helpers/resources | Mocked [cleanup lifecycle](../tests/deploy_cleanup_lifecycle_test.sh) and [durable-data guards and development updates](../tests/deploy_development_test.sh): lifecycle, six-function code updates and guarded table/counter bindings. | SAM provisions both seat Lambdas, their queues/mappings and Events table, with an owned or referenced counter binding under the [resource contract](DEPLOY_AWS_LAMBDA_WITH_SAM.md#4-understand-what-the-template-creates). Mocks establish no deployed routing, delivery or IAM behavior. |

## Independent service evidence

Record deterministic, SDK/DynamoDB Local, authorized local native and executed
cloud results using the [deployment evidence levels](DEPLOY_AWS_LAMBDA_WITH_SAM.md#seat-workflow-evidence-and-deployed-scenarios).

The [SDK/DynamoDB Local probe](SEAT_TRANSACTIONS.md) uses the pinned SDK, isolated
loopback database and dummy credentials to execute shared transaction builders,
condition cancellation, coherent readback and runtime finalization. Fake transaction
success does not replace this probe; database evidence does not establish native
accounting or AWS transaction-contention behavior.

The separate [native integration suite](../tests/tigerbeetle_integration.zig) uses
fresh record identities against the authorized local development replica:

```sh
TIGERBEETLE_ADDRESSES=127.0.0.1:3000 zig build test-tigerbeetle --system zig-pkg
```

Its seat cases establish funding and complete-chain replay, all account bounds,
competing all-or-nothing reservations, class independence, maximum-u128 full
posting, already-posted effective success, tenant/Event/class/credit/ledger/code
association mismatches before and after posting, expiry without replay renewal,
and conservative availability while native expiry cleanup lags. Missing local
prerequisites are validation gaps, never simulated native passes.

No offline suite or local service probe certifies deployed IAM, SQS mappings,
network connectivity or AWS service behavior. Cloud scenarios require separate
explicit authorization and deployed resources.

## Retry and retention limits

Intake writes before sending and has no outbox; a saved submitted Operation alone
does not cause delivery. Recovery from that gap depends on the caller retrying.
Fresh submission attempts can create different native holds, including abandoned
holds when another attempt's failure wins the public Result. Finalization neither
undoes those effects nor renews a hold's native timeout.

Operations retain the existing 24-hour TTL, including submitted Operations. No
recovery guarantee extends past that window or Operation deletion. Deletion cases
cover delayed creation and reservation evidence both before and after finalization:
query returns absence, completion diagnoses without reconstructing the Operation,
and permanent Event/native records remain. These cases model deletion; they do
not simulate DynamoDB TTL scheduling. The [consistency ADR](adr/0007-seat-completion-consistency.md)
owns these limits, and the [seat reference](SEAT_RESERVATION.md) owns current behavior.
