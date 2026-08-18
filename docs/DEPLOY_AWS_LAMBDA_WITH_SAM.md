# Deploy the intake, query, and execution Lambdas with SAM

This guide documents how to deploy the three Zig Lambda packages in this repository
using AWS SAM and `template.yaml`.

SAM deploys all three Lambda functions as one CloudFormation-managed stack. It creates
their execution roles, public Function URLs for intake and query, the DynamoDB
operations table shared by all three Lambdas, and the SQS operations queue sent
by intake and consumed by execution. It can also provision an optional EC2
WireGuard gateway that routes execution-Lambda traffic to TigerBeetle on a
development workstation. The gateway is disabled by default; enabling it adds
EC2 and Elastic IP charges.

## Assumptions

- AWS CLI v2 and SAM CLI are installed.
- `zip`, `unzip`, and `file` are installed for package validation.
- `jq` is installed when using `lambda_logs.sh`.
- You have an IAM Identity Center / SSO profile named `dev`.
- The deployment region is `ca-central-1`.
- `template.yaml` exists in this repository.
- `intake-lambda.zip`, `query-lambda.zip`, and `execution-lambda.zip` each contain one Linux ARM64
  executable named `bootstrap`.
- Both Lambda Function URLs are intentionally public for authenticated demo testing.
- `LAMBDA_PRINCIPAL` defaults to `'*'` unless you override the
  `LambdaPrincipal` template parameter.
- `PASETO_PUBLIC_KEY` contains the padded Base64 Ed25519 public key generated
  by `zig-out/bin/paseto keygen`. The corresponding private key remains only
  in the token-signing environment.

Enabling the WireGuard gateway additionally requires:

- An existing VPC with distinct public gateway and Lambda subnets.
- An internet gateway and an active `0.0.0.0/0` route from the gateway public
  subnet to that internet gateway.
- The effective Lambda-subnet route table, with no route already claiming
  `10.200.0.0/24` unless that route is owned by the existing deployment of this
  stack.
- DynamoDB reachability from the Lambda subnet through NAT or a DynamoDB
  gateway endpoint. A public-subnet internet-gateway route alone does not give
  a VPC-attached Lambda internet access.
- For the recommended isolated topology, an unused IPv4 `/28` in the VPC and
  permission to create and tag a subnet, route table, route-table association,
  and DynamoDB gateway endpoint.
- Local WireGuard tools (`wg` and the platform-specific interface helper) on a
  workstation that can initiate outbound UDP/51820 to the gateway Elastic IP.
- `wg` must be on `PATH` for `deploy.sh` to generate the default gateway pair
  when both default SSM parameters are absent.
- Permission for the deployment identity to create the additional EC2
  instance, Elastic IP, security groups, route, IAM role and instance profile,
  and launch template, as well as the execution-Lambda network interface.
- `ssm:GetParameter` and `ssm:PutParameter` on
  `/applications/${STACK_NAME}/wireguard/gateway-private-key` and
  `/applications/${STACK_NAME}/wireguard/gateway-public-key`, plus
  `ssm:DeleteParameter` on
  the private path for rollback if paired creation fails.

## 1. Refresh AWS SSO credentials

Authenticate the local AWS CLI profile with IAM Identity Center.

```sh
aws sso login --profile dev
```

Verify that the profile resolves to an assumed SSO role, not the root user.

```sh
aws sts get-caller-identity --profile dev
```

Expected ARN shape:

```text
arn:aws:sts::<account-id>:assumed-role/AWSReservedSSO_.../<user>
```

When using `deploy.sh`, this refresh is automatic when needed. Before building,
the helper clears inherited static credential variables, selects the configured
refreshable profile, and verifies it with STS. Valid cached credentials are
reused without opening a browser. If verification fails for a directly
configured SSO profile, the helper runs `aws sso login --profile <profile>` once
and retries. Direct `sam` and `aws` commands in this guide still require an
active session.

## 2. Build and package the Zig Lambdas

Build the stripped, single-threaded, ReleaseSafe Lambda executables for AWS
Lambda ARM64.

```sh
zig build --release -Darch=arm
```

The build also installs the host-native `paseto` utility and the local command
implementations invoked by `persistence.sh` and `queue.sh`. Each Lambda zip
contains only its handler's root-level `bootstrap`.

Verify that all three built artifacts are Linux ARM64 executables.

```sh
file zig-out/bin/intake/bootstrap \
  zig-out/bin/query/bootstrap \
  zig-out/bin/execution/bootstrap
```

Expected executable shape:

```text
ELF 64-bit LSB executable, ARM aarch64, statically linked, stripped
```

Create or refresh all three packages.

```sh
zip -qj intake-lambda.zip zig-out/bin/intake/bootstrap
zip -qj query-lambda.zip zig-out/bin/query/bootstrap
zip -qj execution-lambda.zip zig-out/bin/execution/bootstrap
```

SAM reads the packages from the matching `CodeUri` properties in `template.yaml`.

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
- `OperationsQueue`: `AWS::SQS::Queue`
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
- `ExecutionFunctionOperationsQueueMapping`: `AWS::Lambda::EventSourceMapping`

When `EnableWireGuardGateway=true`, the template also creates:

