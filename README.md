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
The execution Lambda consumes SQS batches, creates a replay-safe TigerBeetle
account and transfer for each valid queued `SUBMITTED` Operation, then conditionally
transitions DynamoDB to `COMPLETED` with a tagged success or failure `result`.
Definitive account or transfer rejections are persisted as completed failures;
TigerBeetle client/request or DynamoDB uncertainty is returned through SQS
partial-batch failures and leaves the Operation retryable.

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

Build the stripped ReleaseSafe Linux ARM64 Lambda executables:

```sh
zig build --release -Darch=arm
```

This also installs the host-native `zig-out/bin/paseto` utility and the local
implementations invoked by `persistence.sh` and `queue.sh`. The intake and query
bootstraps and the PASETO utility use the shared PASETO implementation in
`src/paseto.zig`; the persistence and queue commands use the shared model in
`src/operation.zig`. The Lambda and local commands reach AWS through
`src/operation_persistence.zig` and `src/operation_queue.zig`.

Verify the ARM64 Linux executables:

```sh
file zig-out/bin/intake/bootstrap \
  zig-out/bin/query/bootstrap \
  zig-out/bin/execution/bootstrap
```

Intake and query are statically linked and single-threaded. Execution is
multithread-capable for the TigerBeetle callback thread and is a dynamically
linked glibc executable. All three are stripped.

```text
intake/query: ELF 64-bit LSB executable, ARM aarch64, statically linked, stripped
execution:    ELF 64-bit LSB executable, ARM aarch64, dynamically linked, stripped
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
compact serialization must fit the 4,096-byte full-envelope limit:

```sh
./persistence.sh update \
  --id 00112233-4455-6677-8899-aabbccddeeff \
  --state SUBMITTED \
  </dev/null

printf '%s\n' \
  '{"type":"SUCCESS","payload":{"transfer_id":"00112233-4455-6677-8899-aabbccddeeff"}}' \
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
the current Unix time. Omitted state defaults to `SUBMITTED`, while explicit state
must be `SUBMITTED`. It validates the complete output view and serializes it once.
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
roles remain separate. The intake role is limited to table-scoped
`dynamodb:PutItem` and queue-scoped `sqs:SendMessage`; the execution role has
queue-scoped polling permissions, and the query role has no SQS permissions.
Once the event source mapping is enabled, `queue.sh receive` competes with the
execution Lambda for messages.

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
receives `OPERATIONS_TABLE_NAME`, `TIGERBEETLE_CLUSTER_ID`, and
`TIGERBEETLE_ADDRESSES`; it reuses its AWS resources and one TigerBeetle client
across warm invocations. It has table-scoped `dynamodb:UpdateItem` permission
without `GetItem`. Lambda polls `OperationsQueue` in batches of at most 10
records with no batching delay.

For every record, the handler retains the debug log containing its message ID
and body, parses the complete Operation output, and accepts only a queued `SUBMITTED`
Operation with a body and no result. It creates account `Operation.id` on
ledger/code `1`, then transfer `Operation.id` from that account to account `1`
for amount `100` on ledger/code `1`. Only after both return `created` or
identical `exists` does the successful path sample the real-time clock. The
conditional update
requires the stored canonical ID, tenant, name, queued hash, `SUBMITTED` state,
and absent result; it deliberately compares no timestamps. A match
becomes `COMPLETED` with a fresh `last_updated` and `expires_at` exactly 86,400
seconds later. The exact success envelope is:

```json
{"type":"SUCCESS","payload":{"transfer_id":"00112233-4455-6677-8899-aabbccddeeff"}}
```

A definitive account or transfer rejection instead completes the Operation
with its exact stage and raw TigerBeetle status, sampling the completion time
after the rejecting request:

```json
{"type":"FAILURE","payload":{"stage":"ACCOUNT","status":19}}
```

```json
{"type":"FAILURE","payload":{"stage":"TRANSFER","status":22}}
```

Processing continues after every record. Invalid records and DynamoDB
conditional conflicts are acknowledged; a conflict leaves the stored Operation
unchanged, including when another delivery already completed it. TigerBeetle
client/request errors and DynamoDB service uncertainty add the exact message ID
to `batchItemFailures`, leave the Operation `SUBMITTED` without a result, and
permit infrastructure retry. Account `1` must be pre-provisioned on ledger `1`;
the executor never creates it.

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

### Optional EC2 WireGuard gateway

`deploy.sh` can provision an EC2 WireGuard gateway and VPC-attach the execution
Lambda so the Lambda subnet can reach TigerBeetle on a development workstation.
The feature is opt-in and disabled by default. Enabling it incurs EC2 and public
IPv4/Elastic IP costs. The execution handler sends its account and transfer
requests through this path. The SQS mapping stays enabled when the gateway is
disabled, so another trusted route must reach the configured address or records
will retry after TigerBeetle timeouts.

