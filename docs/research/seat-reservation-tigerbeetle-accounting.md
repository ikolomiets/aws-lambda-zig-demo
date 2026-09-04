# Validate TigerBeetle Seat-Capacity Accounting

## Conclusion

The proposed topology is sound if seat capacity is modeled as a **credit balance on each Seat
Section**:

1. post initial capacity by debiting the Event's Seat Supply Account and crediting the Seat Section;
2. reserve seats with a timed pending transfer that debits the Seat Section and credits the Event's
   Seats Reserved Account; and
3. confirm the whole hold with a post-pending transfer that references the reserve transfer.

The Seat Section must have `debits_must_not_exceed_credits`. TigerBeetle then rejects a reserve of
`q` unless:

```text
section.debits_pending + section.debits_posted + q <= section.credits_posted
```

This is the required no-oversell invariant, and TigerBeetle applies it when the pending transfer is
created rather than deferring it until confirmation. [TB `docs/reference/account.md`,
§ `flags.debits_must_not_exceed_credits`; TB `docs/coding/two-phase-transfers.md`,
§ `Interaction with Account Invariants`]

The topology is conditional on globally unique account IDs, distinct reserve and confirm Operation
IDs, stable transfer fields on retry, and ordering confirmation after the reserve is known to have
been accepted. It does **not** provide a bounded expiry-cleanup delay, a notification when a hold
expires, or a guarantee that an `exists` response for a retried reserve still represents a live
hold. Those are application-visible hazards, not details that can be hidden in the adapter.

This note labels statements as **Fact**, **Recommendation**, or **Hazard**. TigerBeetle citations
are paths relative to the bundled `tigerbeetle-docs` corpus. Repository citations name the current
path and symbol or section.

## Fixed topology and identifier fit

**Fact.** A TigerBeetle ledger is not a separate stored object. It is a nonzero `u32` value on each
account and transfer, and only accounts with the same ledger can transact directly. Therefore, “one
ledger per Event” provides direct-transfer isolation, but Event metadata and the mapping from
sections to an Event remain control-plane data. [TB `docs/coding/data-modeling.md`,
§ `Accounts, Transfers, and Ledgers`; TB `docs/reference/account.md`, § `ledger`; TB
`docs/reference/transfer.md`, § `ledger`]

**Fact.** The repository's current Event definition assigns globally unique, monotonically
allocated Event IDs from `1000` through `2^32 - 1`, so `Event.id == ledger` satisfies TigerBeetle's
nonzero-`u32` ledger constraint. The current runtime `Operation` model is different: its ID is a
`u128` parsed from a canonical UUID string. [Repo `CONTEXT.md`, `Event ID`; repo
`src/operation.zig`, `Operation`, `uuidFromString`, and `uuidToString`]

**Hazard.** Account IDs and transfer IDs are cluster-global, not ledger-local. Supply, reserved, and
section account IDs must therefore incorporate a globally unique discriminator; repeating local
account ID `1` on every Event would collide even though the ledgers differ. Accounts and transfers
have separate namespaces and technically may share an ID, but TigerBeetle advises against doing so.
[TB `docs/reference/account.md`, § `id`; TB `docs/reference/transfer.md`, § `id`; TB
`docs/coding/data-modeling.md`, § `id`]

**Hazard.** TigerBeetle rejects account and transfer IDs `0` and `2^128 - 1`. The repository's UUID
parser currently accepts every syntactically canonical 128-bit UUID, including those two values;
`validateView` does not add TigerBeetle ID constraints. Reserve and confirm ingestion must reject
the two reserved values before execution. [TB `docs/reference/account.md`, § `id`; TB
`docs/reference/transfer.md`, § `id`; repo `src/operation.zig`, `uuidFromString` and
`validateView`]

