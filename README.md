# Zig AWS Lambda Operations Framework

A 100% Zig implementation of AWS Lambda functions and runtime, integrated with
DynamoDB and SQS to create an asynchronous operation-processing framework backed
by TigerBeetle over a WireGuard VPN.

The project builds custom `provided.al2023` intake, query, TigerBeetle processor, and Completion processor
bootstraps and a host-native PASETO v4.public utility named `paseto`. The
stack-aware `persistence.sh` and `queue.sh` commands manage Operations in
DynamoDB and SQS, while `lambda_logs.sh` downloads any function's CloudWatch
logs. The HTTP handlers use `src/lambda_auth.zig` to authenticate a PASETO v4.public
bearer token through the `aws-lambda-zig` runtime package. The query Lambda
accepts only `GET /<uuid>`, strongly reads the Operation from DynamoDB, and
returns it only when its tenant matches the verified token subject. The intake
Lambda accepts only POST, validates and hashes an
Operation JSON document, derives required tenant metadata from the verified
token subject, resolves the exact `<name>Queue` environment mapping, persists
the Operation idempotently in DynamoDB, submits new work to that SQS queue, and
returns the current stored output view without the body.
The TigerBeetle processor consumes queued `SUBMITTED` Operations and validates their complete
Bodies before executing requested account creations, transfers and account lookups. Each creation
list is an independent linked chain. Replay safety requires callers to preserve each chain's
Resource IDs, order and original native inputs across all writers and attempts. The processor
publishes fully determined Results in bounded Completion aggregates. The Completion processor
consumes one aggregate at a time and owns the conditional DynamoDB transition from `SUBMITTED` to `COMPLETED`:

```text
intake -> TigerBeetleQueue -> tiger-beetle-processor -> CompletionQueue -> completion-processor -> DynamoDB
```

A definite creation rejection or missing account produces FAILURE once all requested work is
determined, including lookups after write rejection. Account rejection skips that Operation's
transfers; successful earlier writes survive later failure. Native request uncertainty stops further
native calls and retries unfinished Operations. Completion publication uncertainty retries the
failed message's source records and later unpublished records; transient DynamoDB uncertainty
retries the single Completion queue message.

The maintained [TigerBeetle processor design](docs/TIGER_BEETLE_PROCESSOR.md) defines the
Body schema, replay obligations, complete Results and retry behavior; use it for the current
processor contract.

## Requirements for Zig on AWS Lambda

- Zig 0.16.0 or newer within the supported 0.16.x line.
- AWS CLI v2 and AWS SAM CLI for the SAM deployment flow and stack queries.
- `jq` for the Lambda log helper and shell regression tests.
- An AWS profile with permission to create Lambda, IAM, and CloudFormation
  resources.

The deployment docs use:

- AWS profile: `dev`
- Region: `ca-central-1`
- Intake function name: `intake-lambda`
- Query function name: `query-lambda`
- TigerBeetle processor name: `tiger-beetle-processor`
- Completion processor name: `completion-processor`

Adjust those values for your AWS account as needed.

## Build the Lambda Stack

Build the stripped ReleaseSafe Linux ARM64 Lambda executables:

```sh
zig build --release -Darch=arm
```

This also installs the host-native `zig-out/bin/paseto` utility and the local
implementations invoked by `persistence.sh` and `queue.sh`. The intake and query
bootstraps and the PASETO utility use the shared PASETO implementation in
`src/paseto.zig`; the persistence and queue commands use the shared model in
`src/operation.zig`. The Lambda and local commands reach AWS through
`src/operation_persistence.zig` and `src/sqs_queue.zig`.

Verify the ARM64 Linux executables:

```sh
file zig-out/bin/intake/bootstrap \
  zig-out/bin/query/bootstrap \
  zig-out/bin/tiger_beetle_processor/bootstrap \
  zig-out/bin/completion_processor/bootstrap
```

Intake, query, and the Completion processor are statically linked and single-threaded. TigerBeetle processor is
multithread-capable for the TigerBeetle callback thread and is a dynamically
linked glibc executable. All four are stripped.

```text
intake/query/completion-processor: ELF 64-bit LSB executable, ARM aarch64, statically linked, stripped
tiger-beetle-processor:           ELF 64-bit LSB executable, ARM aarch64, dynamically linked, stripped
```

