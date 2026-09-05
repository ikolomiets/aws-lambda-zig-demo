# Repository Guidelines

## Repository and Sources of Truth

This repository is a small Zig 0.16.0 AWS Lambda example. The root build files
define the intake, query, TigerBeetle processor, and Completion processor bootstrap executables,
application code lives in `src/`, AWS
deployment material lives in `template.yaml`, `deploy.sh`,
`wireguard-gateway-setup.sh`, and `docs/`, while the vendored `aws_lambda`
dependency is under `zig-pkg/`.

Use these sources in order:

- `build.zig` and `build.zig.zon` define the supported Zig version, target
  selection, dependency graph, optimization mode, and installed executable.
- `src/intake_lambda.zig` is the authenticated POST intake entrypoint and handler.
- `src/query_lambda.zig` is the authenticated GET environment-query entrypoint and handler.
- `src/tiger_beetle_processor.zig` is the SQS-driven TigerBeetle processor entrypoint and handler.
- `src/completion_processor.zig` is the SQS-driven Completion processor entrypoint and handler.
- `src/completion_batch.zig` is the bounded ID-and-result Completion message contract.
- `src/lambda_auth.zig` is the shared bearer-token and PASETO verification module.
- `template.yaml` defines the SAM-managed Lambdas, Function URLs, permissions,
  memory, timeout, runtime, and architecture.
- `deploy.sh` implements the generic, state-preserving AWS SAM deployment flow.
- `wireguard-gateway-setup.sh` implements WireGuard gateway enablement,
  reconfiguration, peer configuration output, and guarded teardown.
- `docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md` documents the supported deployment flow.
- [`docs/TIGER_STYLE_AGENT.md`](docs/TIGER_STYLE_AGENT.md) is the concise,
  recommended operational style guide for Zig changes.
- [`docs/TIGER_STYLE.md`](docs/TIGER_STYLE.md) is the authoritative extended
  Tiger Style philosophy, rationale, and examples.

## Coding Style

Before modifying Zig code, read and follow the recommendations in
[`docs/TIGER_STYLE_AGENT.md`](docs/TIGER_STYLE_AGENT.md). Tiger Style is the
preferred default, with safety first, then performance, then developer
experience. It is not required when it conflicts with established codebase
behavior, architecture, or conventions, or when compliance would require
significant changes outside the task. Do not perform broad refactors or
unrelated cleanup solely for style compliance.

Keep the active use of assertions central to Zig changes. Assert programmer
errors, invariants, preconditions, postconditions, results, and boundary
assumptions; use Zig errors for expected operating failures. Assertions do not
need to satisfy a numeric quota.

Read the relevant section of [`docs/TIGER_STYLE.md`](docs/TIGER_STYLE.md) when:

- making architectural or performance-sensitive decisions;
- introducing an abstraction;
- changing memory-management or control-flow patterns;
- resolving ambiguity in the concise guide; or
- performing a dedicated design or code-quality review.

When a material Tiger Style recommendation is not suitable, document the
reason in the code review or change summary and keep the exception scoped to
the affected change.

## Architecture and Change Scope

Keep the project small. The application has four handlers, one shared authentication module
used by the HTTP handlers, and one shared Completion message module used by the SQS handlers;
do not add modules, layers, or helper packages until real behavior needs that structure.

Before changing deployment behavior, read the SAM template, both deployment
helpers, and the SAM deployment doc. Public Function URL settings are
intentionally demo-oriented;
do not widen IAM, CORS, runtime, timeout, memory, region, or profile assumptions
without updating the matching documentation and calling out the operational
effect.

Treat generated build artifacts as artifacts:

- `zig-out/bin/intake/bootstrap`, `zig-out/bin/query/bootstrap`,
  `zig-out/bin/tiger_beetle_processor/bootstrap`, and `zig-out/bin/completion_processor/bootstrap` are produced by
  `zig build`.
- `intake-lambda.zip`, `query-lambda.zip`, `tiger-beetle-processor.zip`, and
  `completion-processor.zip` package their matching bootstraps for Lambda/SAM.

Only refresh artifacts when the task requires a deployable package.

## Change-Impact Checklist

Keep changes scoped and update only affected files:

- Zig handler or build behavior: update the affected handler, `build.zig`, or `build.zig.zon`
  as appropriate, then run formatting and build validation.
- SAM resources, permissions, function settings, or outputs: update
  `template.yaml` and `docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md`.
- Generic deployment helper behavior: update `deploy.sh` and
  `docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md`.
- WireGuard lifecycle behavior: update `wireguard-gateway-setup.sh` and
  `docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md`.
- Deployment artifact expectations: update the affected deployment docs.
- Any Zig code change: review it against
  [`docs/TIGER_STYLE_AGENT.md`](docs/TIGER_STYLE_AGENT.md), subject to the
  compatibility and change-scope exceptions above.

Avoid unrelated prose rewrites, hidden behavior changes, broad refactors, and
new dependencies unless the task explicitly needs them.

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

Use these local checks:

- `zig fmt --check build.zig src/completion_batch.zig src/completion_processor.zig src/tiger_beetle_processor.zig src/intake_lambda.zig src/lambda_auth.zig src/query_lambda.zig`:
  verify Zig formatting.
- `zig build test-deploy`: run only the local deployment-helper
  regression tests; these use mocked AWS commands, require Bash and `jq`, and need
  no credentials or network access.
- `bash -n deploy.sh wireguard-gateway-setup.sh lambda_logs.sh tests/*.sh`: verify deployment
  helper and shell-test syntax.
- `zig build test`: run the Zig tests and the deployment-helper regression
  tests.
- `zig build --release -Darch=arm`: build the stripped ReleaseSafe Linux ARM64 intake,
  query, TigerBeetle processor, and Completion processor bootstraps. TigerBeetle processor remains multithread-capable
  for the TigerBeetle callback thread; the other three are single-threaded.
- `zip -qj intake-lambda.zip zig-out/bin/intake/bootstrap` and
  `zip -qj query-lambda.zip zig-out/bin/query/bootstrap` and
  `zip -qj tiger-beetle-processor.zip zig-out/bin/tiger_beetle_processor/bootstrap` and
  `zip -qj completion-processor.zip zig-out/bin/completion_processor/bootstrap`: refresh deployable
  packages when required.
- `sam validate --template-file template.yaml --region ca-central-1`: validate
  the SAM template when `template.yaml` changes.
- `sam validate --lint --template-file template.yaml --region ca-central-1`:
  run stricter SAM validation when `template.yaml` changes.

Prefer local validation first. AWS CLI and SAM deploy commands can create,
modify, or expose cloud resources; run them only when the user explicitly asks
for deployment or authorizes cloud-side validation. If cloud validation cannot
run, report the unvalidated gap instead of implying it was completed.