**Recommendation.** The canonical-UUID representation is compatible with the `u128` transfer ID
field, but the repository does not require UUIDs to follow TigerBeetle's time-based, increasing ID
scheme. This is not a correctness contradiction; it is a throughput/locality consideration. Keep
the current representation if external idempotency requires it, while ensuring the actual ID
generator avoids random/unordered IDs where practical. [TB `docs/coding/data-modeling.md`,
§ `TigerBeetle Time-Based Identifiers (Recommended)`; repo `src/operation.zig`, `uuidFromString`]

**Recommendation.** Reserve and confirm must have distinct Operation IDs. Use the reserve Operation
ID as the pending transfer's `id`, and use the confirm Operation ID as the post-pending transfer's
`id` while setting `pending_id` to the reserve Operation ID. A resolver's `id` must be unique and
different from `pending_id`. [TB `docs/coding/two-phase-transfers.md`, § `All Transfers Are
Immutable`; TB `docs/reference/requests/create_transfers.md`, § `pending_id_must_be_different`]

## Accounts and exact flags

All accounts start with the four balance counters, `reserved`, and `timestamp` set to zero; have a
globally unique nonzero/non-max `id`; use `ledger = Event.id`; and use a nonzero, stable account
`code`. Account balances cannot be seeded in `create_accounts`; only transfers change them. [TB
`docs/reference/account.md`, §§ `id`, `debits_pending`, `debits_posted`, `credits_pending`,
`credits_posted`, `reserved`, `ledger`, `code`, and `timestamp`; TB
`docs/reference/requests/create_accounts.md`, §§ `debits_pending_must_be_zero` through
`credits_posted_must_be_zero`]

The selected base flags are:

| Account | Base flags | Requirement and rationale |
| --- | --- | --- |
| Seat Supply | `credits_must_not_exceed_debits` (`TB_ACCOUNT_CREDITS_MUST_NOT_EXCEED_DEBITS`, `1 << 2`) | **Recommended**, not necessary for the fixed one-way flow. Initial capacity debits Supply, so this preserves a nonnegative debit balance if a future transfer ever credits it. `debits_must_not_exceed_credits` must not be used because the first initial-capacity debit would exceed zero credits. [TB `docs/coding/data-modeling.md`, § `Debit Balances`; TB `docs/reference/account.md`, §§ `flags.credits_must_not_exceed_debits` and `flags.debits_must_not_exceed_credits`] |
| Seat Section | `debits_must_not_exceed_credits` (`TB_ACCOUNT_DEBITS_MUST_NOT_EXCEED_CREDITS`, `1 << 1`) | **Required for capacity safety.** Initial capacity credits the section; holds debit it. The check includes both pending and posted debits. [TB `docs/reference/account.md`, § `flags.debits_must_not_exceed_credits`] |
| Seats Reserved | `debits_must_not_exceed_credits` (`TB_ACCOUNT_DEBITS_MUST_NOT_EXCEED_CREDITS`, `1 << 1`) | **Recommended**, not necessary while the account is only credited. It gives the aggregate destination a nonnegative credit balance if future flows ever debit it. `credits_must_not_exceed_debits` must not be used because the first reservation credit would exceed zero debits. [TB `docs/coding/data-modeling.md`, § `Credit Balances`; TB `docs/reference/account.md`, §§ `flags.debits_must_not_exceed_credits` and `flags.credits_must_not_exceed_debits`] |

The symbolic names and bit positions above are verified against the repository's pinned generated C
API header. Use those symbols through the translated C import rather than copying numeric values
into production code. [Repo
`zig-pkg/tigerbeetle_c_artifacts-65535.0.0+g97c7a8ef3.pr3695-fTLGi0aNGQC3xlGJoqTt6DVm9fZPGoBrSKcdqoZZgjNd/include/tb_client.h`,
`TB_ACCOUNT_FLAGS`]

`history` may be ORed into any base flag set only if historical balance queries are required; those
queries work only for accounts created with `history`. The two balance-bound flags are mutually
exclusive. `linked` is added only to nonterminal events in a linked account-creation request; it is
not part of the role's balance semantics. [TB `docs/reference/account.md`, §§ `flags.history` and
`flags.linked`; TB `docs/reference/requests/create_accounts.md`, § `flags_are_mutually_exclusive`]

