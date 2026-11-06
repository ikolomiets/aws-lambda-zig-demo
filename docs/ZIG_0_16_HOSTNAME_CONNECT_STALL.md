# Zig 0.16 multi-address connect stall with a small async worker budget

## Summary

Zig 0.16.0's `std.Io.net.HostName.connect` can stall behind one nonresponsive
address instead of making progress through another reachable address when the
threaded I/O backend has fewer than two async workers available.

The default threaded I/O worker limit is one less than
`std.Thread.getCpuCount()`. A process that reports two CPUs therefore gets one
async worker. `HostName.connect` uses that worker to run `connectMany`, leaving
no worker for its per-address connection tasks. The first connection task then
runs eagerly on the `connectMany` worker. If that address blocks, later
addresses are not attempted.

This was reproduced independently with direct `HostName.connect` calls and
through `std.http.Client` using the repository-pinned AWS SDK transport. It was
then confirmed in a 128 MB ARM64 AWS Lambda running Amazon Linux 2023.

Suggested upstream issue title:

> `std.Io.net.HostName.connect` stalls on an unreachable first address when the
> threaded async limit is one

## Affected environment

- Zig 0.16.0
- `aarch64-linux-gnu.2.34`, ReleaseSafe, multithreaded build
- Amazon Linux 2023 ARM64 container
- Zig's default `std.process.Init` threaded I/O backend
- one or two logical CPUs visible to the process
- a hostname with at least two addresses
- an earlier address whose TCP connection remains pending
- a later address that is immediately reachable

The production confirmation used an ARM64 Lambda configured with 128 MB of
memory. `std.Thread.getCpuCount()` consistently returned two. The regional
dual-stack hostname consistently resolved in this order:

```text
family_index=0 family=ip4
family_index=1 family=ip6
```

The Lambda VPC had working IPv6 egress but no usable IPv4 internet egress. The
SQS request began and then reached the 15-second Lambda timeout without an HTTP
response or transport error.

