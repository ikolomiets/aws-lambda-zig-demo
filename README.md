# aws-lambda-zig

A minimal AWS Lambda Function URL demo written in Zig.

The project builds a custom `provided.al2023` Lambda runtime executable named
`bootstrap`, a host-native PASETO v4.public utility named `paseto`, and a
host-native DynamoDB Operation utility named `operation`. The handler
authenticates a PASETO v4.public bearer token before serving GET and POST
requests through the `aws-lambda-zig` runtime package. GET returns a plain-text
Lambda environment dump, while POST validates and hashes an Operation JSON
document and returns its output view without the body.

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

This also installs the host-native `zig-out/bin/paseto` and
`zig-out/bin/operation` developer utilities. The Lambda `bootstrap` and PASETO
utility both use the shared PASETO implementation in `src/paseto.zig`; the
Operation utility uses the shared model in `src/operation.zig` and the
DynamoDB adapter in `src/operation_persistence.zig`.

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

## Operation CLI

The `operation` utility creates, reads, and updates Operations in the SAM
stack's DynamoDB table. It requires `OPERATIONS_TABLE_NAME` and uses the
standard AWS configuration chain, including `AWS_PROFILE`, `AWS_REGION`, AWS
credential variables, shared AWS configuration files, and configured endpoint
overrides.

Discover the CloudFormation-generated table name after deploying the stack:

```sh
export AWS_PROFILE=dev
export AWS_REGION=ca-central-1
export OPERATIONS_TABLE_NAME="$(
  aws cloudformation describe-stacks \
    --stack-name aws-lambda-zig-demo \
    --query "Stacks[0].Outputs[?OutputKey=='OperationsTableName'].OutputValue" \
    --output text \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION"
)"
```

If the CLI reports `operation: missing or invalid configuration`, it has not
processed the Operation JSON yet. Confirm that table discovery returned a
non-empty value without printing the account-specific table name:

```sh
test -n "${OPERATIONS_TABLE_NAME:-}" && printf 'table configured\n'
```

The same diagnostic is used when `OPERATIONS_TABLE_NAME` is empty, longer than
255 bytes, or not a valid DynamoDB table name, and when the AWS configuration
chain cannot resolve settings such as the region or selected profile. Re-run
the discovery command above, check `AWS_PROFILE` and `AWS_REGION`, and use
`aws sso login --profile "$AWS_PROFILE"` first when the profile uses IAM
Identity Center. Credential or service failures encountered after
configuration loading are reported separately as `operation: AWS request
failed`.

Create an Operation by sending the existing input JSON view on standard input:

```sh
operation_json='{"id":"00112233-4455-6677-8899-aabbccddeeff",'\
'"name":"echo","body":{"message":"hello","count":2}}'
printf '%s\n' "$operation_json" | zig-out/bin/operation create
```

The Operation hash is the BLAKE3-256 digest of a JSON envelope containing only
`name` and `body`. The body is parsed and re-serialized before hashing, so
insignificant whitespace and equivalent string escapes do not change the hash,
while object member order remains significant. The `id`, `state`,
`last_updated`, and `result` fields are not included.

A create is safe to retry with the original UUID, name, and body. If that UUID
already identifies an Operation with the same Operation hash, the retry
succeeds and returns the current stored Operation, including its state,
`last_updated`, and terminal result when present. Reusing the UUID for different
content returns `operation: operation conflict` with exit code `1`.

Read it with a strongly consistent DynamoDB read:

```sh
zig-out/bin/operation read \
  --id 00112233-4455-6677-8899-aabbccddeeff
```

Updates may move to any state, including the current state. Pending states
require empty standard input, while terminal states require one non-null JSON
result of at most 4,096 serialized bytes:

```sh
zig-out/bin/operation update \
  --id 00112233-4455-6677-8899-aabbccddeeff \
  --state RUNNING \
  </dev/null

printf '%s\n' '{"message":"done"}' \
  | zig-out/bin/operation update \
      --id 00112233-4455-6677-8899-aabbccddeeff \
      --state SUCCEEDED
```

Every successful command emits the canonical Operation output JSON. Exit code
`1` identifies an expected missing or Operation-conflict outcome; exit code
`2` identifies invalid invocation or input, missing configuration, an AWS
failure, or an internal failure. Create and update conflicts both emit
`operation: operation conflict`.

The persistent item contains exactly `id`, `name`, `state`, `last_updated`,
`hash`, and an optional terminal `result`; it never contains `body`. Creates
use `attribute_not_exists(id)` and request the existing item on a failed
condition so matching retries need no separate read. Updates first perform a
strongly consistent read and then condition on the complete snapshot, so a
concurrent change is reported instead of overwritten. Updates preserve `id`,
`name`, and `hash`.