- `ExecutionLambdaSecurityGroup`: `AWS::EC2::SecurityGroup`
- `WireGuardGatewaySecurityGroup`: `AWS::EC2::SecurityGroup`
- `WireGuardGatewayRole`: `AWS::IAM::Role`
- `WireGuardGatewayInstanceProfile`: `AWS::IAM::InstanceProfile`
- `WireGuardGatewayLaunchTemplate`: `AWS::EC2::LaunchTemplate`
- `WireGuardGatewayInstance`: `AWS::EC2::Instance`
- `WireGuardGatewayElasticIp`: `AWS::EC2::EIP`
- `WireGuardGatewayElasticIpAssociation`: `AWS::EC2::EIPAssociation`
- `WireGuardLambdaRoute`: `AWS::EC2::Route`

Every gateway resource and output is conditional. The internal
`RetainExecutionVpcCleanupResources` parameter temporarily keeps only
`ExecutionLambdaSecurityGroup` and the execution role's EC2 network-interface
policy during a `deploy.sh` disablement transition. In steady disabled state,
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

The intake and query functions share the runtime, architecture, memory, timeout, basic logging
policy, PASETO configuration, and operations-table environment value:

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

The intake function additionally receives `OPERATIONS_QUEUE_URL` and the
following table-write and queue-send permissions:

```yaml
Policies:
  - Version: "2012-10-17"
    Statement:
      - Effect: Allow
        Action:
          - dynamodb:GetItem
          - dynamodb:PutItem
          - dynamodb:UpdateItem
        Resource: !GetAtt OperationsTable.Arn
      - Effect: Allow
        Action:
          - sqs:SendMessage
        Resource: !GetAtt OperationsQueue.Arn
Environment:
  Variables:
    OPERATIONS_QUEUE_URL: !Ref OperationsQueue
```

The query function receives its own inline policy containing only
`dynamodb:GetItem` for this stack's operations table. It does not receive
`OPERATIONS_QUEUE_URL` or any SQS permission.

The execution function uses the same `provided.al2023` ARM64 runtime, 128 MB
memory, 3-second timeout, and basic logging policy. It has no Function URL or
authentication configuration. Its explicit role grants queue-scoped polling
permissions for `OperationsQueue` and only `dynamodb:UpdateItem` on this
stack's operations table; execution does not receive `dynamodb:GetItem`. When
the gateway is enabled, the role also receives the six EC2 network-interface
actions required by a VPC-attached Lambda. The function is attached to the
single `LambdaSubnetId` with a stack-managed security group that permits only
TCP/3000 to `10.200.0.2/32` and TCP/443 for DynamoDB access through the
subnet's NAT or VPC endpoint path. The current handler has no TigerBeetle
client and does not consume a TigerBeetle environment variable.

The explicit event source mapping is enabled with `BatchSize: 10`,
`MaximumBatchingWindowInSeconds: 0`, and `ReportBatchItemFailures`. Lambda polls
the queue and invokes execution with SQS events. For each record, the handler
retains the debug log containing `message_id` and `body`, parses and validates
the complete Operation output, and attempts completion only for a `SUBMITTED`
Operation with a body and no result. It logs success, failure, or skipped-invalid
without logging DynamoDB item contents.

Completion is one conditional `UpdateItem`. The condition checks canonical
`id`, stored `tenant` and `name`, stored `state = SUBMITTED`, the queued hash,
and an absent stored `result`; timestamps are intentionally not conditions.
Each record samples the real-time clock immediately before its own attempt. A
successful update sets `state = SUCCEEDED`, stores the compact DynamoDB string
`{"success":true}` as `result`, sets `last_updated` to that sample, and sets
`expires_at` to exactly 86,400 seconds later. It requests neither success
attributes nor the conflicting item on conditional failure.

Processing is best effort: valid successes, invalid messages, conflicts, and
AWS failures all advance to the next record. Every valid top-level SQS event
returns exactly `{"batchItemFailures":[]}`, so those record outcomes receive no
SQS retry. A malformed top-level event or a failure that prevents response
encoding can still fail and retry the invocation.

`OPERATIONS_TABLE_NAME` contains the CloudFormation-generated physical table
name. Before each of the three invocation loops starts, its bootstrap loads an
AWS configuration and initializes the Operation persistence module with the
validated table name. The query and execution bootstraps reuse that
configuration, persistence client, HTTP pool, and adapter across warm
invocations. The intake bootstrap also validates `OPERATIONS_QUEUE_URL`,
initializes the queue module, and reuses both clients with its shared AWS
configuration. Missing or invalid configuration prevents the affected Lambda
from handling invocations. The local persistence and queue command
implementations use the same modules and contracts.

Startup validation makes no DynamoDB or SQS request. A missing table or
insufficient DynamoDB permission is discovered by a POST persistence request
and returned by intake as a sanitized HTTP 500. A query DynamoDB request or
service failure returns a sanitized HTTP 503, while a malformed stored item or
unexpected failure returns HTTP 500. A missing queue, insufficient
`SendMessage` permission, or another SQS send failure is returned as a
sanitized HTTP 503. Execution discovers a missing table, insufficient
`UpdateItem` permission, or another DynamoDB service failure while processing a
record, logs the failure, and acknowledges that record without retrying it.

