# EC2 WireGuard Gateway — Implemented Architecture and Operations

## 1. Purpose and current status

`template.yaml` and `deploy.sh` implement an optional EC2 WireGuard gateway
between the VPC-attached execution Lambda and TigerBeetle on a development
workstation. The gateway is disabled by default and is intended for development
and controlled integration testing.

The EC2 instance is a replaceable, stateless network appliance. It runs no
application logic and stores no TigerBeetle data. The execution Lambda owns a
process-lifetime TigerBeetle client and sends its account and transfer requests
through this path. End-to-end traffic remains a cloud acceptance test until an
operator explicitly deploys and exercises it.

The traffic path is:

```text
Execution Lambda
  -> Lambda subnet route table
  -> EC2 WireGuard gateway instance
  -> encrypted WireGuard tunnel over the Internet
  -> development workstation
  -> TigerBeetle
```

For each valid queued Operation, execution creates account `Operation.id`
(ledger/code `1`), then creates transfer `Operation.id` from that account to
account `1` for amount `100` (ledger/code `1`), and only then conditionally
marks DynamoDB `SUCCEEDED`. The two event types require separate requests.
Stable IDs make duplicate delivery replay-safe: `created` and identical
`exists` proceed, while a definite rejection is acknowledged and leaves the
Operation `SUBMITTED`. Client/request uncertainty and DynamoDB service
uncertainty are reported as SQS partial-batch failures.

Enabling the gateway incurs EC2 and public IPv4/Elastic IP charges.

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
│  Execution Lambda                                       │
│      │ TCP 10.200.0.2:3000                              │
│      ▼                                                  │
│  Lambda subnet route table                              │
│      │ 10.200.0.0/24 -> gateway EC2 instance            │
│      ▼                                                  │
│  EC2 gateway                                            │
│      eth0: address in the public gateway subnet         │
│      wg0:  10.200.0.1/24                                │
│      UDP:  51820                                        │
│      IPv4 forwarding enabled; SourceDestCheck=false     │
│                                                         │
└───────────────────────┬─────────────────────────────────┘
                        │ encrypted WireGuard tunnel
                        ▼
               Development workstation
               wg0: 10.200.0.2/24
               TigerBeetle: 10.200.0.2:3000
