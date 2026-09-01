# EC2 WireGuard Gateway — Implemented Architecture and Operations

## 1. Purpose and current status

`template.yaml` and `wireguard-gateway-setup.sh` implement an optional EC2
WireGuard gateway between the VPC-attached execution Lambda and TigerBeetle on
a development workstation. The gateway is disabled by default and is intended
for development and controlled integration testing.

The EC2 instance is a replaceable, stateless network appliance. It runs no
application logic and stores no TigerBeetle data. The execution Lambda owns a
process-lifetime TigerBeetle client and sends its account and transfer requests
through this path. End-to-end traffic remains a cloud acceptance test until an
operator explicitly deploys and exercises it.

The execution traffic paths are:

```text
Execution Lambda
  +-> IPv4 10.200.0.2:3000
  |    -> Lambda subnet route table
  |    -> EC2 WireGuard gateway instance
  |    -> encrypted WireGuard tunnel over the Internet
  |    -> development workstation
  |    -> TigerBeetle
  |
  +-> IPv6 HTTPS
       -> Lambda subnet route table
       -> stack-owned egress-only internet gateway
       -> regional public SQS dual-stack endpoint
       -> Completion queue
       -> completion Lambda
       -> DynamoDB Operations table
```

For each valid queued Operation, execution creates account `Operation.id`
(ledger/code `1`), then creates transfer `Operation.id` from that account to
account `1` for amount `100` (ledger/code `1`). The two event types require
separate requests. Execution gathers each terminal operation ID and result for
the invocation and publishes at most one bounded aggregate Completion message.
The completion Lambda processes that message, conditionally transitions each
matching `SUBMITTED` row to `COMPLETED`, and stores exactly:

```json
{"type":"SUCCESS","payload":{"transfer_id":"00112233-4455-6677-8899-aabbccddeeff"}}
```

Stable IDs make duplicate Operations delivery replay-safe: `created` and
identical `exists` proceed. Definitive rejections are also published and
persisted as `COMPLETED`, using the applicable exact result envelope:

```json
{"type":"FAILURE","payload":{"stage":"ACCOUNT","status":19}}
```

```json
{"type":"FAILURE","payload":{"stage":"TRANSFER","status":22}}
```

TigerBeetle client/request uncertainty or failure to publish a terminal entry
leaves the affected Operation `SUBMITTED` and is reported as an Operations-queue
partial-batch failure. After publication, Completion delivery and DynamoDB
service uncertainty are retried through the Completion queue.
Conditional completion conflicts are acknowledged without changing the stored
row; completed Operations are immutable, including same-outcome refreshes.
`SUBMITTED` and `COMPLETED` are the only lifecycle states. A completed `result`
contains exactly uppercase `type` and non-null `payload`, and the entire compact
envelope is limited to 4,096 bytes.

Enabling the gateway incurs EC2 and public IPv4/Elastic IP charges. The EIGW has
no fixed hourly or processing charge; ordinary service and data-transfer charges
still apply.

## 2. Fixed network design

The initial implementation fixes these values:

| Setting | Value |
| --- | --- |
| WireGuard network | `10.200.0.0/24` |
| Gateway WireGuard address | `10.200.0.1/24` |
| Workstation WireGuard address | `10.200.0.2/24` |
| Public endpoint | Gateway Elastic IPv4 address on UDP/51820 |
| TigerBeetle endpoint | `10.200.0.2:3000` |
| Routing model | Layer 3 forwarding without NAT |
| EC2 source/destination check | Disabled |
| Default instance type | `t4g.nano` |
| Default AMI | ARM64 Amazon Linux 2023 through `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64` |

The workstation sees the original Lambda-subnet source address. The gateway
does not translate it, so the workstation WireGuard peer must accept the
Lambda subnet and install its return route through the tunnel.

```text
AWS VPC
┌─────────────────────────────────────────────────────────┐
│                                                         │
│  Execution Lambda (dual-stack)                          │
│      │                                                  │
│      ├─ IPv4 TCP 10.200.0.2:3000                        │
│      │    -> 10.200.0.0/24 -> gateway EC2 instance      │
│      │       eth0: public gateway subnet                │
│      │       wg0:  10.200.0.1/24; UDP/51820             │
│      │       IPv4 forwarding; SourceDestCheck=false     │
│      │                                                  │
│      └─ IPv6 TCP/443                                    │
│           -> ::/0 -> stack-owned EIGW                   │
│           -> regional public SQS dual-stack endpoint    │
│                                                         │
└───────────────────────┬─────────────────────────────────┘
                        │ encrypted WireGuard tunnel
                        ▼
               Development workstation
               wg0: 10.200.0.2/24
               TigerBeetle: 10.200.0.2:3000
```