The second intake inline-policy statement grants that function only `SendMessage`
access to this stack's operations queue. The handler sends full compact
`SUBMITTED` Operation JSON, but has no receive, delete, purge, or
queue-management permissions. Execution receives its separate queue-scoped
poller policy and table-scoped `UpdateItem`; neither role grants
queue-management access. The `queue.sh` command uses the local caller's AWS
identity and does not expand either Lambda role. Its `receive` command competes
with the enabled execution event source mapping for messages.

`OperationsQueue` is a standard queue with a CloudFormation-generated name.
The template does not configure FIFO behavior, a dead-letter queue, or custom
queue attributes. `DeletionPolicy: Delete` and `UpdateReplacePolicy: Delete`
mean deleting the stack or replacing the queue permanently deletes queued
messages.

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
| `state` | `S` | One of `NEW`, `SUBMITTED`, `RUNNING`, `SUCCEEDED`, or `FAILED`. |
| `last_updated` | `N` | Unix epoch seconds. |
| `expires_at` | `N` | Exactly 86,400 seconds after `last_updated`; DynamoDB TTL attribute. |
| `hash` | `S` | 64-character lowercase BLAKE3-256 hexadecimal value. |
| `result` | `S` | Terminal states only; compact `std.json.Value` JSON; at most 4,096 UTF-8 bytes. |

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

Never persist `body`. The 4,096-byte `result` bound is an application-enforced
constraint because DynamoDB and CloudFormation cannot enforce a per-attribute
size limit. Terminal result input and its compact serialization must both fit
the bound. The adapter serializes caller-provided result Values into fixed
request buffers and validates them immediately before persistence; execution
instead uses its fixed compact success result. On reads, the adapter
parses the stored string once into the caller's arena and requires the string
to equal the compact reserialization, rejecting malformed, duplicate-key,
explicit-null, oversized, or noncanonical items. Creates use
`attribute_not_exists(id)` and request `ALL_OLD` when that condition fails. A
failed create condition succeeds as an idempotent retry only when the returned
item has the submitted tenant and Operation hash, regardless of its current
state; otherwise it is an Operation conflict. Reads are strongly consistent.
Read-modify-write updates condition on the previously read snapshot, including
the old `expires_at`, preserve `id`, `tenant`, `name`, and `hash`, and return
and validate `ALL_NEW`. New items and every successful update set `expires_at` to
`last_updated + 86,400`.
Result-size validation remains in the application rather than a DynamoDB
condition expression.

Tenant is server-owned metadata, part of idempotency identity, and the query
authorization boundary. UUIDs and the `id` partition key remain globally
scoped, so reusing a UUID under another tenant changes the hash and returns an
Operation conflict. Query performs the globally keyed `GetItem`, then returns
the Operation only when its stored tenant equals the verified PASETO subject.
Missing and cross-tenant items are indistinguishable `404 Not Found` responses.
No tenant-scoped key or secondary index is introduced.

DynamoDB TTL deletion is asynchronous. An item becomes eligible for deletion
at `expires_at` but may remain readable until DynamoDB removes it. Legacy rows
without tenant are rejected by the strict item decoder and must be deleted and
recreated before deploying this version; there is no fallback decoder or
application migration path. CloudFormation configures TTL, so the Lambda role
does not need an additional DynamoDB control-plane permission.

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
```

They are controlled by `IntakeFunctionName`, `QueryFunctionName`, and
`ExecutionFunctionName`. Before
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
`QueryFunctionName=query-lambda` and `ExecutionFunctionName=execution-lambda` if parameter
overrides are saved there. The
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
| `RetainExecutionVpcCleanupResources` | Internal `deploy.sh` lifecycle switch; retains only the execution security group and ENI permissions between detach and cleanup phases. Defaults to `false`. |
| `VpcId` | Existing VPC containing both supplied subnets. |
| `GatewayPublicSubnetId` | Existing public subnet for the EC2 gateway. |
| `LambdaSubnetId` | Distinct existing subnet for the execution Lambda. |
| `LambdaRouteTableId` | Effective route table for `LambdaSubnetId`. |
| `LambdaSubnetCidr` | Primary IPv4 CIDR of `LambdaSubnetId`; it must not overlap `10.200.0.0/24`. |
| `WireGuardPrivateKeyParameterName` | Absolute path of the external gateway-private-key SSM `SecureString`. |
| `WireGuardPrivateKeyParameterVersion` | Exact positive version to retrieve; defaults to `1`. |
| `WireGuardGatewayPublicKey` | Padded Base64 public key matching the stored gateway private key. |
| `WireGuardWorkstationPublicKey` | Padded Base64 public key matching the workstation private key. |
| `WireGuardAmiId` | Public SSM parameter resolving to an ARM64 Amazon Linux 2023 AMI. |
| `WireGuardInstanceType` | ARM64 gateway instance type; defaults to `t4g.nano`. |

### Provision a dedicated Lambda subnet and DynamoDB endpoint

The recommended development topology keeps the existing internet-routed subnet
for the EC2 gateway and creates a dedicated Lambda subnet in the same
availability zone. The Lambda subnet has no automatic public IPv4 assignment
and an explicitly associated route table with only the VPC-local route. A
DynamoDB gateway endpoint is associated only with that route table. Omitting an
endpoint policy intentionally selects the AWS default full-access endpoint
policy; the Lambda role's table-scoped IAM policy remains the authorization
boundary.

Recheck the live VPC, availability zone, CIDR availability, and gateway default
route immediately before creation. The following example uses the selected
`172.31.48.0/28` default but keeps live identifiers out of the repository:

```sh
gateway_subnet_id='<existing-public-gateway-subnet-id>'
lambda_subnet_cidr='172.31.48.0/28'
vpc_id="$(aws ec2 describe-subnets \
  --subnet-ids "$gateway_subnet_id" \
  --query 'Subnets[0].VpcId' \
  --output text \
  --profile dev \
  --region ca-central-1)"