For the strictly fixed flow, `flags = 0` on Supply and Seats Reserved would also function. The
critical bit is `debits_must_not_exceed_credits` on every Seat Section. Choosing the recommended
base flags above makes the intended debit/credit type explicit without changing reserve or confirm
behavior.

## Exact transfer shapes

The following shapes assume zeroed structs before the listed fields are assigned. `code` values are
application-defined nonzero enums; distinct codes for initial capacity and reserve are recommended
for audit/query meaning. All non-imported transfers send `timestamp = 0`. [TB
`docs/reference/transfer.md`, §§ `code`, `timestamp`, and `flags`; TB
`docs/coding/data-modeling.md`, § `code`]

### Initial capacity: one posted transfer per section

| Field | Value |
| --- | --- |
| `id` | A stable, globally unique, persisted/deterministic initial-capacity transfer ID for this Event and section |
| `debit_account_id` | Event Seat Supply Account ID |
| `credit_account_id` | Seat Section Account ID |
| `amount` | The section's capacity as a positive `u128` seat count |
| `pending_id` | `0` |
| `timeout` | `0` |
| `ledger` | `Event.id` |
| `code` | Nonzero initial-capacity transfer code |
| `flags` | `0`, except OR `linked` (`TB_TRANSFER_LINKED`, `1 << 0`) on every transfer except the final one when all section allocations must be atomic |
| `user_data_*` | `0` or stable application metadata; never recomputed differently on retry |
| `timestamp` | `0` |

This posted transfer increments `supply.debits_posted` and `section.credits_posted` by the capacity.
A transfer always debits one account and credits one account on the same ledger. [TB
`docs/reference/transfer.md`, opening description and §§ `debit_account_id`, `credit_account_id`,
and `amount`; TB `docs/coding/data-modeling.md`, § `Compound Transfers`]

Cross-Event or otherwise miswired accounts are rejected by
`accounts_must_have_the_same_ledger`; a nonzero transfer ledger that disagrees with its accounts is
rejected by `transfer_must_have_the_same_ledger_as_accounts`. Missing endpoints produce the
transient `debit_account_not_found` or `credit_account_not_found` outcomes. [TB
`docs/reference/requests/create_transfers.md`, corresponding status headings]

**Hazard.** A new transfer ID is a new capacity grant. Re-running initialization with newly
generated IDs credits the section again and can oversell the Event. Linked events do not make
different-ID replays idempotent. Persist or deterministically derive exactly one initialization ID
per Event/section and treat `created` and exact `exists` as success. [TB
`docs/coding/data-modeling.md`, § `id`; TB `docs/coding/reliable-transaction-submission.md`,
§ `Handling Network Failures`]

### Reserve: timed pending section-to-reserved transfer

| Field | Value |
| --- | --- |
| `id` | Reserve Operation ID |
| `debit_account_id` | Selected Seat Section Account ID |
| `credit_account_id` | Event Seats Reserved Account ID |
| `amount` | Requested seat quantity `q`, application-validated as greater than zero |
| `pending_id` | `0` |
| `timeout` | Stable nonzero hold duration in whole seconds |
| `ledger` | `Event.id` |
| `code` | Nonzero reserve transfer code |
| `flags` | Exactly `pending` (`TB_TRANSFER_PENDING`, `1 << 1`) |
| `user_data_*` | `0` or stable reservation/Event metadata |
| `timestamp` | `0` |

`q > 0` is an application rule, not a current TigerBeetle constraint: clients at or after `0.16.0`
allow zero-amount transfers. A zero reserve would consume no capacity and should be rejected before
submission. [TB `docs/coding/api-changes.md`, § `0.16.0` / `Zero-amount transfers`]

