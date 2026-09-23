# Zig 0.16 Wrapper for TigerBeetle

The maintained [processor design](TIGER_BEETLE_PROCESSOR.md) owns Body validation, execution,
replay and public Results. This reference owns native ABI, client packaging and lifetime mechanics.

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
        output: []CreateAccountResult,
    ) Error!usize;

    pub fn createTransfers(
        client: *Client,
        transfers: []const Transfer,
        output: []CreateTransferResult,
    ) Error!usize;

    pub fn lookupAccounts(
        client: *Client,
        ids: []const u128,
        output: []Account,
    ) Error!usize;
};
```

The allocator's backing state and the `std.Io` implementation must outlive the client.
Each call borrows input and output until return, including error returns. Output capacity must be
at least the input count (an asserted caller precondition). Creation returns exactly the input
count; lookup returns at most that count. No request allocates or shrinks result storage.
Callers free the original allocation, never the populated prefix:

```zig
const output = try allocator.alloc(tigerbeetle.Account, ids.len);
defer allocator.free(output);
const count = try client.lookupAccounts(ids, output);
const found = output[0..count];
```

`lookupAccounts` omits missing IDs. Match `Account.id` values rather than assuming positional
correspondence. Output outside the returned prefix is unspecified; capacity beyond the input count
is untouched. On error, ignore all output. Empty input returns zero without native submission.

Named `account_linked`, `account_debits_must_not_exceed_credits`, `transfer_linked`,
`transfer_pending`, and `transfer_post_pending_transfer` flags derive from the private pinned C
header. Each family's `created`, `exists`, and `linked_event_failed` statuses are also exported
with `account_` or `transfer_` prefixes. Raw status values remain u32. Existing singleton success
helpers are retained; they are insufficient to classify a linked chain.

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

Each public operation borrows its caller's typed result buffer and creates one stack-local `Request`:

```zig
const Request = struct {
    io: std.Io,
    event: std.Io.Event = .unset,
    callback_finished: std.atomic.Value(bool) = .init(false),
    client_address: usize,
    result_buffer: []u8,
    result_alignment: usize,
    result_element_size: usize,
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

Empty inputs return zero before constructing or submitting a packet.

## Callback and `std.Io.Event`

TigerBeetle invokes the completion callback from its native client thread. The callback result
pointer is temporary and valid only until the callback returns, so the callback must finish the
copy before waking the caller.

The request uses a one-shot `std.Io.Event` and a final atomic release/acquire handshake.
The callback validates byte length, source alignment, nullable pointer and destination capacity,
then copies ephemeral bytes and sets the event. It does not allocate or access Operation state.
An event set before waiting remains set, so early completion cannot lose a wakeup.

`Event.set` can still be executing `futexWake` after the waiter observes the event. Therefore its
return is followed by a final release-store to `callback_finished`, the callback's last access to
request memory. The caller waits uncancelably for the event, then observes that final store with
an acquire-load before returning or reusing any memory. The short handshake spin has no timeout;
like native completion itself, it requires the callback thread to make progress.

No callback code touches the request after that store. The pinned native client relinquishes the
packet before invoking the callback and does not touch it afterward. Client destruction joins the
native thread. Calls and destruction remain serialized by the application owner.

Immediate `TB_CLIENT_INVALID` submission does not acquire packet ownership or schedule a callback.
The pinned `ClientInterface.submit` checks the magic number and live context before calling the
submission vtable. The wrapper returns that ordinary error without waiting. Offline native tests
exercise a closed handle; the injected submission seam also proves output reuse after this error.

## Result validation and ownership

After completion ownership ends, the caller maps the packet status, returns any callback
validation error, and validates the populated count. Creation replies must contain exactly one
result per input; lookup counts may be zero through input count. Extra output capacity never
permits an oversized native reply. The returned count does not change allocation ownership.

The current native full batch is 8,189 events. The wrapper checks the ABI u32 byte bound and lets
the native client report its stricter `TB_PACKET_TOO_MUCH_DATA` status. Typed outputs preserve
alignment; malformed native byte lengths, nonzero-length null pointers and misaligned source
addresses return `MalformedResult` without unsafe typed pointer conversion.

## Single-caller and shutdown contract

A client should normally be long-lived, but calls on that client must be serialized by the owning
application:

```text
Client.create
    |
    v
request -> wait for callback -> consume/reuse output
    |
    v
next request -> wait for callback -> consume/reuse output
    |
    v
Client.destroy
```

The wrapper does not attempt to detect or coordinate concurrent callers. Violating the contract can
race borrowed storage and invalidates the documented lifetime guarantees. If a future
application needs concurrency, it must add an application-level owner or a separately designed
asynchronous facade rather than weakening this wrapper's contract.

TigerBeetle requests themselves have no client-side timeout: the native client retries until it
receives a reply or the client is shut down. `std.Io.Event.waitUncancelable` intentionally mirrors
that request lifetime.

## Lambda integration rule

The TigerBeetle processor owns one process-lived, pointer-stable client and retains
`.single_threaded = false` for native callbacks. The other Lambda threading settings are unchanged.
The execution adapter and its fake expose the same three borrowed batch methods. The processor
validates the complete Body and original Operation hash before admission. Typed plans reserve
commands/outcomes and borrow aliases from the parsed Body.

Execution finishes the invocation's account phase before eligible transfers, then runs requested
lookups. Each nonempty creation list is an intact independent chain. The executor packs whole lists
to 8,189 events, validating the complete reply before copying any represented Operation's statuses.
All-created and first-member matching exists with linked-failed suffixes (including singleton exists)
are accepted; late-member exists and differing fields remain rejection. Account rejection skips only
that Operation's transfers. Raw native codes are always preserved.

Lookup input retains order and repeated IDs across Operations. Nonrecursive heapsort orders scratch
positions and completed replies by ID; each requested ID needs zero or exactly its requested count
of field-identical Accounts. Validation precedes routing into original positions and aliases. No
prelookup, deduplication, extra native request or bytewise padding comparison is used.

All typed workspace allocations finish before native effects, and packets reuse the same borrowed
buffers after results are copied. A request error or malformed reply stops subsequent native calls;
earlier facts survive and fully determined Operations remain publishable. The ten-record invocation
bound needs at most three native calls and one Completion send. See
[execution evidence](TIGERBEETLE_EXECUTION_EVIDENCE.md) for native semantics, generated properties,
allocation instrumentation, and [complete local recovery evidence](TIGERBEETLE_RETRY_EVIDENCE.md).

After execution finishes or stops, publication skips unfinished Operations and sends terminal
Results in received order. Its ten-Result and byte bounds are independent of native packet and
invocation capacities. Only a successful serial send clears its represented source retries; the
first failed/ambiguous send stops publication and leaves that message and later work retryable.
Redelivery rebuilds from the unchanged Body, with original chains, IDs, timeout intervals and
inheritance sentinels. It retains no observation or native progress journal. Fresh observations
and rejection reasons may differ; the first conditional Completion persistence wins. Unresolved
work never becomes an exhaustion FAILURE. Local host tests do not prove deployed acknowledgement,
DynamoDB atomicity, Lambda ARM64 runtime/timeout/memory, networking or framework retention.

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
- exact creation counts, allocation failure, allocation-free reuse and original-allocation cleanup;
- delayed completion, immediate-submit-error ownership and source alignment; and
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

`tests/tigerbeetle_integration.zig` exercises the public wrapper against the existing development
cluster ID `0` at `127.0.0.1:3000`. Each test uses a fresh random ID namespace, so repeated runs
leave their records in the cluster without colliding with earlier test runs. The suite logs before
native calls; a call can wait if the replica is unavailable. Run it with:

```sh
zig build test-tigerbeetle
```

An optional isolated runner formats a unique temporary data file, starts its own replica, verifies
that its child owns the listener, and waits for all clients before stopping that replica and
deleting only its temporary directory. Its nondefault loopback port requires the runner's fixture
ownership marker; never set that marker for an arbitrary existing service:

```sh
bash tests/tigerbeetle_isolated_test.sh /absolute/path/to/verified/tigerbeetle <verified-server-sha256>
```

Build the server from commit `97c7a8ef385270ebe0e1b75959d3d21d134629df` with its pinned Zig 0.14.1
compiler and `--release=safe`; verify the checkout before computing the binary checksum. The
runner checks that checksum, the expected version string, and the actual client package's
provenance and payload checksums. It uses loopback port 33171 and fails if its child cannot own it.
The client remains the pinned patched tree `e9bb4085cb18500e37df9714b3eea1cc3f7b6d4e` described
above. Any identity mismatch requires investigation; do not substitute a newer server or client.

The suite uses fresh random ID namespaces with stable offsets within each test, ledger 7101 and its
own account pairs. No operator account is used. Baseline creation, singleton replay, sparse lookup, a posted
transfer, and missing-debit rejection verify exact statuses and balances. The execution-accounting
scenario creates its own credit account, posts 100 units and replays unchanged singleton requests.
Native requests have no client-side timeout. The live step is separate from `zig build test`.

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

All creation histories keep their original IDs, fields and chain membership. Successful records
are immutable; regular development runs leave them in place, while the isolated runner disposes of
only its own temporary cluster rather than attempting record deletion.
The suite starts native evidence for ticket 01, and must be extended and rerun against the final
implementation in ticket 05. See [the ticket-01 evidence record](TIGERBEETLE_NATIVE_BUFFERS_EVIDENCE.md)
for commands, identity checks, matrix coverage and runtime limitations.

## Sources of truth

- Generated C API: `include/tb_client.h` in the pinned `tigerbeetle_c_artifacts` package
- Artifact provenance: `PROVENANCE.md` and `SHA256SUMS` in that package
- TigerBeetle request behavior: `docs/coding/requests.md` in the pinned TigerBeetle documentation
- Linked-event behavior: `docs/coding/linked-events.md` in the pinned TigerBeetle documentation
- Account creation: `docs/reference/requests/create_accounts.md` in the pinned documentation
- Transfer creation: `docs/reference/requests/create_transfers.md` in the pinned documentation
- Account lookup: `docs/reference/requests/lookup_accounts.md` in the pinned documentation
- Zig event memory ordering: `std.Io.Event` in the Zig 0.16 standard library