availability_zone="$(aws ec2 describe-subnets \
  --subnet-ids "$gateway_subnet_id" \
  --query 'Subnets[0].AvailabilityZone' \
  --output text \
  --profile dev \
  --region ca-central-1)"
gateway_route_table_id="$(aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=$gateway_subnet_id" \
  --query 'RouteTables[0].RouteTableId' \
  --output text \
  --profile dev \
  --region ca-central-1)"
if [ "$gateway_route_table_id" = None ]; then
  gateway_route_table_id="$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$vpc_id" \
      'Name=association.main,Values=true' \
    --query 'RouteTables[0].RouteTableId' \
    --output text \
    --profile dev \
    --region ca-central-1)"
fi
aws ec2 describe-route-tables \
  --route-table-ids "$gateway_route_table_id" \
  --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0' && State=='active'].GatewayId" \
  --profile dev \
  --region ca-central-1
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$vpc_id" \
  --query 'Subnets[].[SubnetId,CidrBlock,AvailabilityZone]' \
  --output table \
  --profile dev \
  --region ca-central-1
```

Stop if the selected CIDR is already allocated, the public subnet is not in
`ca-central-1a`, or its effective route table does not have an active internet
gateway default route. Once those checks pass, create and tag the manual
resources:

```sh
lambda_subnet_id="$(aws ec2 create-subnet \
  --vpc-id "$vpc_id" \
  --availability-zone "$availability_zone" \
  --cidr-block "$lambda_subnet_cidr" \
  --tag-specifications \
    'ResourceType=subnet,Tags=[{Key=Project,Value=aws-lambda-zig-demo},{Key=Purpose,Value=wireguard-execution-lambda},{Key=ManagedBy,Value=manual},{Key=Name,Value=aws-lambda-zig-demo-wireguard-lambda}]' \
  --query Subnet.SubnetId \
  --output text \
  --profile dev \
  --region ca-central-1)"
aws ec2 modify-subnet-attribute \
  --subnet-id "$lambda_subnet_id" \
  --no-map-public-ip-on-launch \
  --profile dev \
  --region ca-central-1

lambda_route_table_id="$(aws ec2 create-route-table \
  --vpc-id "$vpc_id" \
  --tag-specifications \
    'ResourceType=route-table,Tags=[{Key=Project,Value=aws-lambda-zig-demo},{Key=Purpose,Value=wireguard-execution-lambda},{Key=ManagedBy,Value=manual},{Key=Name,Value=aws-lambda-zig-demo-wireguard-lambda-route-table}]' \
  --query RouteTable.RouteTableId \
  --output text \
  --profile dev \
  --region ca-central-1)"
lambda_route_table_association_id="$(aws ec2 associate-route-table \
  --subnet-id "$lambda_subnet_id" \
  --route-table-id "$lambda_route_table_id" \
  --query AssociationId \
  --output text \
  --profile dev \
  --region ca-central-1)"

dynamodb_endpoint_id="$(aws ec2 create-vpc-endpoint \
  --vpc-id "$vpc_id" \
  --vpc-endpoint-type Gateway \
  --service-name com.amazonaws.ca-central-1.dynamodb \
  --route-table-ids "$lambda_route_table_id" \
  --tag-specifications \
    'ResourceType=vpc-endpoint,Tags=[{Key=Project,Value=aws-lambda-zig-demo},{Key=Purpose,Value=wireguard-execution-lambda},{Key=ManagedBy,Value=manual},{Key=Name,Value=aws-lambda-zig-demo-wireguard-dynamodb}]' \
  --query VpcEndpoint.VpcEndpointId \
  --output text \
  --profile dev \
  --region ca-central-1)"
for endpoint_attempt in $(seq 1 30); do
  endpoint_state="$(aws ec2 describe-vpc-endpoints \
    --vpc-endpoint-ids "$dynamodb_endpoint_id" \
    --query 'VpcEndpoints[0].State' \
    --output text \
    --profile dev \
    --region ca-central-1)"
  [ "$endpoint_state" != available ] || break
  [ "$endpoint_state" = pending ] || exit 1
  sleep 2
done
[ "$endpoint_state" = available ]
```

Record the four returned identifiers only in the operator session. If a step
fails before deployment starts, delete only resources created in that attempt,
in reverse order: endpoint, route-table association, route table, then subnet.
Once deployment starts, retain the topology for diagnosis or retry.

These resources are operator-owned outside SAM. Disabling or deleting the
stack removes the stack-owned `10.200.0.0/24` route and VPC attachment but does
not remove this subnet, route table, association, or endpoint. For intentional
final cleanup, first disable or delete the stack, then run:

```sh
aws ec2 delete-vpc-endpoints \
  --vpc-endpoint-ids "$dynamodb_endpoint_id" \
  --profile dev \
  --region ca-central-1
