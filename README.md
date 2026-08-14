# aws-lambda-zig

A minimal AWS Lambda demo written in Zig.

The project builds custom `provided.al2023` intake, query, and execution Lambda bootstraps
and a host-native PASETO v4.public utility named `paseto`. The
stack-aware `persistence.sh` and `queue.sh` commands manage Operations in
DynamoDB and SQS, while `lambda_logs.sh` downloads any function's CloudWatch
logs. The HTTP handlers use `src/lambda_auth.zig` to authenticate a PASETO v4.public
bearer token through the `aws-lambda-zig` runtime package. The query Lambda
accepts only `GET /<uuid>`, strongly reads the Operation from DynamoDB, and
returns it only when its tenant matches the verified token subject. The intake
Lambda accepts only POST, validates and hashes an
Operation JSON document, derives required tenant metadata from the verified
token subject, persists the Operation idempotently in DynamoDB, submits new
work to SQS, and returns the current stored output view without the body.
The execution Lambda consumes SQS batches and best-effort completes valid
`SUBMITTED` Operations in DynamoDB with `result: {"success":true}`. It logs
each record's message ID and body, then acknowledges every parsed record even
when validation or the conditional update fails.

## Requirements

- Zig 0.16.0 or newer within the supported 0.16.x line.
- AWS CLI v2 and AWS SAM CLI for the SAM deployment flow and stack queries.
- `jq` for the Lambda log download helper.
- An AWS profile with permission to create Lambda, IAM, and CloudFormation
  resources.

The deployment docs use:

- AWS profile: `dev`
- Region: `ca-central-1`
- Intake function name: `intake-lambda`
- Query function name: `query-lambda`
- Execution function name: `execution-lambda`

Adjust those values for your AWS account as needed.

Before updating an existing `aws-lambda-zig-demo` stack, reuse the current
`IntakeFunction` physical name as `IntakeFunctionName`. `deploy.sh` enforces
that match so the existing intake Lambda and Function URL stay managed in
place. The query Lambda, its Function URL, and the SQS-driven execution Lambda are added
alongside them.

## Build

Build the stripped, single-threaded, ReleaseSafe Linux ARM64 Lambda executables:

```sh
zig build --release -Darch=arm
```

This also installs the host-native `zig-out/bin/paseto` utility and the local
implementations invoked by `persistence.sh` and `queue.sh`. The intake and query
bootstraps and the PASETO utility use the shared PASETO implementation in
`src/paseto.zig`; the persistence and queue commands use the shared model in
`src/operation.zig`. The Lambda and local commands reach AWS through
`src/operation_persistence.zig` and `src/operation_queue.zig`.

Verify that all three Lambda outputs are statically linked ARM64 Linux executables:

```sh
file zig-out/bin/intake/bootstrap \
  zig-out/bin/query/bootstrap \
  zig-out/bin/execution/bootstrap
```

Expected shape:

```text
ELF 64-bit LSB executable, ARM aarch64, statically linked, stripped
```

Package the executables for Lambda:

```sh
zip -qj intake-lambda.zip zig-out/bin/intake/bootstrap
zip -qj query-lambda.zip zig-out/bin/query/bootstrap
zip -qj execution-lambda.zip zig-out/bin/execution/bootstrap
```

All three zip archives are intentionally ignored by Git because they are generated
deployment artifacts.

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

## Persistence commands

`persistence.sh` creates, reads, updates, and deletes Operations in the SAM
stack's DynamoDB table. It defaults to profile `dev`, region
`ca-central-1`, and stack `aws-lambda-zig-demo`. It exports temporary profile
credentials and resolves the stack's `OperationsTable` physical resource. Override
the defaults with `PROFILE`, `REGION`, or `STACK_NAME`.
For example, `./persistence.sh read --id <uuid>` performs a stack-aware read.

The destructive `delete-all` command can run without first building the local
Zig command implementation:

```sh
./persistence.sh delete-all
```

It scans and counts the table's Operations, requires typing `delete`, deletes
every item, and verifies that the table is empty. It requires `jq` plus
`cloudformation:DescribeStackResource`, `dynamodb:Scan`, and `dynamodb:DeleteItem`
permissions for the selected local AWS identity.

