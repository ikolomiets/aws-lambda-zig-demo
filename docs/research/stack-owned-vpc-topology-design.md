# Stack-owned dual-stack VPC topology

Status: follow-up architectural note, 2026-08-30. This document describes a
possible evolution of the current implementation. It does not change the SAM
template, deployment helpers, tests, or AWS resources.

## Decision summary

Move the optional WireGuard topology into the same SAM/CloudFormation stack as
the Lambdas. When the WireGuard feature is enabled, the stack should create and
own:

- one application VPC;
- one IPv4 public subnet for the WireGuard EC2 gateway;
- one dual-stack private subnet for the execution Lambda;
- separate public and private route tables and explicit subnet associations;
- the VPC's internet gateway (IGW), egress-only internet gateway (EIGW), and
  their required routes; and
- the existing execution and gateway security groups.

The resulting transport preserves the current design:

```text
internet / workstation
        |
        | IPv4 UDP/51820
        v
stack IGW -> public gateway subnet -> WireGuard EC2 + Elastic IP
                                      |
                                      | routed IPv4 TCP/3000
                                      v
                              workstation TigerBeetle

execution Lambda -> private dual-stack subnet
        |                    |
        | IPv4              | IPv6 TCP/443
        v                    v
10.200.0.0/24 route       ::/0 route -> stack EIGW -> SQS dual-stack endpoint
to WireGuard EC2
```