for endpoint_attempt in $(seq 1 30); do
  endpoint_state="$(aws ec2 describe-vpc-endpoints \
    --vpc-endpoint-ids "$dynamodb_endpoint_id" \
    --query 'VpcEndpoints[0].State' \
    --output text \
    --profile dev \
    --region ca-central-1 2>/dev/null || true)"
  case "$endpoint_state" in deleted | None | '') break ;; esac
  sleep 2
done
aws ec2 disassociate-route-table \
  --association-id "$lambda_route_table_association_id" \
  --profile dev \
  --region ca-central-1
aws ec2 delete-route-table \
  --route-table-id "$lambda_route_table_id" \
  --profile dev \
  --region ca-central-1
aws ec2 delete-subnet \
  --subnet-id "$lambda_subnet_id" \
  --profile dev \
  --region ca-central-1
```

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
shell history, an environment passed to `deploy.sh`, stack parameters or
outputs, documentation, or the repository.

### Default gateway keypair managed by `deploy.sh`

For stack `aws-lambda-zig-demo`, the helper uses these external parameters:

| Value | Default parameter | Type |
| --- | --- | --- |
| Gateway private key | `/applications/aws-lambda-zig-demo/wireguard/gateway-private-key` | `SecureString`, encrypted with `alias/aws/ssm` |
| Gateway public key | `/applications/aws-lambda-zig-demo/wireguard/gateway-public-key` | `String` |

The paths follow `/applications/${STACK_NAME}/wireguard/...` for another stack
name. Parameter Store reserves names beginning with `aws` or `ssm`, ignoring
case, so `deploy.sh` and `template.yaml` reject custom paths with either prefix.
If both
exist, `deploy.sh` validates their types and the public-key format and uses the
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
the missing matching value, or delete the lone value and let `deploy.sh`
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
    LambdaPrincipal='*' \
    PasetoPublicKey="$PASETO_PUBLIC_KEY"
```

The preceding commands leave a new or already-disabled stack disabled. Do not
use a single direct SAM update to transition an enabled stack to disabled: it
does not perform the required Lambda VPC-detach wait and could remove ENI
permissions too early. Use `deploy.sh` for disablement, or manually reproduce
its two phases with `RetainExecutionVpcCleanupResources=true`, a verified wait
for zero VPC-configured Lambda versions and zero ENIs on the retained security
group, then `RetainExecutionVpcCleanupResources=false`. Direct SAM commands also
do not perform `deploy.sh` subnet discovery, SSM generation, or enabled-stack
reuse.
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

`deploy.sh` resolves each gateway value from CLI, then environment, then a
previously enabled stack, then SSM/default discovery. Gateway enablement itself
is always explicit. Assuming the PASETO variables above remain set, the minimal
first enablement needs only the workstation public key when networking has one
valid pair:

```sh
WIREGUARD_WORKSTATION_PUBLIC_KEY="$wireguard_workstation_public_key" \
./deploy.sh --enable-wireguard-gateway
```

The helper considers available IPv4 subnets. A gateway candidate has an active
internet-gateway default route. A Lambda candidate is distinct, in the same VPC
and availability zone, and reaches DynamoDB through an active NAT default route
or a DynamoDB gateway endpoint on its effective route table. Neither subnet may
overlap `10.200.0.0/24`. An explicit VPC or one subnet narrows the search. Each
constrained subnet is inspected once. If no pair remains, the helper prints
rejection counts for gateway routing, Lambda DynamoDB access, CIDR overlap,
subnet identity, VPC, and availability zone. AWS API or malformed-response
failures are reported separately instead of being counted as topology
rejections. If multiple pairs remain, the helper prints every pair and a
specific ambiguity error. Use the reported IDs to constrain that selection:

```sh
./deploy.sh \
  --enable-wireguard-gateway \
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
./deploy.sh \
  --enable-wireguard-gateway \
  --wireguard-private-key-parameter-name '<custom-private-parameter-path>' \
  --wireguard-private-key-parameter-version '<matching-version>' \
  --wireguard-gateway-public-key "$wireguard_gateway_public_key" \
  --wireguard-workstation-public-key "$wireguard_workstation_public_key"
```

A subsequent deployment keeps the gateway enabled only when it again receives
`--enable-wireguard-gateway` or `ENABLE_WIREGUARD_GATEWAY=1`. When the existing
stack is enabled, unspecified subnet, workstation-key, gateway-key, and
instance-type values are reused, including the pinned private-key version. A
deployment without explicit enablement sends `EnableWireGuardGateway=false`,
but does so in two phases. The detach phase sets
`RetainExecutionVpcCleanupResources=true`, removing the gateway, Elastic IP,
route, related resources, and execution VPC attachment while retaining the
execution security group and ENI-deletion permission. The helper then polls for
up to 20 minutes until the current function and every published version have an
empty VPC configuration and no ENI references the retained security group. The
cleanup phase sets `RetainExecutionVpcCleanupResources=false` only after those
checks pass. A timeout stops before cleanup; a later `deploy.sh` run recognizes
the retained phase and resumes the same guarded wait. Both external SSM
parameters remain operator-owned. After teardown, a later enablement recovers
the current default SSM pair but does not reuse gateway inputs from the disabled
stack.