## 3. Required existing network

The template does not create a VPC, subnet, route table, route-table
association, NAT gateway, VPC/subnet IPv6 CIDR association, network ACL, or VPC
DNS setting. An enabled deployment supplies:

- one existing VPC;
- a public gateway subnet with an active `0.0.0.0/0` route to an internet
  gateway;
- a distinct Lambda subnet in the same VPC and availability zone;
- the Lambda subnet's effective route table and primary IPv4 CIDR;
- an active VPC IPv6 CIDR association and exactly one active IPv6 `/64` on the
  Lambda subnet, contained by exactly one active VPC IPv6 allocation;
- VPC `enableDnsSupport` and `enableDnsHostnames` attributes set to `true`;
- a Lambda-subnet network ACL that permits outbound IPv6 TCP/443 and inbound
  response traffic on TCP/1024-65535; and
- a region where the public SQS dual-stack endpoint is available to the
  operator's preflight identity.

Neither subnet may overlap `10.200.0.0/24`. The Lambda route table must not
already contain a route for `10.200.0.0/24`, except when that route belongs to
the existing enabled deployment of this stack. Before first enablement, the
route table must also have no `::/0` route and the VPC must have no attached
EIGW. During reconfiguration, any EIGW and `::/0` route must be the current
stack's `ExecutionEgressOnlyInternetGateway` and `ExecutionSqsIpv6Route`.
Attaching Lambda to a public subnet does not give it Internet access through
the subnet's internet gateway.

For a small development VPC, the recommended topology is a dedicated `/28`
Lambda subnet in the gateway subnet's availability zone, automatic public IPv4
assignment disabled, exactly one active IPv6 `/64`, and an explicitly associated
route table containing only the VPC-local routes before enablement. The VPC,
subnets, route table and association, IPv6 associations, DNS settings, and
network ACL remain operator-owned outside the SAM stack. SAM creates the VPC's
single EIGW and adds the execution-specific `::/0` route to that route table.

## 4. Template parameters and conditions

The TigerBeetle endpoint parameters are always present; the remaining template
interface controls the optional managed gateway:

| Parameter | Behavior |
| --- | --- |
| `TigerBeetleClusterId` | Unsigned 128-bit decimal cluster ID; defaults to `0`. |
| `TigerBeetleAddresses` | Comma-separated replica addresses; defaults to `10.200.0.2:3000`. |
| `EnableWireGuardGateway` | `true` creates the gateway and VPC-attaches execution; defaults to `false`. |
| `RetainExecutionVpcCleanupResources` | Internal setup-script switch that retains the EIGW, IPv6 route, execution security group, VPC/route inputs, and ENI-management IAM between detach and cleanup phases; defaults to `false`. |
| `VpcId` | Existing VPC containing both subnets; its IPv6 association remains externally managed. |
| `GatewayPublicSubnetId` | Existing public subnet for the EC2 gateway. |
| `LambdaSubnetId` | Distinct existing dual-stack subnet for execution Lambda; its IPv6 `/64` remains externally managed. |
| `LambdaRouteTableId` | Effective external route table for `LambdaSubnetId`; SAM adds the IPv4 WireGuard and IPv6 SQS routes. |
| `LambdaSubnetCidr` | Primary IPv4 CIDR for `LambdaSubnetId`. |
| `WireGuardPrivateKeyParameterName` | Absolute SSM path of the gateway private-key `SecureString`. |
| `WireGuardPrivateKeyParameterVersion` | Exact positive version retrieved at bootstrap; template default is `1`. |
| `WireGuardGatewayPublicKey` | Padded Base64 public key matching that private-key version. |
| `WireGuardWorkstationPublicKey` | Padded Base64 public key matching the workstation-owned private key. |
| `WireGuardAmiId` | Public SSM parameter resolving to an ARM64 AMI. |
| `WireGuardInstanceType` | ARM64 EC2 instance type; defaults to `t4g.nano`. |

