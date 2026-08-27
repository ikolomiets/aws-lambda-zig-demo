# Zig-Based Operation State Model

## Overview

An asynchronous operation has one forward lifecycle transition:

```text
SUBMITTED -> COMPLETED
```

`COMPLETED` is the only terminal lifecycle state. Success and failure are completion outcomes,
not separate lifecycle states:

```text
Operation
  status
    submitted
    completed
      success -> std.json.Value
      failure -> std.json.Value
```

This separates whether processing has finished from how it finished. A retryable infrastructure
failure leaves the operation submitted when another execution attempt is expected. A completed
failure is a definitive business or request outcome for which no further execution is expected.

## Concrete Zig Model

The implementation uses one concrete operation model. It is not parameterized as
`Operation(Success, Failure)` because operation kinds share the same JSON boundary and repository
representation.

```zig
pub const Completion = union(enum) {
    success: std.json.Value,
    failure: std.json.Value,
};

pub const Status = union(enum) {
    submitted,
    completed: Completion,
};

pub const Operation = struct {
    id: u128,
    tenant: []const u8,
    name: []const u8,
    body: ?std.json.Value = null,
    status: Status,
    last_updated: ?UnixSeconds = null,
    expires_at: ?UnixSeconds = null,
    hash: ?[32]u8 = null,
};
```

The model retains the repository's identity, tenant, operation name, request body, timestamps,
expiry, and hash fields. The caller's lifetime arena owns `tenant`, `name`, `body`, and every string
and collection nested in a completion payload.

Encoding lifecycle and outcome together makes these invalid combinations unrepresentable:

```text
COMPLETED without an outcome
SUBMITTED with a result
both success and failure outcomes
```

A completion payload must also be non-null. Parsers, serializers, and persistence validation enforce
that boundary because `std.json.Value` itself includes a `null` variant.

## Completion Envelope

External JSON represents a completion with exactly two fields:

```json
{"type":"SUCCESS","payload":{"transfer_id":"00112233-4455-6677-8899-aabbccddeeff"}}
```

or:

```json
{"type":"FAILURE","payload":{"code":"INSUFFICIENT_FUNDS"}}
```

The rules are:

- `type` is exactly uppercase `SUCCESS` or `FAILURE`.
- `payload` is any non-null JSON value. Nested null values remain valid.
- Duplicate and unknown envelope fields are rejected.
- The complete compact envelope, including `type` and `payload`, is at most 4,096 bytes.
- Canonical output is compact and orders `type` before `payload`.

The tagged union and envelope map directly:

```text
.success(value) -> {"type":"SUCCESS","payload":value}
.failure(value) -> {"type":"FAILURE","payload":value}
```

## Persistence Model

The final persisted representation keeps the existing DynamoDB attribute names and types. It stores
`state` as `S`, using `SUBMITTED` or `COMPLETED`, and stores the compact completion envelope in the
existing `result` string attribute only for completed operations.

```text
.submitted              -> state = SUBMITTED, result absent
.completed.success(x)   -> state = COMPLETED, result = SUCCESS envelope containing x
.completed.failure(x)   -> state = COMPLETED, result = FAILURE envelope containing x
```

The operation hash continues to cover only the fixed tenant, name, and body envelope defined by ADR
0001. Status and completion do not affect idempotency identity.

## Transition and Rollout Rules

Submitted operations may be observed or refreshed as submitted, then completed once. Every completed
operation is immutable, including replacement with the same outcome or payload.

The schema rollout is intentionally a one-step cutover. Once readers and writers switch to the new
contract, they accept only `SUBMITTED` and `COMPLETED` with the tagged envelope. They do not decode
legacy `SUCCEEDED` or `FAILED` rows and do not treat a raw terminal result as a completion envelope.

Step 1 adds the tagged types and codec without changing the current `Operation` fields or any HTTP,
SQS, CLI, or DynamoDB behavior. Later steps replace the in-memory representation and then perform
the wire and persistence cutover.
