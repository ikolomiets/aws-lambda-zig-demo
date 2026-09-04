# Operation Execution

This context receives named operations and tracks their execution through completion.

## Language

**Operation**:
A globally identified unit of work with a tenant, name, body, lifecycle state, result, and stable
hash.
_Avoid_: Job, task

**Operation Tenant**:
Required server-owned UTF-8 metadata identifying the subject that requested and may read an
Operation; Lambda derives it only from the verified PASETO `sub` claim, while the host CLI accepts
it only as create-command metadata. It is part of idempotency identity and authorizes query reads
after the globally keyed DynamoDB lookup, but does not scope the partition key.
_Avoid_: Customer ID, partition key

**Operation Body**:
The caller-supplied JSON value that contains an operation's input.
_Avoid_: Payload, parameters

**Operation Result**:
The JSON value produced when an operation succeeds or fails.
_Avoid_: Response, output body

**Operation State**:
The operation's current lifecycle position: submitted or completed.
_Avoid_: Status

**Terminal State**:
The completed state, after which an Operation has an immutable success or failure result.
_Avoid_: Success state, failure state

**Operation Hash**:
A stable fingerprint of an operation's tenant, name, and body used to identify the requested work.
_Avoid_: Body hash, checksum

**Event**:
A scheduled occurrence with a defined set of seat sections that can receive reservations.
_Avoid_: Show, session

**Event ID**:
A globally unique, monotonically allocated integer from 1000 through 2^32-1 that also identifies
the Event's TigerBeetle ledger.
_Avoid_: Tenant event ID, separate ledger ID

**Seat Section**:
A fungible capacity group within an Event; reservations claim a quantity from the section rather
than an individually identified seat.
_Avoid_: Seat map, seat

**Reservation Request**:
A request for a quantity of seats allocated wholly from one eligible Seat Section belonging to an
Event.
_Avoid_: Exact-seat request, ticket order

**Reservation Action**:
One of reserve or confirm, carried by its own Operation while sharing the seat-reservation service
Operation name.
_Avoid_: Operation phase, reservation state

**Reservation Hold**:
A temporary allocation of section capacity awaiting confirmation.
_Avoid_: Pending operation, provisional seat

**Confirmed Reservation**:
A Reservation Hold whose allocation has been finalized for the requested quantity.
_Avoid_: Completed operation, booked seat

**Seat Supply Account**:
The Event-local source from which each Seat Section receives its initial capacity.
_Avoid_: Inventory account, global supply account

**Seats Reserved Account**:
The Event-local aggregate destination for seat quantities held or confirmed from Seat Sections.
_Avoid_: Per-hold account, customer account