The Lambda Function URL requires the token in an HTTP authorization header:

```text
Authorization: Bearer <token>
```

Header names and the `Bearer` scheme are case-insensitive. Missing, malformed,
expired, or unverifiable credentials receive `401 Unauthorized` with
`WWW-Authenticate: Bearer`. Missing or invalid public-key configuration and
internal failures receive a sanitized `500 Internal Server Error`.
Invalid POST operation documents receive `400 Bad Request`. Authenticated
methods other than GET and POST receive `405 Method Not Allowed`.

## Deploy

The preferred deployment path is AWS SAM:

```sh
sam validate --template-file template.yaml --region ca-central-1
sam validate --lint --template-file template.yaml --region ca-central-1
export PASETO_PUBLIC_KEY='<public-key-from-keygen>'
sam deploy --guided \
  --template-file template.yaml \
  --profile dev \
  --region ca-central-1 \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    FunctionName=aws-lambda-zig-demo \
    LambdaPrincipal='*' \
    PasetoPublicKey="$PASETO_PUBLIC_KEY"
```

`LambdaPrincipal` sets the Lambda runtime environment variable
`LAMBDA_PRINCIPAL`. The default `'*'` preserves the public demo behavior; pass a
different value when the function should see a narrower principal string.
`PasetoPublicKey` is required and sets the `PASETO_PUBLIC_KEY` verification
configuration. It is public key material; keep the corresponding private key
only in the signing environment.

See [docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md](docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md)
for the full SAM workflow.

There is also a manual AWS CLI deployment guide:
[docs/DEPLOY_AWS_LAMBDA_WITH_CLI.md](docs/DEPLOY_AWS_LAMBDA_WITH_CLI.md).

## Test The Function URL

After deployment, call the Function URL printed by SAM or the AWS CLI:

```sh
curl -i -L <FunctionUrl>
```

An unauthenticated request receives:

```text
HTTP/2 401
WWW-Authenticate: Bearer
```

Issue a token with the matching private key, then call the URL with it:

```sh
token="$(
  PASETO_PRIVATE_KEY='<private-key-from-keygen>' \
    zig-out/bin/paseto issue --subject 'example-user' --ttl-seconds 300
)"
curl -L -H "Authorization: Bearer $token" <FunctionUrl>
```

The authenticated GET response preserves the demo output:

```text
Hello, example-user!

ConfigMeta
...

RequestMeta
...

Environment
...
```

POST an Operation JSON document with the same bearer token:

```sh
curl -L \
  -H "Authorization: Bearer $token" \
  -H "Content-Type: application/json" \
  --data \
    '{"id":"00112233-4455-6677-8899-aabbccddeeff",'\
'"name":"echo","body":{"message":"hello","count":2}}' \
  <FunctionUrl>
```

The response has `NEW` state, the invocation timestamp, and the stable
BLAKE3-256 operation hash. The input body is intentionally omitted:

```json
{
  "id": "00112233-4455-6677-8899-aabbccddeeff",
  "name": "echo",
  "state": "NEW",
  "last_updated": 1700000000,
  "hash": "ab9a059eb68c36bddaffb5bdd23aa7177c3a97dc34f9af54eb06f1c488ac3662"
}
```

The template intentionally creates a publicly reachable Function URL for demo
HTTP GET and POST testing, while the handler enforces PASETO bearer
authentication.
Production endpoints should also consider stricter infrastructure
authorization, narrower IAM policies, or a fronting layer such as API Gateway
or CloudFront.

## Project Layout

- `src/main.zig`: Lambda entrypoint and request handler.
- `src/operation.zig`: Operation JSON model, validation, and hash contract.
- `src/operation_persistence.zig`: DynamoDB Operation mapping and conditional writes.
- `src/operation_cli.zig`: host Operation persistence CLI and its tests.
- `src/paseto.zig`: shared PASETO v4.public issuance and verification.
- `src/paseto_cli.zig`: host PASETO v4.public CLI and its tests.
- `build.zig`: Zig build graph for `bootstrap`, both host utilities, and tests.
- `build.zig.zon`: package metadata and pinned dependencies.
- `template.yaml`: SAM template for the Lambda, Function URL, and permissions.
- `docs/`: deployment guides and the Zig style reference.
- `AGENTS.md`: repository guidance for coding agents.

## Development Notes

Run formatting checks before committing Zig changes:

```sh
zig fmt --check build.zig src/main.zig src/operation.zig src/operation_persistence.zig \
  src/operation_cli.zig src/paseto.zig src/paseto_cli.zig
```

Run the handler, persistence, and host utility tests with:

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
