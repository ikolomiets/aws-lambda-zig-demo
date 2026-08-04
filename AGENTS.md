# Repository Guidelines

## Repository and Sources of Truth

This repository is a small Zig 0.16.0 AWS Lambda example. The root build files
define the Lambda bootstrap executable, application code lives in `src/`, AWS
deployment material lives in `template.yaml`, `deploy.sh`, and `docs/`, and the
vendored `aws_lambda` dependency is under `zig-pkg/`.

Use these sources in order:

- `build.zig` and `build.zig.zon` define the supported Zig version, target
  selection, dependency graph, optimization mode, and installed executable.
- `src/main.zig` is the Lambda entrypoint and request handler.
- `template.yaml` defines the SAM-managed Lambda, Function URL, permissions,
  memory, timeout, runtime, and architecture.
- `deploy.sh` implements the supported automated AWS SAM deployment flow.
- `docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md` documents the supported deployment flow.
- `docs/TIGER_STYLE.md` is the mandatory coding style reference.

## Coding Style

Follow `docs/TIGER_STYLE.md` for Zig code. Treat it as a hard project
constraint, not background reading. Safety comes first, then performance, then
developer experience.

In practice:

- Keep control flow simple and explicit. Do not introduce recursion.
- Keep scopes small and minimize live variables.
- Prefer direct, concrete code over speculative abstraction.
- Put fixed bounds on work where practical and make important bounds visible.
- Use assertions for programmer errors, invariants, preconditions,
  postconditions, and boundary assumptions.
- Split compound assertions and complex boolean conditions into simpler checks.
- Use Zig errors for expected operating failures.
- Pass dependencies and effects explicitly; avoid hidden global state.
- Keep allocation ownership clear. Do not allocate where a caller-provided
  buffer, arena, or existing Lambda context resource is the right owner.
- Keep `comptime` small and purposeful.

When deviating from a Tiger Style rule because the Lambda runtime or Zig
standard library forces a tradeoff, document the reason in the code review or
change summary and keep the exception as narrow as possible.

## Architecture and Change Scope

Keep the project small. The current application has a single handler in
`src/main.zig`; do not add modules, layers, or helper packages until there is
real behavior that needs that structure.

Before changing deployment behavior, read the SAM template, deployment helper,
and SAM deployment doc. Public Function URL settings are intentionally demo-oriented;
do not widen IAM, CORS, runtime, timeout, memory, region, or profile assumptions
without updating the matching documentation and calling out the operational
effect.

Treat generated build artifacts as artifacts:

- `zig-out/bin/bootstrap` is produced by `zig build`.
- `lambda.zip` packages `zig-out/bin/bootstrap` for Lambda/SAM deployment.

Only refresh artifacts when the task requires a deployable package.

## Change-Impact Checklist

Keep changes scoped and update only affected files:

- Zig handler or build behavior: update `src/main.zig`, `build.zig`, or
  `build.zig.zon` as appropriate, then run formatting and build validation.
- SAM resources, permissions, function settings, or outputs: update
  `template.yaml` and `docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md`.
- Deployment helper behavior: update `deploy.sh` and
  `docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md`.
- Deployment artifact expectations: update the affected deployment docs.
- Any Zig code change: verify it still follows `docs/TIGER_STYLE.md`.

Avoid unrelated prose rewrites, hidden behavior changes, broad refactors, and
new dependencies unless the task explicitly needs them.

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

Use placeholders such as `<account-id>`, `<FunctionUrl>`, `<role-name>`, or
environment variables in documentation. When docs need a live value, document
the AWS CLI query that retrieves it instead of recording the value itself.

## Build and Validation

Use these local checks:

- `zig fmt --check build.zig src/main.zig`: verify Zig formatting.
- `zig build --release -Darch=arm`: build the stripped, single-threaded,
  ReleaseSafe Linux ARM64 Lambda `bootstrap`.
- `zip -qj lambda.zip zig-out/bin/bootstrap`: refresh the deployable package
  when a new package is required.
- `sam validate --template-file template.yaml --region ca-central-1`: validate
  the SAM template when `template.yaml` changes.
- `sam validate --lint --template-file template.yaml --region ca-central-1`:
  run stricter SAM validation when `template.yaml` changes.

Prefer local validation first. AWS CLI and SAM deploy commands can create,
modify, or expose cloud resources; run them only when the user explicitly asks
for deployment or authorizes cloud-side validation. If cloud validation cannot
run, report the unvalidated gap instead of implying it was completed.