When `EnableWireGuardGateway=true`, the `WireGuardGatewayInputsRequired`
CloudFormation rule requires every gateway input. The
`ExecutionVpcCleanupInputsRequired` rule requires both `VpcId` and
`LambdaRouteTableId` while cleanup resources are retained. The
`WireGuardGatewayEnabled` condition controls the gateway and execution VPC
attachment. `ExecutionVpcCleanupResourcesRetained` remains true while either
the gateway or retained-cleanup switch is true. Empty defaults are therefore
safe when both switches are false.
`wireguard-gateway-setup.sh` performs the stronger live topology and SSM checks
described below; a direct SAM deployment does not perform those discovery
checks.

## 5. Stack-owned resources

The always-present execution role is explicit so its VPC permission can be
retained safely during detach. The optional resources are:

| Logical resource | Type | Creation condition |
| --- | --- | --- |
| `ExecutionLambdaSecurityGroup` | `AWS::EC2::SecurityGroup` | Gateway enabled or cleanup resources retained |
| `ExecutionEgressOnlyInternetGateway` | `AWS::EC2::EgressOnlyInternetGateway` | Gateway enabled or cleanup resources retained |
| `ExecutionSqsIpv6Route` | `AWS::EC2::Route` | Gateway enabled or cleanup resources retained |
| `WireGuardGatewaySecurityGroup` | `AWS::EC2::SecurityGroup` | Gateway enabled |
| `WireGuardGatewayRole` | `AWS::IAM::Role` | Gateway enabled |
| `WireGuardGatewayInstanceProfile` | `AWS::IAM::InstanceProfile` | Gateway enabled |
| `WireGuardGatewayLaunchTemplate` | `AWS::EC2::LaunchTemplate` | Gateway enabled |
| `WireGuardGatewayInstance` | `AWS::EC2::Instance` | Gateway enabled |
| `WireGuardGatewayElasticIp` | `AWS::EC2::EIP` | Gateway enabled |
| `WireGuardGatewayElasticIpAssociation` | `AWS::EC2::EIPAssociation` | Gateway enabled |
| `WireGuardLambdaRoute` | `AWS::EC2::Route` | Gateway enabled |

The launch template places one network interface in
`GatewayPublicSubnetId`, associates a public IPv4 address for bootstrap, and
requires IMDSv2. CloudFormation also associates a stable Elastic IP with the
instance. The route sends `10.200.0.0/24` from `LambdaRouteTableId` to the EC2
instance and depends on the Elastic IP association.

The execution function is attached only to `LambdaSubnetId` and the
stack-managed execution security group while the gateway is enabled. It sets
`Ipv6AllowedForDualStack: true`, and `AWS_USE_DUALSTACK_ENDPOINT=true` makes the
AWS SDK select the regional public SQS dual-stack endpoint. SAM creates
`ExecutionEgressOnlyInternetGateway` for `VpcId` and
`ExecutionSqsIpv6Route`, an active `::/0` route in `LambdaRouteTableId` that
targets that EIGW. The same route table carries `WireGuardLambdaRoute`, the
unchanged IPv4 `10.200.0.0/24` route to the gateway instance.

Execution polls `OperationsQueue` through Lambda's managed event-source mapping
and uses its SDK only to send to `CompletionQueue`. The completion Lambda remains
outside the VPC and updates the DynamoDB Operations table. Intake and query also
remain outside the customer VPC. Execution has no VPC attachment in steady
disabled state.

## 6. Security and IAM boundaries

The gateway security group has exactly these rules:

| Direction | Protocol and port | Peer | Purpose |
| --- | --- | --- | --- |
| Ingress | UDP/51820 | `0.0.0.0/0` | Public WireGuard endpoint |
| Ingress | TCP/3000 | `LambdaSubnetCidr` | Forwarded TigerBeetle traffic from Lambda |
| Egress | All IPv4 | `0.0.0.0/0` | Package installation, SSM, and tunnel traffic |

UDP/51820 is intentionally open to all IPv4 sources because a NATed
workstation's public address may change. WireGuard authenticates the configured
peer, but the broad source increases exposure to UDP scanning and floods. The
template opens no IPv6 ingress, SSH, public TCP/3000, or other public ingress.

The execution security group has no ingress and only:

- TCP/3000 egress to `10.200.0.2/32`; and
- IPv6 TCP/443 egress to `::/0` for the regional public SQS dual-stack endpoint.