Before building, `deploy.sh` validates local gateway syntax. A non-dry-run
deployment discovers and verifies the topology, including the DynamoDB path,
checks for a conflicting `10.200.0.0/24` route, and reads SSM parameter metadata
without decrypting the private value. `--dry-run` performs no AWS discovery or
key creation and reports that gateway preflight is deferred.

`deploy.sh` reads the required `PASETO_PUBLIC_KEY` from the host environment and
passes it as the `PasetoPublicKey` SAM parameter. When post-deploy checks are
enabled, it also requires the corresponding `PASETO_PRIVATE_KEY` to issue a
short-lived test token. It verifies unauthenticated HTTP 401 for both URLs,
an authenticated query of a valid UUID with a unique test subject returns a
tenant-safe 404, authenticated wrong methods return 405, and an authenticated
bodyless intake POST returns 400. The private key and test token are not printed
or passed to the Lambda environment. Use
`PASETO_PUBLIC_KEY='<public-key-from-keygen>' ./deploy.sh --dry-run` to run the
local checks, rebuild all three Lambda zip archives, and validate `template.yaml` without
deploying to AWS.

For non-dry-run deployments, the helper clears inherited static AWS credential
variables, exports `AWS_PROFILE` for the selected refreshable profile, passes
the same profile explicitly to SAM, and verifies it before starting local work.
SAM and post-deploy AWS commands can therefore refresh an `sso_session` instead
of inheriting a finite credential snapshot. When STS verification fails for a
profile configured with `sso_session` or the legacy `sso_start_url`, the helper
runs one interactive `aws sso login` and verifies again. Non-SSO profile
failures stop without attempting SSO login. Dry runs make no AWS authentication
calls, and the helper does not print or write resolved credentials.

Before formatting, building, packaging, or validating, the helper queries the
existing stack and stops when its status ends in `_IN_PROGRESS`. If a local SAM
waiter or post-deployment check fails after deployment begins, it queries
CloudFormation with the refreshable profile and distinguishes an update that is
still running, a terminal CloudFormation failure, and remote success followed
by a local failure. Do not rerun deployment against an active stack. Wait for
CloudFormation to reach a terminal state before retrying; after a bounded VPC
cleanup timeout, a later `deploy.sh` run resumes the retained cleanup phase.

After a successful deployment, `deploy.sh` resolves the
`OperationsTable` physical resource, waits for the table to exist, and prints a
concise table summary. It fails unless the table is active, uses on-demand
billing, has only the `id` string partition key, and has no local or global
secondary indexes. It then resolves the `OperationsQueue` physical resource and calls
`GetQueueAttributes` to print a concise SQS summary. This probe verifies that
the deployed queue can be queried but does not enforce SQS attribute values.
For an enabled deployment, it also prints the seven conditional, non-secret
gateway outputs. The intake and query Function URL checks then run.

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

Read all conditional gateway outputs without recording their live values in
the repository:

```sh
aws cloudformation describe-stacks \
  --stack-name aws-lambda-zig-demo \
  --query "Stacks[0].Outputs[?OutputKey=='WireGuardGatewayInstanceId' || OutputKey=='WireGuardGatewayElasticIp' || OutputKey=='WireGuardGatewayEndpoint' || OutputKey=='WireGuardGatewayPublicKey' || OutputKey=='WireGuardGatewayAddress' || OutputKey=='WireGuardWorkstationAddress' || OutputKey=='TigerBeetleEndpoint'].[OutputKey,OutputValue]" \
  --output table \
  --profile dev \
  --region ca-central-1
```

`lambda_logs.sh` resolves the explicit intake, query, or execution function-name output.
`persistence.sh` and `queue.sh` resolve the `OperationsTable` and
`OperationsQueue` physical resources directly because those data-plane names
are intentionally not public stack outputs. Normal local command use does not
require exporting those values.

### Configure the workstation

Install the workstation private key into the platform's protected WireGuard
configuration using mode `0600` or an equivalent secret-store permission. Use
this peer shape, replacing the placeholders with the protected private key,
the gateway public key, conditional Elastic IP output, and supplied Lambda
subnet CIDR:

```ini
[Interface]
Address = 10.200.0.2/24
PrivateKey = <workstation-private-key>

[Peer]
PublicKey = <gateway-public-key>
Endpoint = <WireGuardGatewayElasticIp>:51820
AllowedIPs = <LambdaSubnetCidr>
PersistentKeepalive = 25
```