The public gateway subnet is intentionally IPv4-only. The gateway already needs
an Elastic IP for the workstation tunnel and IPv4 internet access for bootstrap
and Systems Manager. Giving it public IPv6 would add a second public exposure
path with no current use. The execution subnet is dual-stack because Lambda
requires both an IPv4 and IPv6 CIDR when `Ipv6AllowedForDualStack` is enabled;
Lambda does not support this outbound mode from an IPv6-only subnet
([Lambda VPC and IPv6 behavior](https://docs.aws.amazon.com/lambda/latest/dg/configuration-vpc.html)).

This design removes the external identifier parameters `VpcId`,
`GatewayPublicSubnetId`, `LambdaSubnetId`, `LambdaRouteTableId`, and
`LambdaSubnetCidr`. The stack may still accept high-level design inputs such as
an IPv4 VPC CIDR or Availability Zone; accepting configuration is different
from accepting infrastructure that another owner creates and deletes.

## Scope and availability boundary

The repository is a development/demo topology with one WireGuard EC2 instance,
one execution subnet, and one Availability Zone. Keep both subnets in the same
AZ to preserve the current topology and avoid introducing a cross-AZ dependency.
This is not a production high-availability design: the WireGuard instance,
tunnel, and workstation are all single points of failure. AWS recommends using
multiple Availability Zones for production applications, but making this path
multi-AZ would require multiple gateway/tunnel peers and failover semantics,
not merely more subnets
([VPC configuration options](https://docs.aws.amazon.com/vpc/latest/userguide/create-vpc-options.html)).

Do not add a NAT gateway, SQS interface endpoint, public IPv4 default route to
the Lambda subnet, or public IPv6 route to the gateway subnet. Those would
change the current cost or security boundary.

## Address plan

Use one `/16` RFC 1918 IPv4 CIDR, defaulting to an application-specific range
such as `10.42.0.0/16`, and derive two `/24` subnets from it:

| Network | Example | Purpose |
| --- | --- | --- |
| VPC IPv4 | `10.42.0.0/16` | Stack-owned private address space |
| Public gateway subnet | `10.42.0.0/24` | WireGuard EC2, Elastic IP, IGW route |
| Private execution subnet | `10.42.1.0/24` | Lambda Hyperplane ENIs and the WireGuard route |
| WireGuard tunnel | `10.200.0.0/24` | Existing out-of-VPC tunnel network; unchanged |
| TigerBeetle peer | `10.200.0.2/32` | Existing routed destination; unchanged |

Deriving subnet CIDRs with `Fn::Cidr` prevents overlap between the two VPC
subnets. For a `/16`, `!Cidr [<vpc-cidr>, 2, 8]` produces two `/24` values. The
implementation must validate that the selected VPC CIDR does not overlap the
fixed `10.200.0.0/24` tunnel or any network to which this VPC will later be
peered or otherwise connected. `Fn::Cidr` is documented to return a bounded
array of subnet CIDRs
([CloudFormation `Fn::Cidr`](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/intrinsic-function-reference-cidr.html)).

A `/24` is intentionally larger than the current manually documented `/28`.
Lambda creates and scales managed Hyperplane ENIs for the selected
subnet/security-group combination, so leaving address headroom avoids coupling
function scaling or future resources to a very small subnet
([Lambda Hyperplane ENIs](https://docs.aws.amazon.com/lambda/latest/dg/configuration-vpc.html#configuration-vpc-enis)).
AWS also reserves addresses in every IPv4 subnet
([VPC subnet sizing](https://docs.aws.amazon.com/vpc/latest/userguide/subnet-sizing.html)).

For IPv6, create an `AWS::EC2::VPCCidrBlock` with
`AmazonProvidedIpv6CidrBlock: true`. AWS allocates a public `/56`; the range and
size cannot be selected by the template
([`AWS::EC2::VPCCidrBlock`](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ec2-vpccidrblock.html)).
Derive one `/64` for the execution subnet from the first VPC IPv6 range by using
the same form as AWS's CloudFormation IPv6 example:

```yaml
Ipv6CidrBlock: !Select
  - 0
  - !Cidr
    - !Select [0, !GetAtt ApplicationVpc.Ipv6CidrBlocks]
    - 1
    - 64
```

The subnet must explicitly `DependsOn` the VPC IPv6 CIDR association so that
`ApplicationVpc.Ipv6CidrBlocks` is populated before subnet creation. Set
`AssignIpv6AddressOnCreation: false` (or omit it) because only Lambda's managed
ENI needs IPv6 and `Ipv6AllowedForDualStack` requests that address explicitly;
general-purpose ENIs launched in the subnet should not automatically receive
IPv6. An `AWS::EC2::Subnet` is dual-stack when both `CidrBlock` and
`Ipv6CidrBlock` are specified
([`AWS::EC2::Subnet`](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ec2-subnet.html)).

## CloudFormation resource inventory

An AWS SAM template can contain ordinary CloudFormation resources alongside
SAM shorthand resources, so this does not require a nested network stack
([defining SAM resources](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/authoring-define-resources.html)).
Use logical IDs consistently and reference resources directly rather than
copying physical IDs into parameters.

| Logical role | CloudFormation type | Essential properties and ownership |
| --- | --- | --- |
| Application VPC | `AWS::EC2::VPC` | IPv4 `/16`, `EnableDnsSupport: true`, `EnableDnsHostnames: true`, stack tags |
| VPC IPv6 allocation | `AWS::EC2::VPCCidrBlock` | `VpcId: !Ref ApplicationVpc`, `AmazonProvidedIpv6CidrBlock: true` |
| Public gateway subnet | `AWS::EC2::Subnet` | First derived IPv4 `/24`, selected AZ, `MapPublicIpOnLaunch: false`, no IPv6 CIDR |
| Private execution subnet | `AWS::EC2::Subnet` | Second IPv4 `/24`, first VPC IPv6 `/64`, same AZ, no automatic public IPv4 or general IPv6 assignment |
| Internet gateway | `AWS::EC2::InternetGateway` | Stack tags |
| IGW attachment | `AWS::EC2::VPCGatewayAttachment` | References the VPC and IGW |
| Public route table | `AWS::EC2::RouteTable` | References the VPC |
| Public subnet association | `AWS::EC2::SubnetRouteTableAssociation` | References public subnet and public route table |
| Public IPv4 default route | `AWS::EC2::Route` | `0.0.0.0/0` to the IGW; explicit dependency on the IGW attachment |
| Private route table | `AWS::EC2::RouteTable` | References the VPC |
| Private subnet association | `AWS::EC2::SubnetRouteTableAssociation` | References private subnet and private route table |
| Egress-only internet gateway | `AWS::EC2::EgressOnlyInternetGateway` | References the VPC |
| Private IPv6 default route | `AWS::EC2::Route` | `::/0` to the EIGW in the private route table |
| WireGuard route | existing `AWS::EC2::Route` | `10.200.0.0/24` to the stack-owned gateway instance in the private route table |
| Execution security group | existing `AWS::EC2::SecurityGroup` | References the VPC; IPv4 TCP/3000 to `10.200.0.2/32`, IPv6 TCP/443 to `::/0` |
| Gateway security group | existing `AWS::EC2::SecurityGroup` | References the VPC; existing UDP/51820 and forwarded TigerBeetle rules |
| Gateway launch template | existing `AWS::EC2::LaunchTemplate` | References the stack-owned public subnet and gateway security group |
| Execution Lambda VPC config | existing SAM function property | References the stack-owned private subnet and execution security group; keeps `Ipv6AllowedForDualStack: true` |

`AWS::EC2::VPC` requires an IPv4 CIDR; its `CidrBlock` property is a
replacement property, while its DNS attributes can update without interruption
([`AWS::EC2::VPC`](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ec2-vpc.html)).
CloudFormation has first-class resource types for the
[IGW](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ec2-internetgateway.html),
[IGW attachment](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ec2-vpcgatewayattachment.html),
[EIGW](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ec2-egressonlyinternetgateway.html),
[route tables](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ec2-routetable.html),
[subnet associations](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ec2-subnetroutetableassociation.html),
and [routes](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ec2-route.html).

The template should output the created VPC, subnet, and route-table IDs and the
derived Lambda IPv4 CIDR for diagnostics and workstation configuration. Outputs
are observability conveniences, not inputs or a second ownership path. Replace
uses of `LambdaSubnetCidr` with `!GetAtt ExecutionLambdaSubnet.CidrBlock`,
including the WireGuard security-group rule and the peer configuration output.

## Dependency and routing model

CloudFormation infers creation and reverse deletion order from `Ref`, `GetAtt`,
and `Sub`: a referenced resource is created first and deleted last
([CloudFormation dependencies](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-attribute-dependson.html)).
Use those implicit dependencies for most of the graph and add explicit
`DependsOn` only where readiness is not represented by a property reference:

1. `VpcIpv6CidrBlock` references `ApplicationVpc`.
2. `ExecutionLambdaSubnet` references `ApplicationVpc` and explicitly depends
   on `VpcIpv6CidrBlock` before reading `ApplicationVpc.Ipv6CidrBlocks`.
3. `InternetGatewayAttachment` references the VPC and IGW.
4. `GatewayPublicIpv4DefaultRoute` references the public route table and IGW,
   and explicitly depends on `InternetGatewayAttachment`. AWS uses this exact
   dependency pattern for a route to an IGW
   ([`AWS::EC2::Route` example](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ec2-route.html#aws-resource-ec2-route--examples)).
5. `ExecutionEgressOnlyInternetGateway` references the VPC, and
   `ExecutionSqsIpv6Route` references both the private route table and EIGW.
6. The gateway launch template references the public subnet and security group.
7. The execution Lambda references the private subnet and execution security
   group.
8. `WireGuardLambdaRoute` references the private route table and gateway
   instance and retains its existing readiness dependency on the gateway's
   Elastic IP association.

Also make the `WireGuardGatewayInstance` and `WireGuardGatewayElasticIp`
explicitly depend on `InternetGatewayAttachment`. The instance requests a
public IPv4 address in its launch-template network interface, and CloudFormation
requires an EIP associated with a same-template VPC to depend on that VPC's
gateway attachment
([`AWS::EC2::EIP`](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ec2-eip.html)).

Use explicit custom route tables for both subnets. AWS associates an otherwise
unassociated subnet with the VPC's main route table, but explicit associations
make the effective routes deterministic and allow the custom route tables to be
deleted cleanly after their associations are removed
([VPC subnet route tables](https://docs.aws.amazon.com/vpc/latest/userguide/subnet-route-tables.html)).

The public route table contains the VPC-local route and `0.0.0.0/0 -> IGW`.
That route, plus the gateway's Elastic IP, makes this an IPv4 public subnet. An
IGW itself has no hourly charge
([internet gateway behavior and pricing](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Internet_Gateway.html)).

The private route table contains the VPC-local IPv4 and IPv6 routes,
`10.200.0.0/24 -> WireGuard EC2`, and `::/0 -> EIGW`. It deliberately has no
IPv4 internet default route. An EIGW is stateful, supports outbound IPv6 and
return traffic, prevents internet-initiated IPv6 connections, and cannot have a
security group attached
([EIGW behavior](https://docs.aws.amazon.com/vpc/latest/userguide/egress-only-internet-gateway.html)).

AWS permits only one EIGW attached to a VPC at a time. A newly created
stack-owned VPC cannot contain an unmanaged EIGW, so the current
operator-owned-topology conflict preflight disappears. Deployment still needs enough
regional VPC, IGW, and EIGW quota; the default EIGW and IGW quotas are tied to the
regional VPC quota
([Amazon VPC quotas](https://docs.aws.amazon.com/vpc/latest/userguide/amazon-vpc-limits.html)).

## DNS, security groups, and network ACLs

Set both `EnableDnsSupport` and `EnableDnsHostnames` explicitly to `true`.
`EnableDnsSupport` enables queries to the Route 53 Resolver; setting both also
supports Amazon-provided DNS names. The resolver is available through VPC-local
addresses, including the VPC base address plus two
([Amazon VPC DNS](https://docs.aws.amazon.com/vpc/latest/userguide/AmazonDNS-concepts.html)).
The execution SDK must retain `AWS_USE_DUALSTACK_ENDPOINT=true` while it is
VPC-attached so the SQS hostname resolves to the public dual-stack service
endpoint used by the current implementation. SQS publishes regional endpoints that
resolve over IPv4 and IPv6, and the standard SDK environment setting opts into dual-stack
endpoint selection
([SQS dual-stack endpoints](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dual-stack.html),
[SDK endpoint setting](https://docs.aws.amazon.com/sdkref/latest/guide/feature-endpoints.html)).

Keep the existing least-privilege security groups rather than using the default
security group:

- execution: no ingress; outbound IPv4 TCP/3000 only to `10.200.0.2/32`; outbound
  IPv6 TCP/443 to `::/0`;
- gateway: public IPv4 UDP/51820 ingress; forwarded IPv4 TCP/3000 ingress only
  from the derived Lambda subnet CIDR; existing IPv4 egress needed for package
  installation, Systems Manager, Parameter Store, and the tunnel.

Security groups are stateful, so response traffic for an allowed request does
not need a reverse rule
([VPC security groups](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html)).
The `::/0` HTTPS rule is still broader than SQS at the network layer; IAM remains
the precise service/action/queue boundary. The EIGW prevents unsolicited inbound
IPv6 but does not restrict the Lambda to SQS destinations.

For the first implementation, use the default network ACL created with the VPC
and do not mutate it. The default ACL allows all IPv4 and IPv6 traffic in both
directions, while the security groups enforce the application boundary
([default network ACL](https://docs.aws.amazon.com/vpc/latest/userguide/default-network-acl.html)).
This keeps the small repository from duplicating stateful security-group policy
in stateless rules and removes the current implementation's need to interpret an externally
managed ACL.

If literal template ownership of every ACL rule is required, add a custom
`AWS::EC2::NetworkAcl`, four allow-all IPv4/IPv6
`AWS::EC2::NetworkAclEntry` resources, and explicit
`AWS::EC2::SubnetNetworkAclAssociation` resources for both subnets. That is
declarative but provides no stronger restriction than the default. A later
least-privilege ACL must explicitly allow both request and return paths because
ACLs are stateless, and must preserve ICMPv6 Packet Too Big for Path MTU
Discovery
([network ACL semantics](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-network-acls.html),
[Path MTU Discovery](https://docs.aws.amazon.com/vpc/latest/userguide/path_mtu_discovery.html)).
Security groups and network ACLs cannot block DNS to the Route 53 Resolver; use
Route 53 Resolver DNS Firewall if DNS filtering ever becomes a requirement.

## Conditions, ownership, and deletion lifecycle

Reuse the existing `ExecutionVpcCleanupResourcesRetained` condition:

```text
ExecutionVpcCleanupResourcesRetained =
    EnableWireGuardGateway OR RetainExecutionVpcCleanupResources
```

Apply it to the entire stack-owned topology: VPC, IPv6 association, both
subnets, both route tables and associations, IGW and attachment, EIGW, default
routes, execution security group, and any custom ACL resources. Gateway compute,
Elastic IP, gateway security group, and the WireGuard route remain conditioned
only on `EnableWireGuardGateway`. This yields three intentional states:

| Gateway | Retain cleanup | Result |
| --- | --- | --- |
| `true` | either | Full topology and gateway are active; execution is VPC-attached |
| `false` | `true` | Gateway is gone and execution is detached, but topology/IAM needed for ENI cleanup remain |
| `false` | `false` | Optional topology and cleanup IAM are deleted |

Use explicit `DeletionPolicy: Delete` and `UpdateReplacePolicy: Delete` for the
topology. Do not use `Retain`: retained VPC components would become unmanaged
orphans and could continue to block quotas or incur charges. CloudFormation
deletes resources by default, while a retained replacement leaves the old
resource outside CloudFormation's scope
([`DeletionPolicy`](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-attribute-deletionpolicy.html),
[`UpdateReplacePolicy`](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-attribute-updatereplacepolicy.html)).
The condition, not a retention policy, supplies the temporary cleanup hold.

Keep the existing guarded-detach state machine. Lambda can take up to
20 minutes to delete a Hyperplane ENI after VPC detachment and will not delete
an ENI still used by another function or published version. It also needs the
execution role's ENI permissions during cleanup
([Lambda ENI lifecycle](https://docs.aws.amazon.com/lambda/latest/dg/configuration-vpc.html#configuration-vpc-enis)).
CloudFormation waits for Lambda-created ENIs before deleting a same-stack VPC
only when the stack operation identity has `ec2:DescribeNetworkInterfaces`
([Lambda `VpcConfig`](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-properties-lambda-function-vpcconfig.html)).

The safe disable/delete order is therefore:

1. Deploy gateway disabled with retention enabled; detach execution and delete
   gateway compute while keeping the complete network and ENI-management IAM.
2. Wait for the function configuration, all published versions, and the bounded
   set of Lambda-created ENIs to detach or disappear.
3. Deploy with both flags false. References order deletion from Lambda/SG and
   routes through associations/gateways/subnets to the VPC.
4. Clear saved optional high-level inputs only after the final update succeeds.

On timeout or AWS error, leave retention enabled. Do not attempt to delete the
VPC, subnet, route table, security group, or execution role underneath a live
Lambda ENI. Direct stack deletion must also be tested because out-of-band ENIs,
routes, or gateway attachments can cause `DELETE_FAILED`; that failure is safer
than silently orphaning a dependency. AWS requires the dependent VPC resources
to be removed before the VPC itself can be deleted
([delete a VPC](https://docs.aws.amazon.com/vpc/latest/userguide/delete-vpc.html)).

## Replacement risks and topology changes

Treat VPC CIDR or Availability Zone changes as destructive topology changes,
not ordinary parameter updates. `AWS::EC2::VPC.CidrBlock`, subnet VPC/AZ
properties, route-table VPC IDs, EIGW VPC ID, and subnet association targets
can require replacement. CloudFormation normally creates a replacement first,
switches references, and then deletes the old resource
([CloudFormation update behavior](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-updating-stacks-update-behaviors.html)).
For overlapping CIDRs, per-VPC gateway quotas, Lambda ENIs, and route
associations, that generic sequence is not a safe migration contract.

Require the helper to reject an in-place change to the VPC CIDR or selected AZ
while the feature or cleanup retention is active. Perform the existing guarded
disable to reach the no-topology state, then enable with the new values. This
creates an explicit maintenance window and new gateway Elastic IP; the
workstation WireGuard peer must be refreshed after re-enable.

Always preview topology updates with a CloudFormation change set and inspect
every `Replacement: True` or conditional deletion before execution
([CloudFormation change sets](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-updating-stacks-changesets.html)).

## Staged migration from the operator-owned topology

### Recommended: clean cutover to a newly created VPC

Do not try to make CloudFormation adopt the external VPC during the same update
that changes Lambda and gateway references. Use this staged, reversible path:

1. **Baseline the current implementation.** Run all repository-local checks and, only in a
   separately authorized deployment, verify the existing external dual-stack
   topology, WireGuard/TigerBeetle path, and SQS completion send.
2. **Drain the old optional deployment with the existing implementation.** Use
   the existing guarded disable. Confirm execution and all versions are
   detached, Lambda ENIs are gone, and the stack-owned old-VPC EIGW, routes,
   security groups, EC2 gateway, and Elastic IP have been deleted. The external
   VPC/subnets/routes/IPv6 associations remain untouched.
3. **Deploy the ownership change while disabled.** Add the stack-owned topology,
   remove ID parameters and discovery logic, and update docs/tests. Deploy with
   both feature flags false so no new VPC is created yet. This proves the core
   four-Lambda stack remains healthy independently of optional networking.
4. **Create the new topology.** Enable WireGuard. CloudFormation creates the VPC
   graph, gateway, and Lambda attachment in dependency order. Capture the new
   Elastic IP and regenerate/update the workstation peer configuration.
5. **Run transport acceptance.** Verify the WireGuard handshake and
   TigerBeetle operation, then verify execution sends the aggregate Completion
   message over the SQS dual-stack endpoint and completion persists it.
6. **Retire the old external topology separately.** If it was exclusively for
   this demo, inventory it and delete it only through an explicit,
   operator-authorized procedure. It was never in the stack, so the new template
   must not claim or delete it. If it contains any unrelated workload, leave it.

This migration has an intentional WireGuard/execution maintenance window. Intake
can continue to enqueue work, but execution should be disabled or allowed to
retry rather than pointed at a half-migrated route.

### Import alternative: possible but not recommended

CloudFormation resource import can adopt existing VPC resources without
recreating them, and AWS currently lists VPC, subnet, route, route table, IGW,
EIGW, and related association types among import-capable resources
([resource-type support](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/resource-import-supported-resources.html)).
However, an import operation cannot also create, delete, or change resource
properties; every imported resource needs a `DeletionPolicy`; CloudFormation
validates schema and identity but does not verify that the template matches the
live configuration; and AWS recommends drift detection immediately afterward
([manual resource import](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/import-resources-manually.html)).

For this SAM stack, perform such an import through the AWS CLI; the
CloudFormation console does not support resource import for templates that use
`Fn::Transform`
([importing into an existing stack](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/resource-import-existing-stack.html)).
Import therefore requires a separate, resource-by-resource migration plan,
current-region support verification, exact identifiers, matching routes and
associations, temporary `Retain` policies, and a post-import drift review. It
must not attempt to import or create a second EIGW while the current stack's
stack-owned EIGW occupies the VPC's one-gateway slot. An import design must keep
that logical resource attached to the adopted VPC or delete it before creating
a replacement. Use import only when preserving the exact VPC and subnet IDs is
a hard requirement and accept the extra operational complexity.

## Rollback strategy

Rollback must distinguish application rollback from topology rollback:

- **Before new-VPC enablement:** restore the prior template/helper and re-enable
  against the still-existing external topology. No new VPC exists to clean up.
- **During failed new-VPC creation:** allow CloudFormation to roll back. Confirm
  the stack returns to its prior disabled state and check for orphaned Elastic
  IPs, ENIs, IGWs, EIGWs, subnets, and route tables before retrying.
- **After successful enablement:** roll application code or configuration back
  within the new VPC when possible. Do not roll the topology template backward
  under a live execution Lambda.
- **To return to the external topology:** guarded-disable and delete the new
  stack-owned topology first, deploy the prior disabled template, then re-enable
  with the external IDs. This is another maintenance-window operation.

Never use `UpdateReplacePolicy: Retain` as a rollback shortcut for VPC
components: retained replacements leave unmanaged resources and potentially an
Elastic IP charge. If an update reaches `UPDATE_ROLLBACK_FAILED`, repair the
specific dependency and continue rollback rather than manually deleting live
Lambda networking.

## Implementation impact

This should be a separate follow-up change, not folded into the current
implementation.

### `template.yaml`

- Add the resource graph in the inventory above.
- Remove the five external topology ID/CIDR parameters and their Rules.
- Reference stack resources from both security groups, the launch template,
  Lambda `VpcConfig`, routes, and outputs.
- Put the whole topology on `ExecutionVpcCleanupResourcesRetained` and preserve
  the narrower `WireGuardGatewayEnabled` condition for gateway compute.
- Add explicit delete policies and tags; do not add NAT or endpoint resources.

### Deployment helpers

- Remove subnet-pair discovery and all validation of external VPC/subnet/route
  ownership, IPv6 associations, DNS attributes, ACL policy, unmanaged EIGWs,
  and conflicting external `::/0` routes.
- Replace that surface with local validation of the high-level IPv4 CIDR and AZ,
  a preflight quota check where practical, and exact verification of current
  stack-owned physical resources during reconfigure/cleanup.
- Keep guarded detach, published-version checks, Lambda ENI draining, failure
  retention, and peer-configuration output.
- Treat CIDR/AZ changes as a required guarded teardown followed by re-enable.

### Tests and documentation

- Add static template assertions for every reference, condition, route target,
  DNS attribute, derived CIDR, and absence of the old parameters.
- Replace mocked external-topology discovery cases with stack-resource
  readback, quota failure, topology-change rejection, create/disable/delete,
  timeout, and rollback fixtures.
- Keep credential-free helper tests; no test should create a live VPC.
- Update `AGENTS.md`, the main deployment guide, the focused WireGuard guide,
  README resource inventory, and cleanup/private-detail guidance in the same
  implementation sequence.

## Validation and acceptance

### Local and credential-free

Run the repository's normal formatting, shell, Zig, release-build, and
deployment-helper tests, plus:

```sh
sam validate --template-file template.yaml --region ca-central-1
sam validate --lint --template-file template.yaml --region ca-central-1
```

Static/mocked tests should prove:

- there are no external topology ID parameters or SAM overrides;
- the `/24` IPv4 subnets and execution `/64` are derived from their VPC ranges;
- the execution subnet waits for the VPC IPv6 association;
- the public route targets the IGW only after attachment;
- the private IPv6 route targets the stack EIGW and no private IPv4 default
  route exists;
- gateway and Lambda resources reference the correct stack-owned subnets and
  security groups;
- all topology resources survive retained detach and disappear only in the
  final cleanup phase; and
- timeout/error paths cannot delete networking under Lambda ENIs or versions.

### Separately authorized AWS validation

No live validation belongs to the architecture/implementation sessions. In a
later authorized disposable-stack exercise:

1. Create and inspect a CloudFormation change set before executing it.
2. Read back VPC DNS attributes, IPv4/IPv6 associations, subnet CIDRs, effective
   route tables, IGW/EIGW attachments, routes, security groups, and network ACL.
3. Confirm `sqs.<region>.api.aws` has an IPv6 result in the supported Region and
   that the execution Lambda can send only through the configured dual-stack
   path.
4. Verify WireGuard bootstrap/SSM registration, workstation handshake,
   TigerBeetle TCP/3000 routing, the Completion SQS send, and completion
   persistence.
5. Exercise guarded disable, ENI/version waits, final cleanup, and failure
   recovery.
6. Delete the disposable stack and confirm no stack-owned ENI, Elastic IP, IGW,
   EIGW, subnet, route table, or VPC remains.
7. Run CloudFormation drift detection after migration or import. Drift detection
   reports resources whose actual properties differ from the template
   ([CloudFormation drift detection](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-stack-drift.html)).

## Cost effect

The ownership change does not introduce a NAT gateway or interface endpoint.
AWS charges nothing for the IGW itself and nothing for the EIGW itself, although
ordinary transfer charges can apply
([IGW pricing](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Internet_Gateway.html),
[EIGW pricing](https://docs.aws.amazon.com/vpc/latest/userguide/egress-only-internet-gateway.html)).
Same-Region transfers to and from SQS are not charged by SQS
([SQS pricing](https://aws.amazon.com/sqs/pricing/)).

Existing conditional costs remain: the WireGuard EC2 instance, SQS/Lambda
requests and compute, logs, and its public IPv4 address. AWS currently charges
USD 0.005 per hour for an in-use or idle public IPv4 address, including an
Elastic IP; verify current regional EC2 and public IPv4 prices at implementation
and deployment time
([Amazon VPC pricing](https://aws.amazon.com/vpc/pricing/)).
Because the topology is conditional, a failed teardown that leaves an Elastic
IP or instance behind can continue to cost money even if application traffic
has stopped.

## Risks and open decisions

1. **CIDR input versus fixed CIDR.** A fixed `10.42.0.0/16` is simplest and fully
   deterministic; a parameter is friendlier to future peering. If parameterized,
   implement real CIDR containment/overlap validation in the helper rather than
   relying only on a regex.
2. **Availability Zone selection.** Preserve the current single-AZ contract. A
   parameter is more predictable than relying on the order of `Fn::GetAZs`, but
   it becomes one required high-level input.
3. **Default versus custom network ACL.** The default allow-all ACL plus
   least-privilege security groups is the recommended small-project choice. A
   custom ACL is needed only if every ACL rule must be explicit in the template
   or subnet-level deny rules are required.
4. **Deletion on disable.** This note keeps the existing feature lifecycle:
   final disable deletes the VPC. Keeping an empty VPC permanently would make
   re-enable faster but consume VPC/IGW/EIGW quota and weaken the meaning of the
   cleanup flag.
5. **Migration method.** New-VPC cutover is recommended. Import preserves IDs
   but adds manual identifiers, temporary retention, drift risk, and a much more
   fragile rollback.
6. **One-EIGW and regional quotas.** One EIGW per new VPC is correct, but account
   regional VPC/IGW/EIGW and Elastic IP quotas can still block creation. Fail
   before deployment where the helper can obtain a clear quota signal, and
   otherwise preserve CloudFormation rollback evidence.
7. **Public IPv6 security boundary.** The Lambda subnet's IPv6 addresses are
   public addresses, but the EIGW blocks unsolicited inbound connections. The
   `::/0` TCP/443 egress rule still permits non-SQS IPv6 HTTPS destinations;
   queue-scoped IAM remains mandatory.

The smallest safe follow-up is therefore a maintenance-window migration to a
new conditional stack-owned VPC, retaining the existing guarded Lambda detach and
dual-stack SQS design while removing all external topology discovery and ID
parameters.
