# Seat reservation: native accounting and reservation constraints

Research date: 2026-09-25. This note resolves the factual investigation **Verify native seat accounting and reservation constraints**. It does not select the remaining application policies or implement the processors.

## Evidence boundary

The repository pins TigerBeetle C artifacts based on commit `97c7a8ef385270ebe0e1b75959d3d21d134629df`, with the two client patches identified in [build.zig.zon](../../build.zig.zon) and the [wrapper build boundary](../ZIG_WRAPPER_FOR_TIGERBEETLE.md#build-boundary). The bundled official documentation snapshot uses that same base commit; its files are under `/Users/igork/.codex/skills/tigerbeetle-docs/references/tigerbeetle-docs/`. References below labelled **pinned** point to the upstream source pages at this immutable commit. Current official documentation was also checked on the research date. The cited current pages agree on the behaviors used here; this is not evidence that a deployed server matches the pin. No build, live replica, or cloud validation was performed.

The application API is defined by the [processor contract](../TIGER_BEETLE_PROCESSOR.md) and checked against `validate_field`, `construct_command`, `plan_body`, and `classify_chain` in [the processor implementation](../../src/tiger_beetle_processor.zig), plus `creation_success` in [the completion implementation](../../src/tiger_beetle_completion_processor.zig).

User decisions already supplied to the map are: an implementation-ready design as the destination; account codes Capacity=3, Availability=1, Allocation=2; reservation of exactly one specified seat class per request; full confirmation of one pending transfer for one specified class; and shared event storage using tenant-scoped keys. These are inputs, not findings of this investigation.

## Account model and funding

Native account codes are nonzero u16 categories; ledger identifiers are nonzero u32 values. All accounts start with zero balance counters. The debit bound rejects any transfer that would make `debits_posted + debits_pending` exceed `credits_posted`. The opposite bound limits credits against posted debits; both bounds cannot be set together. The accepted 3/1/2 account codes are valid. [Pinned Account: ledger, code and flags](https://github.com/tigerbeetle/tigerbeetle/blob/97c7a8ef385270ebe0e1b75959d3d21d134629df/docs/reference/account.md); [current Account](https://docs.tigerbeetle.com/reference/account/).

For the proposed directions, Availability requires `debits_must_not_exceed_credits` to prevent overselling. Capacity supplies initial debits from zero, so that bound would prevent funding; Allocation receives initial credits from zero, so `credits_must_not_exceed_debits` would prevent reservations. Unbounded Capacity and Allocation support the stated flow; the opposite directional bound on either is compatible but is an additional design choice. No account flag directly caps total event funding at the configured number. Exact one-time funding and restricting other writers are application obligations. This follows from the native inequalities and [processor flags validation](../TIGER_BEETLE_PROCESSOR.md#body-schema).

With one immediate Capacity-to-Availability transfer per class, initial Availability `credits_posted` equals configured seats. Reservations increase its pending debits; posting moves those pending debits into posted debits; expiry eventually releases pending debits. Therefore, assuming no replenishment or unrelated writes:

```text
total seats     = credits_posted
available seats = credits_posted - debits_posted - debits_pending
```

Allocation accumulates all classes' reserved and posted credits; its aggregate balance cannot identify individual reservations. Capacity's posted debits equal the sum of initial funding. These are accounting deductions from the proposed flow and [pinned Two-Phase Transfers: reserve/resolve funds](https://github.com/tigerbeetle/tigerbeetle/blob/97c7a8ef385270ebe0e1b75959d3d21d134629df/docs/coding/two-phase-transfers.md).

Transfer codes are a separate nonzero u16 classification for immediate and pending transfers. They need not equal account codes. A posting may inherit the pending transfer's code through zero/omission, or supply that exact nonzero code. Selecting funding/reservation transfer codes remains a design decision. The same event ledger must appear on the transfer and both accounts. [Pinned Transfer: ledger and code](https://github.com/tigerbeetle/tigerbeetle/blob/97c7a8ef385270ebe0e1b75959d3d21d134629df/docs/reference/transfer.md); [processor Body schema](../TIGER_BEETLE_PROCESSOR.md#body-schema).

## Atomic chains, replay, and initialization

Native linked events execute in order and succeed or roll back together. The last member terminates the chain. Linkage is not retained as a queryable reservation grouping. [Pinned Linked Events](https://github.com/tigerbeetle/tigerbeetle/blob/97c7a8ef385270ebe0e1b75959d3d21d134629df/docs/coding/linked-events.md); [current Linked Events](https://docs.tigerbeetle.com/coding/linked-events/).

The existing processor constructs one linked chain for each nonempty creation list, clearing the linked flag for a singleton. Under the current requirement, reserve_seats submits one pending transfer and confirm_seats submits one full-post transfer. An expired, mismatched, or previously resolved pending transfer can reject that posting attempt; it does not alter another reservation. Linked chains remain relevant to multiclass event account creation and initial funding. [Processor execution phases](../TIGER_BEETLE_PROCESSOR.md#execution-phases-and-linked-chain-replay); [pinned create_transfers: pending lifecycle errors](https://github.com/tigerbeetle/tigerbeetle/blob/97c7a8ef385270ebe0e1b75959d3d21d134629df/docs/reference/requests/create_transfers.md).

Account creation and funding are separate native requests and separate chains. A successful account chain can survive funding failure. There is no atomic transaction spanning DynamoDB, SQS, both native families, and Operation completion. Event readiness and recovery from partially completed initialization remain application design decisions. [Processor execution phases](../TIGER_BEETLE_PROCESSOR.md#execution-phases-and-linked-chain-replay).

Every resource creation must retain its ID, complete ordered chain, and original native inputs across retries. A regenerated ID can repeat a funding or reservation effect. Retrying a subset, reordering, or changing a chain also violates the existing processor contract. Its accepted replay signature is `exists` on the first member and `linked_event_failed` on the rest, or singleton `exists`; these raw statuses do not mean business failure. That signature is sound only under the stable-chain obligation across all writers. Persistent generated plans or reproducible IDs/order need a separate decision. [Processor replay contract](../TIGER_BEETLE_PROCESSOR.md#execution-phases-and-linked-chain-replay); [completion interpreter](../../src/tiger_beetle_completion_processor.zig).

A new business attempt after a definitive rejection differs from transport redelivery. Native `id_already_failed` can record a prior state-dependent failure, such as insufficient credits; repeating the same ID cannot be treated as a fresh attempt after inventory changes. The processor deliberately preserves IDs and does not manufacture the original rejection after retries. [Pinned create_transfers: id_already_failed](https://github.com/tigerbeetle/tigerbeetle/blob/97c7a8ef385270ebe0e1b75959d3d21d134629df/docs/reference/requests/create_transfers.md); [processor recovery](../TIGER_BEETLE_PROCESSOR.md#recovery-and-operating-assumptions).

## Expiration and full confirmation

The reservation timeout starts when the native pending transfer reaches the cluster, not when public intake accepts the Operation. It is an interval in seconds. Expiration is exact for resolution eligibility, but removing expired pending balances is best effort; reads may temporarily show expired holds. The processor requires a positive u32 timeout and retains the original interval on replay. Replaying an expired pending creation can succeed without renewing it. [Pinned Transfer: timeout](https://github.com/tigerbeetle/tigerbeetle/blob/97c7a8ef385270ebe0e1b75959d3d21d134629df/docs/reference/transfer.md); [current Transfer: timeout](https://docs.tigerbeetle.com/reference/transfer/#timeout); [processor recovery](../TIGER_BEETLE_PROCESSOR.md#recovery-and-operating-assumptions).

Confirmation needs a new resolution transfer ID, the pending ID, required flags, and an explicit amount. The full-post sentinel is the decimal string `340282366920938463463374607431768211455` (`2^128-1`). Zero posts zero under this pin; it is not full confirmation. A smaller amount posts only that amount and releases the remainder. Each pending transfer resolves at most once. A first resolution after expiry fails, while stable replay can recognize a resolution that already committed. [Pinned Two-Phase Transfers: Post-Pending Transfer and Errors](https://github.com/tigerbeetle/tigerbeetle/blob/97c7a8ef385270ebe0e1b75959d3d21d134629df/docs/coding/two-phase-transfers.md); [current Two-Phase Transfers](https://docs.tigerbeetle.com/coding/two-phase-transfers/); [processor Body schema](../TIGER_BEETLE_PROCESSOR.md#body-schema).

## What a supplied pending ID proves

Posting can explicitly provide the event/class Availability ID as `debit_account_id`, event Allocation ID as `credit_account_id`, and event `ledger`. Native validation requires these nonzero values to match the original pending transfer. A nonzero `code` can also require the intended reservation transfer category. Omitted or zero fields simply inherit, so an ID-only post provides no explicit event/class check. [Pinned create_transfers: pending_transfer_has_different_*](https://github.com/tigerbeetle/tigerbeetle/blob/97c7a8ef385270ebe0e1b75959d3d21d134629df/docs/reference/requests/create_transfers.md); [current create_transfers](https://docs.tigerbeetle.com/reference/requests/create_transfers/).

These checks prove that the referenced pending transfer uses the expected accounts and ledger. They do not authenticate the caller or independently enforce tenant ownership. Under the single-class requirement, there is no submitted group whose completeness or common reservation origin must be proven. A confirmation resolves the full amount of the one supplied pending transfer.

The existing processor supports account lookups but no transfer lookup and rejects user-data input; aliases are response labels rather than native identity. The design must still obtain trusted tenant/event context and decide whether explicit native field matching plus event authorization suffices or a durable reservation record is needed for ownership. Durable generated-ID correlation and replay remain separate requirements. The earlier multiclass membership argument does not by itself require such a record under the revised scope. [Processor framework boundary and Body schema](../TIGER_BEETLE_PROCESSOR.md#framework-boundary).

## Lookup observations and limits

Account lookup supplies a balance observation, not a promise that the next reservation succeeds. Native balance bounds must arbitrate concurrent reservations. An individual lookup batch can observe the requested accounts together; multiple native lookup calls can interleave other work. In the current processor's admitted size, a single event check fits one native request. Nevertheless, retries can yield different observations and the persisted completion reflects the attempt whose completion wins; it is not a snapshot of the earlier writes or intake time. [Pinned lookup_accounts](https://github.com/tigerbeetle/tigerbeetle/blob/97c7a8ef385270ebe0e1b75959d3d21d134629df/docs/reference/requests/lookup_accounts.md); [current lookup_accounts](https://docs.tigerbeetle.com/reference/requests/lookup_accounts/); [processor recovery](../TIGER_BEETLE_PROCESSOR.md#recovery-and-operating-assumptions).

Lookup results can be sparse and unordered. The processor correlates by ID and restores original positions/aliases; missing accounts produce a failure diagnostic. Account data and an alias are returned for found lookups, while creation results contain statuses and aliases without generated IDs. The Seat completion design must retain its own generated account/transfer mapping; it cannot reconstruct generated IDs from create results alone. [Processor Result contract](../TIGER_BEETLE_PROCESSOR.md#execution-phases-and-linked-chain-replay).

Derived ceilings under the current processor, not yet selected public validation policy:

| Constraint | Consequence |
| --- | --- |
| 64 total commands across all families | `create_event` with N classes and both account creation and funding uses `(N+2)+N=2N+2`; at most 31 classes in that one Body. Extra lookups reduce this ceiling. |
| Alias length 1–64 decoded UTF-8 bytes | Longest requested prefix `available-` occupies 10 bytes, giving a maximum 54-byte class tag if used unchanged. The reserved tags and a narrower grammar still need application validation. |
| Public Body limit 4,096 bytes | Class count alone does not establish admission; event class maps and the single-class reserve/confirm fields must fit intake. |
| Internal Body limit 96 KiB | Generated native requests can exceed the public limit but must remain within internal admission and the 64-command cap. |
| Result complete-envelope limit 96 KiB | Completion must fit its stored result and retain enough context elsewhere to interpret it. |
| Nonzero u32 ledger, nonzero u16 code | Ledger allocation must detect exhaustion and avoid collision with every other writer in the cluster's ledger namespace. |
| IDs 1 through `2^128-2`, decimal strings | IDs are cluster-wide within each resource kind, not isolated by event ledger. |
| u128 amounts | Domain seat limits and safe sums remain explicit design choices; the processor does not supply a smaller business seat cap. |

Sources: [processor Body schema and admission](../TIGER_BEETLE_PROCESSOR.md#body-schema), [processor admission constants](../../src/tiger_beetle_processor.zig), and [pinned Account](https://github.com/tigerbeetle/tigerbeetle/blob/97c7a8ef385270ebe0e1b75959d3d21d134629df/docs/reference/account.md).

The research leaves application decisions about pending-transfer ownership, durable plans and IDs, event readiness/recovery, ledger allocation coordination, class/quantity bounds, transfer codes, and externally described timeout/replay semantics to their decision tickets.
