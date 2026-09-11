# TigerBeetle processor design

This is the maintained design reference for the Body-driven `TigerBeetle` processor in
[src/tiger_beetle_processor.zig](../src/tiger_beetle_processor.zig). It specifies caller obligations,
validation, execution, Results and recovery. An Operation requests account creations, transfers,
account lookups, or any combination. Whole-Operation preflight prevents invalid input from causing
native effects; independent native creation chains and conditional Completion persistence support
redelivery under the operating assumptions below.

This document owns processor behavior and its rationale. [CONTEXT.md](../CONTEXT.md) owns domain
vocabulary; the [hash ADR](adr/0001-operation-json-hash-contract.md) and
[lifecycle ADR](adr/0002-two-state-operation-state.md) own cross-cutting decisions. The
[native wrapper reference](ZIG_WRAPPER_FOR_TIGERBEETLE.md) owns the C ABI, packaging and client
mechanics; the [deployment guide](DEPLOY_AWS_LAMBDA_WITH_SAM.md) owns AWS configuration and
operations. Maintain those boundaries when changing the processor.

The rules below are the accepted contract. [Reconciliation notes](#implementation-reconciliation)
identify implementation differences; [verification evidence](#verification-evidence) records what
was tested and what remains unverified. The [source coverage audit](TIGERBEETLE_PROCESSOR_PROMOTION_AUDIT.md)
traces historical requirements without making scratch documents necessary to use this reference.

## Framework boundary

- Retain `SUBMITTED -> COMPLETED`, with immutable `SUCCESS` or `FAILURE` completion payloads.
  Keep the Operation UUID globally scoped and use it for Operation/Completion correlation only.
- Preserve server-owned Operation Tenant, current intake authentication and tenant-authorized
  query reads. The processor introduces no tenant-scoped native resource ownership or access policy.
- Preserve BLAKE3-256 over the compact normalized fixed-order tenant/name/Body envelope. Verify
  the supplied hash using the original parsed Body, never a reconstructed native plan. Object
  member order still affects identity; whitespace and equivalent string escapes normalize.
- Keep Body capacity at 4,096 bytes. The complete Result envelope limit is
  98,304 bytes throughout production, Completion decoding, persistence and query output.
  Body and Result limits are independent; the larger Result supports complete account observations.
- The Operation name is `TigerBeetle`, routed through `TigerBeetleQueue`. There is no version
  field, parallel legacy parser, queue migration or preservation of the former demonstration.

## Body schema

The Body is an object containing only `create_accounts`, `create_transfers` and `lookup_accounts`.
Each supplied value is an array of command objects. Omitted/empty lists are allowed, but the combined
command set must be nonempty. Preserve array order. Names are case-sensitive after JSON decoding;
reject unknown names, duplicate decoded names, explicit nulls and shorthand command forms.

Every command requires `id` and optionally accepts `alias`. Concrete IDs are canonical unsigned
ASCII decimal strings in the range 1 through 2^128−2. Account and transfer IDs occupy independent
cluster-wide namespaces. Reject a duplicate command ID within each individual list; allow repeated
references, equal numeric IDs across kinds, account creation plus lookup, and IDs shared across
Operations subject to the immutable creation-chain obligation.

Aliases are 1–64 decoded UTF-8 bytes, preserved without normalization or trimming. Repetition is
allowed within and across lists and Operations. Aliases never resolve references or define identity.

| Command | Required fields beyond id | Optional fields beyond alias | Native construction |
| --- | --- | --- | --- |
| Account creation | ledger, code, flags | None | Nonzero ledger/code; flags exactly 0 or debit-bound 2. |
| Immediate transfer | debit_account_id, credit_account_id, amount, ledger, code, flags | None | Flags 0; concrete account references; nonzero ledger/code; reject pending_id and timeout even zero. |
| Pending transfer | debit_account_id, credit_account_id, amount, ledger, code, flags, timeout | None | Flags 2; concrete references; nonzero ledger/code; positive timeout; reject pending_id even zero. |
| Post-pending transfer | pending_id, amount, flags | debit_account_id, credit_account_id, ledger, code | Flags 4; concrete pending ID; omitted optional fields default to native zero inheritance; reject timeout even zero. |
| Account lookup | None | None | Submit the concrete account ID. |

- ID/reference/amount strings use `0|[1-9][0-9]*`, with checked conversion and no floats, coercion,
  whitespace, signs, leading zeros, exponents or alternative radices. Amount admits the full u128
  range including zero and maximum. Post account references additionally admit zero inheritance.
- Ledger and timeout use unsigned JSON integers within u32; code and flags within u16. Apply mode
  constraints from the table. Validate the existing normalized Zig 0.16 Body: original `1.0`/`1e0`
  may already be `1`; reject remaining fractions, negative zero, negatives and overflow. Add no
  raw-token parser, arbitrary-precision intake contract or u64 input field.
- Require explicit flags and amount. Pending timeout must be 1 through u32 maximum seconds.
  Resubmit its original interval on retry. Native creation time starts expiry; cleanup is best
  effort and need not occur at the exact expiry instant.
- Post amount zero posts zero; partial amount posts that amount and releases the remainder;
  maximum requests the full pending amount. Omitted or explicit-zero post account/ledger/code
  fields inherit; supplied nonzero fields must match native state. Preserve these sentinels.
- Reject equal immediate/pending debit and credit IDs, post ID equal to pending ID, and equal
  nonzero post debit and credit IDs. Either or both post account references may be zero.
- Reject caller linked bits, combined transfer modes, void, balancing, closing, imported,
  credit-bound/history account creation, user-data input, timestamps, reserved fields and balance
  counters, including supplied zeros. Derive linked bits; zero processor-owned native fields.
  Post zero user data may inherit metadata from the pending transfer.
- Leave existence, ledger compatibility, balances, pending lifecycle, inheritance matching and
  other state-dependent checks to TigerBeetle. Add no local resource simulation, sibling dependency
  inference, prelookup or requirement that referenced resources appear in this Body.

## Validation precedence and admission

First apply bounded generic queued-Operation parsing and existing metadata/UUID/name/timestamp
validation. Require SUBMITTED, Body and a matching recomputed hash. Invalid envelopes, malformed or
duplicate JSON, generic oversize and mismatching hashes are acknowledged and logged without native
work or Completion. Do not salvage an ID from malformed input. The hash checks consistency under the
trusted queue-producer boundary; it is not producer authentication.

For a valid envelope/hash, invalid Body or admission produces one terminal FAILURE without any native
submission for that Operation. Publication must succeed before acknowledging its source record.
Allocation and other operating errors retry; they never become permanent validation failures.

Choose the first diagnostic in this order:

1. Body object type, then unknown root members in normalized member order.
2. Families in account-creation, transfer-creation, lookup order: array type then each element.
3. Element object type, then unknown members in normalized member order. Known vocabulary is the
   union of fields accepted by that family across modes.
4. Creation flags first; then id, alias, pending_id, debit_account_id, credit_account_id, amount,
   ledger, code, timeout. Lookup checks id then alias. At each applicable field check mode
   prohibition, required presence, type, grammar/UTF-8, then range/length.
5. Duplicate ID, then own/pending-ID equality, then forbidden debit/credit equality.
6. After full wire validation, empty command set, then command-count admission. A later wire error
   wins over exceeding the command cap; do not stop validation at command 65.

For a command diagnostic, emit preceding null placeholders in that family's list, one diagnostic at
its original position, and no suffix. The other lists are empty. Independently project a valid ID
or null and a valid optional alias; do not echo invalid values. Diagnostic fields are id, error_code
(null), optional alias, message, then optional field or member_index. Known field names identify
invalid/missing/forbidden fields; unknown members use their zero-based u32 member index. Field and
member_index are mutually exclusive. Non-object elements need neither.

Body-level errors have three empty lists and a payload-level error containing message and optional
field/member_index, without code. Wrong Body type, empty command set and admission have message only;
wrong family type names the family; unknown root members use member_index. Emit exactly one error.
Messages are processor-owned, nonempty valid UTF-8 of at most 160 decoded bytes. Their wording is
human-readable, not an enum; do not interpolate arbitrary caller values or add processor_error,
JSON Pointer, command indexes or a second machine-readable error taxonomy.

Use one size-policy parameter: Result multiplier 24 times the 4,096-byte Body bound. Derive raw command
capacity as floor((98,304−147)/1,435)=68 and round down to a power of two: 64 total commands across all
families. Use checked arithmetic and compile-time assertions. The complete execution Result proof is
148 base bytes + 64 × 1,434 maximum entry bytes + 63 separators = 91,987 bytes. It includes maximum
integer widths and six-byte escaping for alias/message control bytes. The conservative preflight
prefix bound is 3,655 bytes; validate both proofs against the actual writer. Never use outcome-weighted
admission or truncate after effects. Overflow after proven admission is a programmer invariant failure.

## Execution phases and linked-chain replay

- Execute the entire invocation's account phase, then eligible transfer phase, then lookup phase.
  Within each family traverse admitted Operations in received order. This supplies no general
  cross-Operation ordering guarantee; clients must wait for dependent prerequisites themselves.
- Each nonempty creation list is one complete ordered Linked Chain, independent of the other
  family. Set linked on every member except the last; clear it for singleton chains. There is
  no cross-family or whole-Operation atomicity.
- Pack complete same-family lists into Native Requests of at most 8,189 events. Flush before
  adding a complete list that would overflow. Never split/join chains, submit empty packets,
  deduplicate cross-Operation lookup IDs, or carry packets across invocations.
- Before mutating any Operation from a reply, validate its entire count/layout/correlation.
  Creation count must equal submitted count; each chain must be all-created or have exactly
  one decisive non-created/non-linked-failed status and linked_event_failed everywhere else.
  Invalid layout anywhere invalidates the whole request, preserving only earlier request facts.
- All-created succeeds. Matching exists at the first member with linked_event_failed suffix
  establishes accepted replay, including singleton exists. Late-member exists, different-field
  conflicts and other decisive rejections do not establish replay success. Preserve raw statuses.
- Replay proof relies on a client obligation across all writers: every creation Resource ID belongs
  to the same complete ordered chain with identical original native inputs on every creation
  attempt. No member may move, disappear, be replaced or be retried alone. Resource IDs are stable,
  unique and deterministic independently of Operation UUID. Aliases can change in a new Operation;
  the same Operation preserves its Body/hash. References to existing resources are not creations.
- Add no global chain registry or violation detector. First-member existence does not itself encode
  chain history; incompatible caller histories can produce false success and are outside contract.
- Account rejection skips only that Operation's transfers; requested lookups still run. Transfer
  rejection also permits requested lookups. Ordinary business rejection does not stop neighbors.
- Any native request error or malformed reply stops all further native calls in that invocation.
  It supplies no new trustworthy outcomes. Preserve earlier facts; publish fully determined
  Operations and retry unfinished ones. Add no intra-invocation retries, salvage, compensation,
  replacement IDs or submission-provenance classification.

Lookup replies may be sparse and unordered. For an ID submitted n times across Operations, accept
zero returned copies (missing) or exactly n copies with identical Account fields (found). Unrequested
IDs, partial/excess multiplicity and field disagreement invalidate the whole reply before routing.
Sort bounded scratch submitted-position indexes and the completed reply by ID, then validate groups
and populate original positions in separate passes. Preserve input/native submission order and each
alias; compare fields rather than padding. Use bounded nonrecursive O(n log n) sorting, no hash table
or extra request. A request error never establishes account absence.

## Result and Completion publication

Keep the complete Result envelope with exactly type (`SUCCESS` or `FAILURE`) and non-null payload.
The processor payload serializes operation_id, create_accounts, create_transfers, lookup_accounts
in that order, plus error only for a Body-level diagnostic. Its canonical lowercase hyphenated UUID
matches the enclosing Completion entry's operation_id. Both UUID occurrences are intentional.

Complete execution lists contain one entry per original command, in original order; absent families
are empty. Serialize entry fields as id, error_code, optional alias, then message or account:

| Entry | error_code | Remaining content |
| --- | --- | --- |
| Submitted creation | Canonical native status name (JSON string) | Optional alias only; omit native creation timestamp/reserved. |
| Transfer deliberately skipped after account rejection | null | Required explanatory message. |
| Found account lookup | null | Full account object, no message. |
| Missing account lookup | null | Required explanatory message, no account. |

Serialize canonical lowercase status names from the pinned native boundary, including "created",
"exists" (account status 21 or transfer status 46), and "linked_event_failed". This replaces the
previous integer error_code format; consumers must accept string or null. Previously stored Results
are not rewritten. null is absence of a per-command native status, not itself failure.
Do not rewrite replay suffixes. If a native status has no name in the pinned definitions, serialize
"unknown" and log its family and numeric value. Name translation does not change native outcome
classification or introduce retries.

The account object omits id because the entry already carries it. Serialize all remaining native
fields in this order: debits_pending, debits_posted, credits_pending, credits_posted, user_data_128,
user_data_64, user_data_32, reserved, ledger, code, flags, timestamp. Encode u128/u64 as canonical
unsigned decimal strings and u32/u16 as JSON integers. Preserve every returned flag and field,
including creation-forbidden flags and zero metadata. Timestamp is native creation time, not read time.

SUCCESS requires every requested creation chain to succeed under the replay rule and every requested
lookup to be found. Any definite creation rejection or missing account gives FAILURE once all requested
work is determined. Retain found data and surviving earlier effects. Failure does not imply rollback,
unused transfer IDs or absence of earlier effects. Unfinished work has no terminal Result.

Derive Completion packing independently from invocation delivery count. With the external 1 MiB
transport ceiling, n maximum Results require 13 + n × (98,304 + 66) bytes: ten fit 983,713 bytes;
eleven require 1,082,083 and another message. Keep each Result intact. Collect terminal Results in
received order, skipping unfinished Operations; flush at the derived count and check byte capacity.
`completion_batch.maximum_result_count` derives that count from the Result bound, framing overhead
and transport ceiling; `maximum_results_size` derives the corresponding processor buffer size.

Send messages serially. Successful sends make represented source records eligible for acknowledgement.
Stop at the first failed or uncertain send; retry its records and every later unpublished terminal
record, together with unfinished work. Do not resend earlier successful messages in the invocation.
A native stop does not prevent publication. Lost handler responses can cause safe redelivery.

## Recovery and operating assumptions

Retain trustworthy outcomes only within the live invocation. Redelivery repeats validation and normal
execution from the original Body, with intact chains and unchanged IDs, amounts, inheritance sentinels
and pending timeout intervals. Native rejection reasons may change, including id_already_failed;
linked-failed members are not necessarily individually consumed. Never fabricate original reasons.

Requested lookups are fresh observations from the attempt whose valid Completion first persists.
Results may differ in statuses, values, presence or outcome across attempts and after ambiguous sends.
No earliest/latest observation, write-time snapshot or whole-Operation snapshot is promised. The first
successful SUBMITTED-to-COMPLETED persistence transition wins; duplicate/partial aggregate replay
cannot overwrite completed Results. Retry exhaustion never manufactures a terminal business failure.

The contract requires the framework to guarantee unique Operation identity and adequate retention
for pending expiry/retries, and to own exhaustion disposition and reporting. TTL is not processor
admission or cancellation.
Participating accounts must not be closed by any writer. Pending and cumulative posted totals,
including intermediate execution, remain small under the accepted operating assumption; unrestricted
u128-boundary recovery and special overflow-code deferral are not requirements. No new numeric
admission cap is implied by the small-total operating assumption.
Expired pending creation may replay successfully without renewing a reservation; a first post after
expiry may reject, while replay can establish an already committed post.

## Interfaces and memory ownership

Keep existing modules. The processor owns validation, admission, packing, invocation sequencing,
reply classification/correlation, direct Result encoding and source dispositions. Use focused pure
helpers and the existing explicit execution/publisher adapters; add no layer or package.

The native wrapper retains its private C boundary, record aliases and client/packet/callback lifetime.
Expose needed named flags/statuses from pinned definitions. Its three batch methods borrow caller-owned
output buffers with capacity for every input and return populated counts through ordinary Zig errors.
Creation returns exact counts; lookup returns at most input count. Allocate/shrink no result storage
on the request path. Callers free original allocations, not populated prefixes.

The batch interfaces are `Client.createAccounts(accounts, output)`,
`Client.createTransfers(transfers, output)` and `Client.lookupAccounts(ids, output)`, each returning
`Error!usize`. The execution adapter carries corresponding context-first callbacks. Creation output
contains native creation-result records; lookup output contains Accounts. The wrapper may return
zero for an empty input, but the processor never submits one.

One pointer-stable process-lived client serves one synchronous request at a time. Keep the processor
multithread-capable for the native callback. The callback copies ephemeral native bytes, signals
completion and never allocates or accesses Operation state. A method returns only after borrowed
memory is no longer native-owned, including immediate-submit-error paths. No overlapping call/deinit,
finite client wait timeout or cancellation mechanism is introduced.

Invocation-owned parsed input/aliases, typed commands/outcomes and source dispositions remain alive
through Result publication and handler response construction. Allocate native input/output and
correlation storage before effects, bounded by admitted commands and packet capability. Reuse off-stack
storage, including one 96 KiB Result scratch buffer and one bounded Completion buffer; do not accumulate
arena allocations per packet/send. Copy validated outcomes before reuse and pair ownership cleanup.
Do not free, move or reuse borrowed request/input/output memory until the native call returns.
The synchronous publisher borrows Completion bytes until its send returns. Source dispositions and
response construction retain their invocation lifetime; response-allocation failure after effects
can still cause whole-invocation redelivery.

Reuse the existing Operation hash logic. Keep Completion framing in the shared Completion codec,
using a bounded writer for already encoded complete Results while retaining existing structured
consumer paths. Do not construct a second Result JSON tree or reparse generated Results merely to frame
them. Consumers must accommodate the full bound, JSON escaping and outer framing; review their
buffers and stack placement whenever the bound changes.

The existing ten-record configuration bounds invocation arrays, loops and checked allocation arithmetic;
it admits at most 640 commands. Validate delivered count; do not add configuration interfaces. Native
packet and Completion packing remain independently testable at larger synthetic boundaries. Current
application storage stays within a few MiB before parser/SDK/client overhead, and normal maximum work
requires at most three native family calls and one Completion send. These are work bounds, not finite
latency guarantees; Lambda termination does not prove an outstanding write aborted.

Use assertions for programmer invariants, capacities, chain/range coverage, phase/callback lifetime and
serializer proofs. Handle malformed external replies, allocation/native/publication failures as errors.
Retain the repository's scoped dynamic invocation-allocation allowance and follow Tiger Style
without unrelated refactors.

## Rationale and precise boundaries

Native IDs are cluster-wide within each resource kind, not tenant- or ledger-scoped. References
select their kind through the field name. Aliases are labels, so neither aliases nor native field
matching can establish client intent, ownership, or accidental ID reuse. The processor generates
no IDs, hashes no aliases, and maintains no allocation counter or registry.

Hash identity describes the original normalized requested work. Omitted arrays versus empty arrays,
and omitted post defaults versus explicit zeros, produce different hashes even when the native
commands coincide. Equivalent JSON escapes normalize before validation; numeric strings are never
trimmed or rewritten. Small-number normalization can lose original spelling or precision before
the processor sees the Body; this design adds no arbitrary-precision intake guarantee.

Mandatory positive pending timeout gives abandoned pending transfers an automatic expiry because
this surface has no void command. A zero-amount transfer still requests a recorded native event.
Posting resolves a pending transfer once; zero posting releases its reservation while posting zero,
and partial posting releases the unused remainder. State-dependent timeout overflow uses the
server-assigned timestamp and remains a native check.

The first-member replay proof is conditional: matching exists establishes that the first record
exists; the immutable-chain obligation means only the same complete chain could have created it;
linked atomicity then establishes that all members committed together. Native exists alone contains
no historical chain association. For example, creating A alone and then requesting [A, B] when B
is absent violates the obligation and can produce false application success. Referencing A is
allowed; enrolling it into an incompatible creation chain is not. Corrective work uses a new valid
chain with fresh creation IDs, while existing resources may be referenced normally.

Account rejection skips all transfers in that Operation even if they reference only pre-existing
accounts. Empty lists mean unrequested work, not skips. Native linked_event_failed can describe
rolled-back or unexecuted members of a submitted chain; it is distinct from a deliberate transfer
skip. Direct submission avoids a prelookup that could become stale and could not establish later
balance or pending-state validity. It accepts native failure consequences, including consumed IDs.
The invocation-wide native stop avoids continuing with a suspect client or unusable reply; ordinary
business rejection does not make that client suspect. A stalled uncancelable call can prevent even
ready Completions from publishing.

The full Account projection preserves returned fields that input deliberately forbids. Creation
result timestamp/reserved are intentionally omitted because those entries report statuses, while
lookup timestamp is account creation time in nanoseconds since Unix epoch, not observation time.
Preflight null placeholders mean no execution result. They do not mean success; omitted suffixes and
empty neighboring lists in that diagnostic do not mean the corresponding commands were unrequested.
The public null-code/message shape alone need not prove that an Operation attempted no writes.

The capacity proof reserves worst-case widths and escaping so admission is independent of native
outcomes. Maximum compact sizes are 467 bytes for a submitted creation entry, 935 for a found lookup,
1,434 for a skip/miss, 1,462 for a command diagnostic, and 463 for the full nested Account.
The preflight proof allows 409 preceding minimal ten-byte commands, each becoming `null,`:
148 + 409 × 5 + 1,462 = 3,655. These are conservative structural shapes, not necessarily realizable
4 KiB Bodies. The complete Result bound applies both to sent bytes and compact parser-normalized
bytes; outer Completion UUID/framing counts separately. Native records are 128 bytes, lookup IDs
16 bytes, creation results 16 bytes and lookup results 128 bytes. A full native record buffer is
approximately 1 MiB, independently of the current much smaller invocation workspace.

## Body examples

These are separate illustrative Bodies, not a sequence to execute with reused IDs. Each is locally
admissible; native existence, balances and lifecycle still determine execution. Real callers must
allocate conforming Resource IDs independently of the enclosing Operation UUID.

Lookup only, with repeated labels at distinct positions:

```json
{"lookup_accounts":[{"id":"101","alias":"seat"},{"id":"102","alias":"seat"}]}
```

All families, with an immediate transfer between unrestricted accounts:

```json
{"create_accounts":[{"id":"101","ledger":1,"code":1,"flags":0},{"id":"102","ledger":1,"code":1,"flags":0}],"create_transfers":[{"id":"201","debit_account_id":"101","credit_account_id":"102","amount":"3","ledger":1,"code":1,"flags":0}],"lookup_accounts":[{"id":"101","alias":"seat"},{"id":"102","alias":"seat"}]}
```

A debit-bound account and lookup:

```json
{"create_accounts":[{"id":"103","ledger":1,"code":1,"flags":2}],"lookup_accounts":[{"id":"103"}]}
```

Expiring pending transfer referencing existing accounts:

```json
{"create_transfers":[{"id":"301","debit_account_id":"101","credit_account_id":"102","amount":"3","ledger":1,"code":1,"flags":2,"timeout":60}]}
```

Full post using omitted inheritance fields (the maximum is a decimal string, not `"AMOUNT_MAX"`):

```json
{"create_transfers":[{"id":"302","pending_id":"301","amount":"340282366920938463463374607431768211455","flags":4}]}
```

Zero post with explicit inheritance sentinels:

```json
{"create_transfers":[{"id":"303","pending_id":"301","debit_account_id":"0","credit_account_id":"0","amount":"0","ledger":0,"code":0,"flags":4}]}
```

Rejected Body examples, each with a valid generic envelope/hash:

| Body | First diagnostic |
| --- | --- |
| `{}` | Payload error: no commands. |
| `{"lookup_accounts":{}}` | Payload error, field `lookup_accounts`. |
| `{"lookup_accounts":["101"]}` | Command 0: expected object; null ID, no field/member. |
| `{"lookup_accounts":[{"id":"101"},{"id":"101"}]}` | Command 1, field `id`; one preceding null. |
| `{"lookup_accounts":[{"id":"01","alias":"main","unexpected":true}]}` | Command 0, member_index 2; null ID and retained alias. |
| `{"create_transfers":[{"id":"301","debit_account_id":"101","credit_account_id":"102","amount":"3","ledger":1,"code":1,"flags":2}]}` | Command 0, field `timeout`. |

Duplicate decoded JSON keys instead prevent generic envelope acceptance and produce no Completion.

## Result examples

Examples are complete compact Results unless explicitly labelled Completion. Values and timestamps
are illustrative observations, not live output or promised balances.

Accepted replay of a previously committed immutable account chain and singleton transfer, for a
Body requesting no lookups; raw linked-failed suffixes remain visible:

```json
{"type":"SUCCESS","payload":{"operation_id":"00112233-4455-6677-8899-aabbccddeeff","create_accounts":[{"id":"101","error_code":"exists","alias":"pair"},{"id":"102","error_code":"linked_event_failed","alias":"pair"}],"create_transfers":[{"id":"201","error_code":"exists"}],"lookup_accounts":[]}}
```

A missing lookup fails the Operation while preserving a found account and its full native fields:

```json
{"type":"FAILURE","payload":{"operation_id":"00112233-4455-6677-8899-aabbccddeeff","create_accounts":[],"create_transfers":[],"lookup_accounts":[{"id":"102","error_code":null,"alias":"pair","message":"Account was not found."},{"id":"101","error_code":null,"alias":"pair","account":{"debits_pending":"0","debits_posted":"7","credits_pending":"0","credits_posted":"9","user_data_128":"123","user_data_64":"456","user_data_32":789,"reserved":0,"ledger":1,"code":1,"flags":8,"timestamp":"1790000000000000001"}}]}}
```

For the unknown-member Body above, unknown-field precedence and independent projection give:

```json
{"type":"FAILURE","payload":{"operation_id":"00112233-4455-6677-8899-aabbccddeeff","create_accounts":[],"create_transfers":[],"lookup_accounts":[{"id":null,"error_code":null,"alias":"main","message":"Unknown field.","member_index":2}]}}
```

For the duplicate-ID Body above, no command executes and only the diagnostic prefix appears:

```json
{"type":"FAILURE","payload":{"operation_id":"00112233-4455-6677-8899-aabbccddeeff","create_accounts":[],"create_transfers":[],"lookup_accounts":[null,{"id":"101","error_code":null,"message":"This ID repeats an earlier command's ID in the same list.","field":"id"}]}}
```

For a non-array lookup family:

```json
{"type":"FAILURE","payload":{"operation_id":"00112233-4455-6677-8899-aabbccddeeff","create_accounts":[],"create_transfers":[],"lookup_accounts":[],"error":{"message":"Expected an array of commands.","field":"lookup_accounts"}}}
```

Completion framing intentionally repeats the UUID outside the Result:

```json
{"results":[{"operation_id":"00112233-4455-6677-8899-aabbccddeeff","result":{"type":"SUCCESS","payload":{"operation_id":"00112233-4455-6677-8899-aabbccddeeff","create_accounts":[{"id":"104","error_code":"created"}],"create_transfers":[],"lookup_accounts":[]}}}]}
```

## Scope exclusions

The processor adds no resource-tenant authorization, ID-generation algorithm, durable recovery
journal, checkpoint, lease, saved observation, chain registry, dependency scheduler, proof lookup,
compensation, member salvage, new module/dependency or asynchronous timeout mechanism. Framework
identity allocation, retention, cancellation policy and exhaustion disposition remain external.

Unsupported creation features include void, balancing, closing, historical import, credit-bound or
history accounts, user-data input and non-expiring pending transfers. Closure by any participating
writer, incompatible/partially overlapping creation histories, and unrestricted numeric-boundary
account totals are excluded from the recovery guarantee. Such counterexamples do not imply new
production detection or special overflow deferral behavior.

Legacy preservation, dual contracts, migrations, queue drain, historical Result repair and rollback
compatibility are not provided. This does not authorize deleting cloud/native resources or reusing
creation IDs incompatibly. Deployment, AWS validation, topology/IAM/CORS/runtime/timeout/memory
changes and package refresh belong to separately authorized deployment work. Seat-reservation
business rules, UI and unrelated APIs are outside this processor reference.