Package the executables for Lambda when preparing artifacts manually (`deploy.sh` does this
automatically):

```sh
zip -qj intake-lambda.zip zig-out/bin/intake/bootstrap
zip -qj query-lambda.zip zig-out/bin/query/bootstrap
zip -qj tiger-beetle-processor.zip zig-out/bin/tiger_beetle_processor/bootstrap
zip -qj completion-processor.zip zig-out/bin/completion_processor/bootstrap
```

All four zip archives are intentionally ignored by Git because they are generated
deployment artifacts.

## PASETO Authentication

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

## DynamoDB Operations

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
UTF-8 between 1 and 64 bytes. This schema-neutral persistence example stores an `echo` Operation;
it does not enqueue work or demonstrate the TigerBeetle Body contract:

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
distinct `std.json.Value`. A completed result must be present and contain
exactly uppercase `type` and non-null `payload` fields. A submitted Operation
has no result.

A create is safe to retry with the original UUID, tenant, name, and body. If that UUID
already identifies an Operation with the same Operation hash, the retry
succeeds and returns the current stored Operation, including its state,
`last_updated`, `expires_at`, and completed result when present. Reusing the UUID
for different content returns `dynamodb: operation conflict` with exit code
`1`. UUIDs are globally scoped, so reusing an ID under another tenant also
changes the hash and returns a conflict.

Read it with a strongly consistent DynamoDB read:

```sh
./persistence.sh read \
  --id 00112233-4455-6677-8899-aabbccddeeff
```

The lifecycle is `SUBMITTED -> COMPLETED`. Submitted Operations may be
refreshed as submitted or completed once. Completed Operations are immutable:
they cannot be reopened, changed, or refreshed with the same outcome. A
`SUBMITTED` update requires empty standard input. A `COMPLETED` update requires
the complete tagged result envelope on standard input; both its input and
compact serialization must fit the 98,304-byte (96 KiB) full-envelope limit:

```sh
./persistence.sh update \
  --id 00112233-4455-6677-8899-aabbccddeeff \
  --state SUBMITTED \
  </dev/null

printf '%s\n' \
  '{"type":"SUCCESS","payload":{"message":"hello","count":2}}' \
  | ./persistence.sh update \
      --id 00112233-4455-6677-8899-aabbccddeeff \
      --state COMPLETED
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
`last_updated`, `expires_at`, `hash`, and an optional completed `result`; it never
contains `body`. Tenant is a required DynamoDB `S` attribute. Creates use
`attribute_not_exists(id)` and request the existing item on
a failed condition so matching retries need no separate read. Updates first
perform a strongly consistent read and then condition on the complete snapshot,
including `expires_at`, so a concurrent change is reported instead of
overwritten. Updates preserve `id`, `tenant`, `name`, and `hash`. DynamoDB keeps
`result` as an `S` attribute containing the complete compact tagged envelope.
Reads reject malformed, oversized, duplicate-key, explicit-null,
noncanonical, or incorrectly tagged stored result strings.

The SAM table enables native DynamoDB TTL on `expires_at`. Expiration is
best-effort: an Operation becomes eligible for deletion after 24 hours but may
remain readable until DynamoDB removes it asynchronously.

## SQS Workflows

`queue.sh` sends canonical Operations, destructively consumes queued messages,
and checks a named SQS queue in the SAM stack. Its first argument must be the
queue's SAM logical resource ID, such as `TigerBeetleQueue` or
`CompletionQueue`. It uses `PROFILE`, `REGION`, and `STACK_NAME`, defaulting to
`dev`, `ca-central-1`, and `aws-lambda-zig-demo`. It exports temporary profile
credentials, resolves the selected physical queue URL, and exports that URL
under the logical resource ID expected by the CLI. Send a lookup-only `TigerBeetle` Operation
with a concrete account Resource ID like this:

```sh
operation_json='{"id":"11223344-5566-7788-99aa-bbccddeeff00",'\
'"name":"TigerBeetle","body":{"lookup_accounts":[{"id":"101"}]}}'
printf '%s\n' "$operation_json" \
  | ./queue.sh TigerBeetleQueue send --tenant 'tenant-a'
