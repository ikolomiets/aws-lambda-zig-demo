# Deploy the intake, query, execution, and completion Lambdas with SAM

This guide documents how to deploy the four Zig Lambda packages in this repository
using AWS SAM and `template.yaml`.

SAM deploys all four Lambda functions as one CloudFormation-managed stack. It creates
their execution roles, public Function URLs for intake and query, the DynamoDB
operations table, the TigerBeetle queue sent by intake and consumed by execution,
and the Completion queue sent by execution and consumed by completion. The complete
data flow is:

```text
intake -> TigerBeetle queue -> execution/TigerBeetle -> Completion queue -> completion -> DynamoDB
```

The template can also provision an optional EC2 WireGuard gateway that routes
execution-Lambda traffic to TigerBeetle on a development workstation. While
execution is VPC-attached, SAM supplies outbound IPv6 access to the regional SQS
dual-stack endpoint through a stack-owned egress-only internet gateway (EIGW).
The gateway is disabled by default; enabling it adds EC2 and Elastic IP charges.

## Assumptions

- AWS CLI v2 and SAM CLI are installed.
- `zip`, `unzip`, and `file` are installed for package validation.
- `jq` is installed when using `lambda_logs.sh`.
- You have an IAM Identity Center / SSO profile named `dev`.
- The deployment region is `ca-central-1`.
- `template.yaml` exists in this repository.
- `intake-lambda.zip`, `query-lambda.zip`, `execution-lambda.zip`, and
  `completion-lambda.zip` each contain one Linux ARM64 executable named
  `bootstrap`.
- Both Lambda Function URLs are intentionally public for authenticated demo testing.
- The fixed physical name `TigerBeetleQueue` permits only one such queue per AWS
  account and region; deploy only one stack using this template in that scope.
- `LAMBDA_PRINCIPAL` defaults to `'*'` unless you override the
  `LambdaPrincipal` template parameter.
- `PASETO_PUBLIC_KEY` contains the padded Base64 Ed25519 public key generated
  by `zig-out/bin/paseto keygen`. The corresponding private key remains only
  in the token-signing environment.

Enabling the WireGuard gateway additionally requires:

- An existing VPC with distinct public gateway and Lambda subnets.
- An internet gateway and an active `0.0.0.0/0` route from the gateway public
  subnet to that internet gateway.
- An active IPv6 CIDR association on the VPC and exactly one active IPv6 `/64`
  association on the Lambda subnet contained by that VPC allocation. These
  associations remain externally managed.
- VPC DNS support and DNS hostnames enabled so the AWS SDK can resolve regional
  dual-stack service names.
- The Lambda subnet's effective route table, with no unmanaged `::/0` route and
  no route already claiming `10.200.0.0/24` unless that route is owned by the
  existing deployment of this stack.
- A Lambda-subnet network ACL that permits outbound IPv6 TCP/443 and returning
  inbound TCP/1024-65535. Nontrivial ordered policies require operator review.
- No unmanaged EIGW attached to the VPC. A VPC can have only one EIGW; the stack
  must be able to create and own it for this deployment.
- For the recommended isolated topology, an unused IPv4 `/28` in the VPC and
  permission to create and tag a subnet, route table, and route-table
  association. Assign the IPv6 `/64` outside this template and helper.
- Local WireGuard tools (`wg` and the platform-specific interface helper) on a
  workstation that can initiate outbound UDP/51820 to the gateway Elastic IP.
- `wg` must be on `PATH` for `wireguard-gateway-setup.sh` to generate the default gateway pair
  when both default SSM parameters are absent.
- Permission for the deployment identity to create, inspect, and delete the
  additional EC2 instance, Elastic IP, security groups, IPv4 and IPv6 routes,
  EIGW, IAM role and instance profile, launch template, and execution-Lambda
  network interfaces. Preflight also describes VPCs, subnets, route tables,
  EIGWs, network ACLs, VPC DNS attributes, Lambda versions, and network
  interfaces, and probes regional SQS dual-stack availability with
  `sqs:ListQueues`.
- `ssm:GetParameter` and `ssm:PutParameter` on
  `/applications/${STACK_NAME}/wireguard/gateway-private-key` and
  `/applications/${STACK_NAME}/wireguard/gateway-public-key`, plus
  `ssm:DeleteParameter` on
  the private path for rollback if paired creation fails.

## 1. Authenticate with AWS SSO

For direct `aws` and `sam` commands, authenticate the local AWS CLI profile
with IAM Identity Center.

```sh
aws sso login --profile dev
```

Optionally inspect the account and assumed role selected by the profile. This is
an identity check, not a token-validity step.

```sh
aws sts get-caller-identity --profile dev
```

Expected ARN shape:

```text
arn:aws:sts::<account-id>:assumed-role/AWSReservedSSO_.../<user>
```

Every non-dry-run deployment-helper invocation requires an SSO-backed profile. The
helper clears inherited static credential variables, exports the selected
profile, and unconditionally runs `aws sso login --profile <profile>` to obtain
a fresh access token before AWS discovery or local build work. A login failure
stops the deployment immediately; static, credential-process, and other non-SSO
profiles are unsupported. Dry runs make no AWS authentication calls.

## 2. Build and package the Zig Lambdas

Check Zig and shell formatting/syntax before the test graph:

```sh
zig fmt --check build.zig src/completion_batch.zig src/completion_lambda.zig \
  src/execution_lambda.zig src/intake_lambda.zig src/lambda_auth.zig \
  src/query_lambda.zig
bash -n deploy.sh wireguard-gateway-setup.sh tests/*.sh
```

Run the full local test graph before packaging. This includes the Zig tests and
the dependency-free deployment-helper regression tests:

```sh
zig build test
```

To run only the deployment-helper regression tests, use:

```sh
zig build test-deploy
```

The deployment-helper tests replace AWS commands with shell mocks, so they
require no AWS credentials or network access. `deploy.sh` invokes only
`zig build test`, which includes these tests exactly once.

Build the stripped ReleaseSafe Lambda executables for AWS Lambda ARM64. ARM64
is also the project build default; `-Darch=arm` keeps the deployment command
explicit.

```sh
zig build --release -Darch=arm
```

The build also installs the host-native `paseto` utility and the local command
implementations invoked by `persistence.sh` and `queue.sh`. Each Lambda zip
contains only its handler's root-level `bootstrap`.

Verify that all four built artifacts are Linux ARM64 executables.

```sh
file zig-out/bin/intake/bootstrap \
  zig-out/bin/query/bootstrap \
  zig-out/bin/execution/bootstrap \
  zig-out/bin/completion/bootstrap
```

Inspect the execution bootstrap before creating or updating any AWS resource. It must be the
stripped ARM64 glibc executable and must contain the patched epoll client markers. The native
client must not expose `io_uring` syscall names or diagnostic strings:

```sh
execution_bootstrap=zig-out/bin/execution/bootstrap
file "$execution_bootstrap"
strings "$execution_bootstrap" | rg 'epoll_create1|eventfd|timerfd_create'
if strings "$execution_bootstrap" | rg -i 'io_uring'; then
  echo 'unexpected io_uring marker in execution bootstrap' >&2
  exit 1
fi
```

The execution bootstrap is linked against the Amazon Linux 2023 ARM64 glibc loader. On a Linux
machine with binutils installed, inspect the loader and dynamic dependencies explicitly:

```sh
readelf -lW "$execution_bootstrap" | rg 'Requesting program interpreter|ld-linux-aarch64'
readelf -dW "$execution_bootstrap" | rg 'NEEDED|libc|libm|libdl'
```

The package-level check is independent of the Lambda executable: `strings` on
`lib/aarch64-linux-gnu.2.27/libtb_client.a` must show epoll, eventfd, and timerfd markers and no
`io_uring` marker. The macOS archive remains the Darwin/kqueue build.

Intake, query, and completion remain single-threaded, statically linked
executables:

```text
ELF 64-bit LSB executable, ARM aarch64, statically linked, stripped
```

Execution is multithread-capable because the TigerBeetle C client completes
requests on a native callback thread. It is a stripped ARM64 glibc executable
and `file` reports it as dynamically linked. Amazon Linux 2023 supplies the
glibc loader and libraries; do not expect the execution bootstrap to be
static.

Create or refresh all four packages.

```sh
zip -qj intake-lambda.zip zig-out/bin/intake/bootstrap
zip -qj query-lambda.zip zig-out/bin/query/bootstrap
zip -qj execution-lambda.zip zig-out/bin/execution/bootstrap
zip -qj completion-lambda.zip zig-out/bin/completion/bootstrap
```

SAM reads the packages from the matching `CodeUri` properties in `template.yaml`.

### Deferred execution cold-start acceptance

Local bootstrap inspection proves the architecture, glibc linkage, and native epoll artifact only;
it does not prove Lambda cold-start acceptance. Do not refresh the zip files, deploy, invoke SQS, or
claim cold-start acceptance as part of this artifact-only validation.

After a separately authorized deployment, inspect the published execution version and its first
invocation in the target environment. Confirm the Lambda ARM64 architecture, the expected
`provided.al2023` runtime, the configured TigerBeetle address, successful native-client
initialization, and a completed accounting operation in CloudWatch logs. Also verify that the
execution subnet route/security-group path reaches the TigerBeetle replica and that a deferred
invocation after the first cold start reuses the retained client. Record the invocation ID,
bootstrap logs, and operation result before accepting the cold start; a timeout, initialization
error, or SQS retry is not acceptance evidence.

## 3. Validate the SAM template

Run basic SAM validation.

```sh
sam validate \
  --template-file template.yaml \
  --region ca-central-1
```

Run stricter lint validation.

```sh
sam validate --lint \
  --template-file template.yaml \
  --region ca-central-1
```

Both commands should report that `template.yaml` is valid.

## 4. Understand what the template creates

`template.yaml` defines these resources:

- `OperationsTable`: `AWS::DynamoDB::Table`
- `TigerBeetleQueue`: `AWS::SQS::Queue`
- `CompletionQueue`: `AWS::SQS::Queue`
- `IntakeFunction`: `AWS::Serverless::Function`
- `IntakeFunctionUrl`: `AWS::Lambda::Url`
- `FunctionUrlInvokeFunctionUrlPermission`: allows `lambda:InvokeFunctionUrl`
- `FunctionUrlInvokeFunctionPermission`: allows `lambda:InvokeFunction` only
  through the Function URL
- `QueryFunction`: `AWS::Serverless::Function`
- `QueryFunctionUrl`: `AWS::Lambda::Url`
- `QueryFunctionUrlInvokeFunctionUrlPermission`: allows `lambda:InvokeFunctionUrl`
- `QueryFunctionUrlInvokeFunctionPermission`: allows `lambda:InvokeFunction` only
  through the query Function URL
- `ExecutionFunction`: `AWS::Serverless::Function`
- `ExecutionFunctionRole`: `AWS::IAM::Role`
- `ExecutionFunctionTigerBeetleQueueMapping`: `AWS::Lambda::EventSourceMapping`
- `CompletionFunction`: `AWS::Serverless::Function`
- `CompletionFunctionRole`: `AWS::IAM::Role`
- `CompletionFunctionCompletionQueueMapping`: `AWS::Lambda::EventSourceMapping`

When `EnableWireGuardGateway=true`, the template also creates:

- `ExecutionLambdaSecurityGroup`: `AWS::EC2::SecurityGroup`
- `ExecutionEgressOnlyInternetGateway`: `AWS::EC2::EgressOnlyInternetGateway`
- `ExecutionSqsIpv6Route`: `AWS::EC2::Route`
- `WireGuardGatewaySecurityGroup`: `AWS::EC2::SecurityGroup`
- `WireGuardGatewayRole`: `AWS::IAM::Role`
- `WireGuardGatewayInstanceProfile`: `AWS::IAM::InstanceProfile`
- `WireGuardGatewayLaunchTemplate`: `AWS::EC2::LaunchTemplate`
- `WireGuardGatewayInstance`: `AWS::EC2::Instance`
- `WireGuardGatewayElasticIp`: `AWS::EC2::EIP`
- `WireGuardGatewayElasticIpAssociation`: `AWS::EC2::EIPAssociation`
- `WireGuardLambdaRoute`: `AWS::EC2::Route`