If a persistence command reports `dynamodb: missing or invalid configuration`,
it has not processed the Operation JSON yet. Check `PROFILE` and `REGION`, and
use `aws sso login --profile "${PROFILE:-dev}"` when the profile uses IAM
Identity Center. Credential or service failures encountered after configuration
loading are reported separately as `dynamodb: AWS request failed`.

Create an Operation by supplying required tenant metadata separately and
sending the unchanged input JSON view on standard input. A tenant must be valid
UTF-8 between 1 and 64 bytes:

```sh
operation_json='{"id":"00112233-4455-6677-8899-aabbccddeeff",'\
'"name":"echo","body":{"message":"hello","count":2}}'
printf '%s\n' "$operation_json" \
  | ./persistence.sh create --tenant 'tenant-a'
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
`create` command accepts it only through `--tenant`, and Lambda derives it
exclusively from the verified PASETO `sub` claim. Supplying `tenant` inside the
JSON document is rejected to prevent spoofing.

Each persistence command and Lambda POST owns its Operation tenant, strings,
body, and result through one short-lived arena. Optional absence means a field
is omitted from that Operation view; an explicit JSON `null` remains a
distinct `std.json.Value`. Terminal results must be present and non-null.

A create is safe to retry with the original UUID, tenant, name, and body. If that UUID
already identifies an Operation with the same Operation hash, the retry
succeeds and returns the current stored Operation, including its state,
`last_updated`, `expires_at`, and terminal result when present. Reusing the UUID
for different content returns `dynamodb: operation conflict` with exit code
`1`. UUIDs are globally scoped, so reusing an ID under another tenant also
changes the hash and returns a conflict.

Read it with a strongly consistent DynamoDB read:

```sh
./persistence.sh read \
  --id 00112233-4455-6677-8899-aabbccddeeff
```

Updates may move to any state, including the current state. Pending states
require empty standard input, while terminal states require one non-null JSON
result of at most 4,096 input bytes whose compact serialization is also at most
4,096 bytes:

```sh
./persistence.sh update \
  --id 00112233-4455-6677-8899-aabbccddeeff \
  --state RUNNING \
  </dev/null

printf '%s\n' '{"message":"done"}' \
  | ./persistence.sh update \
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

## Queue commands

`queue.sh` sends canonical Operations, destructively consumes queued messages,
and checks the SAM stack's operations queue. It uses `PROFILE`, `REGION`, and
`STACK_NAME`, defaulting to `dev`, `ca-central-1`, and
`aws-lambda-zig-demo`. It exports temporary profile credentials and resolves
the `OperationsQueue` physical resource. Send a validated Operation input like
this:

```sh
operation_json='{"id":"00112233-4455-6677-8899-aabbccddeeff",'\
'"name":"echo","body":{"message":"hello","count":2}}'
printf '%s\n' "$operation_json" | ./queue.sh send --tenant 'tenant-a'
```

`send` parses and validates the input through the shared Operation model using
the current Unix time. It then replaces an omitted or explicit `NEW` state
with `SUBMITTED`, validates the complete output view, and serializes it once.
The exact compact JSON bytes sent to SQS contain `id`, `tenant`, `name`,
`body`, `state`, `last_updated`, `expires_at`, and `hash`. After `SendMessage`
succeeds, the same bytes are printed followed by a newline; the SQS message
does not include that newline. State is excluded from the existing Operation
hash, along with `id`, timestamps, expiration, and result. This command does
not read or update DynamoDB.

Inspect all queue attributes, including attributes added by future AWS API
versions:

```sh
./queue.sh check
```

Consume messages until interrupted:

```sh
./queue.sh receive
```

`receive` is a destructive long-running consumer. It requests one message at a
time with 20-second SQS long polling and silently polls again after an empty
response. For each message, it writes the body byte-for-byte, appends exactly
one newline, flushes standard output, and then deletes the message using its
receipt handle. Bodies may be noncanonical, non-JSON, or contain newlines.

The consumer runs until SIGINT. It keeps the default signal action, so Ctrl-C
terminates promptly and the shell reports status `130`. Interruption can occur
after output is flushed but before deletion completes; an already-printed
message may therefore become visible and be printed again. A missing body or
receipt handle is an invalid AWS response and is not deleted. AWS, malformed
response, output, deletion, and internal failures stop the loop with exit code
`2` and a sanitized diagnostic. Invocation, validation, and configuration
failures also exit with code `2`.