The public IPv6 HTTPS boundary is broader than PrivateLink's private-only reach
and endpoint policy. Queue-scoped IAM remains the service authorization
boundary: execution receives only `sqs:SendMessage` on `CompletionQueue`. The
design accepts that tradeoff to avoid the fixed hourly and data-processing cost
of an SQS interface endpoint or NAT Gateway. The EIGW itself has no fixed hourly
or processing charge.

The execution role receives its six Lambda ENI-management actions only while
the gateway or retained-cleanup condition is active. The gateway role grants
the SSM agent control/data-channel actions required for Session Manager and
`ssm:GetParameter` for only the selected gateway-private-key parameter ARN.
There is no SSH key or TCP/22 rule. The default private parameter uses the
AWS-managed `alias/aws/ssm` key, so the role needs no separate `kms:Decrypt`
grant.

## 7. Gateway bootstrap

EC2 user data performs these steps with `set -euo pipefail` and `umask 077`:

1. Retry `dnf install -y wireguard-tools` up to five times.
2. Retrieve the exact
   `WireGuardPrivateKeyParameterName:WireGuardPrivateKeyParameterVersion` with
   decryption, retrying up to five times.
3. Derive the public key and stop if it differs from
   `WireGuardGatewayPublicKey`.
4. persist `net.ipv4.ip_forward=1` and apply it;
5. create mode-`0600` `/etc/wireguard/wg0.conf` with the gateway private key
   and workstation public key;
6. enable and start `wg-quick@wg0`; and
7. verify the interface address and IPv4 forwarding state.

The installed peer configuration is equivalent to:

```ini
[Interface]
Address = 10.200.0.1/24
ListenPort = 51820
PrivateKey = <gateway-private-key-from-ssm>

[Peer]
PublicKey = <WireGuardWorkstationPublicKey>
AllowedIPs = 10.200.0.2/32
```

The private key is never a CloudFormation parameter, tag, output, or repository
value.

## 8. Gateway setup resolution and preflight

Running `./wireguard-gateway-setup.sh` enables or reconfigures the feature;
enablement is implicit. The legacy `--enable-wireguard-gateway` option and
`ENABLE_WIREGUARD_GATEWAY=0|1` remain accepted by this script for command
compatibility; `0` selects teardown. Prefer
`./wireguard-gateway-setup.sh --disable` for teardown.
Routine `./deploy.sh` updates preserve the stack's complete gateway parameter
set and never enable, reconfigure, or disable it. A new stack uses the template's
disabled defaults. If retained cleanup is in progress, routine deployment is
rejected until `wireguard-gateway-setup.sh --disable` completes it.

For enabled deployments, values resolve in this order:

1. CLI option;
2. environment variable;
3. matching value from an existing stack only when that stack has
   `EnableWireGuardGateway=true`; and
4. network discovery, the external default SSM pair, or the instance-type
   default as applicable.

The helper inspects available IPv4 subnet pairs. A candidate must use distinct
subnets in one VPC and availability zone, avoid the WireGuard CIDR, provide an
Internet-gateway default route for the gateway, and have an unambiguous
effective route table for the Lambda subnet. The Lambda subnet does not need
NAT. Explicit VPC or subnet inputs constrain the candidate set.
`LAMBDA_SUBNET_CIDR` and `LAMBDA_ROUTE_TABLE_ID` are assertions against the
selected subnet's live values.

Discovery proceeds only when exactly one pair matches. Multiple matches are
printed and require one or both subnet options. With no match, the helper
prints rejection counts for gateway routing, CIDR overlap, subnet identity,
VPC, and availability zone. AWS inspection failures are reported separately
rather than counted as topology rejections.

Before deployment, the helper rechecks the VPC/subnet relationships, same-AZ
constraint, effective route tables, gateway Internet route, CIDRs, and
conflicting WireGuard route. It then fails closed unless all dual-stack
prerequisites are trustworthy:

- `LambdaSubnetId` has exactly one active IPv6 `/64`, and exactly one active VPC
  IPv6 association contains it. Missing, malformed, inactive, non-`/64`, or
  ambiguous associations are rejected.
- `enableDnsSupport` and `enableDnsHostnames` are both enabled, so the SDK can
  resolve regional dual-stack AWS service names.
- `LambdaRouteTableId` is the subnet's effective route table. An existing
  `10.200.0.0/24` route is accepted only when the current enabled stack owns the
  route and target instance.