Every gateway resource and output is conditional. The internal
`RetainExecutionVpcCleanupResources` parameter temporarily keeps
`ExecutionEgressOnlyInternetGateway`, `ExecutionSqsIpv6Route`,
`ExecutionLambdaSecurityGroup`, the required `VpcId` and `LambdaRouteTableId`
values, and the execution role's EC2 network-interface policy during a
setup-script detach or reconfiguration transition. In steady disabled state,
the execution Lambda has no VPC attachment or EC2 network-interface
permissions, and the empty gateway parameter defaults create no gateway or
cleanup resources.

The gateway security group admits public IPv4 UDP/51820 and private TCP/3000
from `LambdaSubnetCidr`; it allows IPv4 egress for bootstrap, SSM, and tunnel
traffic. The launch template creates one ARM64 Amazon Linux network interface
in the public subnet, requires IMDSv2, and bootstraps a routed `wg0` interface
at `10.200.0.1/24`. The instance has source/destination checking disabled. Its
Elastic IP and the Lambda-subnet route to `10.200.0.0/24` follow the
stack-managed instance lifecycle.

The intake and query functions share the runtime, architecture, memory,
three-second timeout, basic logging policy, PASETO configuration, and
operations-table environment value:

```yaml
Runtime: provided.al2023
Handler: bootstrap
Architectures:
  - arm64
MemorySize: 128
Timeout: 3
Policies:
  - AWSLambdaBasicExecutionRole
Environment:
  Variables:
    LAMBDA_PRINCIPAL: !Ref LambdaPrincipal
    OPERATIONS_TABLE_NAME: !Ref OperationsTable
    PASETO_PUBLIC_KEY: !Ref PasetoPublicKey
```

The intake function additionally receives the queue URL under the exact
operation-routing key `TigerBeetleQueue` and the following table-write and
queue-send permissions:

```yaml
Policies:
  - Version: "2012-10-17"
    Statement:
      - Effect: Allow
        Action:
          - dynamodb:PutItem
        Resource: !GetAtt OperationsTable.Arn
      - Effect: Allow
        Action:
          - sqs:SendMessage
        Resource: !GetAtt TigerBeetleQueue.Arn
Environment:
  Variables:
    TigerBeetleQueue: !Ref TigerBeetleQueue
```

The query function receives its own inline policy containing only
`dynamodb:GetItem` for this stack's operations table. It does not receive
`TigerBeetleQueue` or any SQS permission.

The execution function uses the same `provided.al2023` ARM64 runtime, 128 MB
memory, a 15-second timeout, and basic logging policy. It has no Function URL
or authentication configuration. Its explicit role grants queue-scoped
polling permissions for `TigerBeetleQueue` and `sqs:SendMessage` only for
`CompletionQueue`. It has no DynamoDB permission. When the gateway is enabled,
the role also receives the six EC2 network-interface actions required by a
VPC-attached Lambda. The function receives `COMPLETION_QUEUE_URL` plus the
TigerBeetle settings.

Only execution is attached to `LambdaSubnetId`. Its VPC configuration sets
`Ipv6AllowedForDualStack: true`, its stack-managed security group allows IPv4
TCP/3000 only to `10.200.0.2/32` and IPv6 TCP/443 to `::/0`, and
`AWS_USE_DUALSTACK_ENDPOINT=true` makes the AWS SDK select the regional public
SQS dual-stack endpoint. SAM creates the VPC's EIGW and an execution-specific
`::/0` route in `LambdaRouteTableId`. The externally supplied VPC, subnets,
route table, IPv6 associations, DNS settings, and network ACL remain outside
the stack.

The completion function uses `provided.al2023`, ARM64, 128 MB, and a 15-second
timeout. It has no Function URL, authentication configuration, or VPC
attachment. Its explicit role can poll only `CompletionQueue` and can call
only `dynamodb:UpdateItem` on `OperationsTable`. Its only application
environment value is `OPERATIONS_TABLE_NAME`.

The least-privilege boundary is deliberate: intake creates an Operation and
routes `"name":"TigerBeetle"` to `TigerBeetleQueue`; query reads the table;
execution polls `TigerBeetleQueue` and publishes terminal results to
`CompletionQueue`; and
completion polls `CompletionQueue` and updates the table. Lambda's managed
event-source pollers consume both source queues outside the function execution
environment. Therefore only execution's AWS SDK `SendMessage` call needs the
VPC SQS egress path. Completion remains outside the VPC and reaches DynamoDB
normally.

`TigerBeetleClusterId` and `TigerBeetleAddresses` populate
`TIGERBEETLE_CLUSTER_ID` and `TIGERBEETLE_ADDRESSES`. Their defaults are `0`
and `10.200.0.2:3000`. The cluster ID must parse as an unsigned 128-bit decimal
integer, and the comma-separated address string must be non-empty, no longer
than 4,096 bytes, and contain no whitespace. The native client performs final
address-syntax validation during cold start. `deploy.sh` exposes matching
`--tigerbeetle-cluster-id` and `--tigerbeetle-addresses` options plus matching
environment overrides.

The execution event source mapping is enabled with `BatchSize: 10`,
`MaximumBatchingWindowInSeconds: 0`, `MaximumConcurrency: 8`, and
`ReportBatchItemFailures`. The event-source concurrency cap limits the mapping
to eight concurrent execution invocations, preventing unbounded Lambda scaling
from consuming TigerBeetle's default 64 client sessions. Lambda polls the queue
and invokes execution with SQS events. The mapping remains enabled when the
managed WireGuard gateway is disabled; operators must provide another trusted
route to the configured TigerBeetle address or accept timeout-driven
partial-batch retries. For each record, the handler
retains the debug log containing `message_id` and `body`, parses and validates
the complete Operation output, and processes only a queued `SUBMITTED` Operation with
a body and no result. Records are handled sequentially within the ten-record
bound. Invalid records are logged and acknowledged without contacting
TigerBeetle.

For each valid Operation, execution first creates a TigerBeetle account with
`id = Operation.id`, ledger `1`, and code `1`. It then creates a posted transfer
with `id = Operation.id`, debit account `Operation.id`, credit account `1`,
amount `100`, ledger `1`, and code `1`. Account and transfer creation are
separate requests because linked events cannot atomically join different
TigerBeetle event types. Account `1` is an operator-provisioned prerequisite;
execution never creates it, and it must use ledger `1` with flags compatible
with receiving this credit.

After both accounting requests return `created` or the replay-safe identical
`exists`, execution creates a terminal success entry. The success result is
exactly:

```json
{"type":"SUCCESS","payload":{"transfer_id":"00112233-4455-6677-8899-aabbccddeeff"}}
```

A definitive account or transfer rejection creates a terminal failure entry
with its stage and raw TigerBeetle status. The failure results are exactly:

```json
{"type":"FAILURE","payload":{"stage":"ACCOUNT","status":19}}
```

```json
{"type":"FAILURE","payload":{"stage":"TRANSFER","status":22}}
```

Processing always advances to the next TigerBeetle queue record. A definite
TigerBeetle rejection is logged and represented as a terminal Completion
entry. TigerBeetle client/request or result-construction uncertainty adds only
that TigerBeetle queue message ID to `batchItemFailures`. After processing the
invocation, execution encodes all terminal entries into at most one aggregate
Completion message and sends it once. The stable account and transfer IDs make
Operations retries replay-safe: `created` and identical `exists` proceed,
while every `exists_with_different_*` result is a definitive terminal failure.

The aggregate JSON contract is `{"results":[...]}`. Each entry contains only
the canonical `operation_id` and a validated tagged `result`; it does not copy
the queued Operation snapshot, tenant, name, hash, or timestamps. The codec
rejects an empty aggregate and bounds the complete encoded message to 1 MiB.
That byte limit, rather than a promised fixed number of result entries, is the
message contract. If publication fails, every TigerBeetle queue record represented
in that aggregate is returned for retry. If publication succeeds, those source
records are acknowledged; execution never acknowledges a terminal result
before its Completion message is published.

The completion event source mapping uses `BatchSize: 1`,
`MaximumBatchingWindowInSeconds: 0`, and `ReportBatchItemFailures`. One Lambda
invocation therefore receives one aggregate Completion queue message and
updates only that message's entries, sequentially. The 15-second function
timeout and the queue's 90-second visibility timeout are paired with this
one-message boundary. Do not infer that every aggregate up to the byte limit
will necessarily finish in 15 seconds: use measured cold-start and worst-case
sequential DynamoDB latency when changing the encoded-message bound, function
timeout, or queue visibility timeout, and size all three together.

For each valid entry, completion performs one ID-only `UpdateItem`: the
canonical ID selects the item and the condition is only stored
`state = SUBMITTED`. There is no read-before-write and no comparison against
tenant, name, hash, `last_updated`, `expires_at`, a queued snapshot, or an
absent result. A successful write sets `state = COMPLETED`, stores the
canonical result envelope, samples `last_updated` immediately before that
entry's write, and derives `expires_at` as exactly 86,400 seconds later. The
request asks for neither success attributes nor the conflicting item.

A missing item or an item no longer in `SUBMITTED` state is an acknowledged
`OperationConflict`. This makes duplicate or stale at-least-once Completion
delivery unable to overwrite the first terminal result. An invalid entry that
still contains one trustworthy canonical ID is converted to an identifiable,
deterministic failure result and persisted. An entry with a missing,
noncanonical, duplicate, or otherwise untrustworthy ID is acknowledged without
a write because there is no safe item to select. A malformed outer aggregate
is also acknowledged unless decoding failed for allocation.

A transient allocation or DynamoDB failure stops processing that aggregate and
returns its single SQS message ID in `batchItemFailures`. The entire message is
then replayed. Earlier successful entries become acknowledged conflicts on
replay, allowing processing to reach the failed entry and any later entries;
each newly successful write gets its actual replay-time timestamp and TTL.
Completion acknowledges the SQS message only after every entry has either
succeeded or reached an acknowledged deterministic/conflict outcome.

`OPERATIONS_TABLE_NAME` contains the CloudFormation-generated physical table
name. Intake, query, and completion initialize the Operation persistence
module around an AWS configuration and reuse their clients and HTTP pools
across warm invocations. Intake also initializes one reusable SQS sender. On
each valid POST it rejects the exact reserved operation name `Completion`, then
appends `Queue` to any other case-sensitive operation name and resolves that
environment key before persistence; `"name":"TigerBeetle"` therefore resolves
`TigerBeetleQueue`. Execution validates
`COMPLETION_QUEUE_URL`, initializes the fixed-queue SQS module, and retains one
TigerBeetle client across warm invocations. Missing or invalid cold-start
configuration prevents the affected Lambda from handling invocations. The
local persistence and queue command implementations use the same modules and
contracts.

Startup validation makes no DynamoDB or SQS request. A missing, empty, or
oversized intake route mapping returns HTTP 400 before persistence or send. A
missing table or insufficient DynamoDB permission is discovered by a POST persistence request
and returned by intake as a sanitized HTTP 500. A query DynamoDB request or
service failure returns a sanitized HTTP 503, while a malformed stored item or
unexpected failure returns HTTP 500. A missing queue, insufficient
`SendMessage` permission, or another SQS send failure is returned as a
sanitized HTTP 503. Execution discovers a missing Completion queue, insufficient
`SendMessage` permission, or another Completion queue send failure while
publishing the aggregate and retries every represented TigerBeetle queue record.
Completion discovers a missing table, insufficient `UpdateItem` permission,
or another DynamoDB service failure while processing an entry and retries the
single Completion message.

The second intake inline-policy statement grants that function only
`SendMessage` access to this stack's TigerBeetle queue. The handler sends full
compact `SUBMITTED` Operation JSON, but has no receive, delete, purge, or
queue-management permissions. Execution receives its separate TigerBeetle queue
queue-scoped poller policy and Completion queue-scoped `SendMessage` policy.
Completion receives its separate Completion queue-scoped poller policy and
table-scoped `UpdateItem`; neither role grants queue-management access. The
`queue.sh` command uses the local caller's AWS identity and does not expand any
Lambda role. Its `receive` command competes with the selected queue's enabled
event source mapping: execution for `TigerBeetleQueue` or completion for
`CompletionQueue`.

