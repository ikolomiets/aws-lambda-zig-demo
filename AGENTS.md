# Repository Guidelines

## Repository and Sources of Truth

This is a Zig 0.16.0 AWS Lambda example with six handlers and host-native
`paseto`, `dynamodb`, `sqs`, `events`, and `ledger-counter` CLI tools. `build.zig` and `build.zig.zon` own
supported targets, optimization, executables, and pinned dependencies, including
`aws_lambda`.

Read sources relevant to the task:

| Task | Sources |
| --- | --- |
| HTTP intake or operation query | `src/intake_lambda.zig`, `src/query_lambda.zig`, `src/lambda_auth.zig` |
| Operation data and persistence | `src/operation.zig`, `src/operation_persistence.zig` |
| Seat contracts, Event metadata, and host tooling | `src/seat_reservation.zig`, `src/seat_reservation_persistence.zig`, `src/seat_events_cli.zig`, `events.sh`, [seat reference](docs/SEAT_RESERVATION.md), [Event utility setup and discovery](docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md#seat-event-metadata-utility) |
| Global ledger allocation and counter tooling | `src/ledger_counter.zig`, `src/ledger_counter_cli.zig`, `ledger-counter.sh`, [seat reference](docs/SEAT_RESERVATION.md#global-ledger-allocator), [counter setup and discovery](docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md#global-ledger-counter-utility) |
| Queue transport and Completion messages | `src/sqs_queue.zig`, `src/processor_message.zig`, [minimal Processor Messages ADR](docs/adr/0003-minimal-processor-messages.md) |
| Seat SQS processors | `src/seat_reservation_processor.zig`, `src/seat_reservation_completion_processor.zig`, [seat reference](docs/SEAT_RESERVATION.md) |
| Cross-handler behavior, recovery tests, or evidence assessment | [Workflow coverage index](docs/SEAT_WORKFLOW_EVIDENCE.md), [composed workflow suite](tests/seat_rejection_workflow.zig) |
| SQS processors | `src/tiger_beetle_processor.zig`, `src/tiger_beetle_completion_processor.zig`, [processor contract](docs/TIGER_BEETLE_PROCESSOR.md) |
| TigerBeetle client wrapper | `src/tigerbeetle.zig`, [wrapper design](docs/ZIG_WRAPPER_FOR_TIGERBEETLE.md) |
| SDK/client dependency internals | `build.zig.zon`, `zig build dependency-paths` with the active cache/fork options; [dependency source discovery](README.md#dependency-source-discovery) |
| PASETO and local CLI tools | `src/paseto.zig`, `src/paseto_cli.zig`, `src/persistence_cli.zig`, `src/queue_cli.zig`, `persistence.sh`, `queue.sh`, [persistence utility](docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md#10-create-read-update-and-delete-persisted-operations), [queue utility](docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md#11-send-receive-and-check-queued-operations) |
| Vocabulary or cross-cutting decisions | `GLOSSARY.md`, relevant files in `docs/adr/` |
| SAM resources, permissions, or function settings | `template.yaml`, [resource contract](docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md#4-understand-what-the-template-creates), [deployment values](docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md#5-preserve-the-intake-function-name-and-choose-deployment-values) |
| Generic deployment flow or development code updates | `deploy.sh`, [full deployment](docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md#6-deploy-with-sam-guided-mode), [development code updates](docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md#development-code-updates) |
| Deployment lifecycle | `deploy.sh`, [stack deletion](docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md#13-delete-the-sam-stack), [gateway deployment and disablement](docs/EC2-WireGuard-Gateway.md#10-deployment-and-disablement-lifecycle) |
| WireGuard setup and keys | `wireguard-gateway-setup.sh`, [gateway operation](docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md#7-configure-and-operate-the-wireguard-gateway), [key rotation](docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md#rotate-wireguard-keys) |
| Deployment or runtime diagnostics | `lambda_logs.sh`, [Lambda logs](docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md#9-download-lambda-logs), [gateway failures](docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md#diagnose-failures), [persistence configuration](docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md#troubleshoot-persistence-command-configuration), [Lambda initialization](docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md#troubleshoot-lambda-initialization) |

Consult related implementation files when behavior crosses these boundaries.
Keep processor contract changes in the processor reference, vocabulary in
`GLOSSARY.md`, and cross-cutting decisions in ADRs.
Write reference documentation in the present tense and describe only the current
contract. Keep change history and cutover instructions in the deployment guide;
record lasting cross-cutting decisions in ADRs.

## Agent skills

- **Issue tracker:** local Markdown issues under `.scratch/<effort>/`. Before reading
  or updating tickets, specs, or decision maps, read the
  [tracker conventions](docs/agents/issue-tracker.md).
- **Triage labels:** use the default role names. Before triaging incoming issues
  or changing triage labels, read the [label mapping](docs/agents/triage-labels.md).
- **Domain docs:** one root `GLOSSARY.md` and `docs/adr/`. Before engineering
  exploration, read the [domain documentation rules](docs/agents/domain.md).

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

Before selecting targeted checks, running final validation or diagnosing
check-environment failures, read the [local-check guide](docs/agents/local-checks.md).
Use its targeted checks during implementation and its complete offline checks
after final fixes.

The TigerBeetle processor build currently requires the sibling Zig standard
library at `../zig/lib`. Before a Lambda build, check `zig version` (0.16.0) and
`test -f ../zig/lib/std/Io/net/HostName.zig`. A missing checkout is an environment
prerequisite failure. File presence does not verify the patch; consult the
[hostname-connect workaround note](docs/ZIG_0_16_HOSTNAME_CONNECT_STALL.md) when
setting up or diagnosing this build.

For Zig code or build changes, check formatting and build the affected targets,
then select tests for the changed behavior. Documentation-only changes need link
and command consistency checks rather than an application rebuild. The
TigerBeetle processor must remain multithread-capable for its native callback
thread; the other five Lambda bootstraps are single-threaded.
