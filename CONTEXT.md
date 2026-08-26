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
The operation's current lifecycle position: new, succeeded, or failed.
_Avoid_: Status

**Terminal State**:
A succeeded or failed state after which an operation has a result.
_Avoid_: Completed state

**Operation Hash**:
A stable fingerprint of an operation's tenant, name, and body used to identify the requested work.
_Avoid_: Body hash, checksum