On success, TigerBeetle adds `q` to `section.debits_pending` and
`reserved.credits_pending`, leaves posted counters unchanged, and reserves that capacity until the
pending transfer posts, voids, or expires. [TB `docs/coding/two-phase-transfers.md`, § `Reserve Funds
(Pending Transfer)`; TB `docs/reference/account.md`, §§ `debits_pending` and `credits_pending`]

### Confirm: post the full pending transfer

| Field | Value |
| --- | --- |
| `id` | Confirm Operation ID, distinct from the Reserve Operation ID |
| `debit_account_id` | `0` (inherit from pending transfer) |
| `credit_account_id` | `0` (inherit from pending transfer) |
| `amount` | `AMOUNT_MAX` (`2^128 - 1`) to post the entire held quantity |
| `pending_id` | Reserve Operation ID |
| `timeout` | `0` |
| `ledger` | `0` (inherit from pending transfer) |
| `code` | `0` (inherit from pending transfer) |
| `flags` | Exactly `post_pending_transfer` (`TB_TRANSFER_POST_PENDING_TRANSFER`, `1 << 2`) |
| `user_data_*` | `0` (inherit from pending transfer) or exact matching values |
| `timestamp` | `0` |

For a post/void transfer, zero account IDs, ledger, code, and user-data values are filled from the
pending transfer; nonzero values must match. A post requires nonzero `pending_id`; its `timeout` must
be zero; and `pending`, `post_pending_transfer`, and `void_pending_transfer` are mutually exclusive.
[TB `docs/reference/transfer.md`, §§ `debit_account_id`, `credit_account_id`, `pending_id`,
`user_data_128`, `user_data_64`, `user_data_32`, `timeout`, `ledger`, `code`, and `flags`; TB
`docs/reference/requests/create_transfers.md`, § `flags_are_mutually_exclusive`]

`AMOUNT_MAX` is the unambiguous full-post sentinel for clients at or after `0.16.0`. Do not send
`amount = 0`: that posts zero and releases the entire remainder. Sending the original quantity is
also valid, but an accidentally smaller value performs a partial post and releases the remainder,
which violates the fixed “confirm the whole reservation” meaning. [TB
`docs/reference/transfer.md`, § `amount`; TB `docs/coding/two-phase-transfers.md`, § `Post-Pending
Transfer`; TB `docs/coding/api-changes.md`, § `0.16.0` / `Zero-amount transfers`]

On a full post, TigerBeetle removes `q` from the two pending counters and adds `q` to
`section.debits_posted` and `reserved.credits_posted`. The pending record is not modified; the post
is a second immutable transfer. [TB `docs/coding/two-phase-transfers.md`, §§ `Post Full Pending
Amount` and `All Transfers Are Immutable`; TB `docs/reference/transfer.md`, § `Updates`]

The useful section availability expression is therefore:

```text
available = credits_posted - debits_posted - debits_pending
```

The section flag guarantees that this value is nonnegative for accepted transfers. The Seats
Reserved Account separately aggregates live pending quantities in `credits_pending` and confirmed
quantities in `credits_posted`. [TB `docs/reference/account.md`, §§ `debits_pending`,
`debits_posted`, `credits_pending`, `credits_posted`, and
`flags.debits_must_not_exceed_credits`]

## Timeout and expiry behavior

**Fact.** `timeout` is a `u32` interval in seconds measured from the pending transfer's
TigerBeetle-assigned cluster `timestamp`; zero means no timeout. Expiry is exactly
`timestamp + timeout * 1_000_000_000`, and `overflows_timeout` rejects an unrepresentable expiry.
The interval begins when the reserve arrives at the cluster, not when the application accepts or
queues the Operation. [TB `docs/reference/transfer.md`, §§ `timeout` and `timestamp`; TB
`docs/reference/requests/create_transfers.md`, § `overflows_timeout`]

