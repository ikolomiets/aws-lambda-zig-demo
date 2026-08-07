# aws-lambda-zig

A minimal AWS Lambda Function URL demo written in Zig.

The project builds a custom `provided.al2023` Lambda runtime executable named
`bootstrap`, a host-native PASETO v4.public utility named `paseto`, and a
host-native DynamoDB Operation utility named `dynamodb`. The handler
authenticates a PASETO v4.public bearer token before serving GET and POST
requests through the `aws-lambda-zig` runtime package. GET returns a plain-text
Lambda environment dump, while POST validates and hashes an Operation JSON
document, derives required tenant metadata from the verified token subject,
persists the Operation idempotently in DynamoDB, and returns the current stored
output view without the body.

## Requirements

- Zig 0.16.0 or newer within the supported 0.16.x line.
- AWS CLI v2 and AWS SAM CLI for the SAM deployment flow and stack queries.
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
`zig-out/bin/dynamodb` developer utilities. The Lambda `bootstrap` and PASETO
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

## DynamoDB CLI

The `dynamodb` utility creates, reads, and updates Operations in the SAM
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

If the CLI reports `dynamodb: missing or invalid configuration`, it has not
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
configuration loading are reported separately as `dynamodb: AWS request
failed`.

Create an Operation by supplying required tenant metadata separately and
sending the unchanged input JSON view on standard input. A tenant must be valid
UTF-8 between 1 and 64 bytes:

```sh
operation_json='{"id":"00112233-4455-6677-8899-aabbccddeeff",'\
'"name":"echo","body":{"message":"hello","count":2}}'
printf '%s\n' "$operation_json" \
  | zig-out/bin/dynamodb create --tenant 'tenant-a'
```

The Operation hash is the BLAKE3-256 digest of a JSON envelope containing only
`tenant`, `name`, and `body`, in that fixed order. The body is parsed once into an arena-owned
`std.json.Value` and serialized directly into the hash stream, so
insignificant whitespace and equivalent string escapes do not change the hash,
while object member order remains significant. The `id`, `state`,
`last_updated`, `expires_at`, and `result` fields are not included.
For reference,
`{"tenant":"tenant-a","name":"echo","body":{"message":"hello","count":2}}`
hashes to
`d271e3bd560113d2b82e42dfc46be33fb90b43d7f4b12114f3da4888eae445d4`.

Tenant is server-owned Operation metadata rather than an input JSON field. The
CLI accepts it only through `--tenant`, and Lambda derives it exclusively from
the verified PASETO `sub` claim. Supplying `tenant` inside the JSON document is
rejected to prevent spoofing.

Each CLI command and Lambda POST owns its Operation tenant, strings, body, and result
through one short-lived arena. Optional absence means a field is omitted from
that Operation view; an explicit JSON `null` remains a distinct
`std.json.Value`. Terminal results must be present and non-null.

A create is safe to retry with the original UUID, tenant, name, and body. If that UUID
already identifies an Operation with the same Operation hash, the retry
succeeds and returns the current stored Operation, including its state,
`last_updated`, `expires_at`, and terminal result when present. Reusing the UUID
for different content returns `dynamodb: operation conflict` with exit code
`1`. UUIDs are globally scoped, so reusing an ID under another tenant also
changes the hash and returns a conflict.

Read it with a strongly consistent DynamoDB read:

```sh
zig-out/bin/dynamodb read \
  --id 00112233-4455-6677-8899-aabbccddeeff
```

Updates may move to any state, including the current state. Pending states
require empty standard input, while terminal states require one non-null JSON
result of at most 4,096 input bytes whose compact serialization is also at most
4,096 bytes:

```sh
zig-out/bin/dynamodb update \
  --id 00112233-4455-6677-8899-aabbccddeeff \
  --state RUNNING \
  </dev/null

printf '%s\n' '{"message":"done"}' \
  | zig-out/bin/dynamodb update \
      --id 00112233-4455-6677-8899-aabbccddeeff \
      --state SUCCEEDED
```

A newly created item and every successful update set `expires_at` to exactly
86,400 seconds after `last_updated`, extending the Operation's DynamoDB lifetime
by 24 hours.

Every successful command emits the canonical Operation output JSON. Exit code
`1` identifies an expected missing or Operation-conflict outcome; exit code
`2` identifies invalid invocation or input, missing configuration, an AWS
failure, or an internal failure. Create and update conflicts both emit
`dynamodb: operation conflict`.

