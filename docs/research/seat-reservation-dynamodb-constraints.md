# Seat Reservation: DynamoDB constraints and persistence options

Research date: 2026-09-25. This report supplies facts and design alternatives for
**Verify durable allocation and completion options in DynamoDB**. It does not
select application policy or implement a processor. The agreed constraints are a
shared event table with tenant-scoped keys, reservation of one specified seat class
per request, and full confirmation of one pending transfer for one specified class.

## Service guarantees

| Concern | Verified DynamoDB behavior | Consequence for this design |
| --- | --- | --- |
| Counter updates | `UpdateItem` is atomic, but an unconditional increment is not idempotent. A retry can increment again. Conditional writes can prevent repeating the same state transition. [Item operations](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/WorkingWithItems.html) | A successful allocation response can identify a unique value while an ambiguous attempt consumes an additional, unused value. A counter alone does not associate an allocation durably with an Operation. |
| Ambiguous response | A server error can occur before or after a counter update; the caller cannot always distinguish them. AWS documents transaction markers as a way to extend deduplication beyond a transaction token's lifetime. [Counter strategies](https://aws.amazon.com/blogs/database/implement-resource-counters-with-amazon-dynamodb/) | Treat an uncertain allocation as potentially committed. Reading the current counter cannot identify which caller consumed an earlier value. |
| Multi-item writes | `TransactWriteItems` commits all actions or none, supports up to 100 distinct items and 4 MB, and can span tables in one account and Region. Two actions cannot target the same item. [Transaction API](https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_TransactWriteItems.html) | A counter, immutable plan, event, and Operation can participate in one transaction if colocated. Put conditions directly on updates instead of adding a separate check for the same item. |
| Retry tokens | `ClientRequestToken` deduplicates identical transactions for 10 minutes after first completion. Reusing it with changed parameters inside that interval produces a mismatch; later use is a new request. Tokens contain 1–36 characters. [Transaction API](https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_TransactWriteItems.html) | Persisted operation identity and conditional writes must carry any longer deduplication guarantee. Changes to timestamps or a newly selected counter candidate require care when constructing retry tokens. |
| Reads | Strong reads on the base table reflect prior successful writes. GSIs and streams offer eventual reads. A read does not stop subsequent modification. [Read consistency](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/HowItWorks.ReadConsistency.html) | Read authoritative plans and readiness directly from their base-table keys; protect later writes with conditions. A cache requires an explicit validity rule. |
| Read snapshots | `TransactGetItems` supplies an atomic view across items; ordinary reads can observe different stages of a transaction if issued at different times. Transactional changes propagate to streams incrementally. [Transaction behavior](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/transaction-apis.html) | Consumers requiring a coherent event/Operation pair can use a transaction read. A stream consumer cannot infer that one record represents the entire transaction. |
| TTL | TTL is an epoch-seconds Number; deletion normally occurs within days. Expired items remain readable and writable until deleted. [TTL](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/TTL.html) | TTL cannot drive reservation expiration or promptly remove a deduplication marker. Application checks and TigerBeetle timeouts need their own contract. |
| Bounds | Items include attribute names and values within 400 KB; Numbers have 38 digits of precision; expressions have a 4 KB limit; document nesting reaches 32 levels. String partition and sort keys are bounded by 2048 and 1024 bytes. [Constraints](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Constraints.html) | A u32 ledger counter fits exactly. Full u128 IDs can require 39 decimal digits, so a String/Binary representation avoids Number precision loss. Bound class count, tags, plans, and results explicitly. |

These guarantees cover DynamoDB operations. They do not make a DynamoDB write,
SQS send, and TigerBeetle execution one atomic transaction.

## Global ledger allocation alternatives

The following are derived design options, not additional AWS guarantees. The
requested nonzero u32 namespace has values 1 through 4,294,967,295. Its scope must
cover every event allocator using the same TigerBeetle ledger namespace, across
tenants and any deployments sharing that namespace.

