# Zig 0.16 Wrapper for TigerBeetle

## Purpose

`src/tigerbeetle.zig` is the synchronous Zig boundary around the versioned TigerBeetle C client
package fetched from a GitHub Release asset.
It exposes only the account and transfer operations needed by this application and keeps the C
client, packets, callbacks, and temporary result pointers private.

```text
application
    |
    | synchronous Zig calls
    v
src/tigerbeetle.zig
    |
    | translated C declarations
    v
tb_client.h + matching libtb_client.a
```

The wrapper is deliberately single-caller. For one `*Client`, only one request method may execute
at a time, and `destroy` may not overlap a request. It contains no client lock, active-request
counter, or concurrent-shutdown machinery.

## Build boundary

`build.zig` resolves the `tigerbeetle_c_artifacts` Zig package dependency, translates
`include/tb_client.h`, and links the matching archive through `add_tigerbeetle_c_module`. The
translated declarations are imported privately as `tigerbeetle_c`; application code imports the
wrapper module as `tigerbeetle`.

The release package and its header/archive contents are one versioned unit:

```text
tigerbeetle_c_artifacts/include/tb_client.h
tigerbeetle_c_artifacts/lib/aarch64-macos/libtb_client.a
tigerbeetle_c_artifacts/lib/aarch64-linux-gnu.2.27/libtb_client.a
```

The current immutable release asset is:

```text
https://github.com/ikolomiets/aws-lambda-zig-demo/releases/download/tigerbeetle-c-97c7a8ef385270ebe0e1b75959d3d21d134629df-pr3695-dde119796197d30e73cfc706cc18f58efee78735-pr3914-ce5d8f5ff585b0d3505a0f69946473fa2138b220/tigerbeetle-c-97c7a8ef385270ebe0e1b75959d3d21d134629df-pr3695-dde119796197d30e73cfc706cc18f58efee78735-pr3914-ce5d8f5ff585b0d3505a0f69946473fa2138b220.tar.gz
```

The release tag and asset identify the base and both patch heads. The verified tarball SHA-256 is
`5b64418ebdb3deb54b99c4374a916a869ced0b5bd8ace4dfa0a60c0cb5acd08b` and its size is 540,991 bytes.
The Zig package content hash is
`tigerbeetle_c_artifacts-65535.0.0+g97c7a8ef3.pr3695-fTLGi0aNGQC3xlGJoqTt6DVm9fZPGoBrSKcdqoZZgjNd`.
The root `build.zig.zon` records this hash with the URL. The package uses the Zig 0.16-compatible
version field `65535.0.0+g97c7a8ef3.pr3695`; the full requested provenance identifier
`65535.0.0+g97c7a8ef3.pr3695.gdde119796.pr3914.gce5d8f5ff` is retained in the release tag and
`PROVENANCE.md` because Zig 0.16 rejects version fields longer than 32 bytes. Do not mix a header
and archive from different TigerBeetle revisions or replace a release asset in place.

The package records these payload checksums in `SHA256SUMS`:

```text
include/tb_client.h                                      3ad1dd26fb67f3c89c971072cf22ad4a833971f6a40947ca562db2685587964d
lib/aarch64-linux-gnu.2.27/libtb_client.a                 66dc4532b426d52b5305f223d2a0206b4947822d1ce1eb8a69acc03c3467b142
lib/aarch64-macos/libtb_client.a                          3cd3c36a86a7b3d1eb935482c753924eb8d7a8d2d25e7e65827bede0a7d82a3c
LICENSE                                                    0d542e0c8804e39aa7f37eb00da5a762149dc682d7829451287e11b938e94594
```

The Linux archive is built for `aarch64-linux-gnu.2.27` and registers nonblocking sockets,
timerfds, and eventfds with TigerBeetle's epoll backend. The macOS archive remains
`aarch64-macos` and retains the Darwin backend. The header checksum and exported `tb_client_*`
symbol set match the previous release. The backport also decodes raw Linux syscall results with
`std.os.linux.E.init`, avoiding libc-aware errno decoding in the glibc-linked client. The previous
release remains available for rollback at:

```text
https://github.com/ikolomiets/aws-lambda-zig-demo/releases/download/tigerbeetle-c-97c7a8ef385270ebe0e1b75959d3d21d134629df/tigerbeetle-c-97c7a8ef385270ebe0e1b75959d3d21d134629df.tar.gz
```

`PROVENANCE.md` records the exact upstream commits, nine-file PR review, manually resolved
initialization-error mapping, patched source-tree hash, Zig compiler and SDK shim, build command,
targets, CPU features, and payload checksums. It is part of the package and is verified with the
same immutable release asset.

On a clean machine, fetch dependencies before building:

```sh
zig build --fetch=all
zig build test
```

Zig stores the verified package in its global cache. Subsequent builds are offline as long as the
cache entry remains available; no local `vendor/tigerbeetle` directory or custom download step is
required. `SHA256SUMS` and `PROVENANCE.md` inside the package provide an independent artifact
check and record the pinned TigerBeetle source commit, compiler, targets, and build mode.

To upgrade the client, build and verify a new complete header/archive set, update the package
version, provenance, and `SHA256SUMS`, preserve the package fingerprint, and publish a new
immutable release tag and asset. Run `zig fetch --save-exact=tigerbeetle_c_artifacts` with the new
release URL, then run all offline ABI/wrapper tests and the ARM64 Lambda build. Never mutate an
existing release asset.

## Public API

```zig
pub const Account = c.tb_account_t;
pub const Transfer = c.tb_transfer_t;
pub const CreateAccountResult = c.tb_create_account_result_t;
pub const CreateTransferResult = c.tb_create_transfer_result_t;

pub const Client = struct {
    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        cluster_id: u128,
        addresses: []const u8,
    ) Error!*Client;

    pub fn destroy(client: *Client) void;

    pub fn createAccounts(
        client: *Client,
        accounts: []const Account,
    ) Error![]CreateAccountResult;

    pub fn createTransfers(
        client: *Client,
        transfers: []const Transfer,
    ) Error![]CreateTransferResult;

    pub fn lookupAccounts(
        client: *Client,
        ids: []const u128,
    ) Error![]Account;
};
```

The allocator's backing state and the `std.Io` implementation must outlive the client. Every
returned slice belongs to the caller, including an empty slice, and must be freed with the
allocator supplied to `Client.create`:

```zig
const results = try client.createAccounts(accounts);
defer allocator.free(results);
```

`lookupAccounts` can return fewer accounts than IDs because missing IDs have no result. Callers
must match `Account.id` values rather than assume positional correspondence.

## Error set

```zig
pub const Error = error{
    OutOfMemory,
    Unexpected,
    AddressInvalid,
    AddressLimitExceeded,
    SystemResources,
    NetworkSubsystem,
    ClientInvalid,
    ClientClosed,
    TooMuchData,
    ClientEvicted,
    ClientReleaseTooLow,
    ClientReleaseTooHigh,
    InvalidOperation,
    InvalidDataSize,
    MalformedResult,
};
```

The error layers remain distinct:

- `tb_client_init` statuses become initialization errors.
- Immediate `tb_client_submit` failure becomes `ClientInvalid`.
- Packet statuses become client/session/transport errors.
- `MalformedResult` means the callback violated the wrapper's pointer, byte-size, or result-count
  bounds.
- `CreateAccountResult.status` and `CreateTransferResult.status` remain operation results; the
  wrapper does not translate them into Zig errors.

## Pinned client lifetime

TigerBeetle requires the address of `tb_client_t` to remain stable. `Client.create` therefore
heap-allocates the wrapper and returns `*Client`. It records both the wrapper and embedded C-client
addresses and asserts them before initialization returns, before submission, and during
deinitialization.

The cluster ID is encoded explicitly as 16 little-endian bytes before either native initializer is
called. Address length and packet byte length are checked before conversion to the C API's `u32`
fields.

The private `Client.create_echo` constructor uses `tb_client_init_echo` only for in-module tests. No
echo mode or C declarations are exposed by the public API.

## Pinned request lifetime

Each public operation allocates its largest possible result slice on the calling thread, then
creates one stack-local `Request`:

