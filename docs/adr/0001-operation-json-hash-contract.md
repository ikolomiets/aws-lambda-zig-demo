# Use one operation model and a fixed JSON hash contract

Use one `Operation` model for input, output, and DynamoDB persistence so that invariants are defined
once while each view admits only its own fields. `Operation.tenant` is required server-owned
metadata: Lambda derives it only from the verified PASETO `sub` claim, while the host CLI accepts it
only through `operation create --tenant`. Caller-supplied Operation JSON cannot set it. The operation
hash is always BLAKE3-256 of the compact Zig 0.16 `std.json.Value` serialization of the fixed-order
envelope
`{"tenant":<JSON-encoded-tenant>,"name":<JSON-encoded-name>,"body":<normalized-body>}`. This
normalization deliberately is not RFC 8785 canonical JSON: insignificant whitespace and equivalent
string escapes compare equally, but object key order is retained and therefore affects the hash.

`Operation.body` and `Operation.result` are optional `std.json.Value` fields owned, together with
their nested strings and collections, by the caller's lifetime arena. Input bodies and terminal
results are parsed once with duplicate-key rejection and owned strings. Hashing and output serialize
those Values directly. DynamoDB omits `body` and stores a terminal `result` as the compact Value
serialization in an `S` attribute; reads accept only an exact compact reserialization no larger than
4,096 bytes.

The reference envelope
`{"tenant":"tenant-a","name":"echo","body":{"message":"hello","count":2}}` has lowercase
digest `d271e3bd560113d2b82e42dfc46be33fb90b43d7f4b12114f3da4888eae445d4`. Tenant is therefore part
of idempotency identity. UUIDs remain globally scoped: reusing a UUID under another tenant produces
a different hash and an Operation conflict. This metadata does not introduce tenant-scoped table
keys or new read authorization behavior. Changing the shared model, hash algorithm, envelope, or
normalization rules requires an explicit schema migration or a new versioned contract.
