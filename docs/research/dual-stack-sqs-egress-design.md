# Dual-stack SQS egress through an egress-only internet gateway

Status: implementation design, 2026-08-29. This document describes dual-stack SQS
egress through an egress-only internet gateway; it does not change the template,
deployment helpers, or AWS resources.

## Decision summary

The TigerBeetle processor can send Completion messages to SQS without an SQS interface
endpoint by using SQS's public dual-stack regional endpoint over IPv6:

```text
Operations SQS -- Lambda-managed poller --> TigerBeetle processor
                                               |             \
                                               | IPv4         \ IPv6 HTTPS
                                               v               v
                                        WireGuard route     ::/0 route
                                               |               |
                                               v               v
                                        TigerBeetle       egress-only IGW
                                                               |
                                                               v
                                                    sqs.<region>.api.aws

Completion SQS -- Lambda-managed poller --> Completion processor (not VPC-attached)
```

This preserves the application behavior: TigerBeetle processor still receives Operations
messages through its Lambda event source mapping, communicates with TigerBeetle over the
existing IPv4 WireGuard route, and calls `SendMessage` once for the aggregate Completion
message. Only the final SDK call needs the new IPv6 path.

The recommended ownership boundary is:

- The operator owns the existing VPC, the Lambda subnet's IPv6 CIDR association, the
  VPC's IPv6 CIDR association, and the VPC's egress-only internet gateway (EIGW).
- SAM owns the TigerBeetle processor `::/0` route in `LambdaRouteTableId`, the TigerBeetle processor
  Lambda's dual-stack setting, its SDK endpoint setting, and its IPv6 security-group
  egress rule.
- The deployment helper validates the external topology before deploying and passes the
  discovered EIGW ID as an explicit stack parameter.
- Teardown removes only the SAM-owned route and TigerBeetle processor security group. It never
  removes the operator-owned EIGW or IPv6 associations.

This design replaces the previously considered `ExecutionSqsInterfaceEndpoint` with
explicit dual-stack topology validation, ownership-aware IPv6 egress preflight, and
guarded route and security-group cleanup.

## Why it works

### The source queue does not need function-subnet egress