The persistent item contains exactly `id`, `tenant`, `name`, `state`,
`last_updated`, `expires_at`, `hash`, and an optional terminal `result`; it never
contains `body`. Tenant is a required DynamoDB `S` attribute. Creates use
`attribute_not_exists(id)` and request the existing item on
a failed condition so matching retries need no separate read. Updates first
perform a strongly consistent read and then condition on the complete snapshot,
including `expires_at`, so a concurrent change is reported instead of
overwritten. Updates preserve `id`, `tenant`, `name`, and `hash`. DynamoDB keeps `result`
as an `S` attribute containing the compact `std.json.Value` serialization.
Reads reject malformed, oversized, duplicate-key, explicit-null, or
noncanonical stored result strings.

The SAM table enables native DynamoDB TTL on `expires_at`. Expiration is
best-effort: an Operation becomes eligible for deletion after 24 hours but may
remain readable until DynamoDB removes it asynchronously. The item contract is
strict: legacy records without `tenant` are rejected and must be deleted and
recreated before this version reads them. There is no fallback decoder or
migration path in the application.

The Lambda Function URL requires the token in an HTTP authorization header:

```text
Authorization: Bearer <token>
```

Header names and the `Bearer` scheme are case-insensitive. Missing, malformed,
expired, or unverifiable credentials receive `401 Unauthorized` with
`WWW-Authenticate: Bearer`. Missing or invalid public-key configuration and
internal failures receive a sanitized `500 Internal Server Error`.
Invalid POST operation documents receive `400 Bad Request`. Authenticated
methods other than GET and POST receive `405 Method Not Allowed`. A POST that
reuses an Operation ID with a different server-computed hash receives a
sanitized `409 Conflict`; DynamoDB and malformed stored-item failures receive
the static `500 Internal Server Error` response.

Tenant is metadata and part of idempotency identity only. The DynamoDB `id`
partition key remains globally scoped, and this change does not add
tenant-scoped keys or new read authorization behavior.

`OPERATIONS_TABLE_NAME` is mandatory at Lambda initialization. The bootstrap
validates the table name, loads the AWS SDK configuration, and creates one
shared DynamoDB client before requesting an invocation. Missing or invalid
table configuration prevents all request handling, including GET. Table
existence and IAM authorization are checked only when POST first calls
DynamoDB, so those failures are returned as sanitized HTTP 500 responses.

## Deploy

The supported deployment path is AWS SAM:

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

The SAM-managed DynamoDB table, `OPERATIONS_TABLE_NAME` environment variable,
and table-scoped `GetItem`, `PutItem`, and `UpdateItem` IAM policy are mandatory
parts of the runnable application. Deploy the complete stack from
`template.yaml` with AWS SAM.

See [docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md](docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md)
for the full SAM workflow.

## Test The Function URL

After deployment, call the Function URL printed by SAM:

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

For a new ID, the response has `NEW` state, the invocation timestamp, its
24-hour expiry, verified subject as tenant, and the stable BLAKE3-256 operation
hash. The input body is intentionally omitted:

```json
{
  "id": "00112233-4455-6677-8899-aabbccddeeff",
  "tenant": "example-user",
  "name": "echo",
  "state": "NEW",
  "last_updated": 1700000000,
  "expires_at": 1700086400,
  "hash": "f4142429f9f7373c34b7b5eeab555ed5b4534a746193c40bfca65bb73f9a3014"
}
```

The POST is persisted before the response is generated. Retrying the same ID,
tenant, name, and body returns the latest stored state, timestamps, terminal
result when present, and hash. Reusing the ID for different work or from a
different verified subject returns `409 Conflict`.

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
- `src/dynamodb_cli.zig`: host DynamoDB Operation persistence CLI and its tests.
- `src/paseto.zig`: shared PASETO v4.public issuance and verification.
- `src/paseto_cli.zig`: host PASETO v4.public CLI and its tests.
- `build.zig`: Zig build graph for `bootstrap`, both host utilities, and tests.
- `build.zig.zon`: package metadata and pinned dependencies.
- `template.yaml`: SAM template for the Lambda, Function URL, and permissions.
- `docs/`: the SAM deployment guide, ADRs, and the Zig style reference.
- `AGENTS.md`: repository guidance for coding agents.

## Development Notes

Run formatting checks before committing Zig changes:

```sh
zig fmt --check build.zig src/main.zig src/operation.zig src/operation_persistence.zig \
  src/dynamodb_cli.zig src/paseto.zig src/paseto_cli.zig
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