The fixed initial network configuration is:

| Setting | Value |
| --- | --- |
| WireGuard network | `10.200.0.0/24` |
| Gateway WireGuard address | `10.200.0.1/24` |
| Workstation WireGuard address | `10.200.0.2/24` |
| Public endpoint | IPv4 UDP/51820 on the gateway Elastic IP |
| TigerBeetle endpoint | `10.200.0.2:3000` |
| Gateway AMI | ARM64 Amazon Linux 2023, resolved through `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64` |
| Routing | Layer 3 forwarding without NAT; EC2 source/destination checking disabled |

The gateway public subnet and Lambda subnet must be distinct existing subnets
in one VPC. The gateway subnet needs an active default route to an internet
gateway. Neither subnet may overlap `10.200.0.0/24`, and the Lambda route table
must not contain a conflicting route for that CIDR. The stack creates a
DynamoDB gateway endpoint on the Lambda route table, so the Lambda subnet does
not need NAT. Attaching a Lambda to a public subnet does not provide internet
access through that subnet's internet gateway.

The gateway security group exposes IPv4 UDP/51820 from `0.0.0.0/0` because a
NATed workstation's public address may change. WireGuard authenticates its
configured peer, but this deliberate source policy increases exposure to UDP
scanning and floods. No IPv6 ingress, SSH, public TigerBeetle TCP port, or
other public ingress is opened.

#### Gateway environment variables and options

Gateway values resolve in this order: CLI option, environment variable,
matching parameter from a previously enabled stack, then SSM/default network
discovery. Prior values are reused only when the existing stack has
`EnableWireGuardGateway=true`; omitting `--enable-wireguard-gateway` (and
leaving `ENABLE_WIREGUARD_GATEWAY` unset or `0`) still explicitly disables the
feature.

| Environment variable | `deploy.sh` option | Default | Meaning |
| --- | --- | --- | --- |
| `ENABLE_WIREGUARD_GATEWAY` | `--enable-wireguard-gateway` | `0` | Set the environment value to `1`, or use the flag, to enable the gateway. Only `0` and `1` are accepted. |
| `VPC_ID` | `--vpc-id ID` | Discovered | Optional VPC constraint for subnet discovery. |
| `GATEWAY_PUBLIC_SUBNET_ID` | `--gateway-public-subnet-id ID` | Discovered | Optional existing gateway-subnet constraint. |
| `LAMBDA_SUBNET_ID` | `--lambda-subnet-id ID` | Discovered | Optional existing Lambda-subnet constraint. |
| `LAMBDA_ROUTE_TABLE_ID` | `--lambda-route-table-id ID` | Derived | Optional assertion against the Lambda subnet's effective route table. |
| `LAMBDA_SUBNET_CIDR` | `--lambda-subnet-cidr CIDR` | Derived | Optional assertion against the Lambda subnet's primary IPv4 CIDR. |
| `WIREGUARD_PRIVATE_KEY_PARAMETER_NAME` | `--wireguard-private-key-parameter-name NAME` | `/applications/${STACK_NAME}/wireguard/gateway-private-key` | External gateway-private-key `SecureString`. A custom path disables automatic generation. |
| `WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION` | `--wireguard-private-key-parameter-version VERSION` | Current stored version | Exact positive SSM version retrieved during instance bootstrap. |
| `WIREGUARD_GATEWAY_PUBLIC_KEY` | `--wireguard-gateway-public-key KEY` | `/applications/${STACK_NAME}/wireguard/gateway-public-key` value | Public key matching the selected private-key version. Required with a custom private path. |
| `WIREGUARD_WORKSTATION_PUBLIC_KEY` | `--wireguard-workstation-public-key KEY` | Prior enabled stack value; otherwise required | Public key matching the workstation-owned private key. |
| `WIREGUARD_INSTANCE_TYPE` | `--wireguard-instance-type TYPE` | `t4g.nano` | ARM64 EC2 instance type for the stateless gateway. |

`deploy.sh` has no AMI environment variable or option; it uses the template's
Amazon Linux 2023 SSM parameter default. Direct SAM deployments may override
the `WireGuardAmiId` template parameter. The common `PROFILE`, `REGION`, and
`STACK_NAME` options still apply.

When neither subnet is specified, the helper considers available IPv4 subnet
pairs. The gateway subnet must have an active `0.0.0.0/0` route to an internet
gateway. The distinct Lambda subnet must be in the same VPC and availability
zone and have an effective route table on which the endpoint can be managed;
neither NAT nor a pre-existing endpoint is required. Neither subnet may overlap
`10.200.0.0/24`. An explicit VPC or one subnet narrows the candidates. The
helper proceeds only for one pair; otherwise it prints all matching pairs and
requires `--gateway-public-subnet-id` and/or `--lambda-subnet-id`. With no valid
pair it reports rejection counts for gateway routing, Lambda endpoint
management, CIDR overlap, subnet identity, VPC, and availability zone. An AWS
API inspection failure is reported separately and is never treated as ordinary
topology rejection. It prints the selected VPC, availability zone, subnets,
Lambda CIDR, and effective Lambda route table before deployment.