- First enablement requires no EIGW attached to the VPC and no `::/0` route in
  the Lambda route table. There is no operator-supplied EIGW ID; SAM creates
  `ExecutionEgressOnlyInternetGateway`.
- Same-topology reconfiguration and old-topology or retained cleanup require
  exactly one attached EIGW owned by this stack and exactly one
  `ExecutionSqsIpv6Route`. A missing, malformed, ambiguous, unmanaged, or
  mismatched EIGW is rejected. The route must be unique, active, created by
  `CreateRoute`, and target that EIGW; missing, unmanaged, duplicate,
  mismatched, or blackhole `::/0` routes are rejected.
- The Lambda subnet has one effective network ACL. An obvious policy must allow
  outbound IPv6 TCP/443 and inbound TCP/1024-65535 response traffic. A plainly
  blocking or malformed policy is rejected; a nontrivial ordered policy emits a
  warning and requires operator verification. The bounded parser recognizes
  AWS's implicit IPv6 terminal deny at rule number `32768`; other out-of-range
  or malformed explicit rules remain rejected.
- `AWS_USE_DUALSTACK_ENDPOINT=true aws sqs list-queues --max-results 1` succeeds
  in the selected Region. This operator-side probe verifies regional SQS
  dual-stack availability and requires `sqs:ListQueues`; it does not broaden the
  execution role.

These checks inspect external topology and stack ownership but never allocate
IPv6 space, change DNS or network ACLs, attach an EIGW directly, or add routes
outside CloudFormation.

With a unique topology and the default SSM paths, first enablement therefore
needs only the workstation public key in addition to the normal PASETO inputs:

```sh
WIREGUARD_WORKSTATION_PUBLIC_KEY="$wireguard_workstation_public_key" \
./wireguard-gateway-setup.sh
```

Use explicit subnet options when discovery is ambiguous:

```sh
./wireguard-gateway-setup.sh \
  --gateway-public-subnet-id '<gateway-public-subnet-id>' \
  --lambda-subnet-id '<lambda-subnet-id>' \
  --wireguard-workstation-public-key "$wireguard_workstation_public_key"
```

## 9. Key ownership and lifecycle

The workstation private key is generated and retained only on the workstation.
Only its padded Base64 public key is passed to deployment.

By default, `wireguard-gateway-setup.sh` uses this operator-owned external pair:

| Value | Parameter |
| --- | --- |
| Gateway private key | `/applications/${STACK_NAME}/wireguard/gateway-private-key` as `SecureString` |
| Gateway public key | `/applications/${STACK_NAME}/wireguard/gateway-public-key` as `String` |

If both parameters exist, the helper validates their types, validates the
public-key format, and pins the selected private version. If neither exists,
it requires local `wg`, generates the pair in a temporary mode-`0700`
directory under a restrictive umask, creates both parameters without
overwrite, and removes the temporary files on success or failure. If creation
of the public parameter fails, it deletes only the private parameter created by
that invocation. A one-parameter partial pair is rejected without modification.

A custom private-parameter path disables automatic pair creation. It must be
an absolute SSM path that does not begin with the case-insensitive reserved
prefix `aws` or `ssm`. The custom parameter must be a `SecureString`, and its
matching gateway public key must be supplied. There is deliberately no option
for passing the private-key value.

The helper never rotates or overwrites the default pair. A non-current private
version must be supplied with its matching public key. The selected version is
pinned in the stack so a later SSM update cannot silently change a running
gateway. Changing the selected private version, gateway public key, workstation
public key, AMI, or instance configuration creates a new launch-template
version and can replace the stateless gateway.

The deployment identity needs `ssm:GetParameter` and `ssm:PutParameter` for
both default paths plus `ssm:DeleteParameter` for scoped creation rollback.
Neither stack disablement nor stack deletion removes the external SSM pair.

## 10. Deployment and disablement lifecycle

Before any non-dry-run build, the shared deployment runner clears inherited static AWS credential
variables, exports the selected SSO-backed profile, and unconditionally runs
`aws sso login` to obtain a fresh access token. Login happens before stack
inspection or other AWS discovery, and a failure stops the deployment;
non-SSO profiles are unsupported. Dry runs make no AWS authentication calls.
The helper stops before local work when the stack status ends in
`_IN_PROGRESS`.