The `TigerBeetleProcessorQueueMapping` is a Lambda event source mapping. AWS's
Lambda-managed poller reads the TigerBeetle queue and invokes TigerBeetle processor; the TigerBeetle processor
code does not poll that queue through its VPC network. AWS documents this polling model
in [Using Lambda with Amazon SQS](https://docs.aws.amazon.com/lambda/latest/dg/with-sqs.html).

The outbound requirement appears when TigerBeetle processor changes from updating DynamoDB to calling
`SendMessage` on `CompletionQueue`. The template grants that action and supplies
`COMPLETION_QUEUE_URL`; the completion consumer remains outside the VPC. Consequently,
only the TigerBeetle processor function's Completion-queue send needs an SQS network path.

### Lambda can use IPv6 from a dual-stack subnet

AWS Lambda supports outbound IPv6 when every subnet selected in `VpcConfig` is dual-stack
and `Ipv6AllowedForDualStack` is enabled. IPv6-only subnets are not supported. Merely
placing a Lambda in a public subnet does not give the function internet access
([Lambda VPC configuration](https://docs.aws.amazon.com/lambda/latest/dg/configuration-vpc.html),
[Lambda internet access](https://docs.aws.amazon.com/lambda/latest/dg/configuration-vpc-internet.html)).

The repository selects exactly one subnet for TigerBeetle processor while the WireGuard gateway is
enabled ([current `VpcConfig`](../../template.yaml#L365-L373)). That subnet must therefore
have both its existing IPv4 CIDR and an associated IPv6 `/64` from the VPC's IPv6
allocation.

### SQS has a dual-stack regional endpoint

Amazon SQS publishes dual-stack endpoints such as `sqs.ca-central-1.api.aws`; the
authoritative region list is in [Amazon SQS endpoints and quotas](https://docs.aws.amazon.com/general/latest/gr/sqs-service.html).
The standard SDK setting `AWS_USE_DUALSTACK_ENDPOINT=true` requests the dual-stack service
endpoint ([AWS SDK endpoint configuration](https://docs.aws.amazon.com/sdkref/latest/guide/feature-endpoints.html)).

The active vendored Zig AWS SDK already supports this setting. It reads
`AWS_USE_DUALSTACK_ENDPOINT` in
[`config.zig`](../../zig-pkg/aws_sdk-0.0.1-ApQSL17Y_xOC5IhLm247KBZKDcbCRU3qf7GiiiRHcrND/src/config.zig#L182-L185)
and selects the partition's `api.aws` suffix in
[`endpoint.zig`](../../zig-pkg/aws_sdk-0.0.1-ApQSL17Y_xOC5IhLm247KBZKDcbCRU3qf7GiiiRHcrND/src/endpoint.zig#L166-L194).
The setting must be explicit because this SDK defaults dual-stack endpoint selection to
false. The generated SQS `SendMessage` implementation obtains its transport host from
that service endpoint configuration; `queue_url` is serialized into the JSON request
body rather than used as the HTTP host
([`send_message.zig`](../../zig-pkg/aws_sdk-0.0.1-ApQSL17Y_xOC5IhLm247KBZKDcbCRU3qf7GiiiRHcrND/service/sqs/send_message.zig#L263-L279)).

### The EIGW supplies outbound-only public IPv6 routing

An egress-only internet gateway permits connections initiated from inside the VPC and
rejects connections initiated from the internet. It performs no IPv4-to-IPv6 translation;
the Lambda ENI and destination must both use IPv6. The private Lambda route table sends
`::/0` to the EIGW while its existing, more-specific IPv4 route continues to send
`10.200.0.0/24` to the WireGuard gateway
([EIGW behavior](https://docs.aws.amazon.com/vpc/latest/userguide/egress-only-internet-gateway.html)).

## External network prerequisites and ownership

The deployment helper must treat the following as prerequisites, not resources it may
silently create or delete:

1. `VpcId` has an active IPv6 CIDR association. An Amazon-provided IPv6 CIDR is adequate;
   IPAM- or BYOIP-managed space also works if the operator chooses it.
2. `LambdaSubnetId` has an active IPv6 `/64` association belonging to that VPC allocation.
   The subnet remains dual-stack; its IPv4 CIDR and the TigerBeetle path are unchanged.
3. An EIGW has an attachment to `VpcId` whose state is `attached`.
4. `LambdaRouteTableId` is the effective route table for `LambdaSubnetId` and belongs to
   the same VPC.
5. The route table has no unmanaged or conflicting `::/0` route. The stack will own that
   exact destination.
6. VPC DNS resolution and DNS hostnames are enabled.
7. The subnet network ACL permits the IPv6 request and response traffic described below.

AWS allows adding IPv6 to existing VPCs and subnets, but the operation changes shared
network address management and routing. See [Add IPv6 support to a VPC](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-migrate-ipv6-add.html)
and [Associate an IPv6 CIDR block with a subnet](https://docs.aws.amazon.com/vpc/latest/userguide/subnet-associate-ipv6-cidr.html).
It should remain an explicit operator decision rather than an incidental SAM deployment
side effect.

AWS permits only one EIGW per VPC
([Amazon VPC quotas](https://docs.aws.amazon.com/vpc/latest/userguide/amazon-vpc-limits.html)).
A reusable stack must therefore consume the VPC's existing gateway instead of attempting
to create another one. This also prevents stack deletion from removing a shared gateway
used by other subnets.

### Why SAM should not own the EIGW or IPv6 allocations

`AWS::EC2::EgressOnlyInternetGateway` can create an EIGW for a VPC, and CloudFormation can
model VPC/subnet IPv6 associations. That ownership model is appropriate when one stack
creates and exclusively owns the entire VPC. It is not appropriate here because the
repository consumes operator-supplied VPC, subnet, and route-table IDs:

- Creating an EIGW can conflict with the VPC's one-gateway quota.
- Deleting the application stack could break unrelated IPv6 egress.
- Automatically selecting part of a VPC IPv6 allocation can collide with the operator's
  subnet addressing plan.
- Importing pre-existing associations and a gateway expands deployment complexity far
  beyond the current optional WireGuard feature.

The stack should own only the route it needs in the operator-supplied route table.

### One-time operator provisioning outline

For a VPC that does not yet have IPv6, the operator can perform the following conceptual
sequence. These commands mutate shared AWS networking and are examples for an explicitly
authorized maintenance window, not commands for the deployment helper to run:

```sh
aws ec2 associate-vpc-cidr-block \
  --vpc-id <vpc-id> \
  --amazon-provided-ipv6-cidr-block

aws ec2 associate-subnet-cidr-block \
  --subnet-id <lambda-subnet-id> \
  --ipv6-cidr-block <unused-vpc-ipv6-/64>

aws ec2 create-egress-only-internet-gateway \
  --vpc-id <vpc-id>
```

Wait for both CIDR associations and the EIGW attachment to reach their successful states
before enabling the stack. The operator must select a non-overlapping `/64` from the VPC
allocation; do not derive or choose it from unvalidated text in the helper. If the VPC
already has an EIGW, reuse it and omit the create command. Do not manually add the
Lambda route-table `::/0` route, because the proposed SAM resource owns that route.

## Proposed SAM contract

### Parameter and rules

Add one parameter whose value is discovered and validated by the deployment helper:

```yaml
EgressOnlyInternetGatewayId:
  Type: String
  Default: ""
  AllowedPattern: '^$|^eigw-([0-9a-f]{8}|[0-9a-f]{17})$'
  ConstraintDescription: Must be an EC2 egress-only internet gateway ID.
  Description: ID of the existing egress-only internet gateway attached to the VPC.
```

Require this parameter in both cases where `TigerBeetleProcessorVpcCleanupResourcesRetained` is
true:

- normal WireGuard enablement; and
- the guarded Lambda VPC-detach phase.

`VpcId` remains necessary for the TigerBeetle processor security group. `LambdaRouteTableId` remains
necessary for both the WireGuard route during enablement and the IPv6 default route during
retention. `LambdaSubnetId` remains necessary during enablement, but the proposed IPv6
route does not itself depend on the subnet ID.

Rename descriptions that currently refer to a retained DynamoDB endpoint so they instead
refer to retained TigerBeetle processor VPC routing, the security group, and Lambda ENI cleanup
resources.

### TigerBeetle processor function configuration

Add `Ipv6AllowedForDualStack: true` to the enabled branch of TigerBeetle processor's `VpcConfig`:

```yaml
VpcConfig: !If
  - WireGuardGatewayEnabled
  - Ipv6AllowedForDualStack: true
    SecurityGroupIds:
      - !Ref TigerBeetleProcessorSecurityGroup
    SubnetIds:
      - !Ref LambdaSubnetId
  - !Ref AWS::NoValue
```

Add the SDK switch to TigerBeetle processor's environment:

```yaml
AWS_USE_DUALSTACK_ENDPOINT: !If
  - WireGuardGatewayEnabled
  - "true"
  - "false"
```

Using a condition keeps the special endpoint selection coupled to the dual-stack VPC
attachment. When TigerBeetle processor is detached from the VPC, the standard endpoint remains
reachable through Lambda's service-managed networking. Setting the value permanently to
`"true"` would also work in regions where SQS advertises dual-stack support, but coupling
the settings is easier to reason about and fails less surprisingly if this template is
used outside its documented region.

Do not hard-code `ca-central-1` in an endpoint URL and do not set
`AWS_ENDPOINT_URL_SQS`. The standard setting retains the SDK's region, partition, signing,
and endpoint-resolution behavior.

### IPv6 route

Replace `ExecutionDynamoDBGatewayEndpoint` with a conditional route:

```yaml
TigerBeetleProcessorSqsIpv6Route:
  Type: AWS::EC2::Route
  Condition: TigerBeetleProcessorVpcCleanupResourcesRetained
  DeletionPolicy: Delete
  UpdateReplacePolicy: Delete
  Properties:
    RouteTableId: !Ref LambdaRouteTableId
    DestinationIpv6CidrBlock: "::/0"
    EgressOnlyInternetGatewayId: !Ref EgressOnlyInternetGatewayId
```

The CloudFormation form is documented in the
[`AWS::EC2::Route` examples](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/quickref-ec2-vpc.html).
No EIGW resource or output is needed because the gateway is operator-owned. No SQS
endpoint output replaces the obsolete DynamoDB endpoint output.

The route uses `TigerBeetleProcessorVpcCleanupResourcesRetained`, not only
`WireGuardGatewayEnabled`, so it survives the first guarded detach deployment. This keeps
the old Lambda configuration functional while CloudFormation changes TigerBeetle processor's
`VpcConfig` and Lambda-created ENIs and published versions finish detaching.

### TigerBeetle processor security group

Keep the narrowly scoped TigerBeetle rule and replace IPv4 HTTPS egress with IPv6 HTTPS
egress:

```yaml
SecurityGroupEgress:
  - Description: TigerBeetle traffic through the WireGuard gateway.
    IpProtocol: tcp
    FromPort: 3000
    ToPort: 3000
    CidrIp: 10.200.0.2/32
  - Description: HTTPS to AWS dual-stack service endpoints through the EIGW.
    IpProtocol: tcp
    FromPort: 443
    ToPort: 443
    CidrIpv6: "::/0"
```

Removing the `0.0.0.0/0` TCP/443 rule is intentional. It proves that Completion sends do
not depend on an undocumented IPv4 NAT/default route and reduces the TigerBeetle processor ENI's
public IPv4 egress. Do not alter the gateway instance's security group: the TigerBeetle processor
function's SQS traffic does not traverse that instance.

There is no endpoint security group. An EIGW has no security-group attachment and no
endpoint ENIs.

### Resources excluded from the design

The alternative must not add or retain:

- `ExecutionSqsInterfaceEndpoint`;
- a dedicated endpoint security group;
- private DNS on a VPC endpoint;
- an endpoint policy;
- an endpoint ID output; or
- endpoint-ENI discovery or cleanup logic.

It also removes the existing `ExecutionDynamoDBGatewayEndpoint` and its output after the
completion consumer assumes responsibility for DynamoDB updates.

## Deployment-helper preflight

Preflight should be bounded, validate every AWS CLI response before using it, and fail
before `sam deploy` when the topology is ambiguous. It should perform these checks:

1. Validate the supplied VPC, Lambda subnet, and route-table IDs and confirm that all
   belong to the same VPC.
2. Confirm that `LambdaRouteTableId` is the subnet's explicit route table or the VPC main
   route table that actually applies to it.
3. Query the VPC's IPv6 CIDR associations and accept exactly an active association that
   contains the subnet allocation.
4. Query the subnet's IPv6 CIDR associations and accept an active `/64`. Do not require
   the subnet's general-purpose auto-assign-IPv6 setting; Lambda's
   `Ipv6AllowedForDualStack` controls IPv6 for its managed networking.
5. Verify both `enableDnsSupport` and `enableDnsHostnames` on the VPC.
6. Discover EIGWs attached to the VPC. Accept exactly one attached gateway and pass its
   validated `eigw-...` ID to SAM. Reject none, multiple/malformed results, or a gateway
   attached to another VPC.
7. Inspect `LambdaRouteTableId` for `::/0`:
   - accept a healthy route owned by the current stack and targeting the validated EIGW;
   - permit no route before first stack creation; and
   - reject an unmanaged, mismatched, blackhole, or duplicate default route rather than
     importing or overwriting it.
8. Verify the Lambda subnet's network ACL is compatible with IPv6 TCP/443 and return
   traffic, or emit an explicit warning if the helper cannot safely determine effective
   NACL behavior.
9. Confirm that SQS publishes a dual-stack endpoint for the deployment region. A DNS AAAA
   lookup is a useful diagnostic but is not a substitute for the VPC/subnet/EIGW checks.

Representative read-only operator queries are:

```sh
aws ec2 describe-vpcs --vpc-ids <vpc-id>
aws ec2 describe-subnets --subnet-ids <lambda-subnet-id>
aws ec2 describe-route-tables --route-table-ids <lambda-route-table-id>
aws ec2 describe-vpc-attribute --vpc-id <vpc-id> --attribute enableDnsSupport
aws ec2 describe-vpc-attribute --vpc-id <vpc-id> --attribute enableDnsHostnames
aws ec2 describe-egress-only-internet-gateways \
  --filters Name=attachment.vpc-id,Values=<vpc-id>
```

Creating the VPC/subnet IPv6 associations or EIGW is an explicit, operator-authorized
networking operation and is outside the generic helper's responsibility. The helper
should report the missing prerequisite and stop rather than silently mutate it.

### Network ACL expectations

Security groups are stateful, but network ACLs are stateless. A restrictive ACL on the
Lambda subnet must allow, at minimum:

- outbound IPv6 TCP destination port 443 to the intended public IPv6 range (usually
  `::/0` because SQS has no SG-addressable managed prefix list); and
- inbound IPv6 TCP destination ephemeral ports used by the client, conventionally
  1024-65535, for response traffic.

The exact ephemeral range should follow the runtime and the operator's NACL policy. The
default VPC network ACL already allows all traffic, but preflight must not assume that an
operator-supplied subnet uses it.

## Guarded enable, reconfigure, and teardown lifecycle

### Enable

1. The operator establishes the VPC/subnet IPv6 allocations and attaches the VPC's EIGW.
2. The helper validates the full prerequisite set and passes
   `EgressOnlyInternetGatewayId` to SAM.
3. SAM creates the TigerBeetle processor SG and `::/0` route, then configures TigerBeetle processor with the SG,
   subnet, `Ipv6AllowedForDualStack: true`, and the SDK dual-stack switch.
4. Existing `10.200.0.0/24` routing and the WireGuard gateway remain unchanged.

Same-VPC enablement and reconfiguration must be idempotent. A switch to a different VPC,
subnet, route table, or EIGW should use the guarded detach sequence first; it must not
replace network resources beneath attached Lambda ENIs.

### Guarded detach phase

Deploy with `EnableWireGuardGateway=false` and
`RetainTigerBeetleProcessorVpcCleanupResources=true`, preserving at least `VpcId`,
`LambdaRouteTableId`, and `EgressOnlyInternetGatewayId`:

- TigerBeetle processor loses its `VpcConfig` and no longer requires VPC networking;
- the TigerBeetle processor SG remains;
- `TigerBeetleProcessorSqsIpv6Route` remains;
- Lambda ENI-management IAM remains; and
- the external IPv6 associations and EIGW remain untouched.

As in the existing implementation, wait with bounded polling until the TigerBeetle processor
function and all published versions are detached and Lambda-created ENIs using the
TigerBeetle processor SG/subnet have disappeared. There are no endpoint ENIs to classify or exclude.
EIGWs do not create interface endpoint ENIs.

On timeout or an AWS error, stop with retention still enabled. Do not remove the route or
SG while Lambda may still use them.

### Final cleanup phase

After detachment is proven, deploy with both feature flags false. CloudFormation removes
the SAM-owned IPv6 route, TigerBeetle processor SG, and conditional ENI-management IAM. Preserve the
validated route-table and EIGW parameter values through this deploy so deletion is
unambiguous; clear optional saved inputs only after the update succeeds.

Do not delete or disassociate:

- the VPC's IPv6 CIDR;
- the Lambda subnet's IPv6 CIDR; or
- the VPC's EIGW.

Those resources predate or outlive the application stack and may serve other workloads.

## Security properties and tradeoffs

### Properties retained

- The EIGW rejects unsolicited internet-initiated IPv6 connections.
- The TigerBeetle processor SG allows no inbound traffic.
- TigerBeetle remains limited to IPv4 TCP/3000 at `10.200.0.2/32`.
- IAM can remain limited to `sqs:SendMessage` on `CompletionQueue`.
- Completion remains outside the VPC and needs no new networking.

### Properties weaker than an interface endpoint

The SG's `::/0` TCP/443 rule permits TigerBeetle processor code to reach any public IPv6 HTTPS
destination, not only SQS. AWS does not publish an SQS managed prefix list that can be
referenced by an SG. IAM restricts what AWS API actions the function can authorize, but it
is not a general network destination control.

The public dual-stack SQS endpoint also lacks the interface endpoint's additional policy
and `aws:SourceVpce` boundary. Traffic is encrypted with TLS and remains destined for an
AWS service, but it is routed through the public service endpoint rather than PrivateLink.

These differences are reasonable for this small development/demo deployment if avoiding
fixed endpoint cost is the priority. A production environment requiring private-only
service reachability, endpoint policy enforcement, or destination-specific network
control should keep the SQS interface endpoint.

### IAM is unchanged by the route

The EIGW and route require no IAM permission in the TigerBeetle processor role. The role still needs
only the existing `sqs:SendMessage` permission on `CompletionQueue` for this call. Do not
add wildcard SQS actions or resources to compensate for network changes.

## Cost model

AWS does not charge an hourly or per-GB processing fee for an egress-only internet
gateway; ordinary data-transfer rules still apply
([EIGW pricing note](https://docs.aws.amazon.com/vpc/latest/userguide/egress-only-internet-gateway.html)).
This avoids the per-AZ hourly and processing charges of an SQS interface endpoint and the
hourly/processing charges of a NAT Gateway. SQS request charges, Lambda charges, and the
existing WireGuard EC2/EIP costs are unaffected.

The cost advantage is greatest when the optional WireGuard topology remains enabled for
long periods. For short-lived test deployments, an interface endpoint's conditional
hourly cost may be small enough that its stronger network boundary and simpler external
prerequisites are preferable.

## Failure modes and diagnostics

| Failure | Expected symptom | Required response |
| --- | --- | --- |
| VPC has no active IPv6 allocation | Lambda dual-stack configuration or subnet validation fails | Preflight stops and directs the operator to add IPv6 |
| Lambda subnet has no active IPv6 `/64` | Lambda cannot enable dual-stack VPC access | Preflight stops before deploy |
| EIGW is absent or attached to another VPC | No valid `::/0` target | Preflight stops; never substitute an IGW or NAT silently |
| Conflicting `::/0` route exists | CloudFormation route creation would conflict or use the wrong target | Fail closed; operator resolves route ownership |
| Route is blackhole/mismatched | SQS connection times out/fails | Preflight rejects the route; do not deploy |
| `Ipv6AllowedForDualStack` is absent | Lambda ENI has no supported IPv6 egress | Static template test fails |
| SDK dual-stack setting is absent/false | The design no longer explicitly selects the SDK's `api.aws` dual-stack endpoint; current SQS standard endpoints may still be dual-stack | Static template test fails; inspect the resolved host/address without logging secrets |
| SG lacks IPv6 TCP/443 | TLS connection cannot leave the ENI | Static template test and cloud smoke test fail |
| NACL blocks return ephemeral ports | Connection times out despite a correct route and SG | Diagnose NACL and VPC Flow Logs |
| VPC DNS is disabled | SQS hostname resolution fails | Preflight stops with the exact disabled attribute |
| SQS dual-stack endpoint is unavailable in the selected region | SDK resolution fails or returns unsupported-endpoint behavior | Reject the region or use the interface-endpoint design |

The producer's partial-batch behavior should treat a failed Completion send as a failed
source record so SQS retries it. The networking alternative must not weaken that behavior
or acknowledge an Operation before its Completion message is successfully sent.

## Validation plan

### Static and mocked checks

Update repository tests to prove:

- no SQS interface endpoint, endpoint SG, endpoint policy, or endpoint output exists;
- the obsolete DynamoDB gateway endpoint and output are gone;
- TigerBeetle processor's enabled `VpcConfig` contains `Ipv6AllowedForDualStack: true`;
- TigerBeetle processor sets `AWS_USE_DUALSTACK_ENDPOINT` to `"true"` while VPC-attached;
- TigerBeetle processor SG has IPv6 TCP/443 to `::/0`, retains IPv4 TCP/3000 to
  `10.200.0.2/32`, and has no IPv4 public HTTPS rule;
- `TigerBeetleProcessorSqsIpv6Route` is conditional on retained cleanup resources and targets the
  supplied EIGW with exactly `DestinationIpv6CidrBlock: "::/0"`;
- Completion is not VPC-attached;
- helper discovery rejects missing, malformed, multiple, mismatched, or detached EIGWs;
- helper discovery rejects absent/malformed IPv6 associations and unmanaged, blackhole,
  or mismatched default routes;
- detach preserves the route, SG, relevant parameters, and ENI-management IAM;
- only Lambda-created ENIs delay cleanup; no endpoint-ENI branch remains; and
- timeout/error paths leave retained resources in place.

After implementation, run the repository-prescribed local checks:

```sh
bash -n deploy.sh wireguard-gateway-setup.sh lambda_logs.sh tests/*.sh
zig build test-deploy
sam validate --template-file template.yaml --region ca-central-1
sam validate --lint --template-file template.yaml --region ca-central-1
```

### Cloud acceptance test

Cloud-side validation changes AWS resources and must be run only with explicit operator
authorization. In a disposable or approved environment:

1. Verify the Lambda subnet route table has no IPv4 internet/NAT default route.
2. Enable the WireGuard deployment with the validated dual-stack prerequisites.
3. Read back TigerBeetle processor's VPC configuration and confirm
   `Ipv6AllowedForDualStack=true`, the intended subnet, and the intended SG.
4. Submit an Operation that reaches TigerBeetle and produces one Completion message.
5. Confirm the Completion processor consumes it and performs the intended DynamoDB
   transition.
6. Confirm VPC Flow Logs show TigerBeetle processor ENI IPv6 TCP/443 traffic and no dependency on
   IPv4 public HTTPS egress.
7. Exercise guarded disable and verify the route/SG remain until Lambda ENIs drain, then
   disappear in the final cleanup update while the external EIGW and IPv6 allocations
   remain.

This smoke test is important because static inspection can prove the selected hostname,
route, and security rules but cannot prove the runtime resolver's AAAA selection and the
operator VPC's effective NACL/routing behavior.

## Migration and rollback

### From the existing DynamoDB endpoint

Apply this design only after the completion consumer owns the DynamoDB update.
Removing `ExecutionDynamoDBGatewayEndpoint` earlier would cut off the current TigerBeetle processor
handler's DynamoDB call while it is VPC-attached.

### From an SQS interface endpoint

If an SQS endpoint has already been deployed:

1. Establish and validate the dual-stack path first.
2. Enable Lambda dual-stack and the SDK switch while retaining the endpoint.
3. Prove a Completion send over IPv6; private DNS may still direct the SQS hostname to
   the interface endpoint, so temporarily disabling/removing endpoint private DNS may be
   required for a conclusive route test.
4. Remove the interface endpoint and endpoint SG through guarded cleanup only after the
   IPv6 path is proven.

### Roll back to PrivateLink

Create and validate the SQS interface endpoint, its endpoint SG, private DNS, and endpoint
policy before removing the IPv6 route. Restore the TigerBeetle processor SG's IPv4/private-address
TCP/443 egress as required by the endpoint ENIs. After the endpoint path succeeds, remove
the SAM-owned `::/0` route and SDK dual-stack requirement. Leave external IPv6 resources
alone unless the operator separately decides they are unused.

## Implementation objectives

### Add dual-stack SQS egress to SAM

- Remove the obsolete DynamoDB endpoint/output.
- Add the EIGW ID parameter and enable/retention rules.
- Enable `Ipv6AllowedForDualStack` on TigerBeetle processor.
- Set `AWS_USE_DUALSTACK_ENDPOINT` while TigerBeetle processor is VPC-attached.
- Replace IPv4 public HTTPS SG egress with IPv6 TCP/443.
- Add the conditional SAM-owned `::/0` route to the operator-owned EIGW.
- Add no interface endpoint, endpoint SG, endpoint policy, or endpoint output.
- Validate SAM locally without deploying.

### Validate external dual-stack topology prerequisites

- Remove DynamoDB endpoint-aware subnet discovery and import preflight.
- Validate VPC/subnet IPv6 associations, effective route-table ownership, and VPC DNS
  attributes.
- Cover external-topology discovery and failure cases with credential-free mocked AWS
  responses.

### Add ownership-aware IPv6 egress preflight

- Validate EIGW attachment and ownership, `::/0` route conflicts, and relevant NACL
  behavior.
- Confirm regional SQS dual-stack endpoint availability.
- Keep SQS interface-endpoint discovery workflows absent.
- Cover all egress ownership and failure cases with credential-free mocked AWS responses.

### Update guarded route and SG cleanup

- Retain the TigerBeetle processor SG, IPv6 route, EIGW/route parameters, and Lambda ENI IAM during
  detach.
- Wait only for Lambda VPC configurations, versions, and Lambda-created ENIs.
- Remove endpoint-ENI classification because no endpoint ENIs exist.
- Delete the SAM-owned route and SG only after the bounded wait succeeds.
- Never mutate or delete the operator-owned EIGW or IPv6 CIDR associations.
- Cover enable, reconfigure, timeout, recovery, and final-cleanup cases with mocked tests.

## Recommendation

Use this alternative when the operator accepts dual-stack as an explicit prerequisite
for the supplied VPC/subnet and values zero fixed SQS-egress resource cost over a
PrivateLink-only boundary. Keep the SQS interface endpoint design when IPv6 cannot be
required, when the VPC is not under the operator's address-management control, or when
endpoint policies/private-only reachability are production requirements.