```

## 3. Required existing network

The template does not create a VPC, subnet, route table, NAT gateway, or
DynamoDB VPC endpoint. An enabled deployment supplies:

- one existing VPC;
- a public gateway subnet with an active `0.0.0.0/0` route to an internet
  gateway;
- a distinct Lambda subnet in the same VPC and availability zone;
- the Lambda subnet's effective route table and primary IPv4 CIDR; and
- DynamoDB access from the Lambda subnet through an active NAT default route
  or a DynamoDB gateway endpoint associated with its effective route table.

Neither subnet may overlap `10.200.0.0/24`. The Lambda route table must not
already contain a route for `10.200.0.0/24`, except when that route belongs to
the existing enabled deployment of this stack. Attaching Lambda to a public
subnet does not give it Internet access through the subnet's internet gateway.

For a small development VPC, the recommended topology is a dedicated `/28`
Lambda subnet in the gateway subnet's availability zone, automatic public IPv4
assignment disabled, an explicitly associated route table containing only the
VPC-local route, and a DynamoDB gateway endpoint associated only with that
route table. These supporting resources remain operator-owned outside the SAM
stack.

## 4. Template parameters and conditions

The TigerBeetle endpoint parameters are always present; the remaining template
interface controls the optional managed gateway:

| Parameter | Behavior |
| --- | --- |
| `TigerBeetleClusterId` | Unsigned 128-bit decimal cluster ID; defaults to `0`. |
| `TigerBeetleAddresses` | Comma-separated replica addresses; defaults to `10.200.0.2:3000`. |
| `EnableWireGuardGateway` | `true` creates the gateway and VPC-attaches execution; defaults to `false`. |
| `RetainExecutionVpcCleanupResources` | Internal `deploy.sh` switch used only between detach and cleanup phases; defaults to `false`. |
| `VpcId` | Existing VPC containing both subnets. |
| `GatewayPublicSubnetId` | Existing public subnet for the EC2 gateway. |
| `LambdaSubnetId` | Distinct existing subnet for execution Lambda. |
| `LambdaRouteTableId` | Effective route table for `LambdaSubnetId`. |
| `LambdaSubnetCidr` | Primary IPv4 CIDR for `LambdaSubnetId`. |
| `WireGuardPrivateKeyParameterName` | Absolute SSM path of the gateway private-key `SecureString`. |
| `WireGuardPrivateKeyParameterVersion` | Exact positive version retrieved at bootstrap; template default is `1`. |
| `WireGuardGatewayPublicKey` | Padded Base64 public key matching that private-key version. |
| `WireGuardWorkstationPublicKey` | Padded Base64 public key matching the workstation-owned private key. |
| `WireGuardAmiId` | Public SSM parameter resolving to an ARM64 AMI. |
| `WireGuardInstanceType` | ARM64 EC2 instance type; defaults to `t4g.nano`. |

When `EnableWireGuardGateway=true`, a CloudFormation rule requires every
gateway input. A second rule requires `VpcId` while cleanup resources are
retained. Empty defaults are therefore safe when both switches are false.
`deploy.sh` performs the stronger live topology and SSM checks described below;
a direct SAM deployment does not perform those discovery checks.

## 5. Stack-owned resources

The always-present execution role is explicit so its VPC permission can be
retained safely during detach. The optional resources are:

| Logical resource | Type | Creation condition |
| --- | --- | --- |
| `ExecutionLambdaSecurityGroup` | `AWS::EC2::SecurityGroup` | Gateway enabled or cleanup resources retained |
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
stack-managed execution security group while the gateway is enabled. It has no
VPC attachment in steady disabled state.

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
- TCP/443 egress to `0.0.0.0/0` for DynamoDB through the subnet's NAT or VPC
  endpoint path.

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

## 8. `deploy.sh` resolution and preflight

Enable the feature with `--enable-wireguard-gateway` or
`ENABLE_WIREGUARD_GATEWAY=1`. The environment value accepts only `0` or `1`.
Omitting explicit enablement requests the disabled state even when the existing
stack is enabled.

For enabled deployments, values resolve in this order:

1. CLI option;
2. environment variable;
3. matching value from an existing stack only when that stack has
   `EnableWireGuardGateway=true`; and
4. network discovery, the external default SSM pair, or the instance-type
   default as applicable.

The helper inspects available IPv4 subnet pairs. A candidate must use distinct
subnets in one VPC and availability zone, avoid the WireGuard CIDR, provide an
Internet-gateway default route for the gateway, and provide a NAT or DynamoDB
gateway-endpoint path for Lambda. Explicit VPC or subnet inputs constrain the
candidate set. `LAMBDA_SUBNET_CIDR` and `LAMBDA_ROUTE_TABLE_ID` are assertions
against the selected subnet's live values.

Discovery proceeds only when exactly one pair matches. Multiple matches are
printed and require one or both subnet options. With no match, the helper
prints rejection counts for gateway routing, Lambda DynamoDB access, CIDR
overlap, subnet identity, VPC, and availability zone. AWS inspection failures
are reported separately rather than counted as topology rejections.

Before deployment, the helper rechecks the VPC/subnet relationships, same-AZ
constraint, effective route tables, gateway Internet route, Lambda DynamoDB
path, CIDRs, and conflicting WireGuard route. An existing WireGuard route is
accepted only when the current enabled stack owns that route and target
instance.

With a unique topology and the default SSM paths, first enablement therefore
needs only the workstation public key in addition to the normal PASETO inputs:

```sh
WIREGUARD_WORKSTATION_PUBLIC_KEY="$wireguard_workstation_public_key" \
./deploy.sh --enable-wireguard-gateway
```

Use explicit subnet options when discovery is ambiguous:

```sh
./deploy.sh \
  --enable-wireguard-gateway \
  --gateway-public-subnet-id '<gateway-public-subnet-id>' \
  --lambda-subnet-id '<lambda-subnet-id>' \
  --wireguard-workstation-public-key "$wireguard_workstation_public_key"
