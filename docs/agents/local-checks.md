# Local checks

Run checks directly from the repository root against the current working tree,
including uncommitted development files.

## Complete offline checks

Run the executable gate against the current working tree:

```sh
./check.sh --offline
```

The [gate](../../check.sh) checks the compiler version, formatting, root shell
entry points, recursive shell scripts under `tests/` and `scripts/`, the optional
commit hook, and the existing aggregate offline test graph. Each failure stops the gate and
preserves its exit status, including when output is redirected to a log.
`ZIG_PACKAGE_DIR` selects an already provisioned package directory (default:
`zig-pkg`); build-cache environment settings also apply. The gate performs no
dependency fetching, packaging, or deployment.
Review documentation changes using the [documentation review guide](documentation-checks.md).

Run `./check.sh` for the complete gate, including loopback runtime tests after
the offline checks. `--runtime` remains a compatibility alias for this default.
Use `--offline` when loopback access is unavailable.

Use focused checks during implementation and normally run this complete sequence
once after final fixes. Repeat or broaden validation when subsequent changes,
failures or unresolved concerns warrant it, and record the reason for another
complete run.

### Automatic checks

The [Checks workflow](../../.github/workflows/checks.yml) runs on pushes and pull
requests using `ubuntu-24.04-arm`. It provisions the pinned Zig 0.17.1 compiler
with SHA-256 verification and the packages pinned by `build.zig.zon`, then runs
`./check.sh`. Provisioning requires network access; the checks use the
provisioned packages and mock external effects. The runtime suite uses loopback.
This workflow needs no AWS credentials or deployment permissions.

After publishing the workflow, configure the GitHub branch rules to require
**Offline and runtime checks** before merging. A workflow file alone does not
make its result a required merge check.

For a lightweight local commit check, opt into the repository-managed hook:

```sh
git config --local core.hooksPath .githooks
```