The helper then runs Zig formatting and tests, builds all four Linux ARM64
bootstraps, refreshes their zip archives, and runs both SAM validations. First
enablement preflights a VPC with no EIGW or `::/0` conflict, then uses one SAM
update. CloudFormation creates `ExecutionEgressOnlyInternetGateway`, adds
`ExecutionSqsIpv6Route` and `WireGuardLambdaRoute`, attaches execution with its
dual-stack setting, and creates the two security groups. After success, the
helper prints the conditional network outputs and masked peer configuration,
then continues with the DynamoDB, SQS, and optional Function URL checks.

Intake, query, and completion are stripped, statically linked executables.
Execution is multithread-capable for the native TigerBeetle callback thread and
is a stripped ARM64 glibc executable reported as dynamically linked; Amazon
Linux 2023 provides its dynamic loader and system libraries.

Routine `deploy.sh` runs preserve both enabled and disabled gateway state.
Gateway lifecycle changes use these sequences:

- A same-topology reconfiguration, such as a key version, instance type, or
  workstation peer change, verifies that the current EIGW and routes are
  stack-owned and healthy, then applies one enabled SAM update.
- A change to `VpcId`, `LambdaSubnetId`, or `LambdaRouteTableId` is a topology
  change and always uses guarded detach. This includes moving the Lambda subnet
  or route table within the same VPC. The helper first validates the old
  stack-owned IPv6 egress, detaches and cleans up the old topology as described
  below, preflights the target topology with no EIGW or `::/0` conflict, and only
  then deploys the enabled stack again. In a same-VPC move, the old stack-owned
  EIGW is removed before SAM recreates it for the target route table.
- A cross-VPC reconfiguration uses the same guarded sequence. The old VPC and
  route-table IDs remain selected through old-resource cleanup. The target VPC
  and Lambda subnet must already have their external active IPv6 associations,
  DNS settings, and compatible network ACL, and the target VPC must have no
  unmanaged EIGW.
- Teardown runs the guarded detach and cleanup but does not perform a target
  deployment.

Run `./wireguard-gateway-setup.sh --disable` for teardown. Guarded detach and
topology changes use this exact old-resource sequence:

1. Set `EnableWireGuardGateway=false` and
   `RetainExecutionVpcCleanupResources=true`. This detaches execution and removes
   the EC2 gateway, Elastic IP, `WireGuardLambdaRoute`, launch resources, and
   gateway security group. It retains `ExecutionEgressOnlyInternetGateway`,
   `ExecutionSqsIpv6Route`, `ExecutionLambdaSecurityGroup`, the old `VpcId` and
   `LambdaRouteTableId`, and the role's ENI-management policy.
2. Wait up to approximately 20 minutes for the current execution function and
   every published version to have no VPC configuration, then require zero
   Lambda-created network interfaces associated with the retained execution
   security group. An EIGW creates no endpoint ENIs, so the wait has no separate
   EIGW-interface branch.
3. Set `RetainExecutionVpcCleanupResources=false` while preserving the old VPC
   and route-table parameters for unambiguous deletion. CloudFormation removes
   the IPv6 route first, then the EIGW, execution security group, and conditional
   ENI-management policy.
4. Only after cleanup succeeds, clear the saved optional gateway inputs. A
   topology reconfiguration then preflights and deploys the target values.

If the bounded wait or an AWS inspection fails, cleanup and parameter reset are
not attempted. The EIGW, IPv6 route, execution security group, required
parameters, and ENI-management IAM remain intact. After CloudFormation is no
longer in progress, rerun `wireguard-gateway-setup.sh --disable`; it recognizes
the retained state and resumes the guarded wait. Never start another deployment
while CloudFormation still reports an `_IN_PROGRESS` state.

Gateway disablement does not disable the SQS event-source mapping. Execution
continues consuming and uses `TigerBeetleAddresses`; provide another reachable
trusted endpoint or expect TigerBeetle timeouts to return per-record retries.

`--dry-run` checks the syntax of supplied gateway inputs but deliberately skips
AWS discovery, SSM inspection or generation, topology preflight, and deployment.
It still formats, tests, builds, packages, and validates locally.

Direct SAM deployment requires every gateway input to resolve to a non-empty
value; the template supplies defaults only for the private-key version, AMI,
and instance type. It does not provide setup-script discovery, key generation,
enabled-stack value reuse, or guarded disablement. Do not use a single direct
SAM update to disable an enabled stack; use
`wireguard-gateway-setup.sh --disable` or manually reproduce both detach and
cleanup phases with the same current-function, published-version, and
Lambda-created-ENI checks.