```zig
const Request = struct {
    io: std.Io,
    event: std.Io.Event = .unset,
    client_address: usize,
    result_buffer: []u8,
    result_size: usize = 0,
    callback_error: ?Error = null,
    packet: c.tb_packet_t,
    pinned_request_address: usize,
    pinned_packet_address: usize,
};
```

The packet is submitted only after the request has reached its final stack address. The request
stores that address and the address of its packet; both are asserted again in the native callback.
The request remains in scope until callback completion, so neither object moves while native code
can refer to it.

Empty inputs return an owned empty allocation before constructing or submitting a packet.

## Callback and `std.Io.Event`

TigerBeetle invokes the completion callback from its native client thread. The callback result
pointer is temporary and valid only until the callback returns, so the callback must finish the
copy before waking the caller.

The request uses a one-shot `std.Io.Event`:

```zig
fn wait(request: *Request) void {
    request.event.waitUncancelable(request.io);
    assert(request.event.isSet());
}

fn complete(
    request: *Request,
    result: ?[*]const u8,
    result_size_raw: u32,
) void {
    const result_size: usize = @intCast(result_size_raw);

    // Validate the destination bound and nullable source, then copy.
    // Store result_size or callback_error before publishing completion.

    request.event.set(request.io);
}
```

`Event.set` publishes all preceding callback writes. `waitUncancelable` observes those writes after
it returns. An event that is set before the caller starts waiting remains set, so early completion
does not lose a wakeup.

The callback never allocates and never retains TigerBeetle's result pointer. It only:

1. recovers `Request` from `packet.user_data`;
2. asserts the completion context, packet identity, and pinned addresses;
3. validates and copies the temporary result bytes into preallocated storage;
4. records callback state; and
5. sets the event.

Allocator calls remain on the calling thread, so the wrapper does not require a thread-safe
application allocator.

## Result validation and ownership

After the event is observed, the caller:

1. maps the packet status;
2. returns any callback validation error;
3. requires `result_size` to be a multiple of the result element size;
4. requires the element count to be no larger than the operation's input count; and
5. shrinks the preallocated slice to the actual element count.

For `create_accounts` and `create_transfers`, one result per input event is the maximum. For
`lookup_accounts`, the input ID count is the maximum. The current TigerBeetle default full batch is
8189 events, but the wrapper checks the ABI byte bound and lets the native client report its
stricter `TB_PACKET_TOO_MUCH_DATA` status.

## Single-caller and shutdown contract

A client should normally be long-lived, but calls on that client must be serialized by the owning
application:

```text
Client.create
    |
    v
request -> wait for callback -> consume/free result
    |
    v
next request -> wait for callback -> consume/free result
    |
    v
Client.destroy
```

The wrapper does not attempt to detect or coordinate concurrent callers. Violating the contract can
race the application allocator and invalidates the documented lifetime guarantees. If a future
application needs concurrency, it must add an application-level owner or a separately designed
asynchronous facade rather than weakening this wrapper's contract.

TigerBeetle requests themselves have no client-side timeout: the native client retries until it
receives a reply or the client is shut down. `std.Io.Event.waitUncancelable` intentionally mirrors
that request lifetime.

## Lambda integration rule

The wrapper is not imported by any current Lambda in this change. A future Lambda that imports it
must use:

```zig
.single_threaded = false,
```

TigerBeetle invokes the Zig completion callback from a native thread. Compiling that Lambda as
single-threaded would make the wrapper's synchronization assumptions invalid. Existing Lambda
settings remain unchanged until a Lambda actually adopts this module.

## Offline tests

`src/tigerbeetle.zig` keeps its tests in the module so they can inspect private status-mapping
helpers and private `tigerbeetle_c` constants without exposing either in the public API. The suite
covers:

- zero and non-symmetric little-endian cluster IDs;
- every documented init, client, and packet status plus unknown-status fallbacks;
- empty inputs for all public operations;
- a native echo submission with byte-for-byte result comparison;
- completion before waiting;
- null, oversized, and element-misaligned callback results;
- shrinking and caller ownership of result allocations; and
- stable client and embedded C-client addresses through native deinitialization.

Commands:

```sh
zig build test-tigerbeetle-wrapper
zig build test-tigerbeetle-c-abi
zig build test-tigerbeetle-c-abi-linux
zig build test-tigerbeetle-wrapper-linux
zig build test
```

`test-tigerbeetle-wrapper-linux` compiles, but does not run, the wrapper tests for glibc ARM64
Linux while linking the vendored Lambda archive. `zig build test` includes the host wrapper suite
and needs no live TigerBeetle cluster.

## Live integration tests

`tests/tigerbeetle_integration.zig` exercises the public wrapper against cluster ID `0` at
`127.0.0.1:3000` by default. A test-only `TIGERBEETLE_ADDRESSES` environment variable can override
that address (for example, for a Docker-host gateway); production Lambda configuration is not
changed by this override. The test root also receives `tigerbeetle_c` as a test-only import so it can assert
the exact C flags and statuses for created objects, existing accounts, linked-chain failures,
open-ended chains, an account with ledger zero, and a transfer with a missing debit account. The
wrapper itself does not re-export those constants, and business validation statuses remain result
values rather than Zig transport errors.

Confirm that the local cluster is reachable before running the dedicated live step:

```sh
zig build test-tigerbeetle
```

TigerBeetle requests have no client-side timeout and retry until they receive a reply or the client
is shut down. If no cluster is listening at the documented address, a submitted test request will
wait indefinitely. The live step is intentionally not a dependency of `zig build test`, so the
default suite remains network-independent.

The live test uses one long-lived, single-caller `Client`. Its baseline scenario creates two
accounts, retries one identical account, performs account lookups with a missing ID, posts a
transfer, and proves that a transfer rejected for a missing debit account leaves both existing
balances unchanged.

The execution-accounting preflight first looks up operator-provisioned account `1` (ledger `1`),
creates a unique account, posts a `100`-unit transfer from it to account `1`, and replays both
requests to verify the identical `exists` results. It never creates or modifies account `1`.

The linked-account scenarios cover all three chain outcomes:

- A two-account chain sets `linked` only on the first event, returns `created` for both events, and
  stores both accounts.
- A valid linked account followed by a terminal account with ledger zero returns
  `linked_event_failed` and `ledger_must_not_be_zero` in request order. Neither account is stored.
- A final account with `linked` returns `linked_event_chain_open` and is not stored.

The linked-transfer scenarios use a dedicated debit and credit account so their balance assertions
are isolated from the baseline transfer:

- A two-transfer chain sets `linked` only on the first event, returns `created` for both events, and
  posts the sum of both amounts to the account pair.
- A valid linked transfer followed by a terminal transfer with a unique missing debit account
  returns `linked_event_failed` and `debit_account_not_found` in request order. A balance snapshot
  proves that all pending and posted counters remain unchanged.
- A final transfer with `linked` returns `linked_event_chain_open`. A second balance snapshot proves
  that it also leaves every balance counter unchanged.

Create results are dense for the release-package client and are matched to input events in request order.
Lookup responses still omit missing IDs, so every account lookup is matched by `Account.id`, never
by result position.

Each run generates one TigerBeetle-style time-based base ID from the current Unix millisecond in
the high 48 bits and random data in the low 80 bits. The 19 account and transfer IDs are consecutive
values from that base, and failures print the complete set. Successful TigerBeetle records are
immutable and intentionally are not deleted, so rerun the same live command to create a new set
instead of cleaning up records.

## Sources of truth

- Generated C API: `include/tb_client.h` in the pinned `tigerbeetle_c_artifacts` package
- Artifact provenance: `PROVENANCE.md` and `SHA256SUMS` in that package
- TigerBeetle request behavior: `docs/coding/requests.md` in the pinned TigerBeetle documentation
- Linked-event behavior: `docs/coding/linked-events.md` in the pinned TigerBeetle documentation
- Account creation: `docs/reference/requests/create_accounts.md` in the pinned documentation
- Transfer creation: `docs/reference/requests/create_transfers.md` in the pinned documentation
- Account lookup: `docs/reference/requests/lookup_accounts.md` in the pinned documentation
- Zig event memory ordering: `std.Io.Event` in the Zig 0.16 standard library