```

`send` parses and validates the input through the shared Operation model using
the current Unix time. Omitted state defaults to `SUBMITTED`, while explicit state
must be `SUBMITTED`. It validates the complete output view and serializes it once.
The exact compact JSON bytes sent to SQS contain `id`, `tenant`, `name`,
`body`, `state`, `last_updated`, `expires_at`, and `hash`. After `SendMessage`
succeeds, the same bytes are printed followed by a newline; the SQS message
does not include that newline. State is excluded from the existing Operation
hash, along with `id`, timestamps, expiration, and result. This command does
not read or update DynamoDB. `send` always produces an Operation message, so it
must not be used with `CompletionQueue`, whose consumer expects a Completion
batch. For Completion to persist, the matching Operation must already exist as `SUBMITTED`
in DynamoDB. Use authenticated intake for the complete persistence-and-enqueue flow.
The illustrative lookup ID `101` is independent of the Operation UUID; a missing account produces
a terminal FAILURE after a trustworthy lookup reply.

Inspect all queue attributes, including attributes added by future AWS API
versions:

```sh
./queue.sh TigerBeetleQueue check
```

Consume messages until interrupted:

```sh
./queue.sh TigerBeetleQueue receive
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
roles remain separate. The intake role is limited to table-scoped
`dynamodb:PutItem` and TigerBeetle queue-scoped `sqs:SendMessage`; the query role has no SQS
permissions. The TigerBeetle processor role can poll only the TigerBeetle queue and send to only the
Completion queue. The Completion processor role can poll only the Completion queue and has
table-scoped `dynamodb:UpdateItem`; TigerBeetle processor has no DynamoDB permission.
Once an event source mapping is enabled, `queue.sh <queue-name> receive`
competes with that queue's Lambda consumer. In this stack, `TigerBeetleQueue`
feeds TigerBeetle processor and `CompletionQueue` feeds the Completion processor.

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
sanitized `409 Conflict`. The exact operation name `Completion` is reserved and
receives `400 Bad Request` before route lookup, DynamoDB, or SQS. For other
names, intake appends `Queue` without case conversion; a missing, empty, or
oversized resulting environment mapping receives `400 Bad Request` before
DynamoDB or SQS is called. Query DynamoDB request or service failures and
intake SQS submission failures receive a static `503 Service Unavailable`
response.
Malformed stored items and other unexpected failures receive the static
`500 Internal Server Error` response.

Tenant is server-owned metadata, part of idempotency identity, and the query
authorization boundary. The DynamoDB `id` partition key remains globally
scoped; query authorization is enforced after `GetItem` by comparing the stored
tenant with the verified token subject.

`OPERATIONS_TABLE_NAME` is mandatory at intake Lambda initialization. The
bootstrap validates the table name and initializes Operation persistence plus
one reusable SQS sender around a shared AWS SDK configuration and HTTP pool.
Those resources are reused across warm invocations. For each valid POST, intake
rejects the exact reserved operation name `Completion`, then forms the bounded,
case-sensitive key `<operation.name>Queue`; for example,
`"name":"TigerBeetle"` selects `TigerBeetleQueue`. It resolves and validates a
non-empty, at-most-2,048-byte URL under that key before persistence. A reserved
name or absent or invalid mapping returns HTTP 400 without writing or sending.
Resource existence and IAM authorization are checked when POST calls the
services, so a DynamoDB failure returns a sanitized HTTP 500. An SQS send
failure after a successful write returns HTTP 503 and leaves the stored
`SUBMITTED` Operation available for a matching POST to retry.

`OPERATIONS_TABLE_NAME` is also mandatory at query Lambda initialization. The
query bootstrap initializes one AWS SDK configuration and one Operation
persistence client and reuses them across warm invocations. It does not receive
queue mappings or initialize an SQS client. Query DynamoDB request or
service failures return sanitized HTTP 503; malformed items and unexpected
failures return sanitized HTTP 500.

The TigerBeetle processor has no authentication configuration or Function URL. It
receives `COMPLETION_QUEUE_URL`, `TIGERBEETLE_CLUSTER_ID`, and
`TIGERBEETLE_ADDRESSES`; it reuses its SQS resources and one TigerBeetle client across warm
invocations. Lambda polls `TigerBeetleQueue` in batches of at most 10 records with no batching
delay.