`TigerBeetleQueue` and `CompletionQueue` are standard queues with 90-second
visibility timeouts, six times
their consumer functions' 15-second timeouts. The template does not configure
FIFO behavior or a dead-letter queue for either queue. No additional
retention or replay path is introduced. `DeletionPolicy: Delete` and
`UpdateReplacePolicy: Delete` mean deleting the stack or replacing either
queue permanently deletes its queued messages; retries do not outlive the
queue's configured retention period.
`TigerBeetleQueue` has that exact fixed physical name, while CloudFormation
generates the Completion queue name. Renaming from the former queue resource
replaces it and deletes any messages left in the old queue under these policies.

The operations table uses on-demand `PAY_PER_REQUEST` billing and has one
string partition key named `id`. It has no sort key, secondary indexes,
streams, provisioned capacity, or explicit table name. Native DynamoDB TTL is
enabled on `expires_at`. Point-in-time recovery is explicitly disabled, and
omitting `SSESpecification` selects DynamoDB's default AWS-owned encryption.

The DynamoDB item contract enforced by `src/operation_persistence.zig` is:

| Attribute | DynamoDB type | Contract |
| --- | --- | --- |
| `id` | `S` | Always present; partition key; canonical lowercase hyphenated Operation UUID. |
| `tenant` | `S` | Always present; server-owned valid UTF-8; 1 to 64 bytes. |
| `name` | `S` | Always present. |
| `state` | `S` | One of `SUBMITTED` or `COMPLETED`. |
| `last_updated` | `N` | Unix epoch seconds. |
| `expires_at` | `N` | Exactly 86,400 seconds after `last_updated`; DynamoDB TTL attribute. |
| `hash` | `S` | 64-character lowercase BLAKE3-256 hexadecimal value. |
| `result` | `S` | `COMPLETED` only; compact tagged envelope with exactly uppercase `type` and non-null `payload`; complete envelope at most 4,096 UTF-8 bytes. |

The Operation hash covers only the fixed-order JSON envelope containing
`tenant`, `name`, and `body`.
The body is parsed once into an arena-owned `std.json.Value` and serialized
directly into the hash stream, so insignificant whitespace and equivalent
string escapes do not change the hash, while object member order remains
significant. The `id`, `state`, `last_updated`, `expires_at`, and `result`
fields are excluded. Lambda derives tenant exclusively from the verified
PASETO `sub` claim. The persistence `create` command accepts it only through
`--tenant`; caller-supplied Operation JSON cannot set it. One lifetime arena
owns each Operation's tenant, strings, and nested body or result Values for a
persistence command or Lambda POST.

The reference envelope
`{"tenant":"tenant-a","name":"echo","body":{"message":"hello","count":2}}`
has lowercase BLAKE3-256 digest
`d271e3bd560113d2b82e42dfc46be33fb90b43d7f4b12114f3da4888eae445d4`.

Never persist `body`. The 4,096-byte full-envelope `result` bound is an application-enforced
constraint because DynamoDB and CloudFormation cannot enforce a per-attribute
size limit. Completed result input and its compact serialization, including
both `type` and `payload`, must fit the bound. The adapter serializes
caller-provided tagged results into fixed request buffers and validates them
immediately before persistence; execution builds one of its bounded success or
failure envelopes. On reads, the adapter
parses the stored string once into the caller's arena and requires the string
to equal the compact reserialization, rejecting malformed, duplicate-key,
explicit-null, incorrectly tagged, oversized, or noncanonical items. Creates use
`attribute_not_exists(id)` and request `ALL_OLD` when that condition fails. A
failed create condition succeeds as an idempotent retry only when the returned
item has the requested tenant and Operation hash, regardless of its current
state; otherwise it is an Operation conflict. Reads are strongly consistent.
Read-modify-write updates condition on the previously read snapshot, including
the old `expires_at`, preserve `id`, `tenant`, `name`, and `hash`, and return
and validate `ALL_NEW`. A submitted Operation may refresh as `SUBMITTED` or
transition once to `COMPLETED`; every completed Operation is immutable,
including a same-outcome refresh. New items and every successful update set
`expires_at` to `last_updated + 86,400`.
Result-size validation remains in the application rather than a DynamoDB
condition expression. The completion Lambda uses the separate relaxed
ID-only update described above; the strict snapshot-based update interface
remains available to local persistence callers.

Tenant is server-owned metadata, part of idempotency identity, and the query
authorization boundary. UUIDs and the `id` partition key remain globally
scoped, so reusing a UUID under another tenant changes the hash and returns an
Operation conflict. Query performs the globally keyed `GetItem`, then returns
the Operation only when its stored tenant equals the verified PASETO subject.
Missing and cross-tenant items are indistinguishable `404 Not Found` responses.
No tenant-scoped key or secondary index is introduced.

DynamoDB TTL deletion is asynchronous. An item becomes eligible for deletion
at `expires_at` but may remain readable until DynamoDB removes it.
CloudFormation configures TTL, so the Lambda role does not need an additional
DynamoDB control-plane permission.

The Function URLs use `AuthType: NONE` and buffered invocation. CORS is not
configured because the service targets non-browser HTTP clients. The handlers
enforce the supported methods: intake allows only POST and query allows only
`GET /<uuid>`. Their public permissions use the existing intake logical IDs and new
query-specific logical IDs.

```yaml
AuthType: NONE
InvokeMode: BUFFERED
```

`AuthType: NONE` and `Principal: "*"` make the Function URL public.

`LambdaPrincipal` configures only the `LAMBDA_PRINCIPAL` environment variable
inside the function. It does not change the Function URL resource permissions.

`PasetoPublicKey` is a required parameter that configures the
`PASETO_PUBLIC_KEY` used by the handler to verify PASETO v4.public bearer
tokens.

## 5. Preserve the intake function name and choose deployment values

The template defaults to:

```text
intake-lambda
query-lambda
execution-lambda
completion-lambda
```

They are controlled by `IntakeFunctionName`, `QueryFunctionName`,
`ExecutionFunctionName`, and `CompletionFunctionName`. Before
updating an existing stack, resolve the current intake physical name and reuse
it exactly:

```sh
intake_function_name="$(
  aws cloudformation describe-stack-resource \
    --stack-name aws-lambda-zig-demo \
    --logical-resource-id IntakeFunction \
    --query StackResourceDetail.PhysicalResourceId \
    --output text \
    --profile dev \
    --region ca-central-1
)"
printf '%s\n' "$intake_function_name"
```

Pass that value as `IntakeFunctionName`. `deploy.sh` performs the same preflight
and stops before building or deploying if the requested name differs. Use
`./deploy.sh --migration-check-only` to run only this guard. An absent stack is
accepted as a first deployment; a matching existing name is accepted; a
mismatch is rejected. The `IntakeFunction`, `IntakeFunctionUrl`,
`FunctionUrlInvokeFunctionUrlPermission`, and
`FunctionUrlInvokeFunctionPermission` logical IDs remain unchanged, so this
guard keeps the current intake Lambda and URL managed in place.

For a first deployment with no stack, set `intake_function_name=intake-lambda`
before using the direct SAM commands below.

Remove obsolete `FunctionName=...` entries from `samconfig.toml`, then add
`IntakeFunctionName=<existing-physical-name>` and
`QueryFunctionName=query-lambda`, `ExecutionFunctionName=execution-lambda`, and
`CompletionFunctionName=completion-lambda` if parameter overrides are saved
there. The
removed `FunctionName` parameter and generic function outputs were template
interfaces, not physical resources, so they require no cleanup.

