---
title: Define scale, batching, and concurrency bounds
status: closed
assignee: codex
labels:
  - wayfinder:prototype
parent: ../map.md
blocked_by:
  - "[Define name-based routing and executor ownership](03-define-name-based-routing-and-executor-ownership.md)"
  - "[Define the reserve action contract](06-define-reserve-action-contract.md)"
  - "[Define the reserve transaction and allocation protocol](07-define-reserve-transaction-and-allocation.md)"
  - "[Define the confirm action and transaction contract](08-define-confirm-action-and-transaction.md)"
  - "[Define retry and failure taxonomy](09-define-retry-and-failure-taxonomy.md)"
  - "[Define Operation result contracts](10-define-operation-result-contracts.md)"
---

## Question

Given that reserve-v1 already bounds a caller-supplied eligibility list to 32 section IDs of at
most 64 UTF-8 bytes, quantity to `u32`, timeout to one hour, and the complete Operation body to
4,096 bytes, what matching bound on total sections per Event keeps the omitted-list manifest-order
path bounded and keeps every public section ID addressable? Given also that `srs-packed-v1`
structurally permits ordinals through `2^56 - 2`, Event creation stores one complete manifest in a
DynamoDB item, provisioning submits linked batches of `section_count + 2` accounts and
`section_count` transfers, and an omitted-list reserve must atomically look up
`section_count + 1` accounts (all sections plus Seats Reserved) before submitting only one transfer,
what explicit section and encoded-manifest bounds fit below DynamoDB's 400 KB limit and the pinned
TigerBeetle batch maximum? Given that each Confirm also performs bounded strong reads, exactly one
pending-transfer lookup, and at most one deterministic post submission—and retries a still-
`SUBMITTED` Reserve only until the fixed 900-second Confirm dependency deadline—what bounds on SQS
records per invocation, reserved executor concurrency, in-invocation parallelism, lookup/create
request batching, per-Operation conditional
decision writes, and shared Completion throughput keep latency and resource use predictable,
prevent concurrent duplicates from escaping their immutable intent, preserve useful hold time, and
avoid coupling the legacy executor?

Keep the retry/redrive decision fixed while sizing: the seat queue uses partial batch responses,
four-day source retention, a fourteen-day DLQ, and
`maxReceiveCount = max(5, ceil(900 / visibility_timeout_seconds) + 2)`; the Completion queue uses
`maxReceiveCount = 8` and its own fourteen-day DLQ. Choose the seat Lambda timeout and queue
visibility together so visibility remains at least six times the function timeout and the formula
leaves two deliveries beyond the dependency deadline. Include the strong Operation reads,
`reserve-decision-v1` write, `seat-terminal-v1` write/readback, exact Completion republish, and
TigerBeetle's potentially invocation-long client wait in the memory, latency, and concurrency
prototype. Treat each compact seat Completion as bounded to 1,024 UTF-8 bytes and preserve its
already-pinned bytes when sizing terminal-marker storage, aggregate Completion messages, and
republish buffers; do not reopen its field sets, deadline semantics, or failure classifications.

## Resolution

[The TigerBeetle accounting research](../../../docs/research/seat-reservation-tigerbeetle-accounting.md)
fixes the safety boundary: TigerBeetle applies the section balance invariant when a pending
transfer is created, exact retries must retain their original fields, and a client request may
wait until the Lambda is terminated. The pinned TigerBeetle documentation adds two sizing facts:
the default maximum is 8,189 events for each lookup/create request, and one client session permits
only one in-flight request. The scale contract therefore favors small, whole-request batches and
bounded Lambda concurrency over attempting to fill the product maximum. [TB
`docs/coding/requests.md`, §§ `Batching Events` and `Guarantees`; TB
`docs/reference/sessions.md`, opening paragraphs and § `Retries`]

### Bound every Event to 32 sections

`section_count` is a required integer in `1...32`. This matches reserve-v1's maximum of 32
caller-supplied `eligible_section_ids`: every section of a valid Event can be named explicitly in
one request, while an omitted list expands to no more than the same 32 sections in manifest order.
The bound is a version-1 operational limit; the much wider `srs-packed-v1` ordinal field remains a
structural namespace reserve, not permission to provision a larger Event.