For every record, the handler retains the debug log containing its message ID
and body, parses the complete Operation output, and accepts only a queued `SUBMITTED`
Operation with a body and no result and a matching tenant/name/Body hash. The Body contains
`create_accounts`, `create_transfers`, and `lookup_accounts` command lists, with at most 64
commands combined. See the maintained [Body schema](docs/TIGER_BEETLE_PROCESSOR.md#body-schema),
[examples](docs/TIGER_BEETLE_PROCESSOR.md#body-examples) and
[Result contract](docs/TIGER_BEETLE_PROCESSOR.md#result-and-completion-publication).

A complete Result retains the original command positions, optional aliases, raw native creation
codes and all found Account fields. For example, an accepted two-account replay preserves the
native suffix code:

```json
{"type":"SUCCESS","payload":{"operation_id":"00112233-4455-6677-8899-aabbccddeeff","create_accounts":[{"id":"101","error_code":21},{"id":"102","error_code":1}],"create_transfers":[],"lookup_accounts":[]}}
```

FAILURE preserves surviving writes and found observations. A missing lookup has a null native
code and descriptive message:

```json
{"type":"FAILURE","payload":{"operation_id":"00112233-4455-6677-8899-aabbccddeeff","create_accounts":[],"create_transfers":[],"lookup_accounts":[{"id":"101","error_code":null,"message":"Account was not found."}]}}
```

Complete Results are bounded to 96 KiB. Completion uses `{"results":[...]}` with a canonical
`operation_id` and complete `result` per entry, retaining the matching UUID inside the payload.
Ten maximum-size Results occupy 983,713 bytes, within the 1 MiB transport bound; eleven require
another message. No Operation snapshot is copied.

The processor executes all admitted account chains, then eligible transfer chains, then requested
lookups. Each creation list remains one immutable chain, packed in received order with intact
neighbors; account rejection skips only that Operation's transfers. First-member matching `exists`
with a linked-failed suffix is accepted replay under the caller's immutable-chain obligation
across all writers, with every actual native code retained. Lookups run after known rejection and retain positions/aliases, including IDs requested by other Operations.

A native error or malformed reply stops subsequent native calls. Earlier trustworthy facts survive;
fully determined Operations publish while unfinished Operations retry without a synthetic FAILURE.
Invalid envelopes acknowledge without Completion. Publication collects terminal Results in received
order, skips unfinished records, and sends intact aggregates serially, flushing at ten Results or
byte capacity. A failed or ambiguous send retries its represented records and every unpublished
suffix record; earlier successful sends remain acknowledgement-eligible. The current ten-record
bound needs at most three native calls and one send.

Redelivery revalidates the original Body and repeats its complete immutable chains, including IDs,
order, pending timeout intervals and post inheritance sentinels. There is no recovery journal or
native retry loop. A later lookup may observe different values or presence, and rejection reasons
may change. The first valid Completion persisted wins even when another valid attempt differs.
Expiry replay does not renew a pending reservation. Unresolved retries never fabricate FAILURE;
the framework owns exhaustion and retention. The fixed 24-hour TTL does not prove every pending
expiry/retry combination. See [complete local verification](docs/TIGERBEETLE_RETRY_EVIDENCE.md)
for the matrix audit and deferred deployed SQS, DynamoDB and Lambda runtime guarantees.

The Completion processor also has no authentication configuration or Function URL. It is not
VPC-attached and receives only `OPERATIONS_TABLE_NAME`. Its event source mapping delivers one
Completion queue message per invocation. The handler decodes the bounded aggregate and performs
its DynamoDB updates sequentially. Each write selects only the canonical Operation ID, requires
the stored state to be `SUBMITTED`, writes the result and `COMPLETED` state, samples a separate
write-time `last_updated`, and derives `expires_at` exactly 86,400 seconds later. It does not read
or compare the queued tenant, name, hash, or timestamps.

Both standard queues are unordered and at least once. A missing or already completed item makes
the ID-only state condition fail with an acknowledged Operation conflict, so duplicate
Completion delivery cannot overwrite the first terminal result. Invalid entries with one
trustworthy canonical ID are completed with an identifiable deterministic failure; entries
without a trustworthy ID are acknowledged without a write. A transient write stops that
invocation and replays the one aggregate message. On replay, earlier successful entries become
acknowledged conflicts and processing reaches the failed and later entries; every newly
successful write receives its actual replay-time timestamp.

## Lambda Observability

`lambda_logs.sh` downloads one Lambda's CloudWatch events into a root-level
file named after the deployed function. The stack name is fixed as
`aws-lambda-zig-demo`; choose the explicit intake, query, TigerBeetle processor, or Completion processor output:

```sh
./lambda_logs.sh intake
./lambda_logs.sh query
./lambda_logs.sh tiger-beetle-processor
./lambda_logs.sh completion-processor
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

## Deploy to AWS

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
    TigerBeetleProcessorName=tiger-beetle-processor \
    CompletionProcessorName=completion-processor \
    LambdaPrincipal='*' \
    PasetoPublicKey="$PASETO_PUBLIC_KEY"
```

`LambdaPrincipal` sets the Lambda runtime environment variable
`LAMBDA_PRINCIPAL`. The default `'*'` preserves the public demo behavior; pass a
different value when the function should see a narrower principal string.
`PasetoPublicKey` is required and sets the `PASETO_PUBLIC_KEY` verification
configuration. It is public key material; keep the corresponding private key
only in the signing environment.

`deploy.sh` builds and packages all four bootstraps, preserves any existing WireGuard state,
and defaults the TigerBeetle processor and Completion processor names to `tiger-beetle-processor` and `completion-processor`.
Override them with `TIGER_BEETLE_PROCESSOR_NAME`, `COMPLETION_PROCESSOR_NAME`, or the matching
`--tiger-beetle-processor-name` and `--completion-processor-name` options. Both deployment helpers accept these options.
The template outputs
`IntakeFunctionName`, `QueryFunctionName`, `TigerBeetleProcessorName`, and
`CompletionProcessorName`, plus `IntakeFunctionArn`, `QueryFunctionArn`,
`TigerBeetleProcessorArn`, and `CompletionProcessorArn`; only intake and query have Function URL
outputs. Resolve deployed values instead of recording them in documentation:

```sh
aws cloudformation describe-stacks \
  --stack-name aws-lambda-zig-demo \
  --query 'Stacks[0].Outputs' \
  --profile dev \
  --region ca-central-1
```

### Connect to External TigerBeetle with an EC2 WireGuard Gateway

`wireguard-gateway-setup.sh` enables, reconfigures, or disables the optional EC2
WireGuard gateway and VPC-attaches only the TigerBeetle processor so it can reach TigerBeetle on
a development workstation. `deploy.sh` preserves the current gateway state during ordinary
application deployments. The feature is disabled on a new stack and incurs EC2 and public
IPv4/Elastic IP costs when enabled. The Completion processor stays outside the VPC.

The operator supplies an existing VPC, a public gateway subnet, a distinct private TigerBeetle processor
subnet, and the TigerBeetle processor subnet's effective route table. The VPC must have an active IPv6
CIDR association, the TigerBeetle processor subnet must have one active IPv6 `/64` contained by that VPC
allocation, and VPC DNS support and DNS hostnames must be enabled. The gateway subnet still
needs an IPv4 internet-gateway default route for WireGuard, and the TigerBeetle processor subnet's network
ACL must permit outbound IPv6 TCP/443 and the corresponding inbound ephemeral traffic. These
VPC, subnet, route-table, IPv6-association, DNS, and network-ACL resources remain externally
managed. Preflight rejects clearly incompatible ACLs, warns when an ordered ACL policy needs
operator review, and never provisions or changes these external resources.

SAM owns the VPC's one egress-only internet gateway for this deployment, the TigerBeetle processor route
table's `::/0` route to it, the TigerBeetle processor security group, and the Lambda dual-stack setting.
The security group permits IPv4 TCP/3000 only toward the workstation TigerBeetle address and
IPv6 TCP/443 to `::/0`. The AWS SDK selects the regional public SQS dual-stack endpoint, so
Completion publishing uses outbound-only public IPv6 HTTPS. This avoids a paid SQS interface
endpoint, but the network boundary is any public IPv6 HTTPS destination; the TigerBeetle processor role's
queue-scoped `sqs:SendMessage` permission remains the service authorization boundary.

Before first enablement, preflight rejects an existing unmanaged EIGW or `::/0` route. During
reconfiguration and teardown it verifies that the attached EIGW and route are the current
stack-owned resources. Disablement first detaches TigerBeetle processor while retaining the EIGW, IPv6
route, TigerBeetle processor security group, VPC parameters, and Lambda ENI-management IAM. It removes
them only after every TigerBeetle processor version is detached and Lambda-created ENIs have drained;
a timeout leaves those resources retained so `wireguard-gateway-setup.sh --disable` can safely
resume. External IPv6 associations, routes other than the stack-owned routes, and WireGuard
key parameters are never deleted.

Gateway values resolve from CLI options, environment variables, a previously enabled stack,
then SSM and network discovery. The external SSM private/public key pair remains
operator-owned, and the private key is never placed in a stack parameter or output. See the
[WireGuard gateway guide](docs/EC2-WireGuard-Gateway.md) for prerequisites, options, key
handling, enable/reconfigure/disable procedures, peer configuration, and failure recovery.
See the [SAM deployment guide](docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md) for the complete build,
parameter, validation, and deployment workflow.

The SAM-managed DynamoDB table and both SQS queues are mandatory. Intake receives the table
name and TigerBeetle queue URL with table-scoped `PutItem` and queue-scoped `SendMessage`.
Query receives only the table name and table-scoped `GetItem`. TigerBeetle processor receives the
Completion queue URL and TigerBeetle configuration, polls only the TigerBeetle queue, and can
send only to the Completion queue; it has no DynamoDB access. Completion receives only the
table name, polls only the Completion queue, and has table-scoped `UpdateItem`. Both SQS
mappings report partial-batch failures. Deploy the complete stack from `template.yaml` with
AWS SAM.

The TigerBeetle queue has the fixed physical name `TigerBeetleQueue`, so only one
stack using this template can exist in an AWS account and region. Replacing the
former queue resource deletes its queued messages under the template's
`DeletionPolicy: Delete` and `UpdateReplacePolicy: Delete` settings.

See [docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md](docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md)
for the full SAM workflow.

## Test the Authenticated APIs

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

POST a lookup-only Operation with the same bearer token. Replace the illustrative account ID
`101` with an account to observe; it is independent of the Operation UUID. If it is missing,
a trustworthy lookup produces a FAILURE Result. Use a new Operation UUID for different work,
and preserve the original Body when retrying the same Operation:

```sh
curl -L \
  -H "Authorization: Bearer $token" \
  -H "Content-Type: application/json" \
  --data \
    '{"id":"00112233-4455-6677-8899-aabbccddeeff",'\
'"name":"TigerBeetle","body":{"lookup_accounts":[{"id":"101"}]}}' \
  <IntakeFunctionUrl>
```

For a new ID, the response has `SUBMITTED` state, the invocation timestamp, its
24-hour expiry, verified subject as tenant, and the stable BLAKE3-256 operation
hash. The example below uses illustrative timestamps and the hash for the exact Body above
with tenant `example-user`. The input body is intentionally omitted:

```json
{
  "id": "00112233-4455-6677-8899-aabbccddeeff",
  "tenant": "example-user",
  "name": "TigerBeetle",
  "state": "SUBMITTED",
  "last_updated": 1700000000,
  "expires_at": 1700086400,
  "hash": "bbcd394c710db838cd69c3dbc7cfa53fc5017e2af707fc5c614d1dcc38f8f614"
}
```

Read the Operation with the same token subject and UUID:

```sh
curl -L \
  -H "Authorization: Bearer $token" \
  <QueryFunctionUrl>/00112233-4455-6677-8899-aabbccddeeff
```

The query response is the same compact bodyless Operation output JSON shown
above. `COMPLETED` Operations additionally include `result`; `SUBMITTED` Operations
do not. The ID comes only from the single `rawPath` segment: query strings and
GET bodies neither provide nor alter it. A different token subject receives the
same `404 Not Found` response as a missing Operation.

For `SUBMITTED`, the handler reattaches the parsed input body only to a queued copy
of the persisted snapshot and sends that exact compact full `SUBMITTED` Operation
JSON to SQS without a trailing newline. It returns the unchanged bodyless
snapshot. A matching retry whose item is still `SUBMITTED` sends it again; matching
`COMPLETED` items are returned immediately without another SQS
send.

If `SendMessage` fails, DynamoDB remains `SUBMITTED` and the handler returns the
static `503 Service Unavailable` response so the caller can retry. Intake
performs no read or update after the send.

Delivery is at least once. The standard queue, acknowledgement loss, and
concurrent `SUBMITTED` retries can produce duplicate messages, so consumers must
handle the Operation ID and hash idempotently. Reusing the ID for different
work or from a different verified subject still returns `409 Conflict`. The TigerBeetle processor
replays complete creation chains under the caller obligations described above and obtains fresh
requested lookups. It sends terminal ID/result entries to the Completion queue. Completion
conditionally updates only a stored `SUBMITTED` item; duplicate or stale entries cannot overwrite
its first persisted Result. A native request error stops later native calls and retries every
unfinished Operation, including those sharing the failed request. Completion publication uncertainty
retries the failed aggregate's source records and every later unpublished record; earlier successful
sends remain acknowledgement-eligible. DynamoDB uncertainty replays the single Completion aggregate.

The template intentionally creates publicly reachable intake POST and query
GET Function URLs for demo testing, while both Function URL handlers enforce PASETO bearer
authentication. The TigerBeetle processor has no Function URL and is invoked from SQS.
The Completion processor likewise has no Function URL and is invoked from its SQS mapping.
Production endpoints should also consider stricter infrastructure
authorization, narrower IAM policies, or a fronting layer such as API Gateway
or CloudFront.

## Project Structure

- `src/intake_lambda.zig`: authenticated POST intake entrypoint, named-queue routing, and handler.
- `src/query_lambda.zig`: authenticated tenant-scoped Operation GET entrypoint and handler.
- `src/tiger_beetle_processor.zig`: SQS-driven TigerBeetle processor entrypoint and handler.
- `src/completion_processor.zig`: SQS-driven conditional completion entrypoint and handler.
- `src/completion_batch.zig`: bounded aggregate Completion message contract and codec.
- `src/lambda_auth.zig`: shared bearer-token parsing and PASETO verification.
- `src/operation.zig`: Operation JSON model, validation, and hash contract.
- `src/operation_persistence.zig`: DynamoDB Operation mapping and conditional writes.
- `src/sqs_queue.zig`: reusable SQS sender plus fixed-queue configuration and transport contract.
- `src/persistence_cli.zig`: persistence command implementation and tests.
- `src/queue_cli.zig`: queue command implementation and tests.
- `src/paseto.zig`: shared PASETO v4.public issuance and verification.
- `src/paseto_cli.zig`: host PASETO v4.public CLI and its tests.
- `persistence.sh`: stack-aware persistence command and credential setup.
- `queue.sh`: stack-aware queue command and credential setup.
- `lambda_logs.sh`: explicit four-handler CloudWatch log download helper.
- `build.zig`: Zig build graph for all four bootstraps, local commands, and tests.
- `build.zig.zon`: package metadata and pinned dependencies.
- `template.yaml`: SAM template for all four Lambdas, two Function URLs, two queue mappings, permissions, and the optional EC2 WireGuard gateway.
- `docs/EC2-WireGuard-Gateway.md`: implemented gateway architecture, lifecycle, security, and ownership reference.
- `docs/`: the SAM deployment guide, ADRs, and the Zig style reference.
- `AGENTS.md`: repository guidance for coding agents.

## Development and Validation

Run formatting checks before committing Zig changes:

```sh
zig fmt --check build.zig src/completion_batch.zig src/completion_processor.zig \
  src/tiger_beetle_processor.zig src/intake_lambda.zig src/lambda_auth.zig \
  src/query_lambda.zig \
  src/operation.zig src/operation_persistence.zig src/sqs_queue.zig \
  src/persistence_cli.zig src/queue_cli.zig src/paseto.zig src/paseto_cli.zig
```

Run only the local deployment-helper regression tests with:

```sh
zig build test-deploy
```

The shell tests mock AWS commands, so they require no AWS credentials or
network access. Run all Zig tests and deployment-helper regression tests with:

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