**Fact.** The pending balance is never removed before expiry, and an expired transfer cannot be
posted or manually voided. Automatic pending-balance removal is best effort and is not guaranteed at
the expiry instant; reads may still observe expired pending balances. The documentation provides no
maximum cleanup lag. [TB `docs/reference/transfer.md`, § `timeout`]

**Consequence.** Confirmation racing the expiry has a deterministic TigerBeetle outcome: the post
is either created before expiry or rejected with `pending_transfer_expired`. However, expired
pending counters may conservatively suppress later availability until cleanup catches up. A counter
read is not a reliable “hold is live” test at or just after expiry. [TB
`docs/reference/transfer.md`, §§ `Guarantees` and `timeout`; TB
`docs/reference/requests/create_transfers.md`, § `pending_transfer_expired`]

**Hazard.** With no void/cancel operation, expiry is the only way to release an abandoned hold. A
reserve accidentally created with `timeout = 0` can retain capacity indefinitely. Automatic expiry
also does not create a historical-balance change, so even an account with `history` does not receive
a balance-history entry for timeout cleanup. [TB `docs/coding/two-phase-transfers.md`, § `Expire
Pending Transfer`; TB `docs/reference/requests/get_account_balances.md`, opening notes]

**Hazard.** TigerBeetle client requests never time out and retry until reply or client termination.
A delayed reserve begins its hold only when it eventually reaches the cluster, and a reply can be
observed after much of—or all of—the hold interval has elapsed. Application/Lambda timeouts cannot
prove non-execution. [TB `docs/reference/sessions.md`, § `Retries`; TB `docs/coding/requests.md`,
§ `Guarantees`]

## Retry, idempotency, and exact outcomes

### Successful duplicates

`created` means the object was newly created. `exists` means the same ID already names an object
whose compared fields match, and reliable submission should generally treat `exists` like
`created`. The repository wrapper does exactly that in `create_account_succeeded` and
`create_transfer_succeeded`; execution otherwise retains the raw `u32` result as a rejection.
[TB `docs/reference/requests/create_accounts.md`, §§ `created` and `exists`; TB
`docs/reference/requests/create_transfers.md`, §§ `created` and `exists`; repo
`src/tigerbeetle.zig`, `create_account_succeeded` and `create_transfer_succeeded`; repo
`src/execution_lambda.zig`, `RuntimeResources.createAccount` and
`RuntimeResources.createTransfer`]

Every retry must reuse the exact canonical object fields. Relevant account collision results are
`exists_with_different_flags`, `exists_with_different_user_data_128`,
`exists_with_different_user_data_64`, `exists_with_different_user_data_32`,
`exists_with_different_ledger`, and `exists_with_different_code`. Relevant transfer collision
results are those same suffixes plus `exists_with_different_pending_id`,
`exists_with_different_timeout`, `exists_with_different_debit_account_id`,
`exists_with_different_credit_account_id`, and `exists_with_different_amount`. [TB
`docs/reference/requests/create_accounts.md`, status headings from
`exists_with_different_flags` through `exists`; TB
`docs/reference/requests/create_transfers.md`, status headings from
`exists_with_different_flags` through `exists`]

For a reserve, this means never recomputing a remaining timeout on retry: resend the original
timeout interval. For a confirm, resend the same `pending_id`, flags, and amount sentinel. The
post-pending `exists` comparison has special amount normalization, but depending on it would hide
input drift; exact retry fields remain the safer application invariant. [TB
`docs/reference/requests/create_transfers.md`, §§ `exists_with_different_timeout` and `exists`]

### Transient failures permanently consume a transfer ID

The documented transient set is:

- `debit_account_not_found`
- `credit_account_not_found`
- `pending_transfer_not_found`
- `exceeds_credits`
- `exceeds_debits`
- `debit_account_already_closed`
- `credit_account_already_closed`

