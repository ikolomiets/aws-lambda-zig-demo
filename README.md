# aws-lambda-zig

A minimal AWS Lambda Function URL demo written in Zig.

The project builds a custom `provided.al2023` Lambda runtime executable named
`bootstrap` and a host-native PASETO v4.public utility named `paseto`. The
handler returns a plain-text response with Lambda config metadata, request
metadata, and environment variables through the `aws-lambda-zig` runtime
package.

## Requirements

- Zig 0.16.0 or newer within the supported 0.16.x line.
- AWS CLI v2 for manual AWS operations.
- AWS SAM CLI for the SAM deployment flow.
- An AWS profile with permission to create Lambda, IAM, and CloudFormation
  resources.

The deployment docs use:

- AWS profile: `dev`
- Region: `ca-central-1`
- Function name: `aws-lambda-zig-demo`

Adjust those values for your AWS account as needed.

## Build

Build the stripped, single-threaded, ReleaseSafe Linux ARM64 Lambda executable:

```sh
zig build --release -Darch=arm
```

This also installs the host-native `zig-out/bin/paseto` developer utility. The
Lambda `bootstrap` does not link PASETO code.

Verify that the output is a statically linked ARM64 Linux executable:

```sh
file zig-out/bin/bootstrap
```

Expected shape:

```text
ELF 64-bit LSB executable, ARM aarch64, statically linked, stripped
```

Package the executable for Lambda:

```sh
zip -qj lambda.zip zig-out/bin/bootstrap
```

`lambda.zip` is intentionally ignored by Git because it is a generated
deployment artifact.

## PASETO CLI

Generate an Ed25519 signing key pair with OS cryptographic randomness:

```sh
zig-out/bin/paseto keygen
```

The command prints padded standard-Base64 values for
`PASETO_PRIVATE_KEY` and `PASETO_PUBLIC_KEY`, plus the public key's standard
PASERK `k4.pid` identifier. Copy the private value into the signing
environment and the public value into the verification environment:

```sh
export PASETO_PRIVATE_KEY='<private-key-from-keygen>'
token="$(
  zig-out/bin/paseto issue \
    --subject 'example-user' \
    --ttl-seconds 300
)"

unset PASETO_PRIVATE_KEY
export PASETO_PUBLIC_KEY='<public-key-from-keygen>'
printf '%s\n' "$token" | zig-out/bin/paseto verify
```

`issue` creates only the `sub` and integer `exp` claims. `verify` requires the
explicit public key, authenticates the PASERK identifier in the footer, accepts
one token of at most 16 KiB from standard input, and enforces `now < exp`
without clock-skew allowance.

Treat `PASETO_PRIVATE_KEY` as a secret. Do not put it in the Lambda environment
or logs, source it from untrusted shell output, commit it, or pass it on a
command line. The demo handler redacts the exact `PASETO_PRIVATE_KEY` variable
if one is present, but that safeguard is not a secret-management system and
does not cover differently named variables. Verification needs only
`PASETO_PUBLIC_KEY`; it never falls back to the private key.

## Deploy

The preferred deployment path is AWS SAM:

```sh
sam validate --template-file template.yaml --region ca-central-1
sam validate --lint --template-file template.yaml --region ca-central-1
sam deploy --guided \
  --template-file template.yaml \
  --profile dev \
  --region ca-central-1 \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    FunctionName=aws-lambda-zig-demo \
    LambdaPrincipal='*'
```

`LambdaPrincipal` sets the Lambda runtime environment variable
`LAMBDA_PRINCIPAL`. The default `'*'` preserves the public demo behavior; pass a
different value when the function should see a narrower principal string.

See [docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md](docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md)
for the full SAM workflow.

There is also a manual AWS CLI deployment guide:
[docs/DEPLOY_AWS_LAMBDA_WITH_CLI.md](docs/DEPLOY_AWS_LAMBDA_WITH_CLI.md).

## Test The Function URL

After deployment, call the Function URL printed by SAM or the AWS CLI:

```sh
curl -L <FunctionUrl>
```

Expected response:

```text
ConfigMeta
...

RequestMeta
...

Environment
...
```

The template intentionally creates a public Function URL for demo HTTP GET
testing. Production endpoints should use stricter authorization, narrower IAM
policies, or a fronting layer such as API Gateway or CloudFront.

## Project Layout

- `src/main.zig`: Lambda entrypoint and request handler.
- `src/paseto_cli.zig`: host PASETO v4.public CLI and its tests.
- `build.zig`: Zig build graph for `bootstrap`, `paseto`, and both test roots.
- `build.zig.zon`: package metadata and pinned dependencies.
- `template.yaml`: SAM template for the Lambda, Function URL, and permissions.
- `docs/`: deployment guides and the Zig style reference.
- `AGENTS.md`: repository guidance for coding agents.

## Development Notes

Run formatting checks before committing Zig changes:

```sh
zig fmt --check build.zig src/main.zig src/paseto_cli.zig
```

Run the handler and PASETO integration tests with:

```sh
zig build test
```

When developing against a sibling checkout of `aws-lambda-zig`, keep
`build.zig.zon` pinned and override the dependency at build time:

```sh
zig build --fork=../aws-lambda-zig --release -Darch=arm
```

Use the same local checkout in the deployment helper with:

```sh
./deploy.sh --dry-run --use-local-libs
```

Zig code in this repository should follow
[docs/TIGER_STYLE.md](docs/TIGER_STYLE.md).