The [hook](../../.githooks/pre-commit) checks staged whitespace and runs the
[AWS privacy check](#aws-privacy-check). It does not run the full suite or change
staged content. Hooks are optional and bypassable; CI runs the full gate.

## Host and package prerequisites

Use an ARM64 macOS or ARM64 glibc Linux host, Zig **0.17.x** (minimum **0.17.0**;
validated with **0.17.1**), Bash (tested with **3.2 and 5.3**), `jq`, `find`,
and Git. Validation tooling and the privacy scanner use shell scripts.
The native TigerBeetle archive in the pinned packages targets glibc 2.27 or newer.

Provision every pinned dependency from [build.zig.zon](../../build.zig.zon),
including transitive packages, before checking. Provisioning is a separate step
that requires network access:

```sh
zig build --fetch
```

Pass `--system zig-pkg` to Zig checks to use provisioned package sources without
fetching. To use another already provisioned package directory, replace `zig-pkg`
with that directory in each command. Relative paths resolve from the checkout.
Build-cache environment settings such as `ZIG_LOCAL_CACHE_DIR` and
`ZIG_GLOBAL_CACHE_DIR` still apply. Provisioning does not upgrade dependency pins.
Use the compiler's bundled standard library for tests and host tools. The
TigerBeetle processor executable requires a compatible patched library at
`../zig/lib` through its `build.zig` override; retain that sibling checkout for
Lambda builds and packaging. See the
[hostname-connect workaround](../ZIG_0_16_HOSTNAME_CONNECT_STALL.md#status).
The offline sequence does not build deployable Lambdas or refresh ZIP packages.
Ordinary builds also leave ZIPs untouched. When deployable packages are requested,
use the explicit `package` check below and follow the
[packaging procedure](../DEPLOY_AWS_LAMBDA_WITH_SAM.md#2-build-and-package-the-zig-lambdas)
for archive filenames and validation.

## Select checks by affected behavior

Use the host and package prerequisites above for Zig checks. The service and
deployment checks below have additional prerequisites and distinct evidence scopes.

| Check | Scope and additional prerequisites |
| --- | --- |
| `zig build fmt-check` | Formatting of build files and all Zig files under `src/` and `tests/` |
| `zig build check` | Combined offline and eleven-case runtime suite through the existing `test` and `test-runtime` runners; requires loopback socket permission, with no AWS credentials or live replica. Formatting remains separate. |
| `zig build test` | Full offline Zig and mocked deployment-helper suite; excludes socket-based runtime tests, the live replica, and separate ABI checks |
| `zig build test-http` | Intake, Query, and PASETO authentication through application-owned HTTP types and the shared AWS payload 2.0 adapter, with persistence and publication mocked |
| `zig build test-agent-tools` | Offline validation-gate and AWS privacy scanner tests using temporary repositories and mocked compiler commands |
| `zig build test-runtime` | Eleven host integration cases through the real Lambda event loop and all six handlers; requires loopback socket permission, with external effects mocked and no AWS credentials or live replica |
| `zig build test-deploy` | Mocked regression tests for cleanup lifecycle, gateway discovery and interfaces, and processor interfaces; requires Bash and `jq`, with no AWS credentials or network access |
| `zig build build-events test-seat-reservation test-seat-persistence test-events-cli` | Host Events build and deterministic seat/domain/persistence/tooling tests |
| `zig build build-ledger-counter test-ledger-counter test-ledger-counter-cli` | Host counter build and deterministic global allocation/tooling tests |
| `zig build build-seat-processors` | Compile host seat invocation adapters without live services or Lambda packaging |
| `zig build test-seat-processors` | Composed seat submission and completion tests with mocked external effects |
| `zig build test-tigerbeetle-processor` | Processor parsing and invocation tests |
| `zig build test-tigerbeetle-wrapper` | Offline wrapper tests |
| `zig build test-tigerbeetle-c-abi` | Native C ABI smoke test on Apple Silicon macOS |
| `zig build test-tigerbeetle-c-abi-linux test-tigerbeetle-wrapper-linux` | Compile ARM64 glibc Linux ABI and wrapper tests; does not execute them |
| `TIGERBEETLE_ADDRESSES=127.0.0.1:3000 zig build test-tigerbeetle` | Live native integration tests against the separately authorized local development replica; establishes no AWS behavior |
| `zig build --release -Darch=arm` | Stripped ARM64 Lambda bootstraps in `safe` mode and host CLI tools; uses a compatible patched library at `../zig/lib` for the TigerBeetle processor and the bundled library for other targets. Building does not refresh zip packages; use the [packaging procedure](../DEPLOY_AWS_LAMBDA_WITH_SAM.md#2-build-and-package-the-zig-lambdas) when deployable packages are requested. |
| `zig build package --release -Darch=arm` | Install the existing executables and create the six Lambda ZIPs under `zig-out/packages/`; uses the same per-target libraries as the ordinary build. |
| `sam validate --template-file template.yaml --region ca-central-1` | SAM template validation when the template changes; requires SAM CLI |
| `sam validate --lint --template-file template.yaml --region ca-central-1` | Stricter SAM template validation; requires SAM CLI with lint support |

For shell changes, run `bash -n` on each affected script. The
[complete offline checks](#complete-offline-checks) cover all root entry points
and recursive shell scripts under `tests/` and `scripts/`.

### Interface migrations

Before changing an interface, record a brief behavior-to-test map in the ticket's
claim comment (or work notes for work without a ticket). Identify the agreed
behavioral interface, the existing behavior cases that move to it, the cases that
remain adapter compatibility or composition tests, and the focused checks for
each group. Account for the relevant existing cases and required failure paths;
test counts alone do not establish coverage. Resolve coverage questions against
the specification before migrating the cases.

Migrate one representative case and run its focused check before using it as an
example for small batches. For HTTP changes, use
`zig build test-http --system zig-pkg`. Compile and test between batches so type
and ownership errors remain local. Spec review assesses behavioral coverage against the map before the final
complete gate; update the map when the agreed scope changes.

## AWS privacy check

Before committing, run the versioned scanner against staged content:

```sh
bash scripts/check_aws_privacy.sh --staged
```

For publishing a committed change, set `BASE_REF` to the reviewed baseline and run:

```sh
bash scripts/check_aws_privacy.sh --base "$BASE_REF" --head HEAD
```

The [scanner](../../scripts/check_aws_privacy.sh) requires Bash, Git, and `jq`.
It examines added lines in modified files and full contents of new files.
Staged mode reads the index, independently
of unstaged edits. Range mode resolves both refs to immutable trees. Renames are
treated as deletion/addition; changed binary files are scanned in full. Deleted
content is excluded. CI compares a pull request's base with its tested merge
commit, or a push's previous tip with its new tip. A new branch uses its merge
base with the default branch; an initial default-branch push scans the tree.

Candidates include AWS access keys, labelled secret keys and session tokens,
12-digit account IDs (including account-specific ARNs), IAM principal IDs,
recognized deployment endpoints, S3 bucket references, and AWS credential/config
or SSO cache paths. UUIDs, CloudFormation substitutions, environment references,
and angle-bracket placeholders are safe representations. The scanner reports
escaped paths, line numbers, and categories without printing matched values.
Exit status is 0 for no candidates, 1 for candidates requiring review, and 2 when
Git inputs cannot be read or arguments are invalid.

Review remains necessary for context-dependent identifiers, intended public
values, unrecognized endpoint formats, and unlabelled secrets. Replace private
values with placeholders; publication exceptions require the explicit user
authorization described in [repository guidance](../../AGENTS.md#security-and-private-aws-details).
The scanner supplies candidate evidence, not a guarantee that content is safe.

## Socket access in agent sandboxes

Keep formatting, ordinary builds, the complete offline checks, and mocked
deployment-helper tests in the default sandbox.

When the active agent sandbox restricts network access, request elevated
execution on the first attempt for each of these socket-based commands:

```sh
./check.sh
zig build check --system zig-pkg --summary all
zig build test-runtime --system zig-pkg
TIGERBEETLE_ADDRESSES=127.0.0.1:3000 zig build test-tigerbeetle --system zig-pkg
```

Run each command in a separate tool call with
`sandbox_permissions = "require_escalated"`. Explain the required access in
the request: `./check.sh` and `zig build check` include the offline suite and
`test-runtime`, which binds a fake Runtime API to `127.0.0.1` on an
operating-system-assigned port, with
external effects mocked; `test-tigerbeetle` connects to and writes test data in the separately authorized
local replica at `127.0.0.1:3000`. Keep that address explicit in the live command.
Where supported, scope reusable approval prefixes to `./check.sh`, `zig build check`,
`zig build test-runtime`, and `zig build test-tigerbeetle`, respectively.

If socket access is denied or elevated execution is unavailable, report the
affected suite as blocked by the environment and continue the unaffected
checks. A sandbox denial is a validation gap, not a passing or skipped test.

## Runtime integration checks

Run the socket-based suite separately from the complete offline sequence:

```sh
zig build test-runtime --system zig-pkg --summary all
```

To run both the offline and runtime suites through the shared gate, use:

```sh
zig build check --system zig-pkg --summary all
```

`./check.sh` runs formatting, shell syntax, the offline suite, and `test-runtime`
in order. Each failure stops the gate and preserves its exit status. `--offline`
omits only `test-runtime`; the existing `--runtime` option selects the default
complete gate.

`deploy.sh` builds through `package` in both full and development modes,
including dry runs, using the selected caches and dependency forks. Deployment
validates configuration, the compiler version, Lambda bootstraps, and ZIPs;
full deployment also validates the SAM template. Run the repository gate
separately before deployment. The helper requires no loopback test server, and
ordinary builds and `package` do not depend on tests. Deployment-helper regression
tests remain part of the offline gate and mock all deployment commands.

`test-runtime` starts a fake Runtime API on `127.0.0.1` with an operating-system-assigned
port. It exercises named HTTP API and Function URL events, base64 intake, authentication
precedence, cross-tenant warm query caching, malformed-event
failure and recovery, partial SQS acknowledgements, and Completion persistence
retry. It checks response/error paths and bodies, invocation-ID echoing and
missing-ID compatibility, and refreshed request and trace metadata. Tests copy
observations before invocation arenas reset and issue tokens against the current
clock. The query case freezes only the handler's cache clock so host scheduling
does not expire its one-second cache between scripted invocations.

Both Seat Reservation handlers use the same
[test support](../../tests/seat_test_support.zig). Their six cases
exercise ready-Event cache reuse across warm invocations, submission publication
retry, Completion retry after an uncertain write with authoritative submitted-state
readback, and malformed-SQS error reporting followed by successful processing.
Captured publications, writes and logs use test-owned memory so assertions remain
valid after invocation arena resets. The summary reports eleven passing cases;
cached compilation still executes all runtime tests.

All external persistence, execution, and publication effects are mocked. Cloud
resource initialization is bypassed; these tests establish no live AWS or
TigerBeetle behavior. The socket-free seat processor tests retain their existing
coverage under `test-seat-processors` and the ordinary `test` target.

Host test wiring uses `sh`, `ln`, and `cp` to place a test facade beside a symlink
to the active `aws_lambda` source directory. It uses the same
resolved dependency, including `--fork` overrides, without copying upstream
sources. The six runtime test variants enable only cases prefixed
`runtime integration:` and support multiple threads for the fake server.
Ordinary tests disable these cases, and production threading settings are
unchanged. Restricted environments need loopback socket permission for this
target; `zig build test` and `zig build test-deploy` do not start the fake server.

## Diagnose check-environment failures

1. Identify the checkout and failing command from its output. Checks accept
   uncommitted files and read the current working tree.
2. Inspect the Bash executable selected by PATH and its version:

   ```sh
   command -v bash
   bash --version
   ```

   For shell compatibility checks, put the selected Bash first on PATH for the
   entire process tree. The test harnesses launch nested `bash` commands, so an
   absolute interpreter path for only the outer script is insufficient.
3. Inspect the package directory passed to `--system`. Relative paths resolve
   from the checkout. Reuse an existing provisioned directory when checking
   another checkout.

## Validation scope

The offline sequence executes no live replica tests, AWS/cloud commands,
deployment or packaging steps, or documentation examples. Syntax-checking a live
shell harness does not execute it. The deployment tests use mocked AWS commands.
Socket-based runtime tests, ABI checks, and live integration tests have separate
explicit validation targets.

Passing checks establishes formatting and tested behavior. Review links, command
names, options, integration prerequisites, and
Processor Message schemas against the
[documentation review scope](documentation-checks.md#manual-review).