## 11. Outputs and workstation configuration

An enabled stack emits these non-secret outputs:

```text
WireGuardGatewayInstanceId
WireGuardGatewayElasticIp
WireGuardGatewayEndpoint
WireGuardGatewayPublicKey
WireGuardGatewayAddress
WireGuardWorkstationAddress
TigerBeetleEndpoint
```

The EIGW and IPv6 route are conditional stack resources rather than outputs.
Resolve and verify their implemented logical IDs without recording live values:

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

Both conditional resources must have a complete CloudFormation status. The
EIGW must have one attached association to `VpcId`; the `::/0` route must be
active, created by `CreateRoute`, and target that EIGW. The
`10.200.0.0/24` route must still target `WireGuardGatewayInstance`.
Execution's VPC configuration must show `Ipv6AllowedForDualStack: true`, and
its environment must show `AWS_USE_DUALSTACK_ENDPOINT=true`. The SQS probe uses
the operator identity and does not expand execution's queue-restricted IAM.

After successful enablement, `wireguard-gateway-setup.sh` validates the endpoint,
gateway public key, workstation address, and deployed `LambdaSubnetCidr`, then
prints this delimited copy-ready shape before unrelated URL checks:

```text
-----BEGIN WIREGUARD PEER CONFIGURATION-----
[Interface]
Address = 10.200.0.2/24
PrivateKey = <wireguard-peer-private-key>

[Peer]
PublicKey = <WireGuardGatewayPublicKey>
Endpoint = <WireGuardGatewayEndpoint>
AllowedIPs = <LambdaSubnetCidr>
PersistentKeepalive = 25
-----END WIREGUARD PEER CONFIGURATION-----
```

The literal `<wireguard-peer-private-key>` is deliberately masked and must be
replaced with the private key matching the supplied
`WireGuardWorkstationPublicKey`. The helper never reads, generates, prints, or
persists that peer private key. It prints no peer configuration during dry runs,
disablement, failed deployment, or invalid/missing output resolution.

`AllowedIPs` contains only the Lambda subnet, not the entire VPC or the
WireGuard overlay. This accepts forwarded packets sourced from the Lambda
subnet and installs their return route. The steady-state configuration therefore
does not accept gateway-originated inner traffic from `10.200.0.1`; temporarily
add `10.200.0.1/32` only when performing a direct EC2-to-workstation diagnostic.

The workstation firewall must permit TCP/3000 from `LambdaSubnetCidr`.
TigerBeetle must listen on `10.200.0.2:3000` or another bind address that
includes the WireGuard interface. Binding only to loopback or another local
interface is insufficient.

## 12. Operational validation

After an explicitly authorized cloud deployment, validate in this order:

1. Confirm the EC2 instance is running, both status checks pass, the Elastic IP
   is associated, and the instance is registered with Systems Manager.
2. Use Session Manager—not SSH—to check `wg-quick@wg0`, `wg show wg0`,
   `net.ipv4.ip_forward`, the IPv4 route table, and cloud-init logs. Do not print
   `/etc/wireguard/wg0.conf`, because it contains the private key.
3. Activate the workstation interface and confirm a recent handshake and
   increasing RX/TX counters.
4. Verify the active VPC/subnet IPv6 associations and VPC DNS attributes, the
   effective Lambda route table, the stack-owned EIGW attachment, both route
   targets, `SourceDestCheck=false`, both security groups, and execution's
   `Ipv6AllowedForDualStack` and `AWS_USE_DUALSTACK_ENDPOINT` settings.
5. Pre-provision TigerBeetle account `1` on ledger `1` with flags compatible
   with receiving credits. Submit a unique valid Operation and verify that
   execution creates account `Operation.id`, posts transfer `Operation.id` for
   amount `100` from that account to account `1`, and sends the bounded result
   to `CompletionQueue`. Verify that completion then marks the DynamoDB row
   `COMPLETED` with the exact `SUCCESS` envelope above. A duplicate delivery
   must replay both IDs as identical `exists` without changing balances a
   second time or mutating the completed row.
6. Reboot the gateway and repeat the interface, forwarding, handshake, and
   routed-connectivity checks to verify bootstrap persistence.