The automated flow never deletes cloud resources. If an operator deliberately
changes the physical intake name outside this guard, CloudFormation replaces
the function because [`FunctionName` changes require replacement](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-lambda-function.html)
and CloudFormation normally [deletes replaced resources during update cleanup](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-updating-stacks-update-behaviors.html).
Review stack events for `DELETE_FAILED`. After validating the replacement,
inspect the old `/aws/lambda/<old-name>` log group and delete it explicitly if
it is no longer required; deleting a Lambda does not delete its log group
([Lambda logging guidance](https://docs.aws.amazon.com/lambda/latest/dg/nodejs-logging.html)).

The `LambdaPrincipal` parameter defaults to:

```text
*
```

You can keep the default or override it during deployment to set the
`LAMBDA_PRINCIPAL` environment variable.

Generate a signing key pair if you do not already have one:

```sh
zig-out/bin/paseto keygen
```

Export only the printed public key in the deployment shell:

```sh
export PASETO_PUBLIC_KEY='<public-key-from-keygen>'
```

`PasetoPublicKey` has no default. Deployment must provide it, and tokens must
be signed by the corresponding private key.

The optional gateway parameters are:

| Parameter | Meaning |
| --- | --- |
| `EnableWireGuardGateway` | `true` enables the gateway; defaults to `false`. |
| `RetainExecutionVpcCleanupResources` | Internal `wireguard-gateway-setup.sh` lifecycle switch; retains the stack-owned EIGW, IPv6 route, execution security group, required VPC/route-table values, and ENI permissions between detach and cleanup phases. Defaults to `false`. |
| `VpcId` | Existing VPC containing both supplied subnets; its IPv6 CIDR association remains externally managed. |
| `GatewayPublicSubnetId` | Existing public subnet for the EC2 gateway. |
| `LambdaSubnetId` | Distinct existing subnet for the execution Lambda; its IPv6 `/64` association remains externally managed. |
| `LambdaRouteTableId` | Effective external route table for `LambdaSubnetId`; SAM adds its execution-specific routes. |
| `LambdaSubnetCidr` | Primary IPv4 CIDR of `LambdaSubnetId`; it must not overlap `10.200.0.0/24`. |
| `WireGuardPrivateKeyParameterName` | Absolute path of the external gateway-private-key SSM `SecureString`. |
| `WireGuardPrivateKeyParameterVersion` | Exact positive version to retrieve; defaults to `1`. |
| `WireGuardGatewayPublicKey` | Padded Base64 public key matching the stored gateway private key. |
| `WireGuardWorkstationPublicKey` | Padded Base64 public key matching the workstation private key. |
| `WireGuardAmiId` | Public SSM parameter resolving to an ARM64 Amazon Linux 2023 AMI. |
| `WireGuardInstanceType` | ARM64 gateway instance type; defaults to `t4g.nano`. |

### Provision and validate the external dual-stack topology

The recommended development topology keeps an existing internet-routed subnet
for the EC2 gateway and uses a distinct private subnet in the same availability
zone for execution. The Lambda subnet has no automatic public IPv4 assignment
and uses an explicitly associated route table. The VPC, subnets, route table,
route-table association, IPv6 CIDR associations, DNS attributes, and network
ACL are operator-owned prerequisites. Neither the SAM template nor
`wireguard-gateway-setup.sh` creates, changes, or deletes them.

Before enablement, the topology must satisfy all of these constraints:

- The gateway subnet and Lambda subnet are distinct, in the same VPC and
  availability zone, and neither IPv4 CIDR overlaps `10.200.0.0/24`.
- The gateway subnet's effective route table has an active `0.0.0.0/0` route
  to an internet gateway.
- The VPC has an active IPv6 CIDR association. The Lambda subnet has exactly
  one active IPv6 `/64`, contained by exactly one active VPC IPv6 allocation.
- `enableDnsSupport` and `enableDnsHostnames` are both enabled on the VPC.
- `LambdaRouteTableId` is the Lambda subnet's effective route table. Before
  first enablement it has no `::/0` route and the VPC has no attached EIGW.
  During reconfiguration, any such route and EIGW must be the current stack's
  `ExecutionSqsIpv6Route` and `ExecutionEgressOnlyInternetGateway`.
- The Lambda subnet's effective network ACL allows outbound IPv6 TCP/443 and
  the corresponding inbound TCP/1024-65535 response traffic. A clearly denying
  policy is rejected; a valid but nontrivial ordered policy produces a warning
  and requires operator verification.
- The route table has no conflicting `10.200.0.0/24` route. The current
  stack-owned WireGuard route is accepted during an in-place reconfiguration.

Use live queries immediately before enablement and keep the returned values in
the operator session rather than documentation:

```sh
vpc_id='<vpc-id>'
gateway_subnet_id='<gateway-public-subnet-id>'
lambda_subnet_id='<lambda-subnet-id>'
lambda_route_table_id='<lambda-route-table-id>'

aws ec2 describe-vpcs \
  --vpc-ids "$vpc_id" \
  --query 'Vpcs[0].[VpcId,Ipv6CidrBlockAssociationSet]' \
  --output json \
  --profile dev \
  --region ca-central-1
aws ec2 describe-subnets \
  --subnet-ids "$gateway_subnet_id" "$lambda_subnet_id" \
  --query 'Subnets[].[SubnetId,VpcId,AvailabilityZone,CidrBlock,Ipv6CidrBlockAssociationSet]' \
  --output json \
  --profile dev \
  --region ca-central-1
aws ec2 describe-vpc-attribute \
  --vpc-id "$vpc_id" \
  --attribute enableDnsSupport \
  --profile dev \
  --region ca-central-1
aws ec2 describe-vpc-attribute \
  --vpc-id "$vpc_id" \
  --attribute enableDnsHostnames \
  --profile dev \
  --region ca-central-1
aws ec2 describe-route-tables \
  --route-table-ids "$lambda_route_table_id" \
  --query 'RouteTables[0].[RouteTableId,VpcId,Associations,Routes]' \
  --output json \
  --profile dev \
  --region ca-central-1
aws ec2 describe-egress-only-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=$vpc_id" \
  --output json \
  --profile dev \
  --region ca-central-1
aws ec2 describe-network-acls \
  --filters "Name=association.subnet-id,Values=$lambda_subnet_id" \
  --output json \
  --profile dev \
  --region ca-central-1
```

If the selected VPC does not yet have IPv6, allocation is an operator-side
address-plan decision. One possible AWS-provided allocation starts with:

```sh
aws ec2 associate-vpc-cidr-block \
  --vpc-id "$vpc_id" \
  --amazon-provided-ipv6-cidr-block \
  --profile dev \
  --region ca-central-1
```

Wait for that association to become active, select one unused `/64` from it,
and associate that exact block with the Lambda subnet:

```sh
lambda_subnet_ipv6_cidr='<unused-vpc-ipv6-subnet-cidr/64>'
aws ec2 associate-subnet-cidr-block \
  --subnet-id "$lambda_subnet_id" \
  --ipv6-cidr-block "$lambda_subnet_ipv6_cidr" \
  --profile dev \
  --region ca-central-1
```

Do not run those mutations against a shared VPC until its address plan and
routing consumers have been reviewed. If DNS attributes are disabled, enable
them as a separate, operator-approved VPC change. The helper intentionally
fails rather than altering these shared settings.

For a new dedicated Lambda subnet, select unused IPv4 and IPv6 CIDRs in the
gateway subnet's availability zone, disable automatic public IPv4 assignment,
create a dedicated route table, and explicitly associate it. Keep the returned
subnet, route-table, and association IDs in the operator session. The helper
can discover the effective route table, but explicit topology makes ownership
and later cleanup easier to audit.

On first enablement, the deployment creates the stack-owned EIGW and adds
`ExecutionSqsIpv6Route` with destination `::/0` to the supplied route table.
A VPC supports only one EIGW, so an existing unmanaged EIGW is a hard conflict;
there is no EIGW-ID template parameter and no import workflow. SAM also adds
the separate `10.200.0.0/24` route for TigerBeetle. It does not remove or
alter any operator-owned NAT route, internet-gateway route, VPC/subnet IPv6
association, or unrelated route.

After disabling or deleting the stack, the supplied VPC, subnets, route table,
route-table association, IPv6 allocations, DNS settings, and network ACL
remain. Delete a dedicated external subnet or route table only as a separate
operator action after verifying that execution and all other workloads are
detached. Never remove a shared IPv6 association merely because this stack was
torn down.

### SQS egress security and cost tradeoff

Execution's Completion `SendMessage` call uses outbound-only public IPv6 HTTPS
through the EIGW. The security group allows TCP/443 to `::/0`, so the network
boundary is broader than PrivateLink's private-only reachability and endpoint
policy. The execution role's queue-scoped `sqs:SendMessage` permission is the
service authorization boundary. The demo accepts that tradeoff to avoid an SQS
interface endpoint and its fixed hourly and data-processing charges. No SQS
interface endpoint, endpoint security group, private-DNS setting, or endpoint
policy is part of this design.

An EIGW has no fixed hourly or processing charge, unlike an SQS interface
endpoint or NAT Gateway. Ordinary AWS charges still apply, including data
transfer where applicable, SQS requests, Lambda, the EC2 WireGuard gateway,
and its public IPv4/Elastic IP.

### Create the workstation key

The workstation private key remains workstation-owned and is never generated
or stored by AWS deployment tooling. Create it in a protected directory and
keep the private file for the workstation configuration in section 7:

```sh
wireguard_key_dir="$(mktemp -d "${TMPDIR:-/tmp}/aws-lambda-zig-wireguard.XXXXXX")"
chmod 700 "$wireguard_key_dir"
(
  umask 077
  wg genkey >"$wireguard_key_dir/workstation.private"
  wg pubkey <"$wireguard_key_dir/workstation.private" \
    >"$wireguard_key_dir/workstation.public"
)
wireguard_workstation_public_key="$(tr -d '\n' <"$wireguard_key_dir/workstation.public")"
```

Never put the workstation private key in `template.yaml`, a command line,
shell history, an environment passed to either deployment helper, stack parameters or
outputs, documentation, or the repository.

### Default gateway keypair managed by `wireguard-gateway-setup.sh`

For stack `aws-lambda-zig-demo`, the helper uses these external parameters:

| Value | Default parameter | Type |
| --- | --- | --- |
| Gateway private key | `/applications/aws-lambda-zig-demo/wireguard/gateway-private-key` | `SecureString`, encrypted with `alias/aws/ssm` |
| Gateway public key | `/applications/aws-lambda-zig-demo/wireguard/gateway-public-key` | `String` |

The paths follow `/applications/${STACK_NAME}/wireguard/...` for another stack
name. Parameter Store reserves names beginning with `aws` or `ssm`, ignoring
case, so `wireguard-gateway-setup.sh` and `template.yaml` reject custom paths with either prefix.
If both
exist, `wireguard-gateway-setup.sh` validates their types and the public-key format and uses the
current private version. If neither exists, it requires `wg`, generates the
pair under `umask 077` in a mode-0700 temporary directory, creates both without
`--overwrite`, and removes the directory on success or failure. The private
value is supplied through a mode-0600 `--cli-input-json file://...` request,
never a command argument or environment variable. If the second creation
fails, the helper rolls back only the private parameter created by that
invocation.

The two parameters are operator-owned, survive gateway disablement and stack
deletion, and are never overwritten or rotated implicitly. A lone parameter is
treated as an error and is left untouched. Repair it by deriving and creating
the missing matching value, or delete the lone value and let `wireguard-gateway-setup.sh`
generate a new pair. Do not combine an existing half with newly generated key
material.

If the private parameter exists and the public parameter is missing, derive
the public key without writing or printing the private value, then create the
missing `String` without `--overwrite`:

```sh
private_parameter_name="/applications/${STACK_NAME:-aws-lambda-zig-demo}/wireguard/gateway-private-key"
public_parameter_name="/applications/${STACK_NAME:-aws-lambda-zig-demo}/wireguard/gateway-public-key"
repaired_gateway_public_key="$(
  aws ssm get-parameter \
    --name "$private_parameter_name" \
    --with-decryption \
    --query Parameter.Value \
    --output text \
    --profile dev \
    --region ca-central-1 |
    wg pubkey
)"
aws ssm put-parameter \
  --name "$public_parameter_name" \
  --description 'WireGuard gateway public key' \
  --type String \
  --value "$repaired_gateway_public_key" \
  --profile dev \
  --region ca-central-1
```

If only the public parameter exists, its private key cannot be reconstructed.
Restore the exact private value from a protected backup, or delete the lone
public parameter and rerun first enablement to create a fresh pair. Wrong types
or a malformed public value likewise require an intentional operator repair;
the helper will not overwrite them.

### Manual gateway pair for direct SAM or a custom path

Direct `sam deploy` does not run helper discovery, generation, validation, or
stack-value reuse. Generate and store the gateway pair first, then pass every
WireGuard template parameter explicitly. The following uses a custom path and
keeps the private value out of the argument list:

```sh
wireguard_parameter_name='/applications/<stack-name>/wireguard/gateway-private-key'
wireguard_public_parameter_name='/applications/<stack-name>/wireguard/gateway-public-key'
(
  umask 077
  wg genkey >"$wireguard_key_dir/gateway.private"
  wg pubkey <"$wireguard_key_dir/gateway.private" \
    >"$wireguard_key_dir/gateway.public"
  {
    printf '{"Name":"%s","Description":"WireGuard gateway private key","Type":"SecureString","KeyId":"alias/aws/ssm","Value":"' \
      "$wireguard_parameter_name"
    tr -d '\r\n' <"$wireguard_key_dir/gateway.private"
    printf '"}\n'
  } >"$wireguard_key_dir/private-put.json"
)
wireguard_parameter_version="$(
  aws ssm put-parameter \
    --cli-input-json "file://$wireguard_key_dir/private-put.json" \
    --query Version \
    --output text \
    --profile dev \
    --region ca-central-1
)"
wireguard_gateway_public_key="$(tr -d '\r\n' <"$wireguard_key_dir/gateway.public")"
aws ssm put-parameter \
  --name "$wireguard_public_parameter_name" \
  --description 'WireGuard gateway public key' \
  --type String \
  --value "$wireguard_gateway_public_key" \
  --profile dev \
  --region ca-central-1
printf 'Recorded SSM parameter version: %s\n' "$wireguard_parameter_version"
```

These create-only commands intentionally omit `--overwrite`. If either path
already exists, stop and inspect the pair rather than replacing it. The
gateway private key remains only in the external `SecureString`; securely
remove the local gateway files after the direct deployment is configured.

## 6. Deploy with SAM guided mode

Run:

```sh
sam deploy --guided \
  --template-file template.yaml \
  --profile dev \
  --region ca-central-1 \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    IntakeFunctionName="$intake_function_name" \
    QueryFunctionName=query-lambda \
    ExecutionFunctionName=execution-lambda \
    CompletionFunctionName=completion-lambda \
    LambdaPrincipal='*' \
    PasetoPublicKey="$PASETO_PUBLIC_KEY"
```

Recommended guided answers:

```text
Stack Name: aws-lambda-zig-demo
AWS Region: ca-central-1
Parameter IntakeFunctionName: <existing-physical-name-or-intake-lambda>
Parameter QueryFunctionName: query-lambda
Parameter ExecutionFunctionName: execution-lambda
Parameter CompletionFunctionName: completion-lambda
Parameter LambdaPrincipal: *
Parameter PasetoPublicKey: <public-key-from-keygen>
Confirm changes before deploy: Y
Allow SAM CLI IAM role creation: Y
Disable rollback: N
Save arguments to configuration file: Y
SAM configuration file: samconfig.toml
SAM configuration environment: default
```

`CAPABILITY_IAM` is required for the Lambda and optional gateway IAM roles.

After the first guided deployment, SAM can reuse `samconfig.toml`, so future
deployments are usually:

```sh
sam deploy --profile dev --region ca-central-1
```

An enabled guided deployment can save account-specific VPC, subnet, route
table, and SSM parameter identifiers in `samconfig.toml`. Treat that file as
local deployment state and do not commit it with live values.

Equivalent non-interactive deployment command:

```sh
sam deploy \
  --template-file template.yaml \
  --stack-name aws-lambda-zig-demo \
  --profile dev \
  --region ca-central-1 \
  --capabilities CAPABILITY_IAM \
  --resolve-s3 \
  --no-confirm-changeset \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    IntakeFunctionName="$intake_function_name" \
    QueryFunctionName=query-lambda \
    ExecutionFunctionName=execution-lambda \
    CompletionFunctionName=completion-lambda \
    LambdaPrincipal='*' \
    PasetoPublicKey="$PASETO_PUBLIC_KEY"
```

The preceding commands leave a new or already-disabled stack disabled. Do not
use a single direct SAM update to transition an enabled stack to disabled: it
does not perform the required Lambda VPC-detach wait and could remove ENI
permissions too early. Use `wireguard-gateway-setup.sh --disable` for disablement, or manually reproduce
its two phases with `RetainExecutionVpcCleanupResources=true`, a verified wait
for zero VPC-configured Lambda versions and zero ENIs on the retained security
group, both `VpcId` and `LambdaRouteTableId` preserved, then
`RetainExecutionVpcCleanupResources=false`. This keeps the EIGW, IPv6 route,
execution security group, and ENI-management permission until the final phase.
Direct SAM commands also do not perform setup-script subnet
discovery, SSM generation, or enabled-stack reuse.
To enable the gateway in guided mode, supply every opt-in parameter. Use the
variables populated by the manual key workflow above and replace only the
network placeholders:

```sh
sam deploy --guided \
  --template-file template.yaml \
  --profile dev \
  --region ca-central-1 \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    IntakeFunctionName="$intake_function_name" \
    QueryFunctionName=query-lambda \
    ExecutionFunctionName=execution-lambda \
    CompletionFunctionName=completion-lambda \
    LambdaPrincipal='*' \
    PasetoPublicKey="$PASETO_PUBLIC_KEY" \
    EnableWireGuardGateway=true \
    VpcId='<vpc-id>' \
    GatewayPublicSubnetId='<gateway-public-subnet-id>' \
    LambdaSubnetId='<lambda-subnet-id>' \
    LambdaRouteTableId='<lambda-route-table-id>' \
    LambdaSubnetCidr='<lambda-subnet-cidr>' \
    WireGuardPrivateKeyParameterName="$wireguard_parameter_name" \
    WireGuardPrivateKeyParameterVersion="$wireguard_parameter_version" \
    WireGuardGatewayPublicKey="$wireguard_gateway_public_key" \
    WireGuardWorkstationPublicKey="$wireguard_workstation_public_key" \
    WireGuardInstanceType=t4g.nano
```

The equivalent enabled non-interactive command is:

```sh
sam deploy \
  --template-file template.yaml \
  --stack-name aws-lambda-zig-demo \
  --profile dev \
  --region ca-central-1 \
  --capabilities CAPABILITY_IAM \
  --resolve-s3 \
  --no-confirm-changeset \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    IntakeFunctionName="$intake_function_name" \
    QueryFunctionName=query-lambda \
    ExecutionFunctionName=execution-lambda \
    CompletionFunctionName=completion-lambda \
    LambdaPrincipal='*' \
    PasetoPublicKey="$PASETO_PUBLIC_KEY" \
    EnableWireGuardGateway=true \
    VpcId='<vpc-id>' \
    GatewayPublicSubnetId='<gateway-public-subnet-id>' \
    LambdaSubnetId='<lambda-subnet-id>' \
    LambdaRouteTableId='<lambda-route-table-id>' \
    LambdaSubnetCidr='<lambda-subnet-cidr>' \
    WireGuardPrivateKeyParameterName="$wireguard_parameter_name" \
    WireGuardPrivateKeyParameterVersion="$wireguard_parameter_version" \
    WireGuardGatewayPublicKey="$wireguard_gateway_public_key" \
    WireGuardWorkstationPublicKey="$wireguard_workstation_public_key" \
    WireGuardInstanceType=t4g.nano
```

The repository also includes a scripted shortcut for the same build, package,
validation, and non-interactive deploy flow:

```sh
export PASETO_PRIVATE_KEY='<private-key-from-keygen>'
export PASETO_PUBLIC_KEY='<public-key-from-keygen>'
./deploy.sh
unset PASETO_PRIVATE_KEY
```

Routine `deploy.sh` runs preserve all existing WireGuard-related CloudFormation
parameters, whether the gateway is enabled or disabled. A new stack uses the
template defaults and remains disabled. Gateway flags are rejected by
`deploy.sh`, while gateway-specific environment variables are not read; use
`wireguard-gateway-setup.sh` for any gateway lifecycle change. A routine
deployment also rejects the internal retained-cleanup state until explicit
teardown finishes.

Override the environment value with either form:

```sh
LAMBDA_PRINCIPAL='<lambda-principal>' ./deploy.sh
./deploy.sh --lambda-principal '<lambda-principal>'
```

Override the execution function name with either supported interface:

```sh
EXECUTION_FUNCTION_NAME='<execution-function-name>' ./deploy.sh
./deploy.sh --execution-function-name '<execution-function-name>'
```

Override the completion function name in the same way:

```sh
COMPLETION_FUNCTION_NAME='<completion-function-name>' ./deploy.sh
./deploy.sh --completion-function-name '<completion-function-name>'
```

When an existing stack uses a nondefault completion name, also export
`COMPLETION_FUNCTION_NAME` for every `wireguard-gateway-setup.sh` enable,
reconfiguration, or disable run so its shared deployment path preserves that
physical name.

`wireguard-gateway-setup.sh` resolves each gateway value from CLI, then
environment, then a previously enabled stack, then SSM/default discovery.
Enablement is implicit. Assuming the PASETO variables above remain set, the
minimal first enablement needs only the workstation public key when networking
has one valid pair:

```sh
WIREGUARD_WORKSTATION_PUBLIC_KEY="$wireguard_workstation_public_key" \
./wireguard-gateway-setup.sh
```

The helper considers available IPv4 subnets. A gateway candidate has an active
internet-gateway default route. A Lambda candidate is distinct and in the same
VPC and availability zone; it does not need NAT. Its effective route table
must be eligible for stack-owned IPv6 and WireGuard routes. Neither subnet may
overlap `10.200.0.0/24`. An explicit VPC or one subnet
narrows the search. Each constrained subnet is inspected once. If no pair
remains, the helper prints rejection counts for gateway routing, Lambda
route management, CIDR overlap, subnet identity, VPC, and availability
zone. AWS API or malformed-response failures are reported separately instead
of being counted as topology rejections. If multiple pairs remain, the helper
prints every pair and a specific ambiguity error. Use the reported IDs to
constrain that selection:

```sh
./wireguard-gateway-setup.sh \
  --gateway-public-subnet-id '<gateway-public-subnet-id>' \
  --lambda-subnet-id '<lambda-subnet-id>' \
  --wireguard-workstation-public-key "$wireguard_workstation_public_key"
```

`VPC_ID`/`--vpc-id` also constrains candidates. `LAMBDA_SUBNET_CIDR` and
`LAMBDA_ROUTE_TABLE_ID` remain supported as optional assertions: the helper
derives both from AWS and rejects a mismatch. It prints the selected VPC,
availability zone, two subnets, Lambda CIDR, and effective route table.

For a pre-existing custom private parameter, supply the matching pinned
version and gateway public key; custom paths never receive automatic key
generation:

```sh
./wireguard-gateway-setup.sh \
  --wireguard-private-key-parameter-name '<custom-private-parameter-path>' \
  --wireguard-private-key-parameter-version '<matching-version>' \
  --wireguard-gateway-public-key "$wireguard_gateway_public_key" \
  --wireguard-workstation-public-key "$wireguard_workstation_public_key"
```

Re-running `wireguard-gateway-setup.sh` reconfigures the enabled gateway and
reuses unspecified subnet, workstation-key, gateway-key, instance-type, and
pinned private-key-version values. Routine `deploy.sh` runs preserve that state.
Explicit teardown is:

```sh
./wireguard-gateway-setup.sh --disable
```

The detach phase sets
`RetainExecutionVpcCleanupResources=true`, removing the gateway, Elastic IP,
`10.200.0.0/24` route, and related resources, and detaching execution from the
VPC. It retains the stack-owned EIGW, `::/0` route, execution security group,
required `VpcId` and `LambdaRouteTableId` values, and ENI-deletion permission.
The helper then polls for up to 20 minutes until the current function and every
published version have an empty VPC configuration and no Lambda-created ENI
references the retained security group. The cleanup phase sets
`RetainExecutionVpcCleanupResources=false` only after those checks pass,
removing the IPv6 route, EIGW, retained group, and ENI permission. An EIGW has
no endpoint ENIs, so there is no endpoint-ENI wait branch. A timeout stops
before cleanup; a later
`wireguard-gateway-setup.sh --disable` run recognizes the retained phase and
resumes the same guarded wait. Both external
SSM parameters remain operator-owned. After teardown, a later enablement
recovers the current default SSM pair but does not reuse gateway inputs from the
disabled stack.

Before building, the shared runner validates the TigerBeetle cluster ID and
address list; the setup script also validates gateway syntax. Set
`TIGERBEETLE_CLUSTER_ID` and `TIGERBEETLE_ADDRESSES`, or pass
`--tigerbeetle-cluster-id` and
`--tigerbeetle-addresses`, to override their defaults. A non-dry-run
setup discovers and verifies the topology. It checks the VPC and subnet IPv6
associations, VPC DNS attributes, effective route table, `10.200.0.0/24` and
`::/0` route conflicts, first-enable EIGW conflicts or current stack ownership,
network-ACL behavior, and regional SQS dual-stack availability. Reconfiguration
and cleanup also verify that the retained EIGW and IPv6 route belong to the
current stack. The SQS availability probe requires `sqs:ListQueues`. Preflight
reads SSM parameter metadata without decrypting the private value. It rejects
plainly incompatible or malformed state and warns when an ordered network ACL
needs operator review. The ACL parser recognizes AWS's implicit IPv6 terminal
deny at rule number `32768` while rejecting other out-of-range rule shapes.
`--dry-run` performs no AWS discovery or key creation and reports that gateway
preflight is deferred.

`deploy.sh` reads the required `PASETO_PUBLIC_KEY` from the host environment and
passes it as the `PasetoPublicKey` SAM parameter. When post-deploy checks are
enabled, it also requires the corresponding `PASETO_PRIVATE_KEY` to issue a
short-lived test token. It verifies unauthenticated HTTP 401 for both URLs,
an authenticated query of a valid UUID with a unique test subject returns a
tenant-safe 404, authenticated wrong methods return 405, and an authenticated
bodyless intake POST returns 400. The private key and test token are not printed
or passed to the Lambda environment. Use
`PASETO_PUBLIC_KEY='<public-key-from-keygen>' ./deploy.sh --dry-run` to run the
local checks, rebuild all four Lambda zip archives, and validate `template.yaml` without
deploying to AWS.

For non-dry-run deployments, the helper clears inherited static AWS credential
variables, exports `AWS_PROFILE` for the selected SSO-backed profile, passes the
same profile explicitly to SAM, and unconditionally runs
`aws sso login --profile <profile>` before AWS discovery or local build work.
The deployment stops immediately if login fails. Static, credential-process,
and other non-SSO profiles are unsupported. Dry runs make no AWS authentication
calls, and the helper does not print or write resolved credentials.

Before formatting, building, packaging, or validating, the helper queries the
existing stack and stops when its status ends in `_IN_PROGRESS`. If a local SAM
waiter or post-deployment check fails after deployment begins, it queries
CloudFormation with the selected SSO profile and distinguishes an update that is
still running, a terminal CloudFormation failure, and remote success followed
by a local failure. Do not rerun deployment against an active stack. Wait for
CloudFormation to reach a terminal state before retrying; after a bounded VPC
cleanup timeout, a later `wireguard-gateway-setup.sh --disable` run resumes the retained cleanup phase.

After a successful deployment, the shared runner resolves the
`OperationsTable` physical resource, waits for the table to exist, and prints a
concise table summary. It fails unless the table is active, uses on-demand
billing, has only the `id` string partition key, and has no local or global
secondary indexes. It then resolves the `TigerBeetleQueue` physical resource and calls
`GetQueueAttributes` to print a concise SQS summary. This probe verifies that
the deployed queue can be queried but does not enforce SQS attribute values.
Resolve and inspect `CompletionQueue` separately when verifying the complete
deployment:

```sh
completion_queue_url="$(
  aws cloudformation describe-stack-resource \
    --stack-name aws-lambda-zig-demo \
    --logical-resource-id CompletionQueue \
    --query StackResourceDetail.PhysicalResourceId \
    --output text \
    --profile dev \
    --region ca-central-1
)"
aws sqs get-queue-attributes \
  --queue-url "$completion_queue_url" \
  --attribute-names QueueArn VisibilityTimeout MessageRetentionPeriod \
  --output json \
  --profile dev \
  --region ca-central-1
```

Its `VisibilityTimeout` must be `90`. The queue has no public stack output;
resolve its physical URL when needed instead of recording it.

After a successful enablement, the setup script resolves and validates the
gateway endpoint, gateway public key, workstation address, and deployed Lambda
subnet CIDR. It then prints the conditional network outputs and a delimited,
copy-ready peer configuration before the intake and query Function URL checks.

Use
`PASETO_PUBLIC_KEY='<public-key-from-keygen>' ./deploy.sh --dry-run --use-local-libs`
to build with local dependency checkouts. The `aws_lambda` checkout defaults
to `../aws-lambda-zig`; override it with `LOCAL_AWS_LAMBDA_ROOT` when needed.

## 7. Configure and operate the WireGuard gateway

After deployment, SAM prints stack outputs. Look for:

```text
IntakeFunctionName
IntakeFunctionArn
IntakeFunctionUrl
QueryFunctionName
QueryFunctionArn
QueryFunctionUrl
ExecutionFunctionName
ExecutionFunctionArn
CompletionFunctionName
CompletionFunctionArn
```

An enabled deployment also emits these conditional outputs:

```text
WireGuardGatewayInstanceId
WireGuardGatewayElasticIp
WireGuardGatewayEndpoint
WireGuardGatewayPublicKey
WireGuardGatewayAddress
WireGuardWorkstationAddress
TigerBeetleEndpoint
```

You can also query it later with CloudFormation:

```sh
aws cloudformation describe-stacks \
  --stack-name aws-lambda-zig-demo \
  --query "Stacks[0].Outputs[?OutputKey=='QueryFunctionUrl'].OutputValue" \
  --output text \
  --profile dev \
  --region ca-central-1
```

Read all conditional network outputs without recording their live values in
the repository:

```sh
aws cloudformation describe-stacks \
  --stack-name aws-lambda-zig-demo \
  --query "Stacks[0].Outputs[?OutputKey=='WireGuardGatewayInstanceId' || OutputKey=='WireGuardGatewayElasticIp' || OutputKey=='WireGuardGatewayEndpoint' || OutputKey=='WireGuardGatewayPublicKey' || OutputKey=='WireGuardGatewayAddress' || OutputKey=='WireGuardWorkstationAddress' || OutputKey=='TigerBeetleEndpoint'].[OutputKey,OutputValue]" \
  --output table \
  --profile dev \
  --region ca-central-1
```

`lambda_logs.sh` resolves the explicit intake, query, execution, or completion
function-name output.
`persistence.sh` resolves the `OperationsTable` physical resource, while
`queue.sh` resolves the queue logical resource ID supplied by the caller. These
data-plane names are intentionally not public stack outputs. Normal local
command use does not require exporting those values.

### Configure the workstation

Install the workstation private key into the platform's protected WireGuard
configuration using mode `0600` or an equivalent secret-store permission.
Successful enablement prints this delimited, copy-ready configuration with all
public values resolved:

```text
-----BEGIN WIREGUARD PEER CONFIGURATION-----
[Interface]
Address = 10.200.0.2/24
PrivateKey = <wireguard-peer-private-key>

[Peer]
PublicKey = <resolved-gateway-public-key>
Endpoint = <resolved-gateway-elastic-ip>:51820
AllowedIPs = <resolved-lambda-subnet-cidr>
PersistentKeepalive = 25
-----END WIREGUARD PEER CONFIGURATION-----
```

Replace the literal `<wireguard-peer-private-key>` with the private key matching
the `WireGuardWorkstationPublicKey` supplied to setup. The helper never reads,
generates, prints, or persists that peer private key. It omits the configuration
on dry runs, disablement, failed deployment, and missing or malformed required
outputs.

`AllowedIPs` intentionally contains only the Lambda subnet, not the entire
VPC. This installs the return route for traffic whose source is the Lambda
subnet while keeping unrelated VPC traffic out of the development tunnel. The
workstation firewall must permit TigerBeetle TCP/3000 from
`LambdaSubnetCidr`. TigerBeetle must listen on `10.200.0.2:3000` or another
socket that includes the WireGuard interface; binding only to loopback or a
different local interface is insufficient. The gateway performs routing, not
NAT.

### Check the IPv6 SQS egress and routes

Resolve the stack-owned EIGW and verify its CloudFormation status, VPC
attachment, active `::/0` route, unchanged WireGuard route, and execution
dual-stack configuration:

```sh
eigw_id="$(
  aws cloudformation describe-stack-resource \
    --stack-name aws-lambda-zig-demo \
    --logical-resource-id ExecutionEgressOnlyInternetGateway \
    --query StackResourceDetail.PhysicalResourceId \
    --output text \
    --profile dev \
    --region ca-central-1
)"
lambda_route_table_id='<lambda-route-table-id>'
execution_function_name='<execution-function-name>'

aws cloudformation describe-stack-resources \
  --stack-name aws-lambda-zig-demo \
  --query "StackResources[?LogicalResourceId=='ExecutionEgressOnlyInternetGateway' || LogicalResourceId=='ExecutionSqsIpv6Route'].[LogicalResourceId,ResourceStatus,PhysicalResourceId]" \
  --output table \
  --profile dev \
  --region ca-central-1
aws ec2 describe-egress-only-internet-gateways \
  --egress-only-internet-gateway-ids "$eigw_id" \
  --query 'EgressOnlyInternetGateways[0].[EgressOnlyInternetGatewayId,Attachments]' \
  --output json \
  --profile dev \
  --region ca-central-1
aws ec2 describe-route-tables \
  --route-table-ids "$lambda_route_table_id" \
  --query "RouteTables[0].Routes[?DestinationIpv6CidrBlock=='::/0' || DestinationCidrBlock=='10.200.0.0/24'].[DestinationIpv6CidrBlock,DestinationCidrBlock,EgressOnlyInternetGatewayId,InstanceId,State,Origin]" \
  --output table \
  --profile dev \
  --region ca-central-1
aws lambda get-function-configuration \
  --function-name "$execution_function_name" \
  --query '[VpcConfig,Environment.Variables.AWS_USE_DUALSTACK_ENDPOINT]' \
  --output json \
  --profile dev \
  --region ca-central-1
AWS_USE_DUALSTACK_ENDPOINT=true aws sqs list-queues \
  --max-results 1 \
  --profile dev \
  --region ca-central-1
```

Both CloudFormation resources must have a complete status. The EIGW must have
one attached association to the selected VPC. The `::/0` route must be active,
created by `CreateRoute`, and target that EIGW; the `10.200.0.0/24` route
must still target the WireGuard instance. Execution's VPC configuration must
show `Ipv6AllowedForDualStack: true`, and its environment must show
`AWS_USE_DUALSTACK_ENDPOINT=true`. The SQS probe confirms regional dual-stack
endpoint availability with the operator's identity; it does not expand the
execution role.
### Check the instance and tunnel

Resolve the instance ID, wait for both EC2 status checks, and confirm that the
instance has registered with Systems Manager:

```sh
gateway_instance_id="$(
  aws cloudformation describe-stacks \
    --stack-name aws-lambda-zig-demo \
    --query "Stacks[0].Outputs[?OutputKey=='WireGuardGatewayInstanceId'].OutputValue | [0]" \
    --output text \
    --profile dev \
    --region ca-central-1
)"

aws ec2 wait instance-status-ok \
  --instance-ids "$gateway_instance_id" \
  --profile dev \
  --region ca-central-1

aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$gateway_instance_id" \
  --query 'InstanceInformationList[0].[InstanceId,PingStatus,PlatformName]' \
  --output table \
  --profile dev \
  --region ca-central-1
```

Start an administrative session through Session Manager. No SSH key or public
TCP/22 ingress is configured:

```sh
aws ssm start-session \
  --target "$gateway_instance_id" \
  --profile dev \
  --region ca-central-1
```

Inside the session, use these checks. Do not print or copy
`/etc/wireguard/wg0.conf`, because it contains the gateway private key:

```sh
sudo systemctl status wg-quick@wg0 --no-pager
sudo wg show wg0
sysctl net.ipv4.ip_forward
ip -4 route
sudo journalctl -u wg-quick@wg0 --no-pager
sudo journalctl -u cloud-final.service --no-pager
sudo tail -n 200 /var/log/cloud-init-output.log
```

On the workstation, activate the interface with the platform's WireGuard tool,
then run `sudo wg show`. A recent handshake and RX/TX counters increasing after
test traffic confirm the encrypted tunnel.

The steady-state workstation `AllowedIPs` deliberately omits the gateway's
`10.200.0.1/32` address, so it rejects gateway-originated inner packets while
accepting forwarded packets from `LambdaSubnetCidr`. For the isolated
EC2-to-workstation diagnostic, temporarily add `10.200.0.1/32` to the
workstation peer's `AllowedIPs`, apply the peer change, run these commands from
the EC2 session, and then restore the documented Lambda-subnet-only value:

```sh
ping -c 3 10.200.0.2
timeout 5 bash -c '</dev/tcp/10.200.0.2/3000'
```

ICMP may be disabled by the workstation firewall; the TCP/3000 result is the
decisive TigerBeetle reachability check.

Inspect the AWS routing and forwarding controls from the operator shell:

```sh
aws ec2 describe-route-tables \
  --route-table-ids '<lambda-route-table-id>' \
  --query "RouteTables[0].Routes[?DestinationCidrBlock=='10.200.0.0/24']" \
  --profile dev \
  --region ca-central-1

aws ec2 describe-instance-attribute \
  --instance-id "$gateway_instance_id" \
  --attribute sourceDestCheck \
  --profile dev \
  --region ca-central-1

aws cloudformation describe-stack-resources \
  --stack-name aws-lambda-zig-demo \
  --query "StackResources[?LogicalResourceId=='ExecutionLambdaSecurityGroup' || LogicalResourceId=='WireGuardGatewaySecurityGroup'].[LogicalResourceId,PhysicalResourceId]" \
  --output table \
  --profile dev \
  --region ca-central-1

aws ec2 describe-security-groups \
  --group-ids '<execution-lambda-security-group-id>' \
    '<wireguard-gateway-security-group-id>' \
  --profile dev \
  --region ca-central-1

aws lambda get-function-configuration \
  --function-name '<execution-function-name>' \
  --query VpcConfig \
  --profile dev \
  --region ca-central-1
```

The route target must be the gateway instance, source/destination checking
must be `false`, the execution security group must have only the documented
TCP/3000 and TCP/443 egress, and the gateway group must match the documented
ingress and egress. To test reboot recovery, explicitly reboot, wait for status
checks again, reconnect with Session Manager, and repeat the interface and
forwarding checks:

```sh
aws ec2 reboot-instances \
  --instance-ids "$gateway_instance_id" \
  --profile dev \
  --region ca-central-1
aws ec2 wait instance-status-ok \
  --instance-ids "$gateway_instance_id" \
  --profile dev \
  --region ca-central-1
```

### Diagnose failures

| Symptom | Likely cause and next check |
| --- | --- |
| No recent handshake | Confirm workstation WireGuard is running, outbound UDP/51820 is allowed, the endpoint is the current Elastic IP, and the two peers use matching public keys. |
| Bootstrap reports a public-key mismatch | The selected SSM version does not contain the private key matching `WireGuardGatewayPublicKey`; correct the version/public-key pair and redeploy. |
| Handshake succeeds but routed counters do not increase | Check the workstation peer `AllowedIPs = <LambdaSubnetCidr>` and the gateway peer route `10.200.0.2/32`. |
| EC2 reaches neither `10.200.0.2` nor TCP/3000 | Check workstation WireGuard state, local routes, and its firewall before checking AWS. |
| EC2 reaches `10.200.0.2`, but not TCP/3000 | Permit TCP/3000 from `LambdaSubnetCidr` and make TigerBeetle listen on `10.200.0.2:3000` or an inclusive bind address. |
| EC2 works, but Lambda cannot reach the overlay | Confirm the `10.200.0.0/24` VPC route, `SourceDestCheck=false`, execution VPC attachment, and TCP/3000 security-group egress. |
| Execution cannot publish Completion messages after VPC attachment | Confirm the VPC/subnet IPv6 associations and DNS attributes, the stack-owned EIGW and active `::/0` route, `Ipv6AllowedForDualStack=true`, `AWS_USE_DUALSTACK_ENDPOINT=true`, IPv6 TCP/443 security-group egress, the network ACL response path, and regional SQS dual-stack availability. |
| SSM registration or bootstrap fails | Check gateway-subnet internet routing, the instance role, `cloud-init` logs, and the exact SSM parameter name/version. The role can read only that parameter. |

### Rotate WireGuard keys

`wireguard-gateway-setup.sh` never rotates either parameter implicitly. To rotate the default
gateway pair, generate both values in a new protected directory, update the
private and public parameters back-to-back, and capture the returned private
version. Do not deploy the intermediate state where only one value is updated:

```sh
rotation_private_parameter_name="/applications/${STACK_NAME:-aws-lambda-zig-demo}/wireguard/gateway-private-key"
rotation_public_parameter_name="/applications/${STACK_NAME:-aws-lambda-zig-demo}/wireguard/gateway-public-key"
rotation_key_dir="$(mktemp -d "${TMPDIR:-/tmp}/aws-lambda-zig-wireguard-rotate.XXXXXX")"
chmod 700 "$rotation_key_dir"
(
  umask 077
  wg genkey >"$rotation_key_dir/gateway.private"
  wg pubkey <"$rotation_key_dir/gateway.private" \
    >"$rotation_key_dir/gateway.public"
  {
    printf '{"Name":"%s","Description":"WireGuard gateway private key","Type":"SecureString","KeyId":"alias/aws/ssm","Overwrite":true,"Value":"' \
      "$rotation_private_parameter_name"
    tr -d '\r\n' <"$rotation_key_dir/gateway.private"
    printf '"}\n'
  } >"$rotation_key_dir/private-put.json"
)

rotated_parameter_version="$(
  aws ssm put-parameter \
    --cli-input-json "file://$rotation_key_dir/private-put.json" \
    --query Version \
    --output text \
    --profile dev \
    --region ca-central-1
)"
rotated_gateway_public_key="$(tr -d '\r\n' <"$rotation_key_dir/gateway.public")"
aws ssm put-parameter \
  --name "$rotation_public_parameter_name" \
  --description 'WireGuard gateway public key' \
  --type String \
  --value "$rotated_gateway_public_key" \
  --overwrite \
  --profile dev \
  --region ca-central-1
printf 'Recorded rotated SSM parameter version: %s\n' \
  "$rotated_parameter_version"
```

If the public update fails, retain the protected directory and retry that
exact public value; do not generate another private key or run a deployment.
After both updates succeed, rerun `wireguard-gateway-setup.sh` with
`WireGuardPrivateKeyParameterVersion` set to
`$rotated_parameter_version` and `WireGuardGatewayPublicKey` set to
`$rotated_gateway_public_key`. Update the workstation peer's `PublicKey` to
the same rotated public key. Expect a brief tunnel interruption while both
sides change.

After both SSM updates and the deployment succeed, securely remove
`private-put.json`, `gateway.private`, and `gateway.public`, then remove the
rotation directory. The public key may remain in the shell variable; no private
value was exported.

Changing the SSM values alone does not reconfigure a running instance. The new
private version and matching public key create a launch-template version and replace
the stateless gateway; the Elastic IP and route remain stack-managed and
follow the replacement. To rotate the workstation key, keep its new private
key local, pass only its new public key as `WireGuardWorkstationPublicKey`,
redeploy, and update the workstation interface. Verify a new handshake and
TCP/3000 connectivity after either rotation.

The workstation-initiated handshake, routed TCP/3000 connection, execution
Lambda VPC attachment, reboot recovery, and key rotation are cloud acceptance
checks and remain unexecuted until an operator explicitly authorizes and runs
the deployment. Once deployed, a queued valid Operation exercises a real
TigerBeetle account request and transfer request, Completion queue publication,
and the completion Lambda's DynamoDB update.

## 8. Test query GET and intake POST

Call both Function URLs returned by SAM.

```sh
curl -i -L <IntakeFunctionUrl>
curl -i -L <QueryFunctionUrl>
```

An unauthenticated request is rejected by the handler:

```text
HTTP/2 401
WWW-Authenticate: Bearer
```

Issue a short-lived token using the private key that corresponds to the
deployed public key:

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
'"name":"TigerBeetle","body":{"message":"hello","count":2}}' \
  <IntakeFunctionUrl>
```

For a new ID, the handler persists `SUBMITTED`, attaches the body only to the queued
copy sent to SQS, and returns the bodyless persisted Operation output view. It
uses the invocation timestamp for `last_updated` and the 24-hour
expiry, the verified subject as tenant, and the stable hash:

```json
{
  "id": "00112233-4455-6677-8899-aabbccddeeff",
  "tenant": "example-user",
  "name": "TigerBeetle",
  "state": "SUBMITTED",
  "last_updated": 1700000000,
  "expires_at": 1700086400,
  "hash": "a155fdd43dc72aafd9d8914da4af79cfde80983ce96e1eec3bd634d36ce7e80f"
}
```

Read the Operation with the same token subject and UUID:

```sh
curl -L \
  -H "Authorization: Bearer $token" \
  <QueryFunctionUrl>/00112233-4455-6677-8899-aabbccddeeff
```

The query performs a strongly consistent read and returns the same compact
bodyless Operation JSON shown above with `Content-Type: application/json`.
`COMPLETED` Operations also include the complete tagged `result`; `SUBMITTED`
Operations do not. The path
must contain exactly one UUID segment. Query strings and GET bodies cannot
supply or alter the ID. Missing and cross-tenant Operations both return the
same static `404 Not Found` response. DynamoDB request or service failures
return static HTTP 503; malformed items and other unexpected failures remain
sanitized HTTP 500 responses. DynamoDB TTL remains asynchronous, so an item is
readable while it is still stored even after `expires_at`.

The SQS message is the exact compact full Operation JSON with `id`, `tenant`,
`name`, `body`, `state`, `last_updated`, `expires_at`, and `hash`, and no
trailing newline. The DynamoDB item and successful HTTP response omit `body`.
A matching retry whose stored item is still `SUBMITTED` sends the queued copy again.
Matching `COMPLETED` retries return the stored Operation without
another send.

An SQS failure leaves DynamoDB unchanged as `SUBMITTED` and returns only the static
`503 Service Unavailable` response. Intake performs no read or update after
the send. Other DynamoDB, malformed stored-item, and allocation failures remain
sanitized HTTP 500 responses. Reusing the ID for different work or from a
different verified subject returns the static `409 Conflict` response.

Delivery is at least once. The standard queue, acknowledgement loss, and
concurrent `SUBMITTED` retries can create duplicate messages. Consumers must use the
Operation ID and hash idempotently. Execution performs the replay-safe
TigerBeetle account and transfer sequence, aggregates terminal ID/result
entries, and acknowledges represented TigerBeetle queue records only after the
one Completion message is published. Invalid TigerBeetle queue records are
acknowledged; TigerBeetle uncertainty retries only the affected queue record, and
publication uncertainty retries every record represented by the aggregate.

Completion receives one aggregate message per invocation and applies its
entries sequentially. It conditionally updates only the item selected by the
canonical ID while its stored state is `SUBMITTED`. Duplicate or stale entries
become acknowledged conflicts without changing the stored result. A malformed
entry with a trustworthy canonical ID becomes a deterministic failure result;
one without such an ID is acknowledged without a write. Transient DynamoDB or
allocation uncertainty retries the one Completion message. On partial replay,
earlier successful writes conflict safely and later entries are still reached;
new writes use their actual write-time timestamp and TTL.

## 9. Download Lambda logs

Run the stack-aware log helper with an explicit Lambda selection:

```sh
./lambda_logs.sh intake
./lambda_logs.sh query
./lambda_logs.sh execution
./lambda_logs.sh completion
```

The stack name is fixed as `aws-lambda-zig-demo`. The helper resolves
`IntakeFunctionName`, `QueryFunctionName`, `ExecutionFunctionName`, or
`CompletionFunctionName` and writes a root-level file named after that
function, such as `intake-lambda.log`. It uses only the standard
`AWS_PROFILE` and `AWS_REGION` environment variables, defaulting to `dev` and
`ca-central-1`:

```sh
AWS_PROFILE=dev AWS_REGION=ca-central-1 ./lambda_logs.sh intake
```

The first run downloads all retained events from
`/aws/lambda/<function-name>`. Subsequent runs parse the final event header,
then query beginning with the following millisecond. Event headers contain a
UTC timestamp without a timezone suffix:

```text
2026-08-09T19:21:14.335 message
```

Embedded newlines remain as unprefixed continuation lines. The script stages
and validates the complete paginated AWS response before appending anything.
The local AWS identity needs `cloudformation:DescribeStacks` and
`logs:FilterLogEvents`; these are caller permissions and do not change the
Lambda execution role. Refresh an expired IAM Identity Center session with:

```sh
aws sso login --profile "${AWS_PROFILE:-dev}"
```

The derived root-level `.log` file is ignored by Git. Lambda logs can contain
private operational data, so do not publish or commit copied log files. Logs
created by earlier versions of the helper with `[event-id=...]` headers are
unsupported; remove or rename the existing log before running the updated
helper.

## 10. Create, read, update, and delete persisted Operations

`persistence.sh` is the supported local persistence command. It defaults to
profile `dev`, region `ca-central-1`, and stack `aws-lambda-zig-demo`. It
exports the selected profile's temporary credentials, resolves the
`OperationsTable` physical resource, and runs the requested operation. Override
the defaults with `PROFILE`, `REGION`, or `STACK_NAME`.

To permanently delete every Operation from the resolved table, run:

```sh
./persistence.sh delete-all
```

`delete-all` does not require the local Zig command implementation to be built.
It scans and counts the table, requires typing `delete`, deletes every item,
and verifies that the table is empty. It also requires `jq` locally.

Create an Operation from its unchanged input JSON view while supplying required
tenant metadata separately. A tenant must be valid UTF-8 between 1 and 64
bytes:

```sh
operation_json='{"id":"00112233-4455-6677-8899-aabbccddeeff",'\
'"name":"echo","body":{"message":"hello","count":2}}'
printf '%s\n' "$operation_json" \
  | ./persistence.sh create --tenant 'tenant-a'
```

Retry create with the original UUID, tenant, name, and body. When the UUID already
identifies an Operation with the same Operation hash, create returns the current
stored Operation, including its state, `last_updated`, `expires_at`, and completed
result when present. A different hash, including one derived under another
tenant, returns `dynamodb: operation conflict` with exit code `1`.

Read the persistent output view:

```sh
./persistence.sh read \
  --id 00112233-4455-6677-8899-aabbccddeeff
```

`SUBMITTED` requires empty standard input. `COMPLETED` requires the full tagged
result envelope on standard input. Both the input and compact envelope,
including `type` and `payload`, must be no larger than 4,096 bytes:

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

Each successful update refreshes both `last_updated` and `expires_at`, keeping
the expiry exactly 24 hours after the update timestamp.

Lifecycle ordering is monotonic: `SUBMITTED` may refresh or transition once to
`COMPLETED`. Completed Operations cannot reopen, change outcome, or refresh
with the same outcome. Exit code `1` means the item
was missing or a create/update conflict occurred. Both conflict paths emit
`dynamodb: operation conflict`. Exit code `2` means invocation, validation,
configuration, AWS, or internal failure.

The caller running `persistence.sh` needs `dynamodb:GetItem`,
`dynamodb:PutItem`, and `dynamodb:UpdateItem` permissions for the table, plus
`cloudformation:DescribeStackResource` to resolve the table resource. Its `delete-all`
command additionally needs `dynamodb:Scan` and `dynamodb:DeleteItem`. The
Lambda roles do not grant these permissions to the local AWS identity;
execution itself has no DynamoDB permissions.

### Troubleshoot persistence command configuration

`dynamodb: missing or invalid configuration` is emitted before Operation JSON
is parsed when the local command implementation cannot load its AWS settings.
`persistence.sh` supplies the resolved table name, temporary credentials, and
region. Confirm `PROFILE`, `REGION`, and `STACK_NAME`; profiles backed by IAM
Identity Center may need a refreshed session:

```sh
aws sso login --profile "${PROFILE:-dev}"
```

Changing the piped Operation JSON cannot fix this diagnostic. Credential-export
or stack-resource lookup failures are reported directly by `persistence.sh`;
DynamoDB failures after configuration loading instead report
`dynamodb: AWS request failed`.

### Troubleshoot Lambda initialization

The SAM template supplies the intake Lambda with `OPERATIONS_TABLE_NAME`, the
`TigerBeetleQueue` route mapping, and their scoped IAM policies together. A
missing or invalid DynamoDB table name makes the intake bootstrap exit during
Lambda INIT, before it requests an invocation. Check the deployed template and
function configuration; no HTTP response can be produced for an INIT failure.
The route mapping is request-specific: the exact operation name `Completion`
is reserved and returns HTTP 400 before route lookup. A missing, empty, or
oversized `<operation.name>Queue` value also returns HTTP 400 before DynamoDB
persistence or SQS send. Route names are exact and case-sensitive.

A syntactically valid but nonexistent table, or missing `PutItem` permission,
does not fail INIT because startup makes no DynamoDB request. The first valid,
authenticated POST returns a sanitized HTTP 500 in those cases; inspect Lambda
logs and the SAM-managed stack resources without recording live table names or
account-specific identifiers in this repository. Likewise, a syntactically
valid but nonexistent queue or missing `SendMessage` permission is discovered
only after POST persists the `SUBMITTED` Operation and attempts submission. It
returns a sanitized HTTP 503, leaving the row available for a matching retry.

The query Lambda requires only `OPERATIONS_TABLE_NAME`; it has no queue
configuration. A missing or invalid table-name setting exits during query INIT.
A nonexistent table, missing `GetItem` permission, or DynamoDB service failure
is discovered by the first authenticated `GET /<uuid>` and returns a sanitized
HTTP 503. A malformed stored item returns a sanitized HTTP 500.

The execution Lambda requires `COMPLETION_QUEUE_URL`,
`TIGERBEETLE_CLUSTER_ID`, and `TIGERBEETLE_ADDRESSES`. Missing or invalid
settings exit during execution INIT. A syntactically valid but nonexistent
Completion queue, missing `SendMessage` permission, or SQS service failure is
discovered when execution publishes its aggregate. Execution logs that
failure and requests retries for all TigerBeetle queue records represented by the
unsent message.

The completion Lambda requires only `OPERATIONS_TABLE_NAME`. A missing or
invalid table-name setting exits during completion INIT. A nonexistent table,
missing `UpdateItem` permission, or DynamoDB service failure is discovered
while processing a Completion entry. Completion logs the failure, stops that
aggregate, and requests a retry for the invocation's single SQS message.

## 11. Send, receive, and check queued Operations

`queue.sh` is the supported local queue command. It defaults to profile `dev`,
region `ca-central-1`, and stack `aws-lambda-zig-demo`. It exports the selected
profile's temporary credentials and requires a queue SAM logical resource ID as
its first argument. It resolves that resource's physical queue URL, exports the
URL under the same logical ID used by the CLI, and runs the requested operation.
Use `TigerBeetleQueue` or `CompletionQueue` for this template. Override the
environment defaults with `PROFILE`, `REGION`, or `STACK_NAME`.

Send an Operation while supplying required tenant metadata separately:

```sh
operation_json='{"id":"00112233-4455-6677-8899-aabbccddeeff",'\
'"name":"echo","body":{"message":"hello","count":2}}'
printf '%s\n' "$operation_json" \
  | ./queue.sh TigerBeetleQueue send --tenant 'tenant-a'
```

`send` validates the input with `src/operation.zig` and derives `last_updated`
from the current time. Omitted state defaults to `SUBMITTED`, while explicit state
must be `SUBMITTED`. It validates and serializes the resulting full Operation exactly
once. The SQS message contains the compact canonical JSON with `id`, `tenant`,
`name`, `body`, `state`, `last_updated`, `expires_at`, and `hash`, with no
trailing newline. After `SendMessage` succeeds, stdout receives those exact
bytes followed by a newline. State remains excluded from the Operation hash.
The command does not read or update DynamoDB. `send` always produces an
Operation message and must not target `CompletionQueue`, whose consumer expects
a Completion batch.

Request every queue attribute and print one JSON object. Unknown future keys
are retained:

```sh
./queue.sh TigerBeetleQueue check
```

Consume queued messages until interrupted:

```sh
./queue.sh TigerBeetleQueue receive
```

On a deployed stack, this local consumer competes with the selected queue's
enabled Lambda event source mapping. `TigerBeetleQueue` feeds execution and
`CompletionQueue` feeds completion. Use `receive` only when intentionally
taking messages away from that handler.

This is a destructive long-running consumer. It requests one message at a time
with `WaitTimeSeconds` set to `20` and silently polls again when SQS returns no
messages. For each message, it writes the body byte-for-byte, appends exactly
one newline, flushes stdout, and only then calls `DeleteMessage` with the
receipt handle. Bodies need not be JSON or canonical Operations and may contain
embedded newlines.

The consumer keeps the default SIGINT action. Ctrl-C terminates it promptly and
the shell reports status `130`. Interruption can occur after a message is
flushed but before deletion completes, so an already-printed message may become
visible and be printed again. A response missing the body or receipt handle is
rejected without deletion. AWS, malformed-response, output, deletion, and
internal failures stop the loop with exit code `2` and sanitized diagnostics.
Invocation, validation, and configuration failures also exit with code `2`.

The caller needs these queue-scoped permissions for the commands it uses:

- `sqs:SendMessage` for `send`
- `sqs:ReceiveMessage` and `sqs:DeleteMessage` for `receive`
- `sqs:GetQueueAttributes` for `check`

`queue.sh` also needs `cloudformation:DescribeStackResource`. These local caller
permissions are independent of the Lambda roles. Intake remains send-only for SQS, execution has
TigerBeetle queue-scoped polling and Completion queue-scoped send permissions,
completion has Completion queue-scoped polling permissions, and query has no
SQS permissions.

If `sqs: missing or invalid configuration` is emitted, the local command
implementation could not load its AWS settings. `queue.sh` supplies the
resolved queue URL under the requested logical resource ID, temporary
credentials, and region, and validates that the URL is non-empty. Confirm the
queue name, `PROFILE`, `REGION`, and `STACK_NAME`. Configuration is checked
before Operation input is parsed; AWS failures after configuration loading
instead report `sqs: AWS request failed`.

## 12. Update the deployed Lambda code

After changing Zig source code, rebuild and repackage:

```sh
zig build --release -Darch=arm
zip -qj intake-lambda.zip zig-out/bin/intake/bootstrap
zip -qj query-lambda.zip zig-out/bin/query/bootstrap
zip -qj execution-lambda.zip zig-out/bin/execution/bootstrap
zip -qj completion-lambda.zip zig-out/bin/completion/bootstrap
```

Then redeploy the stack:

```sh
sam deploy --profile dev --region ca-central-1
```

SAM uploads all four packages and updates their CloudFormation-managed Lambda functions.

## 13. Delete the SAM stack

If the WireGuard gateway is enabled or retained cleanup is in progress, first
run the guarded disable flow:

```sh
./wireguard-gateway-setup.sh --disable
```

This detaches execution, waits for every published version and Lambda-created
ENI to release the retained security group, then removes the stack-owned EIGW,
IPv6 route, security group, and ENI-management IAM before clearing saved
gateway inputs. A timed-out run leaves those resources retained; rerun the
same command to resume. Do not replace this sequence with direct deletion of
an enabled stack.

Then remove all four SAM-managed functions and roles, the operations table,
both queues, Function URLs, permissions, and any remaining stack resources:

```sh
sam delete \
  --stack-name aws-lambda-zig-demo \
  --profile dev \
  --region ca-central-1
```

This deletes only resources owned by the SAM stack. The operations table has
`DeletionPolicy: Delete` and `UpdateReplacePolicy: Delete`, so deleting the
stack or replacing the table permanently deletes its data. Point-in-time
recovery is disabled; this demo configuration provides no recovery capability.
Both queues use the same deletion policies, so deleting or replacing either
one permanently deletes its queued messages. Neither has a dead-letter queue
or another retention/replay resource.

The guarded disable terminates the EC2 gateway, releases its Elastic IP,
removes both stack-owned routes and security groups, and deletes the
stack-owned EIGW, launch template, IAM role, and instance profile. It never
deletes the external VPC/subnet IPv6 associations, VPC, subnets, route table,
network ACL, or DNS configuration. The gateway private/public SSM parameters
are also intentionally external and are not deleted. The workstation keys and
TigerBeetle process and data remain workstation-owned and untouched.

After confirming that neither the gateway nor its keys will be reused, the
operator can explicitly delete both external parameters and securely remove the
local key files according to workstation policy:

```sh
aws ssm delete-parameters \
  --names \
    '/<stack-name>/wireguard/gateway-private-key' \
    '/<stack-name>/wireguard/gateway-public-key' \
  --profile dev \
  --region ca-central-1
rm -f '<private-key-directory>/gateway.private' \
  '<private-key-directory>/gateway.public' \
  '<private-key-directory>/workstation.private' \
  '<private-key-directory>/workstation.public'
rmdir '<private-key-directory>'
```

## Security note

This demo intentionally creates two publicly reachable Lambda Function URLs,
and both Function URL handlers require a valid PASETO bearer token. The
execution Lambda has no Function URL and is invoked from SQS. For production,
consider combining application authentication with stricter infrastructure
authorization, narrower IAM policies, or an API Gateway/CloudFront layer. The
completion Lambda also has no Function URL and is invoked from its SQS mapping.

When the gateway is enabled, IPv4 UDP/51820 is deliberately open from
`0.0.0.0/0` because the NAT public address of the development workstation is
not predictable. WireGuard authenticates the configured peer and remains
silent to unauthenticated handshakes, but removing a security-group source
filter increases exposure to UDP scanning and floods and to future kernel or
WireGuard vulnerabilities. The gateway opens no IPv6 ingress, SSH, public
TigerBeetle TCP port, or other public ingress. Keep the gateway disabled when
it is not needed and account for its EC2 and Elastic IP cost while enabled.

Execution's IPv6 TCP/443 egress to `::/0` can reach public IPv6 HTTPS
destinations; it is not the private-only, endpoint-policy boundary an SQS
interface endpoint would provide. Queue-scoped IAM limits the function's SQS
action to `SendMessage` on `CompletionQueue`. The EIGW adds no fixed hourly or
processing charge, but ordinary data-transfer, SQS, Lambda, EC2, and Elastic
IP charges still apply.

No private WireGuard key is a CloudFormation parameter, template value, tag,
log, or stack output. The instance role can read only the configured external
SSM parameter and intentionally has no `kms:Decrypt` permission because the
workflow uses the AWS-managed `aws/ssm` key.