After any of these outcomes, retrying that transfer ID returns `id_already_failed`; it cannot later
succeed even if database state changes. A genuinely new attempt must use a new idempotency ID. This
guarantee is documented for client behavior at or after `0.16.4`. [TB
`docs/reference/requests/create_transfers.md`, § `id_already_failed`; TB
`docs/coding/api-changes.md`, § `0.16.4` / `Transient Failures`]

For reserve, ordinary insufficient capacity is `exceeds_credits` because the bounded Seat Section
is the debit account. That Reserve Operation is terminally rejected; a later attempt after capacity
changes must be a new Reserve Operation with a new ID. [TB
`docs/reference/requests/create_transfers.md`, § `exceeds_credits`]

**Critical allocation hazard.** The fixed `Reserve Operation ID == pending transfer ID` rule permits
only one selected-section attempt. If that attempt returns `exceeds_credits`, TigerBeetle records the
ID as failed and the same ID cannot later try another section. If the attempt succeeded, replaying
the ID with another section instead returns `exists_with_different_debit_account_id`. Therefore the
executor must choose one section before submitting the pending transfer; a stale availability read
can make that choice fail even while another eligible section still has capacity. Trying fallback
sections requires a new Operation/transfer ID or a redesigned allocation protocol. This conclusion
is an inference from the documented transient-ID and duplicate-field rules. [TB
`docs/reference/requests/create_transfers.md`, §§ `id_already_failed`, `exceeds_credits`, and
`exists_with_different_debit_account_id`]

**Critical ordering hazard.** If confirm is submitted before its reserve transfer exists, it gets
`pending_transfer_not_found`; the Confirm Operation ID is then permanently unusable and subsequent
retries return `id_already_failed`. The application must gate confirm execution on a definitively
accepted reserve or perform a safe preflight/orchestration step before consuming the confirm ID.
The current wrapper has no `lookupTransfers` method, only `lookupAccounts`, and the current generic
execution handler has no reserve-before-confirm business guard. [TB
`docs/reference/requests/create_transfers.md`, §§ `pending_transfer_not_found` and
`id_already_failed`; repo `src/tigerbeetle.zig`, `Client` public request methods; repo
`src/execution_lambda.zig`, `handleInvocation` and `executeOperation`]

### Pending-lifecycle outcomes

The result codes that must be classified explicitly are:

| Outcome | Meaning for this topology |
| --- | --- |
| `pending_transfer_not_found` | Reserve ID does not name a transfer; transient and poisons the confirm ID. |
| `pending_transfer_not_pending` | Reserve ID names a transfer without `pending`; permanent modeling/input error. |
| `pending_transfer_has_different_debit_account_id` | A nonzero confirm debit account disagrees with the reserve; avoid by inheriting with zero. |
| `pending_transfer_has_different_credit_account_id` | A nonzero confirm credit account disagrees with the reserve; avoid by inheriting with zero. |
| `pending_transfer_has_different_ledger` | A nonzero confirm ledger disagrees with the reserve; avoid by inheriting with zero. |
| `pending_transfer_has_different_code` | A nonzero confirm code disagrees with the reserve; avoid by inheriting with zero. |
| `exceeds_pending_transfer_amount` | Confirm amount is above the hold but below `AMOUNT_MAX`. |
| `pending_transfer_already_posted` | Another post transfer ID already resolved the hold. |
| `pending_transfer_already_voided` | A void transfer already resolved it, contradicting the fixed no-void topology. |
| `pending_transfer_expired` | Timeout passed before this post was applied. |

These meanings and names are the authoritative `create_transfers` statuses. The same reference also
defines shape errors `pending_id_must_be_zero`, `pending_id_must_not_be_zero`,
`pending_id_must_not_be_int_max`, `pending_id_must_be_different`,
`timeout_reserved_for_pending_transfer`, and `flags_are_mutually_exclusive`, all of which should be
treated as implementation defects rather than retryable capacity outcomes. [TB
`docs/reference/requests/create_transfers.md`, corresponding status headings]