Account-specific values and raw addresses are intentionally omitted. The
[current build status](#status) records the toolchain and workaround in use.

## Standalone deterministic reproducer

[`tests/hostname_connect_repro.zig`](../tests/hostname_connect_repro.zig) runs
directly with `zig test`, independently of the project build and dependencies.
It uses the selected standard library's real `HostName.connect` implementation
and `std.Io.Threaded` scheduler. Only hostname lookup, IP connection, and socket
closing are simulated, so no DNS configuration, network access, Docker, or AWS
credentials are required.

Lookup supplies a pending IPv4 address followed by an immediately successful
IPv4 address. The pending attempt performs a cancelable one-second sleep; if
the sleep expires, the fixture records that fact and returns `error.Timeout`.
Even if `HostName.connect` subsequently returns the successful stream, the test
fails with `HostNameConnectStalled`. This bounds the injected stall without
using `ConnectOptions.timeout` or leaving the original bug hanging indefinitely.
Successful runs also verify the returned address, stream closure, and that any
started pending attempt is canceled before `HostName.connect` returns.

The three named tests set async limits explicitly to zero, one, and two,
independently of host CPU count. The concurrent limit remains unlimited,
matching the threaded backend's default. Zero and one async workers model
the one- and two-CPU defaults; two workers provide the control.

The following historical Zig 0.16.0 commands use the
[original fixture at revision `c15da407`](https://github.com/ikolomiets/aws-lambda-zig-demo/blob/c15da407207805542e5e22f117206e3e9d357064/tests/hostname_connect_repro.zig)
in that checkout. The current fixture uses Zig 0.17's socket-closing API:

```sh
zig version

# Patched standard library from the sibling checkout.
zig test tests/hostname_connect_repro.zig -OReleaseSafe \
  -fno-single-threaded --zig-lib-dir ../zig/lib

# Stock standard library bundled with the installed compiler.
env -u ZIG_LIB_DIR zig test tests/hostname_connect_repro.zig \
  -OReleaseSafe -fno-single-threaded
```

The Zig 0.16.0 results verified on native Apple Silicon macOS are:

| Async workers | Stock library | Patched sibling library |
| ---: | --- | --- |
| 0 | `FAIL (HostNameConnectStalled)` | pass |
| 1 | `FAIL (HostNameConnectStalled)` | pass |
| 2 | pass | pass |

The stock command intentionally exits with status 1; the patched command exits
with status 0. The reproducer is kept outside `zig build test` because the
stock Zig 0.16.0, 0.17.0, and 0.17.1 libraries fail these regression cases.
To run only the minimal two-CPU case, append
`--test-filter 'one async worker'` to either command.

Run the current fixture from the repository root with Zig 0.17.1 and each library:

```sh
zig version

# Stock library: expected to fail the zero- and one-worker cases.
env -u ZIG_LIB_DIR zig test \
  tests/hostname_connect_repro.zig -Osafe -fno-single-threaded

# Patched Zig 0.17.1 library used by the TigerBeetle processor executable.
zig test tests/hostname_connect_repro.zig -Osafe \
  -fno-single-threaded --zig-lib-dir ../zig/lib
```

All three tests passing means this scheduling reproducer no longer detects the
stall. A `HostNameConnectStalled` failure means a successful second address
still waits for the first attempt to expire. A compilation error is an API
compatibility problem and does not establish whether the stall persists.
On 2026-11-06, the Zig 0.17.0 release compiler with its bundled library on
Apple Silicon macOS passes the two-worker control and fails the zero- and
one-worker cases with `HostNameConnectStalled`. The scheduling defect remains
reproducible with Zig 0.17.0. The fixture uses its `netClose` socket API.

The same check on 2026-11-06 with Zig 0.17.1 on Apple Silicon macOS produces:

| Async workers | Bundled 0.17.1 library | Patched sibling 0.17.1 library |
| ---: | --- | --- |
| 0 | `FAIL (HostNameConnectStalled)` | pass |
| 1 | `FAIL (HostNameConnectStalled)` | pass |
| 2 | pass | pass |

The sibling checkout's scheduling patch is commit `8bc16754`. The patched
command exits with status 0; the stock command exits with status 1.

This fixture isolates address scheduling and cancellation. It does not exercise
real DNS, TCP sockets, IPv6 routing, or the Linux networking backend, and it does
not cover reversed address order or every losing-stream cleanup scenario.

## Real-network reproduction model

Use an isolated Linux/aarch64 container network with:

1. a local HTTP server listening on a reachable IPv6 address;
2. a hostname such as `dual.test` mapped first to an IPv4 address whose TCP
   connection remains pending and then to the server's IPv6 address;
3. the client container restricted to one or two CPUs; and
4. an external five-second watchdog around the client process.

The IPv4 address must actually leave `connect` pending. An address that returns
`ENETUNREACH`, `ECONNREFUSED`, or another immediate error does not reproduce the
failure.

A minimal direct client is:

```zig
const std = @import("std");

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("connect failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const host = try std.Io.net.HostName.init("dual.test");
    var stream = try host.connect(init.io, 8080, .{ .mode = .stream });
    defer stream.close(init.io);
    std.debug.print("connected\n", .{});
}
```

Compile it for the same target used by the affected Lambda:

```sh
zig build-exe \
  -OReleaseSafe \
  -target aarch64-linux-gnu.2.34 \
  direct-connect.zig
```

Run the resulting Linux/aarch64 executable in the controlled network. For the
two-CPU case, use a CPU restriction equivalent to:

```sh
docker run --cpuset-cpus 0-1 ... /direct-connect
```

Do not use Zig's `ConnectOptions.timeout` to bound this Zig 0.16 Linux test.
The POSIX implementation currently panics with:

```text
TODO implement netConnectIpPosix with timeout
```

Use a process-level watchdog so that the watchdog does not create a separate
failure inside the code under test.

## Observed results

The IPv4 entry was nonresponsive and the IPv6 HTTP server was reachable in all
dual-stack cases.

| Client | Visible CPUs | Address set | Result |
| --- | ---: | --- | --- |
| Pinned HTTP transport | 1 | IPv6 only | connected in 1 ms |
| Pinned HTTP transport | 1 | IPv4 then IPv6 | exceeded 5-second watchdog |
| Pinned HTTP transport | 1 | IPv6 then IPv4 | exceeded 5-second watchdog |
| Pinned HTTP transport | 2 | IPv4 then IPv6 | exceeded 5-second watchdog |
| Pinned HTTP transport | 3 | IPv4 then IPv6 | connected through IPv6 in 3 ms |
| Pinned HTTP transport | 10 | IPv4 then IPv6 | connected through IPv6 in 2 ms |
| Direct `HostName.connect` | 1 | IPv4 then IPv6 | exceeded watchdog in 3/3 runs |
| Direct `HostName.connect` | 2 | IPv4 then IPv6 | exceeded 5-second watchdog |
| Direct `HostName.connect` | 3 | IPv4 then IPv6 | connected immediately |

The controls show that these elements are load-bearing:

- multiple address results;
- one address that remains pending;
- a default async worker budget below two; and
- use of `HostName.connect`, directly or through the HTTP client.

The Linux/aarch64 target matches production. A native macOS baseline was also
green against real SQS, but it did not inject the same IPv4 failure and
therefore does not compare the two I/O backends.

TLS, AWS request signing, retries, response parsing, and the SQS service are not
required to reproduce the stall.

## Source-level mechanism

The relevant Zig standard-library path is:

```text
std.http.Client
  -> std.Io.net.HostName.connect
     -> io.async(connectMany, ...)
        -> group.async(enqueueConnection, ...) for each resolved address
           -> IpAddress.connect
```

`std.Io.Threaded.init` defaults `async_limit` to `cpu_count - 1`.
`std.Io.Threaded.async` and its group equivalent execute work immediately when
the async limit is already occupied. Immediate execution is permitted by those
APIs, but it is unsafe for this nested composition because an address connect
may block indefinitely.

With two reported CPUs, the sequence is:

1. `async_limit` is one.
2. `HostName.connect` schedules `connectMany`, consuming the only worker.
3. DNS yields the nonresponsive IPv4 address first.
4. `connectMany` calls `group.async` for that address.
5. The worker limit is already occupied, so `group.async` executes
   `enqueueConnection` eagerly on the `connectMany` worker.
6. The IPv4 `connect` remains pending.
7. `connectMany` never advances to the reachable IPv6 result.
8. The caller remains blocked waiting for a successful stream or a closed
   result queue.

With three reported CPUs, the default limit is two. The outer `connectMany`
task and the pending IPv4 task can coexist while the IPv6 attempt makes
progress, so the same test returns immediately through IPv6.

The one-CPU reversed-order result exposes a related edge case. With an async
limit of zero, `connectMany` itself runs eagerly on the caller. It can enqueue a
successful IPv6 stream, but it then blocks on the nonresponsive IPv4 address
before returning control to `HostName.connect`; the caller therefore cannot
consume the already queued success.

The defect is in the composition of `HostName.connect` and the threaded async
fallback, not in the documented eager fallback itself. A function intended to
race all resolved addresses must not run a potentially unbounded connection
attempt inline on the only task capable of scheduling or consuming the other
attempts.

## Expected behavior

A pending connection to one resolved address must not prevent a connection to
another resolved address from succeeding, regardless of the default threaded
async limit. At minimum, `HostName.connect` should preserve this property for
the default one- and two-CPU configurations supported by Zig.

Failure of every address may still return the most relevant connection error.
Cancellation must close losing streams and must not leak sockets or worker
tasks.

## Upstream regression-test requirements

An upstream test should use a controlled or mocked `Io` implementation rather
than depend on public routing behavior. It should provide two lookup results:

- the first connection remains pending until canceled; and
- the second connection succeeds immediately.

The test should verify the following configurations independently:

- no async workers;
- one async worker, matching a two-CPU default;
- two async workers;
- reachable address first and pending address second; and
- pending address first and reachable address second.

Every case must return the successful stream within a short bound, cancel the
pending attempt, close losing streams, and leave no task blocked after the
result is returned.

## Candidate implementation directions

These are design directions, not validated patches:

- avoid consuming one of the address-racing workers with the `connectMany`
  producer itself;
- reserve enough concurrency for at least two address attempts;
- do not eagerly execute a potentially blocking address connection when the
  group has no worker capacity;
- implement the race with nonblocking sockets and an evented Happy Eyeballs
  state machine; or
- make the sequential fallback explicitly bounded before advancing to the next
  address.

Merely increasing the default worker count hides the failure for the observed
two-address case but does not establish the required progress guarantee for
larger address sets or nested async users.

## Application-level mitigation options

Until Zig contains and the project adopts a verified fix, application
mitigations include:

- use an SQS interface VPC endpoint so the preferred IPv4 connection is
  reachable privately;
- provide controlled IPv4 egress, such as NAT, so the first connection does not
  remain pending;
- use a transport that explicitly implements bounded dual-stack connection
  racing; or
- carry a narrowly scoped Zig standard-library patch with the regression test
  described above.

Increasing Lambda memory or timeout is not a reliable fix. Memory may alter
reported CPU count and mask this particular worker threshold, while a longer
timeout only extends the stall.

## Status

The issue is confirmed against Zig 0.16.0 and the repository-pinned transport.
The standalone scheduling reproducer also detects the defect in stock Zig
0.17.0 and 0.17.1 as recorded above. The build supports Zig 0.17.x starting at
0.17.0; the verified compiler and patched library pair is 0.17.1. In `build.zig`,
only `tiger_beetle_processor_exe` selects the compatible patched standard library
with `.zig_lib_dir = .{ .cwd_relative = "../zig/lib" }`.
Keep that sibling checkout and its hostname-connect scheduling patch available
for Lambda builds and packaging. The checkout is external to this repository
and its patch is not pinned in `build.zig.zon`. The other five Lambda
executables, host tools, and ordinary tests use the compiler's bundled library.

The patched library passes all three standalone scheduling cases. These checks
establish compiler compatibility and simulated scheduling behavior; they do not
validate real DNS, Linux networking, or deployed Lambda connectivity.

Production diagnostic instrumentation was removed after evidence
collection, and the deployed Lambda was restored to the uninstrumented
artifact.
