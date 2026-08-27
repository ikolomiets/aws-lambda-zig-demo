# Use a two-state operation lifecycle with tagged completion outcomes

This decision supersedes only the lifecycle state and terminal result representation in ADR 0001.
ADR 0001 remains authoritative for the single concrete `Operation` model, server-owned tenant,
BLAKE3-256 hash envelope, JSON normalization, UUID scope, arena ownership, and authorization
boundary.

Operations use the lifecycle `SUBMITTED -> COMPLETED`. Success and failure are not lifecycle states;
they are variants of a Zig tagged union carried by the completed status:

```zig
pub const Completion = union(enum) {
    success: std.json.Value,
    failure: std.json.Value,
};

pub const Status = union(enum) {
    submitted,
    completed: Completion,
};
```

All strings and collections nested in a completion payload are owned by the caller's lifetime arena.
The external and persisted result is the compact envelope
`{"type":"SUCCESS|FAILURE","payload":<non-null JSON>}`. The envelope must contain exactly `type`
and `payload`; the type is uppercase, and the payload may contain nested null values but cannot
itself be null. The entire compact envelope is limited to 4,096 bytes.

Completion is immutable. `SUBMITTED -> SUBMITTED` remains valid while an operation is pending, and a
submitted operation may transition once to either completed outcome. Every transition from
`COMPLETED`, including a same-outcome refresh, is rejected.