The AWS identity running `queue.sh` needs `sqs:SendMessage` for
`send`, `sqs:ReceiveMessage` and `sqs:DeleteMessage` for `receive`, and
`sqs:GetQueueAttributes` for `check`. The command additionally calls
`cloudformation:DescribeStackResource`. These are caller permissions: the Lambda
roles remain separate. The intake role is limited to `sqs:SendMessage`, the execution role has
queue-scoped polling permissions, and the query role has no SQS permissions. Once the event source
mapping is enabled, `queue.sh receive` competes with the execution Lambda for messages.

Both Lambda Function URLs require the token in an HTTP authorization header:

```text
Authorization: Bearer <token>
```

Header names and the `Bearer` scheme are case-insensitive. Missing, malformed,
expired, or unverifiable credentials receive `401 Unauthorized` with
`WWW-Authenticate: Bearer`. Missing or invalid public-key configuration and
internal failures receive a sanitized `500 Internal Server Error`.
Invalid POST operation documents receive `400 Bad Request`. Authenticated
non-POST intake methods receive `405 Method Not Allowed` with `Allow: POST`;
authenticated non-GET query methods receive `405` with `Allow: GET`. Query
paths that are not exactly one UUID segment receive `400 Bad Request`. Missing
Operations and Operations owned by another tenant both receive the same static
`404 Not Found` response. A POST that
reuses an Operation ID with a different server-computed hash receives a
sanitized `409 Conflict`. Query DynamoDB request or service failures and intake
SQS submission failures receive a static `503 Service Unavailable` response.
Malformed stored items and other unexpected failures receive the static
`500 Internal Server Error` response.

Tenant is server-owned metadata, part of idempotency identity, and the query
authorization boundary. The DynamoDB `id` partition key remains globally
scoped; query authorization is enforced after `GetItem` by comparing the stored
tenant with the verified token subject.

`OPERATIONS_TABLE_NAME` and `OPERATIONS_QUEUE_URL` are mandatory at intake Lambda
initialization. The intake bootstrap validates the non-empty, at-most-2,048-byte queue
URL and table name while initializing the Operation persistence and queue
modules around one shared AWS SDK configuration. Each module privately owns its
respective DynamoDB or SQS client, and both clients share that configuration
and its HTTP pool. The module values, configuration, and pool are reused across
warm invocations. Missing or invalid configuration prevents intake request
handling. Resource existence and IAM authorization are checked
only when POST first calls the services, so DynamoDB failures return a
sanitized HTTP 500 and SQS send failures return a sanitized HTTP 503.

`OPERATIONS_TABLE_NAME` is also mandatory at query Lambda initialization. The
query bootstrap initializes one AWS SDK configuration and one Operation
persistence client and reuses them across warm invocations. It does not receive
`OPERATIONS_QUEUE_URL` or initialize an SQS client. Query DynamoDB request or
service failures return sanitized HTTP 503; malformed items and unexpected
failures return sanitized HTTP 500.

The execution Lambda has no authentication configuration or Function URL. It
receives `OPERATIONS_TABLE_NAME`, reuses one AWS SDK configuration and DynamoDB
persistence client across warm invocations, and has table-scoped
`dynamodb:UpdateItem` permission without `GetItem`. Lambda polls
`OperationsQueue` in batches of at most 10 records with no batching delay.

For every record, the handler retains the debug log containing its message ID
and body, parses the complete Operation output, and accepts only a `SUBMITTED`
Operation with a body and no result. Immediately before each accepted record's
conditional update it samples the real-time clock independently. The update
requires the stored canonical ID, tenant, name, `SUBMITTED` state, queued hash,
and absent result; it does not compare the queued timestamps. A match becomes
`SUCCEEDED` with the exact compact result `{"success":true}`, a fresh
`last_updated`, and `expires_at` exactly 86,400 seconds later.

Processing is deliberately best effort. Successful, invalid, conflicting, and
service-failing records are logged concisely and processing continues. After a
valid top-level SQS event, the handler always returns
`{"batchItemFailures":[]}`, so none of those individual outcomes is retried by
SQS. Malformed top-level events and failures that prevent response encoding may
still fail and retry the invocation.

## Lambda logs