An exact retry of an already-created confirm uses the same confirm ID and returns `exists`, not
`pending_transfer_already_posted`, because duplicate-ID checks precede semantic checks. The latter
therefore indicates resolution by a *different* transfer ID. This is an inference from the
documented result precedence and the `exists`/pending lifecycle definitions. [TB
`docs/reference/requests/create_transfers.md`, § `status`, § `exists`, and
§ `pending_transfer_already_posted`; TB `docs/coding/api-changes.md`, § `0.16.4` / `Transient
Failures`]

**Critical stale-success hazard.** A pending transfer remains an immutable transfer record after
expiry. Consequently, an exact reserve retry can return `exists` even when the hold can no longer
be confirmed. `exists` proves idempotent creation, not current hold liveness. This follows from
transfer immutability/deletion guarantees, expiry semantics, and duplicate-ID precedence. A reserve
Operation completed from a late `exists`/reply needs an application policy that prevents presenting
an already-expired hold as live. [TB `docs/reference/transfer.md`, §§ `Deletion`, `Guarantees`, and
`timeout`; TB `docs/reference/requests/create_transfers.md`, §§ `status` and `exists`]

The create result supplies the created transfer's cluster timestamp, or the original timestamp for
`exists`, so the application can persist the authoritative calculated expiry
`result.timestamp + timeout * 1_000_000_000`, with both terms expressed in nanoseconds. The current
`RuntimeResources.createTransfer` discards that timestamp and keeps only `status`; the seat workflow
should preserve it and stop advertising a hold after the calculated deadline. This mitigates stale
replies but does not turn local wall-clock checks into a TigerBeetle resolution result; the confirm
outcome remains authoritative. [TB
`docs/reference/requests/create_transfers.md`, § `timestamp`; TB `docs/coding/time.md`,
§ `Why TigerBeetle Manages Timestamps`; repo `src/execution_lambda.zig`,
`RuntimeResources.createTransfer`]

## Linked-event requirements

No linked flag is needed for reserve or confirm: each action is one transfer wholly within one Seat
Section, and the pending/post mechanism supplies the two-stage relationship. Linking reserve and
confirm is neither possible nor desirable because they are separate requests at different times.
[TB `docs/coding/two-phase-transfers.md`, opening workflow; TB `docs/coding/linked-events.md`,
opening paragraphs]

For Event provisioning, linked chains are optional but recommended if partial provisioning is not
acceptable:

1. create Supply, Reserved, and all Section accounts in one `create_accounts` batch, with `linked`
   on every account except the final account;
2. only after that batch is accepted, submit all initial-capacity transfers in one
   `create_transfers` batch, with `linked` on every transfer except the final transfer.

A linked chain succeeds or rolls back as a unit. The final event must omit `linked`; otherwise the
result is `linked_event_chain_open`. The first failing event receives its specific error and the
other chain members receive `linked_event_failed`. [TB `docs/coding/linked-events.md`, entire page;
TB `docs/reference/requests/create_accounts.md`, §§ `linked_event_failed` and
`linked_event_chain_open`; TB `docs/reference/requests/create_transfers.md`, same headings]

**Unavailable guarantee.** Account creation and initial transfers cannot be one atomic chain:
TigerBeetle requests contain events of one type and cannot mix accounts and transfers. There is an
unavoidable accepted-accounts-before-capacity gap. Idempotent provisioning and external lifecycle
state must make that gap recoverable. [TB `docs/coding/requests.md`, opening paragraphs and
§ `Guarantees`]

## Repository integration findings

The current execution integration implements a different proof-of-connection workflow. It creates
account `Operation.id` on fixed ledger/code `1`, then creates an immediate posted transfer with the
same ID from that account to operator-provisioned account `1` for amount `100`; all remaining fields,
including flags, `pending_id`, and `timeout`, are zero. It does not parse Event, section, reserve, or
confirm data. [Repo `src/execution_lambda.zig`, constants `accounting_ledger` through
`accounting_transfer_amount`, `executeOperation`, `accountingAccount`, and `accountingTransfer`]

