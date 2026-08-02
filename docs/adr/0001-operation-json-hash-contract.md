# Use one operation model and a fixed JSON hash contract

Use one `Operation` model for input, output, and future DynamoDB persistence so that invariants are
defined once while each view admits only its own fields. The operation hash is always BLAKE3-256 of
the compact Zig 0.16 `std.json.Value` serialization of the fixed-order envelope
`{"name":<JSON-encoded-name>,"body":<normalized-body>}`. This normalization deliberately is not
RFC 8785 canonical JSON: insignificant whitespace and equivalent string escapes compare equally,
but object key order is retained and therefore affects the hash.

The reference envelope
`{"name":"echo","body":{"message":"hello","count":2}}` has lowercase digest
`ab9a059eb68c36bddaffb5bdd23aa7177c3a97dc34f9af54eb06f1c488ac3662`. Changing the shared model,
hash algorithm, envelope, or normalization rules requires an explicit schema migration or a new
versioned contract.