`AllowedIPs` intentionally contains only the Lambda subnet, not the entire
VPC. This installs the return route for traffic whose source is the Lambda
subnet while keeping unrelated VPC traffic out of the development tunnel. The
workstation firewall must permit TigerBeetle TCP/3000 from
`LambdaSubnetCidr`. TigerBeetle must listen on `10.200.0.2:3000` or another
socket that includes the WireGuard interface; binding only to loopback or a
different local interface is insufficient. The gateway performs routing, not
NAT.

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
| Execution loses DynamoDB access after VPC attachment | Restore the Lambda subnet's NAT path or DynamoDB gateway endpoint; an internet gateway on the public gateway subnet does not provide Lambda egress. |
| SSM registration or bootstrap fails | Check gateway-subnet internet routing, the instance role, `cloud-init` logs, and the exact SSM parameter name/version. The role can read only that parameter. |

### Rotate WireGuard keys

`deploy.sh` never rotates either parameter implicitly. To rotate the default
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
After both updates succeed, rerun the complete enabled SAM or `deploy.sh`
command with
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
the deployment. A real TigerBeetle request from Lambda remains deferred: the
current execution handler does not contain a TigerBeetle client.

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
'"name":"echo","body":{"message":"hello","count":2}}' \
  <IntakeFunctionUrl>
```

For a new ID, the handler persists `NEW`, submits the full Operation to SQS,
conditionally stores `SUBMITTED`, and returns the bodyless Operation output
view. It uses the invocation timestamp for `last_updated` and the 24-hour
expiry, the verified subject as tenant, and the stable hash:

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

The query performs a strongly consistent read and returns the same compact
bodyless Operation JSON shown above with `Content-Type: application/json`.
Terminal Operations also include `result`; pending Operations do not. The path
must contain exactly one UUID segment. Query strings and GET bodies cannot
supply or alter the ID. Missing and cross-tenant Operations both return the
same static `404 Not Found` response. DynamoDB request or service failures
return static HTTP 503; malformed items and other unexpected failures remain
sanitized HTTP 500 responses. DynamoDB TTL remains asynchronous, so an item is
readable while it is still stored even after `expires_at`.

The SQS message is the exact compact full Operation JSON with `id`, `tenant`,
`name`, `body`, `state`, `last_updated`, `expires_at`, and `hash`, and no
trailing newline. The DynamoDB item and successful HTTP response omit `body`.
A matching retry that still reads `NEW` attempts submission again. Matching
`SUBMITTED`, `RUNNING`, `SUCCEEDED`, or `FAILED` retries return the stored
Operation without another send.

An SQS failure leaves DynamoDB unchanged as `NEW` and returns only the static
`503 Service Unavailable` response. A DynamoDB failure after a successful send
returns the static `500 Internal Server Error` response; the message may
already exist. If a conditional update loses a race, the handler performs a
strongly consistent read and returns a matching Operation that has advanced
beyond `NEW`. Other DynamoDB, malformed stored-item, and allocation failures
remain sanitized HTTP 500 responses. Reusing the ID for different work or from
a different verified subject returns the static `409 Conflict` response.

Delivery is at least once. The standard queue, acknowledgement loss, and
concurrent `NEW` retries can create duplicate messages. Consumers must use the
Operation ID and hash idempotently. Execution conditionally completes only a
matching still-`SUBMITTED` item with no result, but it deliberately acknowledges
invalid records, conflicts, and service failures without a per-record retry.

## 9. Download Lambda logs

Run the stack-aware log helper with an explicit Lambda selection:

```sh
./lambda_logs.sh intake
./lambda_logs.sh query
./lambda_logs.sh execution
```

The stack name is fixed as `aws-lambda-zig-demo`. The helper resolves
`IntakeFunctionName`, `QueryFunctionName`, or `ExecutionFunctionName` and writes a root-level file named
after that function, such as `intake-lambda.log`. It uses only the standard
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
stored Operation, including its state, `last_updated`, `expires_at`, and terminal
result when present. A different hash, including one derived under another
tenant, returns `dynamodb: operation conflict` with exit code `1`.

Read the persistent output view:

```sh
./persistence.sh read \
  --id 00112233-4455-6677-8899-aabbccddeeff
