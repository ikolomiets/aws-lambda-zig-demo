# Operation Execution

This context receives named operations and tracks their execution through completion.

## Language

**Operation**:
A globally identified unit of asynchronous work with a tenant, name, body, lifecycle state,
result, and stable hash. Operations are disposable and retained briefly after completion.
_Avoid_: Job, task

**Operation UUID**:
The system-guaranteed unique identifier that names an Operation and correlates its Completion,
independently of the Resource IDs in its Body.
_Avoid_: Resource ID, transfer ID

**Operation Tenant**:
Required server-owned UTF-8 metadata identifying the subject that requested and may read an
Operation; Lambda derives it only from the verified PASETO `sub` claim, while the host CLI accepts
it only as create-command metadata. It is part of idempotency identity and authorizes query reads
after the globally keyed DynamoDB lookup, but does not scope the partition key.
_Avoid_: Customer ID, partition key

**Operation Body**:
The caller-supplied JSON value that contains an operation's input.
_Avoid_: Payload, parameters

**Operation Admission**:
The pre-effect decision that a valid Operation Body fits the fixed execution and complete-Result
bounds. A rejected Operation produces a terminal failure without submitting native work.
_Avoid_: Runtime truncation, partial admission

**Operation Result**:
The JSON value produced when an operation succeeds or fails.
A failure Result may accompany lasting effects of earlier work, and included lookup observations
describe resource state when read.
_Avoid_: Response, output body

**Operation State**:
The operation's current lifecycle position: submitted or completed.
_Avoid_: Status

**Lookup Observation**:
The presence or absence of a requested account and, when present, its values when read.
It describes observed account state, not state at an earlier creation or transfer.
_Avoid_: Write-time snapshot, reservation guarantee

**Terminal State**:
The completed state, after which an Operation has an immutable success or failure result.
_Avoid_: Success state, failure state

**Operation Hash**:
A stable fingerprint of an operation's tenant, name, and body used to identify the requested work.
_Avoid_: Body hash, checksum

**Resource ID**:
A native TigerBeetle account or transfer identifier whose stable, globally unique, deterministic
value the client supplies independently of the Operation UUID. Account and transfer IDs occupy
separate namespaces.
_Avoid_: Operation ID, Ledger ID

**Resource Alias**:
An optional caller-supplied label accompanying a Resource ID to help interpret command results.
It may be repeated within an Operation and reused or changed across Operations without determining
resource identity.
_Avoid_: Resource ID

**Linked Chain**:
One Operation's complete ordered group of account creations or transfer creations, whose new
records and balance effects succeed or fail together. Clients keep each creation Resource ID
bound to its original group, order, and creation fields across all creation attempts.
_Avoid_: Operation, batch

**Native Request**:
One TigerBeetle submission for a single command family. It may pack complete Linked Chains from
multiple Operations, but contains at most 8,189 native events and never splits or joins chains.
_Avoid_: SQS batch, Completion message

**Command-Family List**:
One Operation's ordered `create_accounts`, `create_transfers`, or `lookup_accounts` list. The two
creation lists are independent Linked Chains and all three lists execute in separate native phases.
_Avoid_: Execution group, cross-family batch

**Processor Message**:
A message correlating an Operation UUID and trusted Operation Tenant with a processor's input or
output Body, Context, and an optional Result Queue. It carries work between processors without the Operation's
lifecycle metadata.
_Avoid_: Operation snapshot, Completion batch

**Processor Body**:
The JSON value a processor consumes or produces. One processor's output may be another's input.
_Avoid_: Operation Result, wrapped payload

**Processor Context**:
Information accompanying a Processor Body whose meaning belongs to the participating domain
processors. An intermediate processor may carry it forward without interpreting it.
_Avoid_: Operation Body, Operation Result, execution plan

**Result Queue**:
An internal instruction identifying where the receiving processor should send its result. When absent,
the processor's default behavior applies. Each processor independently chooses the Result Queue for
its outgoing message; external Operation callers do not control it.
_Avoid_: Current message destination, public callback

**Completion Message**:
A Processor Message delivered to the final processor, which interprets its Body and determines the
Operation's terminal Result.
_Avoid_: Native Request, Operation Result, Completion batch

## Seat reservation language

**Seat Event**:
A tenant-owned offering with a configured number of seats in each Seat Class and a reservation
time limit. Only its owning tenant may reserve, confirm, or check its seats.
_Avoid_: Operation, native event

**Seat Class**:
A tagged category of interchangeable seats with positive configured capacity within one Seat Event,
such as general or premium.
_Avoid_: Assigned seat

**Seat Event State**:
The Seat Event's initialization condition: creating while initialization is incomplete or uncertain,
ready after all accounts and initial funding succeed, or failed after definitive initialization
failure. Failed events remain failed; only ready events admit reservations, confirmations,
and seat checks.
_Avoid_: Operation State, funding observation

**Capacity Account**:
The Seat Event's single source account for distributing its configured seat quantities to
Availability Accounts.
_Avoid_: Availability Account

**Availability Account**:
The account representing one Seat Class's configured supply and the seats reserved or confirmed
against that supply.
_Avoid_: Remaining-seat count

**Allocation Account**:
The Seat Event's single destination account for reserved and confirmed seat quantities across
its Seat Classes.
_Avoid_: Customer account

**Seat Reservation**:
A positive quantity of seats held in one specified Seat Class of a Seat Event by one successful
reserve_seats request. Confirmation applies to the full held quantity.
_Avoid_: Operation, individual pending transfer