Useful failure boundaries are:

| Symptom | Primary checks |
| --- | --- |
| No handshake | Workstation interface, UDP/51820 egress, Elastic IP endpoint, and peer public keys |
| Bootstrap public-key mismatch | Selected SSM private version and matching `WireGuardGatewayPublicKey` |
| Handshake but no routed traffic | Workstation `AllowedIPs = <LambdaSubnetCidr>` and gateway peer route `10.200.0.2/32` |
| EC2 reaches the workstation but not TCP/3000 | Workstation firewall and TigerBeetle bind address |
| EC2 works but Lambda cannot reach the overlay | VPC route, source/destination check, Lambda VPC attachment, and execution security-group egress |
| Preflight reports missing or ambiguous IPv6 | Activate exactly one Lambda-subnet IPv6 `/64` contained by exactly one active VPC IPv6 association; allocation and association are external operator actions |
| Preflight reports an EIGW conflict | First enablement and a post-cleanup target preflight require no attached EIGW; same-topology reconfiguration or retained cleanup requires exactly one attached `ExecutionEgressOnlyInternetGateway` owned by the current stack |
| Dual-stack hostname resolution fails | Confirm VPC `enableDnsSupport` and `enableDnsHostnames`, then resolve the regional SQS dual-stack hostname from an equivalent dual-stack environment |
| IPv6 route is absent, mismatched, duplicate, or blackhole | Confirm `LambdaRouteTableId` is the Lambda subnet's effective route table and inspect `ExecutionSqsIpv6Route` and its EIGW target |
| IPv6 HTTPS times out | Check IPv6 TCP/443 execution-security-group egress plus outbound TCP/443 and inbound TCP/1024-65535 in the effective network ACL |
| Execution cannot publish Completion messages | Confirm the EIGW attachment and active `::/0` route, `Ipv6AllowedForDualStack=true`, `AWS_USE_DUALSTACK_ENDPOINT=true`, and the regional SQS dual-stack probe; IAM must still allow `sqs:SendMessage` only to `CompletionQueue` |
| SSM or bootstrap fails | Gateway Internet route, instance role, cloud-init output, and exact SSM parameter name/version |

Cloud handshake, routing, reboot recovery, rotation, and TigerBeetle checks are
not performed by local validation and must not be reported as complete until an
operator explicitly authorizes and runs them.

## 13. Ownership and teardown

The SAM stack owns the execution VPC attachment, both conditional security
groups, `ExecutionEgressOnlyInternetGateway`, `ExecutionSqsIpv6Route`, gateway
role and instance profile, launch template, EC2 instance, Elastic IP and
association, and `WireGuardLambdaRoute` for `10.200.0.0/24`.

The operator owns the existing VPC, subnets, Lambda route table and association,
VPC/subnet IPv6 CIDR associations, VPC DNS attributes, network ACL, any NAT or
default route, and external gateway SSM pair. The workstation owns its
WireGuard configuration and private key, local firewall policy, and TigerBeetle
process and data.

Disabling the gateway removes only stack-owned optional resources. The detach
update removes the WireGuard route and gateway resources and detaches execution;
after guarded Lambda ENI cleanup, the retained-resource update deletes the
SAM-owned IPv6 route, EIGW, execution security group, and conditional
ENI-management IAM. The sequence never deletes or disassociates the external
VPC/subnet IPv6 allocations.

Run guarded disablement before deleting an enabled stack. Neither disablement
nor later stack deletion changes operator-owned IPv6 associations, DNS or
network-ACL configuration, NAT/default routes, external SSM parameters,
supporting network, workstation keys, or TigerBeetle data. Remove external
networking only as a separately authorized operator action after auditing every
consumer.

## 14. Non-goals

This development design intentionally does not provide:

- high availability, multiple gateways, or automatic failover;
- multiple WireGuard peers or automatic workstation discovery;
- NAT between the VPC and WireGuard network;
- a stack-created VPC or Lambda support network;
- SSH administration;
- production monitoring or alerting; or
- production-hosted TigerBeetle.

If this path becomes production-critical, reassess managed VPN alternatives,
redundancy, secret lifecycle, observability, and hosting TigerBeetle outside a
developer workstation.

See [the SAM deployment guide](docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md) for complete
commands for network provisioning, key generation and rotation, deployment,
diagnosis, and cleanup.
