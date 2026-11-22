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
commit hook, and the aggregate offline Zig tests. Shell regression suites are
selected and run directly using the [selection table](#shell-regression-checks);
the gate checks their syntax only. Each failure stops the gate and preserves its
exit status, including when output is redirected to a log.
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
Shell regression suites are agent-selected checks outside the Zig build graph
and do not run through `check.sh` or CI. The workflow independently runs the
[AWS privacy scanner](#aws-privacy-check). This workflow needs no AWS credentials
or deployment permissions.

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
| `zig build check` | Combined offline and 13-case runtime Zig suite through the existing `test` and `test-runtime` runners; requires loopback socket permission, with no AWS credentials or live replica. Formatting remains separate. |
| `zig build test` | Full offline Zig suite; excludes socket-based runtime tests, the live replica, and separate ABI checks |
| `zig build test-http` | Intake and Query through application-owned HTTP types and the shared AWS payload 2.0 adapter with persistence and publication mocked. PASETO authentication and direct exchange with GitHub and secret retrieval simulated. |
| `zig build test-runtime` | Thirteen host integration cases through the real Lambda event loop and all seven handlers; requires loopback socket permission, with external effects mocked and no AWS credentials or live replica |
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
| `zig build package --release -Darch=arm` | Install the existing executables and create the seven Lambda ZIPs under `zig-out/packages/`; uses the same per-target libraries as the ordinary build. |
| `sam validate --template-file template.yaml --region ca-central-1` | SAM template validation when the template changes; requires SAM CLI |
| `sam validate --lint --template-file template.yaml --region ca-central-1` | Stricter SAM template validation; requires SAM CLI with lint support |

For shell changes, run `bash -n` on each affected script. The
[complete offline checks](#complete-offline-checks) cover all root entry points
and recursive shell scripts under `tests/` and `scripts/`.

### Local SAM validation with a fixture profile

Run this block from the repository root to validate the template with an
isolated AWS profile. The subshell supplies fixture credentials and removes
its temporary configuration on exit.

```sh
(
    set -eu
    sam_validation_config="$(mktemp "${TMPDIR:-/tmp}/sam-validation.XXXXXX")"
    trap 'rm -f "$sam_validation_config"' EXIT
    printf '[profile fixture]\nregion = ca-central-1\n' >"$sam_validation_config"

    unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
    export AWS_CONFIG_FILE="$sam_validation_config"
    export AWS_SHARED_CREDENTIALS_FILE=/dev/null
    export AWS_ACCESS_KEY_ID=fixture AWS_SECRET_ACCESS_KEY=fixture
    export AWS_EC2_METADATA_DISABLED=true SAM_CLI_TELEMETRY=0

    sam validate --profile fixture --template-file template.yaml --region ca-central-1
    sam validate --profile fixture --lint --template-file template.yaml --region ca-central-1
)
```

### Shell regression checks

When changing an existing shell script, select and run the applicable checks
below directly from the repository root. Update the checks when behavior changes.
Select every row whose behavior is affected; shared deployment and gateway changes
can require several suites. These tests use Bash and `jq`, temporary fixtures, and
mocked external commands, with no AWS credentials or network access. The privacy
tests also require Git. Shell regression suites belong outside the Zig build graph
and run only when selected by an agent; `check.sh` and CI check their syntax only.
The independent privacy scanner still runs in CI and the optional commit hook.

| Changed script or configuration and affected behavior | Direct check |
| --- | --- |
| `deploy.sh`, `wireguard-gateway-setup.sh`, `template.yaml`: cleanup, durable-data guards, SSO, and stack lifecycle | `bash tests/deploy_cleanup_lifecycle_test.sh` |
| `wireguard-gateway-setup.sh` and shared `deploy.sh` helpers: network discovery, preflight, and key configuration | `bash tests/deploy_wireguard_discovery_test.sh` |
| `deploy.sh`, `wireguard-gateway-setup.sh`: gateway options, deployment, disablement, and preserved configuration | `bash tests/deploy_gateway_interface_test.sh` |
| `deploy.sh`: package invocation, caches, compiler validation, artifact checks, and deployed function selection for code sync | `bash tests/deploy_packaging_test.sh` |
| `deploy.sh`, `wireguard-gateway-setup.sh`, `lambda_logs.sh`: processor names, options, and selectors | `bash tests/processor_interface_test.sh` |
| `deploy.sh`, `template.yaml`: Operations API routes, discovery, probes, throttling, access logs, and optional GitHub exchange routing and permissions | `bash tests/operations_api_test.sh` |
| `api-domain.sh`: custom-domain parsing, certificate/domain reuse, DNS instructions, mappings, and HTTPS probes | `bash tests/api_domain_test.sh` |
| `events.sh`: credentials, HTTP origin selection, Event commands, and polling | `bash tests/events_wrapper_test.sh` |
| `seat_scenarios.sh`: discovery, HTTP origin selection, scenarios, and evidence | `bash tests/seat_scenarios_test.sh` |
| `check.sh`: gate phases, arguments, recursive syntax checks, and failure propagation | `bash tests/check_gate_test.sh` |
| `scripts/check_aws_privacy.sh`, `.githooks/pre-commit`: scanner inputs, candidate detection, and commit rejection | `bash tests/aws_privacy_test.sh` |

### Interface migrations

Before changing an interface, record a brief behavior-to-test map in the ticket's
claim comment (or work notes for work without a ticket). Identify the agreed
behavioral interface, the existing behavior cases that move to it, the cases that
remain adapter compatibility or composition tests, and the focused check for
each group. For each affected boundary, name the tests and the observable
assertions that demonstrate the behavior. Cover the relevant existing cases and
required failure paths. Resolve coverage questions against the specification
before migrating the cases.

For a new outbound HTTP adapter, use the production HTTP client against a
loopback peer in the first runtime test. Record that boundary in the map.
Assert the method, path, relevant headers and body received by the peer, then
assert the caller's observable result after the peer returns its scripted
response.

For new behavior, get the focused test running and confirm it fails at the
intended assertion before implementing the change. Record the command and the
observed failure alongside the map. Run the focused check again after the change
and confirm the test passes.

Migrate one representative case and run its focused check before using it as an
example for small batches. For application HTTP and payload adapter checks, use
`zig build test-http --system zig-pkg`. For full Lambda event-loop coverage, use
the [runtime integration checks](#runtime-integration-checks). Compile and test
between batches so type and ownership errors remain local. Update the map when
the agreed scope changes. Spec review assesses the assertions against the map
before the final validation gate.

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
tests are selected [directly](#shell-regression-checks) and mock all deployment
commands.

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
valid after invocation arena resets.

The authentication cases drive the real entry point with simulated secret
reads. The mismatched OAuth App case sends the token check through the
production HTTP client to a loopback GitHub peer and verifies the request
before checking the Lambda's `401` response and Bearer challenge. The
valid-credential case verifies the returned PASETO.
[GitHub exchange runtime test](../../src/authentication_lambda.zig#L340)

The summary reports 13 passing cases. Cached compilation still executes them.

All external persistence, execution, and publication effects are mocked. Cloud
resource initialization is bypassed; these tests establish no live AWS or
TigerBeetle behavior. The socket-free seat processor tests retain their existing
coverage under `test-seat-processors` and the ordinary `test` target.

Host test wiring uses `sh`, `ln`, and `cp` to place a test facade beside a symlink
to the active `aws_lambda` source directory. It uses the same
resolved dependency, including `--fork` overrides, without copying upstream
sources. The seven runtime test variants enable only cases prefixed
`runtime integration:` and support multiple threads for the fake server.
Ordinary tests disable these cases, and production threading settings are
unchanged. Restricted environments need loopback socket permission for this
target; `zig build test` and the direct shell regression checks do not start the
fake server.

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