Before the Event-creation transaction, measure the immutable manifest using DynamoDB's native item
size rules, including UTF-8 attribute names and values and container overhead. Require the
manifest portion to be at most 32 KiB and the complete Event item, including its key, provisioning
checkpoint, and bounded failure diagnostic, to be at most 64 KiB. Reject an oversized definition
before allocating an Event ID. These are application limits, not targets: they leave a sixfold
margin below DynamoDB's 400 KB item maximum and keep ten maximum-size Event reads below 640 KiB.
[AWS DynamoDB constraints](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Constraints.html)

The resulting per-Event TigerBeetle requests are fixed and indivisible:

| Phase | Request | Maximum events |
| --- | --- | ---: |
| Provision accounts | `create_accounts` | `section_count + 2 = 34` |
| Provision capacity | `create_transfers` | `section_count = 32` |
| Reserve with omitted eligibility | `lookup_accounts` | `section_count + 1 = 33` |
| Confirm preflight | `lookup_transfers` | `1` |
| Reserve or Confirm commit | `create_transfers` | `1` |

All 34 provisioning accounts remain one linked chain and all 32 capacity transfers remain a
second linked chain. Do not split either phase to admit a larger Event. A Reserve snapshot remains
one lookup request containing every candidate section plus Seats Reserved; do not page it or join
multiple observations.

### Give the seat queue a small independent concurrency envelope

Use these version-1 deployment values:

| Control | Bound |
| --- | ---: |
| Seat SQS records per invocation | `10` |
| Maximum batching window | `0` seconds |
| Seat Lambda memory | `256 MiB` |
| Seat Lambda timeout | `15` seconds |
| Seat queue visibility timeout | `90` seconds |
| Seat function reserved concurrency | `8` |
| Seat event-source maximum concurrency | `8` |
| In-invocation record parallelism | `1` |
| Seat queue `maxReceiveCount` | `12` |

The timeout and visibility pair preserves the required six-times relationship. It also fixes the
redrive formula at `max(5, ceil(900 / 90) + 2) = 12`, leaving two deliveries after the Confirm
dependency deadline. Keep `ReportBatchItemFailures`; a Confirm whose Reserve is still `SUBMITTED`
returns promptly as a failed record and never sleeps inside the invocation. The zero batch window
and 15-second function limit avoid spending useful hold time waiting merely to fill a batch.
[AWS Lambda SQS configuration](https://docs.aws.amazon.com/lambda/latest/dg/services-sqs-configure.html)

Each execution environment owns one long-lived TigerBeetle client, so the seat service contributes
at most eight client sessions and eight in-flight TigerBeetle requests. It does not share a Lambda,
event-source mapping, queue, or reserved-concurrency pool with the legacy executor. Deployment
must verify that those eight sessions plus the separately measured legacy, provisioning, test, and
operator clients fit the live cluster's configured client-session limit; the documented default of
64 is not a substitute for reading the live value. Do not raise either seat concurrency control
without a load test and a rechecked client-session budget.

Process records on one thread in stable SQS order, but batch compatible I/O across their current
phase. Coalesce duplicate source records by canonical Operation ID before side effects and apply
the resulting disposition to every corresponding SQS message ID. A hard timeout can therefore
strand at most one grouped TigerBeetle request, while immutable decisions and exact object IDs make
the whole affected subset replayable.

### Batch reads and TigerBeetle calls by phase

For one invocation, the absolute request bounds are:

- Strongly `BatchGetItem` at most 10 source Operations first; after validation, strongly batch-get
  at most 10 referenced Reserve Operations and 10 Event items. Deduplicate keys, set
  `ConsistentRead = true`, verify every returned key explicitly, and retry only returned
  `UnprocessedKeys` while the invocation has time. A deadline refresh or conditional-write
  readback is another phase of at most 10 keys, never an unbounded per-record loop. These batches
  remain below DynamoDB's 100-item and 16 MB request limits. [AWS
  `BatchGetItem`](https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_BatchGetItem.html)