For a small development VPC, the recommended topology is a dedicated `/28`
Lambda subnet in the gateway subnet's availability zone, automatic public IPv4
assignment disabled, an explicitly associated route table containing only the
VPC-local route, and the stack-managed DynamoDB gateway endpoint associated
only with that route table. The subnet, route table, and association remain
operator-owned outside SAM; the endpoint and its prefix-list route follow the
stack lifecycle. See the deployment guide for provisioning, legacy endpoint
import, rollback, and cleanup.

#### Automatic gateway key ownership

The default external SSM pair is:

| Value | Parameter |
| --- | --- |
| Gateway private key | `/applications/${STACK_NAME}/wireguard/gateway-private-key` (`SecureString`, encrypted with `alias/aws/ssm`) |
| Gateway public key | `/applications/${STACK_NAME}/wireguard/gateway-public-key` (`String`) |

Custom private-parameter paths must also avoid names beginning with the
case-insensitive Parameter Store reserved prefixes `aws` and `ssm`.

If both parameters exist, the helper validates their types and public-key
format, pins the current private version, and uses the stored public key. If
neither exists, first enablement requires `wg`; the helper creates a mode-0700
temporary directory under a restrictive umask, generates the pair, and creates
both parameters without overwrite. It never puts the private key in a command
argument, environment variable, stack parameter, or output, and removes the
temporary files on success or failure. If public-parameter creation fails, it
deletes only the private parameter created by that invocation.

The deploying identity therefore needs `ssm:GetParameter` and
`ssm:PutParameter` for both default paths and `ssm:DeleteParameter` for scoped
creation rollback, in addition to the documented CloudFormation and EC2 read
permissions. These parameters are operator-owned external state: stack
teardown retains them, and `deploy.sh` never rotates or overwrites them.

There is no private-key value option. Keep the workstation private key only in
its protected workstation file. Never put either private key in the repository,
template, shell history, stack parameters or outputs, or an environment passed
to `deploy.sh`.

Assuming the existing PASETO variables are set and the workstation keypair has
already been generated, the minimal first enable is:

```sh
WIREGUARD_WORKSTATION_PUBLIC_KEY="$wireguard_workstation_public_key" \
./deploy.sh --enable-wireguard-gateway
```

If discovery is ambiguous, constrain the pair explicitly; VPC, Lambda CIDR,
and route table remain derived:

```sh
./deploy.sh \
  --enable-wireguard-gateway \
  --gateway-public-subnet-id '<gateway-public-subnet-id>' \
  --lambda-subnet-id '<lambda-subnet-id>' \
  --wireguard-workstation-public-key "$wireguard_workstation_public_key"
```

To retain an existing custom private parameter instead of using the managed
default pair, supply the complete pinned pair:

```sh
./deploy.sh \
  --enable-wireguard-gateway \
  --wireguard-private-key-parameter-name '<absolute-ssm-parameter-path>' \
  --wireguard-private-key-parameter-version '<ssm-parameter-version>' \
  --wireguard-gateway-public-key "$wireguard_gateway_public_key" \
  --wireguard-workstation-public-key "$wireguard_workstation_public_key"
```

Before a non-dry-run deployment, the helper verifies the VPC, subnet, and
route-table relationships, confirms the gateway subnet's internet-gateway
route and DynamoDB endpoint manageability, and rejects a conflicting Lambda
route. An unmanaged endpoint on the selected route table must be imported into
the stack; shared, unavailable, duplicate-route, custom-policy, or mismatched
endpoints are rejected without modification. It reads private-parameter
metadata without decryption. The gateway instance retrieves the selected
private version during bootstrap and verifies that its derived public key
matches `WIREGUARD_GATEWAY_PUBLIC_KEY`.

After a successful enabled deployment, `deploy.sh` prints these non-secret
CloudFormation outputs:

```text
ExecutionDynamoDBGatewayEndpointId
WireGuardGatewayInstanceId
WireGuardGatewayElasticIp
WireGuardGatewayEndpoint
WireGuardGatewayPublicKey
WireGuardGatewayAddress
WireGuardWorkstationAddress
TigerBeetleEndpoint
```

Those outputs provide the workstation configuration values. Combine
them with the locally retained workstation private key and the
`LAMBDA_SUBNET_CIDR` selected during deployment:

```ini
[Interface]
Address = <WireGuardWorkstationAddress>
PrivateKey = <locally-retained-workstation-private-key>

[Peer]
PublicKey = <WireGuardGatewayPublicKey>
Endpoint = <WireGuardGatewayEndpoint>
AllowedIPs = <LambdaSubnetCidr>
PersistentKeepalive = 25
```

`AllowedIPs` intentionally contains only the Lambda subnet, not the entire VPC
or the WireGuard overlay. It provides the return route for connections initiated
by a Lambda network interface in that subnet. The workstation firewall must
permit TCP/3000 from `LAMBDA_SUBNET_CIDR`, and TigerBeetle must listen on
`10.200.0.2:3000` or another bind address that includes the WireGuard interface.

On a later enabled deployment, pass only `--enable-wireguard-gateway`: values
not overridden on the CLI or in the environment are reused from the enabled
stack, including its pinned key version, public keys, subnets, and instance
type. A subsequent successful deployment without the enable flag (or with
`ENABLE_WIREGUARD_GATEWAY=0`) explicitly passes
`EnableWireGuardGateway=false` to SAM using two CloudFormation updates. The
first update removes the Lambda VPC attachment, gateway, Elastic IP, route, and
gateway resources while retaining the DynamoDB gateway endpoint, execution
security group, and the role's ENI-deletion permission. The helper then waits
up to 20 minutes for every Lambda version to detach and for the retained
security group's ENI count to reach zero. Only then does the second update
remove the endpoint and its prefix-list route, security group, and VPC access
policy. If the bounded wait fails, cleanup stops with those resources retained;
rerunning `deploy.sh` resumes the guarded cleanup phase. Operator-owned NAT and
default routes are not changed. Both external SSM parameters and workstation
keys remain operator-owned and are not deleted. A later re-enable after teardown
recovers the current default SSM pair but does not reuse values from the
disabled stack.

Before any non-dry-run build, the helper clears inherited static AWS credential
variables, selects the configured SSO-backed profile, and unconditionally runs
`aws sso login` to obtain a fresh access token. Login happens before stack
inspection or other AWS discovery, and a login failure stops the deployment;
non-SSO profiles are unsupported. Dry runs make no AWS authentication calls.
The helper also stops immediately when the stack status ends in `_IN_PROGRESS`;
do not start another deployment while CloudFormation is still operating. If
SAM or a post-deployment check fails after deployment starts, the helper reports
whether CloudFormation is still in progress, reached a terminal failure, or
completed successfully despite the local failure. Leave an `_IN_PROGRESS`
stack alone until CloudFormation reaches a terminal state; after a bounded
VPC-cleanup timeout, rerun `deploy.sh` only when the stack is no longer in
progress so it can resume the retained cleanup phase.

If only one default parameter exists, the helper stops without modifying it.
Repair the pair by deriving and storing the missing matching value, or delete
the lone parameter and let the helper create a fresh pair. For intentional
rotation, generate a new private/public pair, update both SSM parameters
together, record the new private version, then run an enabled deployment with
that version and public key. Updating only one value is an invalid intermediate
state; implicit deployment never repairs or rotates it.

`--dry-run` validates the syntax of supplied gateway inputs but makes no AWS
discovery or SSM calls and reports the deferred gateway preflight.

See [the implemented gateway architecture](EC2-WireGuard-Gateway.md) for the
resource model, routing and ownership boundaries. See
[the detailed SAM deployment guide](docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md) for the
restrictive key-generation workflow, direct SAM parameter overrides, Systems
Manager checks, failure diagnosis, key rotation, and teardown.

The SAM-managed DynamoDB table and SQS queue, their environment variables, the
table-scoped `PutItem` policy, and the queue-scoped `SendMessage` policy are
mandatory parts of the intake Lambda. The query Lambda
receives only `OPERATIONS_TABLE_NAME` and table-scoped `GetItem` in addition to
the basic logging policy. It initializes a reusable DynamoDB persistence client
and has no SQS permissions. The execution Lambda receives
`OPERATIONS_TABLE_NAME`, `TIGERBEETLE_CLUSTER_ID`,
`TIGERBEETLE_ADDRESSES`, table-scoped `UpdateItem`, basic logging, and
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
work or from a different verified subject still returns `409 Conflict`. The
execution consumer conditionally completes only the first matching queued
`SUBMITTED` snapshot with no result after replay-safe TigerBeetle accounting.
It acknowledges invalid records, persisted definitive TigerBeetle rejections,
and update conflicts. TigerBeetle client/request errors and DynamoDB service
uncertainty request a per-record retry and leave the Operation submitted.

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
- `template.yaml`: SAM template for all three Lambdas, Function URLs, queue mapping, permissions, and the optional EC2 WireGuard gateway.
- `EC2-WireGuard-Gateway.md`: implemented gateway architecture, lifecycle, security, and ownership reference.
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

Run only the dependency-free deployment-helper regression tests with:

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