**Bounded increment followed by a conditional plan insert.** Initialize a
dedicated high-water item once. Increment only while its value is below the
maximum; retain the returned value. Conditionally create the operation plan
containing that ledger and all generated IDs. If another worker already created
the plan, load and use its plan. Lost allocation replies and workers losing the
plan race consume gaps. Do not send a TigerBeetle command using a candidate plan
before winning or loading the durable plan. Never recover an ambiguous allocation
by assuming the counter's current value belongs to this operation. This option
is compatible with never reusing ledger IDs if gaps are acceptable, the counter
never regresses, and all writers obey the bound.

**Conditional allocation and plan in one transaction.** Read high-water `n`,
choose `n + 1`, then transact a counter update conditioned on its still being `n`
with an absent-only plan insert containing `n + 1`. Include an event skeleton if
needed. After an ambiguous result or conflict, strongly read the operation's plan
first: a matching plan is the durable outcome, even after the token window.
Otherwise retry contention with a fresh candidate and a token appropriate to that
new transaction. This avoids a counter increment without its plan, at the cost of
contention and additional transaction work. The transactional API does not return
updated item attributes and cannot feed a server-computed increment into another
action; client-selected candidates make the association expressible.

For both options, a retained allocation marker can bind tenant, Operation ID,
request identity, event UUID, and ledger. Same identity with different request
content is a conflict, not a replacement. Application arithmetic must check the
upper bound before increment/conversion, and the write condition must also enforce
it against concurrency. Exhaustion stops allocation; wraparound is unsafe. A
missing or corrupt initialized counter cannot safely be silently recreated from
zero. Restoring an older DynamoDB backup while TigerBeetle retains newer events
also requires reconciliation or a new disjoint namespace before allocating.
Deleting an event does not make its ledger reusable under the requested invariant.
Deciding whether gaps are allowed and selecting recovery procedures remain design
decisions.

## Durable plans and single-class confirmation

A conditionally inserted plan is an available mechanism to stabilize the generated
event UUID, account/transfer IDs, ledger, timeout, class ordering for event creation,
the single class and pending ID for reservation/confirmation, request identity, and exact outgoing TigerBeetle command. Retries then replay the
same semantic operation instead of generating another set of transfers. A plan
or dispatch marker written before sending can preserve recovery information, but
its existence alone does not cause an unsent message to be delivered: queue
redelivery, an outbox/stream path, or another recovery mechanism must be specified.

Each confirmation now supplies one class and one pending transfer ID. The former
requirement to prove completeness and common origin of a multiclass map no longer
applies, so it does not justify a membership index or map fingerprint. The design
still must establish trusted tenant/event context, validate that the pending
transfer targets the expected event/class, and decide whether a durable reservation
record is needed for ownership beyond explicit native account/ledger checks. If
such a record is chosen, an eventually consistent GSI can temporarily miss a
just-created reservation. Addressing, authorization, retention, and replay remain
open decisions; generated-ID correlation is required independently of group membership.

## Event readiness and Operation completion alternatives

**Atomic DynamoDB finalization.** Once the TigerBeetle result is verified against
the durable plan, transact the event's terminal metadata/readiness update and the
Operation's conditional completion, optionally recording the accepted completion
identity. A retry after uncertain success reads the persisted outcome. Conditions
must distinguish a matching replay from a conflicting terminal result. This
cannot undo TigerBeetle work if the final DynamoDB transaction fails; recovery must
retain enough evidence to retry it.

**Recoverable separate updates.** Persist verified event metadata/readiness and
completion evidence first, then complete the Operation conditionally. A retry can
resume the second update using that evidence. This exposes a period in which the
event is ready while its Operation remains submitted. Reversing the order instead
exposes a completed Operation whose event is not ready. Either order needs an
explicit observation/recovery contract and retention sufficient to finish.

Tenant-scoped primary keys must be built from the trusted Operation tenant plus
the event identity, not only from a client-supplied event UUID. Global allocator
items need a disjoint key category. The user has chosen shared physical storage;
the exact key encoding, authorization conditions, and cache key remain design
work. Caching immutable ready event metadata is compatible with strong initial
reads; caching a pending or missing event indefinitely is not a valid readiness
mechanism.

## Repository and pinned SDK observations