Reusing an Operation ID for an account and transfer is accepted by TigerBeetle's separate ID
namespaces and is exercised by the repository integration test, but the seat design should use
role-derived account IDs and Operation-derived transfer IDs to avoid future cross-system namespace
ambiguity. [TB `docs/coding/data-modeling.md`, § `id`; repo
`tests/tigerbeetle_integration.zig`, `run_execution_accounting_workflow`]

The wrapper exports the raw C `Account`, `Transfer`, `CreateAccountResult`, and
`CreateTransferResult` types, plus create methods and created-or-exists predicates. It does not
currently expose named account/transfer flag constants, `AMOUNT_MAX`, named failure statuses, or
transfer lookup. Production seat accounting therefore needs a small wrapper extension for named
flags/statuses and any required lookup; it should use translated symbolic C constants rather than
hard-coded numeric flag/status values. The amount sentinel itself can safely be expressed as the
documented `std.math.maxInt(u128)`. The current execution path logs and returns raw numeric rejection
statuses, so it also needs stable classification for the outcomes listed above. [Repo
`src/tigerbeetle.zig`, public declarations, success predicates, and `Client`; repo
`src/execution_lambda.zig`, `CreateOutcome`, `processRecordRejection`, and `failureCompletion`]

The wrapper is synchronous and single-caller, while TigerBeetle's native client may retry a request
indefinitely. The execution Lambda is configured for 15 seconds. Hard Lambda termination or SQS
redelivery must therefore be assumed at every account/transfer/completion boundary, making stable
IDs and byte-for-byte-stable semantic fields mandatory. [Repo `src/tigerbeetle.zig`, `Client` and
request wait contract; repo `template.yaml`, `ExecutionFunction.Properties.Timeout`; TB
`docs/reference/sessions.md`, § `Retries`]

Finally, the bundled product documentation and the repository's C package share TigerBeetle base
commit `97c7a8ef385270ebe0e1b75959d3d21d134629df`, but the package also includes two recorded patch
heads and advertises a custom `65535.0.0` release. The allowed corpus does not contain those patch
sources or the live cluster configuration. The result names and behavior above are the documented
contract for the bundled snapshot, but exact runtime validation still requires integration tests
against the actual cluster/client pair—especially for `id_already_failed`, full-post
`AMOUNT_MAX`, expiry races, and dense result delivery. [Repo `build.zig.zon`,
`dependencies.tigerbeetle_c_artifacts`; repo `docs/ZIG_WRAPPER_FOR_TIGERBEETLE.md`,
§ `Build boundary` and § `Live integration tests`]

## Decision checklist

- Use `Event.id` as ledger only within the documented nonzero-`u32` range.
- Allocate globally unique account IDs across all Events.
- Credit each section once with a stable initialization transfer ID.
- Put `debits_must_not_exceed_credits` on every Seat Section.
- Reserve with `flags = pending`, stable `timeout > 0`, and `id = Reserve Operation.id`.
- Confirm with `flags = post_pending_transfer`, `amount = AMOUNT_MAX`,
  `pending_id = Reserve Operation.id`, and `id = Confirm Operation.id`.
- Reject zero/max Operation IDs and require reserve/confirm IDs to differ.
- Treat `created` and exact `exists` as idempotent creation success, but never equate reserve
  `exists` with a guarantee that the hold is still live.
- Treat `exceeds_credits` as insufficient section capacity and a terminal outcome for that reserve
  ID.
- Select one section before submitting a reserve; do not try fallback sections with the same
  Operation/transfer ID.
- Prevent confirm-before-reserve; `pending_transfer_not_found` permanently consumes the confirm ID.
- Use linked chains only for all-or-none account provisioning or all-or-none initial section
  allocations, never for the reserve/confirm lifecycle.
- Design explicitly for delayed expiry cleanup and the absence of an expiry notification.
