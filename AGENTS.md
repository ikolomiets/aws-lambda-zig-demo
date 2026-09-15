# Repository Guidelines

## Repository and Sources of Truth

This is a Zig 0.16.0 AWS Lambda example with four handlers and host-native
`paseto`, `dynamodb`, and `sqs` CLI tools. `build.zig` and `build.zig.zon` own
supported targets, optimization, executables, and pinned dependencies, including
`aws_lambda`.

Read sources relevant to the task:

| Task | Sources |
| --- | --- |
| HTTP intake or operation query | `src/intake_lambda.zig`, `src/query_lambda.zig`, `src/lambda_auth.zig` |
| Operation data and persistence | `src/operation.zig`, `src/operation_persistence.zig` |
| Queue transport and Completion messages | `src/sqs_queue.zig`, `src/processor_message.zig` |
| SQS processors | `src/tiger_beetle_processor.zig`, `src/tiger_beetle_completion_processor.zig`, [processor contract](docs/TIGER_BEETLE_PROCESSOR.md) |
| TigerBeetle client wrapper | `src/tigerbeetle.zig`, [wrapper design](docs/ZIG_WRAPPER_FOR_TIGERBEETLE.md) |
| PASETO and local CLI tools | `src/paseto.zig`, `src/paseto_cli.zig`, `src/persistence_cli.zig`, `src/queue_cli.zig` |
| Vocabulary or cross-cutting decisions | `CONTEXT.md`, relevant files in `docs/adr/` |
| SAM resources, permissions, or function settings | `template.yaml`, relevant sections of [deployment guide](docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md) |
| Generic deployment flow | `deploy.sh`, relevant sections of the deployment guide |
| WireGuard lifecycle | `wireguard-gateway-setup.sh`, relevant sections of the deployment guide |

Consult related implementation files when behavior crosses these boundaries.
Keep processor contract changes in the processor reference, vocabulary in
`CONTEXT.md`, and cross-cutting decisions in ADRs.

## Coding Style and Scope

For Zig changes, follow [Tiger Style for agents](docs/TIGER_STYLE_AGENT.md),
which owns the project-specific defaults, compatibility exceptions, and triggers
for consulting the extended guide. Keep assertions central: encode programmer
invariants with assertions and handle expected operating failures with Zig errors.

Keep the project small; add modules or layers only when real behavior needs them.
Avoid unrelated cleanup and hidden behavior changes. Add dependencies only when
the requested task requires them; explain their security, performance, and
maintenance costs in the change summary.

Update affected deployment documentation when changing SAM resources, deployment
helpers, or artifact expectations. Public Function URLs are intentionally
demo-oriented; changes to IAM, CORS, runtime, timeout, memory, region, or profile
assumptions must be documented with their operational effects.

Only refresh Lambda zip packages when the task requires a deployable package.
Build validation may regenerate `zig-out/`; treat its outputs as generated artifacts.
The deployment guide owns packaging commands and artifact paths.

## Completion and Authorization

Complete the requested change, update affected documentation, run relevant
validation, and fix regressions introduced by the change. Continue through these
local steps without asking for approval at each step. Report unrelated failures
and remaining validation gaps accurately. After checks pass, repeat or broaden
validation only when new changes, failures, or unresolved concerns justify it.

Deployment-helper tests use mocked AWS commands and require no credentials or
network access. Live TigerBeetle tests are separately authorized against the local
replica at `127.0.0.1:3000`; do not substitute a remote cluster.

AWS CLI and SAM deploy commands can create, modify, or expose cloud resources;
run them only when the user explicitly requests deployment or authorizes
cloud-side validation. Leave changes uncommitted unless a commit is requested.

## Commit Messages

Leave agent-made changes uncommitted for code review. Do not create a commit at
the end of a session unless the user explicitly requests one.

Write commit messages that are sufficiently detailed for a future maintainer to
understand the change without reconstructing it from the diff. Use a concise
imperative subject, followed by a body for non-trivial changes that explains the
problem or motivation, the material behavior and operational effects, important
safety or migration decisions.

## Security and Private AWS Details

Before committing or publishing changes, check tracked and newly added files for
AWS details that should remain private. Do not check in:

- AWS access keys, secret access keys, session tokens, SSO cache data, or CLI
  credential/config files.
- Concrete 12-digit AWS account IDs, account-specific ARNs, assumed-role ARNs,
  or IAM principal identifiers unless the user explicitly approves publishing
  them.
- Real Lambda Function URLs, CloudFormation stack outputs, API Gateway URLs,
  S3 bucket names, or other account-specific endpoints that are not intended to
  be public documentation.
- Local deployment artifacts, generated packages, or command output that embeds
  account data.

Use placeholders such as `<account-id>`, `<IntakeFunctionUrl>`, `<role-name>`, or
environment variables in documentation. When docs need a live value, document
the AWS CLI query that retrieves it instead of recording the value itself.

## Build and Validation

The TigerBeetle processor build currently requires the sibling Zig standard
library at `../zig/lib`. Before a Lambda build, check `zig version` (0.16.0) and
`test -f ../zig/lib/std/Io/net/HostName.zig`. A missing checkout is an environment
prerequisite failure. File presence does not verify the patch; consult the
[hostname-connect workaround note](docs/ZIG_0_16_HOSTNAME_CONNECT_STALL.md) when
setting up or diagnosing this build.

Select checks by the affected behavior:

| Check | Scope |
| --- | --- |
| `zig build fmt-check` | Formatting of build files and all Zig files under `src/` and `tests/` |
| `zig build test` | Full local Zig and mocked deployment-helper suite; excludes the live replica and separate ABI checks |
| `zig build test-deploy` | Mocked deployment regression tests; requires Bash and `jq` |
| `zig build test-tigerbeetle-processor` | Processor parsing and invocation tests |
| `zig build test-tigerbeetle-wrapper` | Offline wrapper tests |
| `zig build test-tigerbeetle-c-abi` | Native C ABI smoke test on Apple Silicon macOS |
| `zig build test-tigerbeetle-c-abi-linux test-tigerbeetle-wrapper-linux` | Compile ARM64 Linux ABI and wrapper tests; does not execute them |
| `TIGERBEETLE_ADDRESSES=127.0.0.1:3000 zig build test-tigerbeetle` | Live integration tests against the local development replica |
| `zig build --release -Darch=arm` | Stripped ReleaseSafe ARM64 Lambda bootstraps and host CLI tools |
| `sam validate --template-file template.yaml --region ca-central-1` | SAM template validation when the template changes |
| `sam validate --lint --template-file template.yaml --region ca-central-1` | Stricter SAM template validation |

For shell changes, run `bash -n` on each affected script. To check the deployment
helpers and shell tests together, use:

```sh
for script in deploy.sh wireguard-gateway-setup.sh lambda_logs.sh tests/*.sh; do
  bash -n "$script" || exit
done
```

For Zig code or build changes, check formatting and build the affected targets,
then select tests for the changed behavior. Documentation-only changes need link
and command consistency checks rather than an application rebuild. The
TigerBeetle processor must remain multithread-capable for its native callback
thread; the other three Lambda bootstraps are single-threaded.