These are static observations, not executed transaction validation. The later
implementation prerequisite
[Validate SDK transaction composition with a local persistence harness](../../.scratch/seat-reservation/issues/100-validate-sdk-transactions.md)
requires the pinned SDK to combine the two real persistence modules' updates and
pass local execution tests before the completion processor relies on them.

The baseline inspected is the research worktree branched from the repository;
no implementation was changed. These observations come from local source, not
from assumed SDK behavior:

- [Operation persistence](../../src/operation_persistence.zig) offers `create`,
  strong `read`, conditional `update`, `complete`, and `completeById`, with a
  fixed item contract keyed by Operation UUID. It deliberately omits the request
  body from persisted items. It has no event, allocation, immutable-plan,
  reservation, outbox, or multi-item transaction boundary.
- `complete` checks queued identity and submitted state; `completeById` conditions
  only on submitted state. The [existing completion processor](../../src/tiger_beetle_completion_processor.zig)
  calls the latter. Seat Reservation needs a defined correlation/validation path
  before it can safely extend this behavior to event and reservation metadata.
- [Operation constants](../../src/operation.zig) limit input bodies to 4096 bytes
  and serialized completion results to 98,304 bytes. Operation TTL is 86,400
  seconds and updates refresh its timestamps. Durable event/allocation/reservation
  retention cannot be inferred from this transient Operation lifetime.
- [build.zig.zon](../../build.zig.zon) pins `aws-sdk-zig` commit
  `778dcfe1423cf3b3a1bfe56e1e461b99b80124bd`, cache package
  `aws_sdk-0.0.1-ApQSL17Y_xOC5IhLm247KBZKDcbCRU3qf7GiiiRHcrND`. Its cached archive
  was inspected directly. The generated DynamoDB client exposes
  `transactWriteItems`; inputs support `client_request_token` and
  `transact_items`; each action supports conditional `Put`/`Update`/`Delete` or
  `ConditionCheck`. Transactional updates expose failure return values, not
  successful updated attributes. The SDK therefore has the request interfaces
  needed for these options without establishing their application contract.
- Pinned SDK `service/dynamodb/errors.zig` models transaction cancellation reasons,
  conflict, in-progress, and token-mismatch errors. The transaction operation
  parses modeled service errors through a diagnostic output; callers must handle
  those outcomes and owned diagnostic memory. Presence of types is not proof
  that every failure path is correctly integrated or tested here.
- Pinned SDK `src/http.zig` has configurable retry attempts and backoff, and the
  generated transaction operation calls `sendRequestWithOptions`. Do not assume
  one application call means one HTTP attempt, especially for non-idempotent
  counters. Retry behavior was inspected statically, not exercised.

SDK source references at the pinned revision:
[transaction request](https://github.com/ikolomiets/aws-sdk-zig/blob/778dcfe1423cf3b3a1bfe56e1e461b99b80124bd/service/dynamodb/transact_write_items.zig),
[transaction action](https://github.com/ikolomiets/aws-sdk-zig/blob/778dcfe1423cf3b3a1bfe56e1e461b99b80124bd/service/dynamodb/transact_write_item.zig),
[transaction update](https://github.com/ikolomiets/aws-sdk-zig/blob/778dcfe1423cf3b3a1bfe56e1e461b99b80124bd/service/dynamodb/update.zig),
[errors](https://github.com/ikolomiets/aws-sdk-zig/blob/778dcfe1423cf3b3a1bfe56e1e461b99b80124bd/service/dynamodb/errors.zig),
[HTTP retries](https://github.com/ikolomiets/aws-sdk-zig/blob/778dcfe1423cf3b3a1bfe56e1e461b99b80124bd/src/http.zig).

## Decisions this evidence enables

Choose gap-tolerant allocation or transactional candidate allocation; define the
immutable plan and dispatch recovery contract; define tenant/event/reservation
keys and single-transfer ownership checks; choose atomic or recoverable finalization; specify
retention and stale-message handling independent of Operation TTL; and define
namespace ownership, exhaustion, and restore recovery. These are decision tickets,
not policies selected by this research.

Validation consists of primary-source review and static inspection. No AWS calls,
builds, live tests, commits, or production changes were made.