`lambda_logs.sh` downloads one Lambda's CloudWatch events into a root-level
file named after the deployed function. The stack name is fixed as
`aws-lambda-zig-demo`; choose the explicit intake, query, or execution output:

```sh
./lambda_logs.sh intake
./lambda_logs.sh query
./lambda_logs.sh execution
```

The helper uses `AWS_PROFILE` and `AWS_REGION`, defaulting to `dev` and
`ca-central-1`. Override them with the standard AWS CLI environment variables:

```sh
AWS_PROFILE=dev AWS_REGION=ca-central-1 ./lambda_logs.sh intake
```

When the log file is absent or empty, the helper downloads all events retained
in `/aws/lambda/<function-name>`. On later runs, it reads the final event's UTC
timestamp and requests events beginning with the following millisecond. Event
headers use millisecond precision:

```text
2026-08-09T19:21:14.335 message
```

Embedded message newlines remain as unprefixed continuation lines. The local
AWS identity needs `cloudformation:DescribeStacks` and `logs:FilterLogEvents`.
For an expired IAM Identity Center session, run
`aws sso login --profile "${AWS_PROFILE:-dev}"` and retry. Root-level `.log`
files are ignored by Git because Lambda output can contain private operational
details; treat custom copies the same way. Logs created by earlier versions of
the helper with `[event-id=...]` headers are unsupported; remove or rename the
existing log before running the updated helper.

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
    IntakeFunctionName=intake-lambda \
    QueryFunctionName=query-lambda \
    ExecutionFunctionName=execution-lambda \
    LambdaPrincipal='*' \
    PasetoPublicKey="$PASETO_PUBLIC_KEY"
```

`LambdaPrincipal` sets the Lambda runtime environment variable
`LAMBDA_PRINCIPAL`. The default `'*'` preserves the public demo behavior; pass a
different value when the function should see a narrower principal string.
`PasetoPublicKey` is required and sets the `PASETO_PUBLIC_KEY` verification
configuration. It is public key material; keep the corresponding private key
only in the signing environment.

`deploy.sh` defaults the execution name to `execution-lambda`. Override it with
`EXECUTION_FUNCTION_NAME=<name>` or `--execution-function-name <name>`.

The SAM-managed DynamoDB table and SQS queue, their environment variables, the
table-scoped `GetItem`, `PutItem`, and `UpdateItem` policy, and the queue-scoped
`SendMessage` policy are mandatory parts of the intake Lambda. The query Lambda
receives only `OPERATIONS_TABLE_NAME` and table-scoped `GetItem` in addition to
the basic logging policy. It initializes a reusable DynamoDB persistence client
and has no SQS permissions. The execution Lambda receives
`OPERATIONS_TABLE_NAME`, table-scoped `UpdateItem`, basic logging, and
queue-scoped polling permissions; it does not receive `GetItem`. Its explicit
event source mapping consumes `OperationsQueue` with partial-batch failure
reporting enabled. Deploy the complete stack from `template.yaml` with AWS SAM.

See [docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md](docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md)
for the full SAM workflow.

## Test The Function URL

After deployment, call either Function URL printed by SAM:

```sh
curl -i -L <IntakeFunctionUrl>
curl -i -L <QueryFunctionUrl>
```

An unauthenticated request receives:

```text
HTTP/2 401
WWW-Authenticate: Bearer
```

Issue a token with the matching private key:

```sh
token="$(
  PASETO_PRIVATE_KEY='<private-key-from-keygen>' \
    zig-out/bin/paseto issue --subject 'example-user' --ttl-seconds 300
)"
```

POST an Operation JSON document with the same bearer token:

```sh
curl -L \
  -H "Authorization: Bearer $token" \
  -H "Content-Type: application/json" \
  --data \
    '{"id":"00112233-4455-6677-8899-aabbccddeeff",'\
'"name":"echo","body":{"message":"hello","count":2}}' \
  <IntakeFunctionUrl>