- Flatten all ready Reserve snapshots into one `lookup_accounts` request. Ten omitted-list
  Reserves require at most `10 * 33 = 330` account IDs. Keep an explicit per-Operation slice and
  reject missing, duplicate, or cross-Event replies; do not infer reply grouping from position
  alone.
- Put all validated Confirm preflights into one `lookup_transfers` request of at most 10 IDs.
- After every required Reserve decision is durable and every Confirm proof is complete, submit at
  most 10 independent pending or post-pending transfers in one `create_transfers` request. Preserve
  stable source-record order, never set `linked`, and classify every result against its exact
  Operation. A missing, duplicated, or truncated result vector is uncertainty for every affected
  record, not partial evidence.

TigerBeetle request types remain separate and the shared client issues them sequentially. Before
starting a new potentially blocking TigerBeetle request or conditional write, require at least five
seconds of Lambda time to remain; otherwise return the not-yet-terminal records for retry. This is
a local admission guard, not a database timeout: once submitted, a TigerBeetle request may consume
the rest of the invocation and be recovered only by exact redelivery.

### Keep each Operation's decisions individually conditional

Batching must not weaken the per-Operation compare-and-set boundary:

- A Reserve performs at most one conditional `reserve-decision-v1` write attempt in a delivery.
  A conditional loser or uncertain response gets at most one strong readback in that phase and may
  proceed only with an exact marker for the still-matching Operation hash and Event definition.
- Any terminal Reserve or Confirm performs at most one conditional `seat-terminal-v1` write
  attempt in a delivery. A loser or uncertain response gets at most one strong readback and follows
  only an exact marker.
- Neither marker uses `BatchWriteItem`, crosses Operation boundaries in a transaction, refreshes a
  timestamp, or changes after creation. The generic completion worker remains the only public
  `SUBMITTED -> COMPLETED` writer.

A Reserve can therefore make at most two conditional decision writes in one successful delivery;
a Confirm can make at most one. Additional contention or uncertainty ends that record's work for
the invocation and relies on SQS redelivery instead of spinning.

### Bound memory and Completion fan-in explicitly

The canonical Completion bytes stored in `seat-terminal-v1` remain at most 1,024 bytes. Bound the
complete native terminal marker to 4 KiB, `reserve-decision-v1` to 1 KiB, and the whole persisted
Operation item to 32 KiB; reject a local encoding that exceeds its bound before the conditional
write. An existing terminal marker is republished from its stored Completion bytes without parsing
and rebuilding the public result.

At most 10 unique terminal Operations produce one aggregate Completion message. With the existing
`completion_batch` envelope, ten 1,024-byte Completions and ten canonical 36-byte Operation IDs
encode to at most 10,913 bytes. Allocate a fixed 10,913-byte aggregate/republish buffer and return
every represented source record as a partial failure if publication is failed or uncertain. This
is far below both the repository's 1 MiB decoder bound and the SQS message limit.

Cap seat invocation-owned scratch memory at 4 MiB and configure 256 MiB for the function. The
dominant bounded inputs are ten 64 KiB Event items, source/reference Operation items, 330
128-byte TigerBeetle Accounts, ten 128-byte Transfers, result vectors, and the 10,913-byte
Completion buffer; the remaining memory is headroom for the AWS SDK, JSON decoding, and the native
TigerBeetle client. Allocation failure is retry-only and never relaxes a batch or item bound.

Keep the shared Completion mapping at one SQS message per invocation, zero batching window, a
15-second function timeout, 90-second visibility, and `maxReceiveCount = 8`. Give the completion
function reserved concurrency 16 and the mapping maximum concurrency 16. Each message contains at
most ten seat entries, so at most 160 seat Operation updates can be in flight through the shared
worker—twice the seat executor's 80-record concurrency envelope—while the queue continues to
buffer legacy messages. These values are an initial safety bound, not a throughput claim: alarms
and load tests must compare terminal-production rate, completion-drain rate, throttles, and oldest
message age before either concurrency limit changes.