```

## 9. Key ownership and lifecycle

The workstation private key is generated and retained only on the workstation.
Only its padded Base64 public key is passed to deployment.

By default, `deploy.sh` uses this operator-owned external pair:

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

Before any non-dry-run build, `deploy.sh` clears inherited static AWS credential
variables, exports the selected SSO-backed profile, and unconditionally runs
`aws sso login` to obtain a fresh access token. Login happens before stack
inspection or other AWS discovery, and a failure stops the deployment;
non-SSO profiles are unsupported. Dry runs make no AWS authentication calls.
The helper stops before local work when the stack status ends in
`_IN_PROGRESS`.

The helper then runs Zig formatting and tests, builds all three Linux ARM64
bootstraps, refreshes their zip archives, and runs both SAM validations. An
enabled deployment uses one SAM update with the resolved gateway parameters.
After success, the helper prints the seven conditional gateway outputs and
continues with the DynamoDB, SQS, and optional Function URL checks.

Intake and query are stripped, statically linked executables. Execution is
multithread-capable for the native TigerBeetle callback thread and is a stripped
ARM64 glibc executable reported as dynamically linked; Amazon Linux 2023
provides its dynamic loader and system libraries.

Running `deploy.sh` later without explicit gateway enablement disables an
enabled gateway with two CloudFormation updates:

1. Set `EnableWireGuardGateway=false` and
   `RetainExecutionVpcCleanupResources=true`. This removes the execution VPC
   attachment, gateway, Elastic IP, route, launch resources, and gateway
   security group while retaining the execution security group and the role's
   ENI-deletion permission.
2. Wait up to approximately 20 minutes for the current execution function and
   every published version to have no VPC configuration and for no ENI to use
   the retained security group.
3. Set `RetainExecutionVpcCleanupResources=false`, removing the retained group
   and VPC-access policy.

If the bounded wait fails, the second update is not attempted. Rerun
`deploy.sh` after CloudFormation is no longer in progress; it recognizes the
retained state and resumes the guarded wait. Never start another deployment
while CloudFormation still reports an `_IN_PROGRESS` state.

Gateway disablement does not disable the SQS event-source mapping. Execution
continues consuming and uses `TigerBeetleAddresses`; provide another reachable
trusted endpoint or expect TigerBeetle timeouts to return per-record retries.

`--dry-run` checks the syntax of supplied gateway inputs but deliberately skips
AWS discovery, SSM inspection or generation, topology preflight, and deployment.
It still formats, tests, builds, packages, and validates locally.

Direct SAM deployment requires every gateway input to resolve to a non-empty
value; the template supplies defaults only for the private-key version, AMI,
and instance type. It does not provide `deploy.sh` discovery, key generation,
enabled-stack value reuse, or guarded disablement. Do not use a single direct
SAM update to disable an enabled stack; use `deploy.sh` or manually reproduce
both detach and cleanup phases with the same Lambda-version and ENI checks.

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

Combine them with the locally retained workstation private key and the selected
`LambdaSubnetCidr`:

```ini
[Interface]
Address = <WireGuardWorkstationAddress>
PrivateKey = <workstation-private-key>

[Peer]
PublicKey = <WireGuardGatewayPublicKey>
Endpoint = <WireGuardGatewayEndpoint>
AllowedIPs = <LambdaSubnetCidr>
PersistentKeepalive = 25
```

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
4. Verify the VPC route target, `SourceDestCheck=false`, both security groups,
   and the execution Lambda VPC configuration.
5. Pre-provision TigerBeetle account `1` on ledger `1` with flags compatible
   with receiving credits. Submit a unique valid Operation and verify that
   execution creates account `Operation.id`, posts transfer `Operation.id` for
   amount `100` from that account to account `1`, then marks DynamoDB
   `SUCCEEDED`. A duplicate delivery must replay both IDs as identical
   `exists` without changing balances a second time.
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
| Execution loses DynamoDB access | NAT route or DynamoDB gateway endpoint associated with the Lambda route table |
| SSM or bootstrap fails | Gateway Internet route, instance role, cloud-init output, and exact SSM parameter name/version |

Cloud handshake, routing, reboot recovery, rotation, and TigerBeetle checks are
not performed by local validation and must not be reported as complete until an
operator explicitly authorizes and runs them.

## 13. Ownership and teardown

The SAM stack owns the execution VPC attachment, both conditional security
groups, gateway role and instance profile, launch template, EC2 instance,
Elastic IP and association, and the `10.200.0.0/24` route.

The operator owns the existing VPC, subnets, Lambda route table, NAT or
DynamoDB endpoint, and external gateway SSM pair. The workstation owns its
WireGuard configuration and private key, local firewall policy, and
TigerBeetle process and data.

Disabling the gateway removes only the stack-owned optional resources after the
guarded ENI cleanup. Deleting an enabled stack also removes those stack-owned
resources. Neither operation deletes the external SSM parameters, supporting
network, workstation keys, or TigerBeetle data. Delete those separately only
after confirming they will not be reused.

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