```

Pending states require empty standard input. Terminal states require a
non-null JSON result no larger than 4,096 input bytes whose compact
serialization is also no larger than 4,096 bytes:

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

Each successful update refreshes both `last_updated` and `expires_at`, keeping
the expiry exactly 24 hours after the update timestamp.

Lifecycle ordering is intentionally not enforced: any valid state may replace
any previous state, including a same-state update. Exit code `1` means the item
was missing or a create/update conflict occurred. Both conflict paths emit
`dynamodb: operation conflict`. Exit code `2` means invocation, validation,
configuration, AWS, or internal failure.

The caller running `persistence.sh` needs `dynamodb:GetItem`,
`dynamodb:PutItem`, and `dynamodb:UpdateItem` permissions for the table, plus
`cloudformation:DescribeStackResource` to resolve the table resource. Its `delete-all`
command additionally needs `dynamodb:Scan` and `dynamodb:DeleteItem`. The
Lambda execution role's inline policy does not grant these permissions to the
local AWS identity.

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

The SAM template supplies the intake Lambda with `OPERATIONS_TABLE_NAME`,
`OPERATIONS_QUEUE_URL`, and their scoped IAM policies together. Removing either
variable, configuring an empty or oversized queue URL, or configuring an
invalid DynamoDB table name makes the intake bootstrap exit during Lambda INIT,
before it requests an invocation. Check the deployed template and function
configuration; no HTTP response can be produced for an INIT failure.

A syntactically valid but nonexistent table, or missing `PutItem` permission,
does not fail INIT because startup makes no DynamoDB request. The first valid,
authenticated POST returns a sanitized HTTP 500 in those cases; inspect Lambda
logs and the SAM-managed stack resources without recording live table names or
account-specific identifiers in this repository. Likewise, a syntactically
valid but nonexistent queue or missing `SendMessage` permission is discovered
only when POST attempts submission and returns a sanitized HTTP 503.

The query Lambda requires only `OPERATIONS_TABLE_NAME`; it has no queue
configuration. A missing or invalid table-name setting exits during query INIT.
A nonexistent table, missing `GetItem` permission, or DynamoDB service failure
is discovered by the first authenticated `GET /<uuid>` and returns a sanitized
HTTP 503. A malformed stored item returns a sanitized HTTP 500.

The execution Lambda also requires only `OPERATIONS_TABLE_NAME` as application
configuration. A missing or invalid setting exits during execution INIT. A
nonexistent table, missing `UpdateItem` permission, or DynamoDB service failure
is discovered during a record completion attempt. Execution logs that failure,
continues the batch, and acknowledges the record without requesting a retry.

## 11. Send, receive, and check queued Operations

`queue.sh` is the supported local queue command. It defaults to profile `dev`,
region `ca-central-1`, and stack `aws-lambda-zig-demo`. It exports the selected
profile's temporary credentials, resolves the `OperationsQueue` physical
resource, and runs the requested operation. Override the defaults with
`PROFILE`, `REGION`, or `STACK_NAME`.

Send an Operation while supplying required tenant metadata separately:

```sh
operation_json='{"id":"00112233-4455-6677-8899-aabbccddeeff",'\
'"name":"echo","body":{"message":"hello","count":2}}'
printf '%s\n' "$operation_json" | ./queue.sh send --tenant 'tenant-a'
```

`send` validates the input with `src/operation.zig`, derives `last_updated`
from the current time, and replaces an omitted or explicit `NEW` state with
`SUBMITTED`. It validates and serializes the resulting full Operation exactly
once. The SQS message contains the compact canonical JSON with `id`, `tenant`,
`name`, `body`, `state`, `last_updated`, `expires_at`, and `hash`, with no
trailing newline. After `SendMessage` succeeds, stdout receives those exact
bytes followed by a newline. State remains excluded from the Operation hash.
The command does not read or update DynamoDB.

Request every queue attribute and print one JSON object. Unknown future keys
are retained:

```sh
./queue.sh check
```

Consume queued messages until interrupted:

```sh
./queue.sh receive
```

On a deployed stack, this local consumer competes with the enabled execution Lambda event source
mapping. Use it only when intentionally taking messages away from the execution handler.

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
queue-scoped polling permissions, and query has no SQS permissions.

If `sqs: missing or invalid configuration` is emitted, the local command
implementation could not load its AWS settings. `queue.sh` supplies the
resolved queue URL, temporary credentials, and region, and validates that the
URL is non-empty. Confirm `PROFILE`, `REGION`, and `STACK_NAME`. Configuration
is checked before Operation input is parsed; AWS failures after configuration
loading instead report `sqs: AWS request failed`.

## 12. Update the deployed Lambda code

After changing Zig source code, rebuild and repackage:

```sh
zig build --release -Darch=arm
zip -qj intake-lambda.zip zig-out/bin/intake/bootstrap
zip -qj query-lambda.zip zig-out/bin/query/bootstrap
zip -qj execution-lambda.zip zig-out/bin/execution/bootstrap
```

Then redeploy the stack:

```sh
sam deploy --profile dev --region ca-central-1
```

SAM uploads all three packages and updates their CloudFormation-managed Lambda functions.

## 13. Delete the SAM stack

To remove all three SAM-managed functions, roles, the operations table and
queue, Function URLs, permissions, and any enabled gateway resources:

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
The operations queue uses the same deletion policies, so deleting or replacing
it permanently deletes any queued messages.

For an enabled deployment, stack deletion also terminates the EC2 gateway,
releases its Elastic IP, removes the `10.200.0.0/24` route and security groups,
and deletes the stack-owned launch template, IAM role, and instance profile.
The gateway private/public SSM parameters are intentionally external and are
not deleted. The workstation keys and TigerBeetle process and data are also
workstation-owned and remain untouched.

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
authorization, narrower IAM policies, or an API Gateway/CloudFront layer.

When the gateway is enabled, IPv4 UDP/51820 is deliberately open from
`0.0.0.0/0` because the NAT public address of the development workstation is
not predictable. WireGuard authenticates the configured peer and remains
silent to unauthenticated handshakes, but removing a security-group source
filter increases exposure to UDP scanning and floods and to future kernel or
WireGuard vulnerabilities. The gateway opens no IPv6 ingress, SSH, public
TigerBeetle TCP port, or other public ingress. Keep the gateway disabled when
it is not needed and account for its EC2 and Elastic IP cost while enabled.

No private WireGuard key is a CloudFormation parameter, template value, tag,
log, or stack output. The instance role can read only the configured external
SSM parameter and intentionally has no `kms:Decrypt` permission because the
workflow uses the AWS-managed `aws/ssm` key.