```

For a new ID, the response has `SUBMITTED` state, the invocation timestamp, its
24-hour expiry, verified subject as tenant, and the stable BLAKE3-256 operation
hash. The input body is intentionally omitted:

```json
{
  "id": "00112233-4455-6677-8899-aabbccddeeff",
  "tenant": "example-user",
  "name": "echo",
  "state": "SUBMITTED",
  "last_updated": 1700000000,
  "expires_at": 1700086400,
  "hash": "f4142429f9f7373c34b7b5eeab555ed5b4534a746193c40bfca65bb73f9a3014"
}
```

Read the Operation with the same token subject and UUID:

```sh
curl -L \
  -H "Authorization: Bearer $token" \
  <QueryFunctionUrl>/00112233-4455-6677-8899-aabbccddeeff
```

The query response is the same compact bodyless Operation output JSON shown
above. Terminal Operations additionally include `result`; pending Operations
do not. The ID comes only from the single `rawPath` segment: query strings and
GET bodies neither provide nor alter it. A different token subject receives the
same `404 Not Found` response as a missing Operation.

For `NEW`, the handler combines the persisted identity with the parsed input
body, refreshes both timestamps from the invocation time, and sends the exact
compact full `SUBMITTED` Operation JSON to SQS without a trailing newline. It
then conditionally updates the bodyless DynamoDB item to the same state and
returns that item. A matching retry whose item is still `NEW` attempts this
submission again. Matching `SUBMITTED`, `RUNNING`, `SUCCEEDED`, or `FAILED`
items are returned immediately without another SQS send.

If `SendMessage` fails, DynamoDB remains `NEW` and the handler returns the
static `503 Service Unavailable` response so the caller can retry. If the
conditional DynamoDB update fails after a successful send, the handler returns
the static `500 Internal Server Error`; the message may already be available.
A concurrent update conflict is reconciled with a strongly consistent read
when the same Operation has advanced beyond `NEW`.

Delivery is at least once. The standard queue, acknowledgement loss, and
concurrent `NEW` retries can produce duplicate messages, so consumers must
handle the Operation ID and hash idempotently. Reusing the ID for different
work or from a different verified subject still returns `409 Conflict`. The
execution consumer conditionally completes only the first matching queued
snapshot. It intentionally acknowledges invalid records, update conflicts,
and DynamoDB service failures without requesting a per-record retry.

The template intentionally creates publicly reachable intake POST and query
GET Function URLs for demo testing, while both Function URL handlers enforce PASETO bearer
authentication. The execution Lambda has no Function URL and is invoked from SQS.
Production endpoints should also consider stricter infrastructure
authorization, narrower IAM policies, or a fronting layer such as API Gateway
or CloudFront.

## Project Layout

- `src/intake_lambda.zig`: authenticated POST intake entrypoint and handler.
- `src/query_lambda.zig`: authenticated tenant-scoped Operation GET entrypoint and handler.
- `src/execution_lambda.zig`: SQS-driven execution entrypoint and handler.
- `src/lambda_auth.zig`: shared bearer-token parsing and PASETO verification.
- `src/operation.zig`: Operation JSON model, validation, and hash contract.
- `src/operation_persistence.zig`: DynamoDB Operation mapping and conditional writes.
- `src/operation_queue.zig`: SQS Operation queue configuration and message contract.
- `src/persistence_cli.zig`: persistence command implementation and tests.
- `src/queue_cli.zig`: queue command implementation and tests.
- `src/paseto.zig`: shared PASETO v4.public issuance and verification.
- `src/paseto_cli.zig`: host PASETO v4.public CLI and its tests.
- `persistence.sh`: stack-aware persistence command and credential setup.
- `queue.sh`: stack-aware queue command and credential setup.
- `lambda_logs.sh`: explicit intake/query/execution CloudWatch log download helper.
- `build.zig`: Zig build graph for all three bootstraps, local commands, and tests.
- `build.zig.zon`: package metadata and pinned dependencies.
- `template.yaml`: SAM template for all three Lambdas, Function URLs, queue mapping, and permissions.
- `docs/`: the SAM deployment guide, ADRs, and the Zig style reference.
- `AGENTS.md`: repository guidance for coding agents.

## Development Notes

Run formatting checks before committing Zig changes:

```sh
zig fmt --check build.zig src/execution_lambda.zig src/intake_lambda.zig \
  src/lambda_auth.zig src/query_lambda.zig \
  src/operation.zig src/operation_persistence.zig src/operation_queue.zig \
  src/persistence_cli.zig src/queue_cli.zig src/paseto.zig src/paseto_cli.zig
```

Run the handler and local command tests with:

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
