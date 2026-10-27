# Local checks

Run checks directly from the repository root against the current working tree,
including uncommitted development files.

## Complete offline checks

Use Bash for the shell-syntax loops:

```bash
zig build fmt-check --system zig-pkg
for script in ./*.sh; do
  bash -n "$script" || exit
done
while IFS= read -r -d '' script; do
  bash -n "$script" || exit
done < <(find tests -type f -name '*.sh' -print0)
zig build test --system zig-pkg
```

Run each command successfully before continuing. The sequence checks formatting,
root shell entry points and recursive shell harnesses under `tests/`, and the
existing aggregate offline test graph.
Review documentation changes using the [documentation review guide](documentation-checks.md).

Use focused checks during implementation and normally run this complete sequence
once after final fixes. Repeat or broaden validation when subsequent changes,
failures or unresolved concerns warrant it, and record the reason for another
complete run.

## Host and package prerequisites

Use an ARM64 macOS or ARM64 glibc Linux host, Zig **0.16.0**, Bash (tested with
**3.2 and 5.3**), `jq`, Python **3.9 or newer**, and `find`.
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
The patched sibling Zig standard library is a separate Lambda-build prerequisite;
the offline sequence does not build deployable Lambdas or refresh zip packages.

## Select checks by affected behavior

Use the host and package prerequisites above for Zig checks. The service and
deployment checks below have additional prerequisites and distinct evidence scopes.

| Check | Scope and additional prerequisites |
| --- | --- |
| `zig build fmt-check` | Formatting of build files and all Zig files under `src/` and `tests/` |
| `zig build test` | Full offline Zig and mocked deployment-helper suite, including composed workflows; excludes the SDK/local-database probe, live replica and separate ABI checks |
| `zig build test-deploy` | Mocked deployment regression tests, including durable-data guards, owned-resource cleanup and six-function code updates; requires Bash, `jq`, and Python 3.9+, with no AWS credentials or network access |
| `zig build build-events test-seat-reservation test-seat-persistence test-events-cli test-events-wrapper` | Host Events build and deterministic seat/domain/persistence/tooling tests |
| `zig build build-ledger-counter test-ledger-counter test-ledger-counter-cli test-ledger-counter-wrapper` | Host counter build and deterministic global allocation/tooling tests |
| `zig build build-seat-processors test-seat-workflow` | Compile host seat invocation adapters and run the [composed workflow suite](../../tests/seat_rejection_workflow.zig) with controlled external effects; covers cross-handler completion and recovery, without live services. See the [coverage index](../SEAT_WORKFLOW_EVIDENCE.md). |
| `zig build test-tigerbeetle-processor` | Processor parsing and invocation tests |
| `zig build test-tigerbeetle-wrapper` | Offline wrapper tests |
| `zig build test-tigerbeetle-c-abi` | Native C ABI smoke test on Apple Silicon macOS |
| `zig build test-tigerbeetle-c-abi-linux test-tigerbeetle-wrapper-linux` | Compile ARM64 glibc Linux ABI and wrapper tests; does not execute them |
| `./tests/seat_transactions_test.sh` | Separate pinned-SDK/DynamoDB Local probe; requires Docker with a running daemon, the pinned database image and curl. The runner supplies the isolated loopback fixture required by `zig build test-seat-transactions`; see the [probe procedure](../SEAT_TRANSACTIONS.md). |
| `TIGERBEETLE_ADDRESSES=127.0.0.1:3000 zig build test-tigerbeetle` | Live native integration tests against the separately authorized local development replica; establishes no AWS behavior |
| `zig build --release -Darch=arm` | Stripped ReleaseSafe ARM64 Lambda bootstraps and host CLI tools; requires the [patched sibling Zig library](../../AGENTS.md#build-and-validation). Building does not refresh zip packages; use the [packaging procedure](../DEPLOY_AWS_LAMBDA_WITH_SAM.md#2-build-and-package-the-zig-lambdas) when deployable packages are requested. |
| `sam validate --template-file template.yaml --region ca-central-1` | SAM template validation when the template changes; requires SAM CLI |
| `sam validate --lint --template-file template.yaml --region ca-central-1` | Stricter SAM template validation; requires SAM CLI with lint support |

For shell changes, run `bash -n` on each affected script. The
[complete offline checks](#complete-offline-checks) cover all root entry points
and recursive shell harnesses under `tests/`.

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
Separate ABI and live integration targets retain their existing explicit
validation paths.

Passing checks establishes formatting and tested behavior. Review links, command
names, options, integration prerequisites, and
Processor Message schemas against the
[documentation review scope](documentation-checks.md#manual-review).
