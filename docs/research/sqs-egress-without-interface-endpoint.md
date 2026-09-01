# SQS egress without a per-VPC interface endpoint

Status: design research, 2026-08-29. No application or deployment changes were made.

## Conclusion

Yes, the pipeline can operate without creating an SQS interface endpoint. The previously
considered interface-endpoint design required a stack-owned
`ExecutionSqsInterfaceEndpoint`, its endpoint security group, private DNS, endpoint
policy, and output. Avoiding that resource requires a different networking and cleanup
design.

For this development/demo topology, the smallest compatible alternative is to reuse the
already-running WireGuard EC2 gateway as a tightly constrained IPv4 NAT instance whenever
the gateway is enabled. This preserves the execution handler's existing batch and retry
semantics and adds no second hourly networking resource. The tradeoff is that SQS uses its
public regional HTTPS endpoint, the EC2 appliance gains another operational duty, and the
network restriction can practically be narrowed to source/protocol/port but not to an
AWS-managed SQS destination prefix list.

If the operator-controlled VPC and Lambda subnet are already dual-stack, IPv6 through a
free egress-only internet gateway is cleaner and is the preferred zero-fixed-cost network
design. It should not be made the repository default unless requiring IPv6 on the external
VPC/subnet is acceptable. EventBridge Pipes can also move the SQS send out of the function,
but its enrichment failure model forces `BatchSize: 1` (or whole-batch retries) and makes it
an application/workflow redesign rather than a networking substitution.

## What the SQS egress path is solving

The pipeline changes execution from a DynamoDB writer into a producer that sends at most
one aggregate Completion message per invocation. The template grants execution only
`sqs:SendMessage` on `CompletionQueue`, puts `COMPLETION_QUEUE_URL` in its environment,
and leaves the completion consumer outside the VPC.

The Operations queue does not create the outbound-network requirement. A Lambda event
source mapping is a Lambda-managed poller: Lambda polls SQS and invokes the function; the
function's VPC network is not used for that poll
([AWS Lambda: using SQS](https://docs.aws.amazon.com/lambda/latest/dg/with-sqs.html)). The
new requirement is only the execution code's outbound `SendMessage` call after it talks to
TigerBeetle.

The current optional topology is:

```text
Operations SQS --Lambda-managed poller--> execution Lambda
                                            |
                                            | IPv4 TCP/3000
                                            v
Lambda subnet route table --> WireGuard EC2 --> WireGuard --> workstation TigerBeetle
                                            |
                                            `-- needs a path for HTTPS SendMessage --> SQS
```

Execution is VPC-attached only while the WireGuard gateway is enabled, uses exactly
`LambdaSubnetId`, and otherwise has no VPC attachment
([template](../../template.yaml#L347-L371),
[gateway design](../EC2-WireGuard-Gateway.md#L175-L188)). Its route table already sends
`10.200.0.0/24` to the gateway instance, and that instance already has a stable Elastic IP,
IPv4 forwarding enabled, and source/destination checking disabled
([template](../../template.yaml#L575-L605),
[route](../../template.yaml#L616-L630)). AWS documents that a VPC-attached Lambda can use
only connectivity available through its VPC and that putting the function in a public
subnet does not itself give it internet access
([Lambda VPC networking](https://docs.aws.amazon.com/lambda/latest/dg/configuration-vpc.html),
[Lambda internet access](https://docs.aws.amazon.com/lambda/latest/dg/configuration-vpc-internet.html)).

Consequently, merely moving `LambdaSubnetId` to the gateway's public subnet is not a
solution. A private SQS path, IPv4 translation/proxy path, IPv6 egress path, or a managed
service that performs the send is required.

## Cost baseline

A one-subnet endpoint creates one endpoint ENI in one Availability Zone. AWS bills
interface endpoints for every provisioned endpoint-hour in each Availability Zone and
for bytes processed
([PrivateLink pricing](https://aws.amazon.com/privatelink/pricing/)). The current official
Canada (Central) Amazon VPC price list (publication `2026-07-24T15:42:25Z`) prices SKU
`YZK8AEXHY7HJD36A` at **USD 0.011 per endpoint-hour** and SKU
`3W497TYXJM5N3NE7` at **USD 0.01/GB** for the first PB
([regional price list](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonVPC/current/ca-central-1/index.json)).
That is about **USD 8.03 for 730 hours**, plus negligible data processing for this small
message flow.

That cost can be conditional rather than permanent: the endpoint can exist only while the
WireGuard gateway is enabled or while guarded VPC cleanup resources are retained. At the
current rate, one day costs about USD 0.264 and ten test hours cost USD 0.11. SQS request
charges remain under every option and are therefore excluded from the comparison.

## Alternatives at a glance

| Alternative | New fixed network cost | Preserves current handler semantics | Network path | Change surface |
| --- | ---: | --- | --- | --- |
| SQS interface endpoint | About USD 8.03/month if continuous | Yes | PrivateLink/private IP | Endpoint resources and guarded cleanup |
| Reuse WireGuard EC2 as NAT instance | USD 0 incremental while that instance/EIP already run | Yes | Public SQS HTTPS through EC2/IGW | Gateway networking and cleanup changes |
| Dual-stack Lambda + egress-only IGW | USD 0 for the gateway | Yes | Public SQS HTTPS over outbound-only IPv6 | External VPC/subnet prerequisite and IPv6 lifecycle changes |
| EventBridge Pipe with execution enrichment | No endpoint hourly cost; USD 0.40/million billable Pipe requests | Only with batch/retry redesign | AWS-managed Pipe invokes Lambda and SQS | Reopens handler, IAM, mapping, SAM, tests, and pipeline invariants |

The cost figures exclude ordinary Lambda, EC2, SQS, and data-transfer charges already
present in the selected architecture.

## Alternative 1: reuse the WireGuard EC2 gateway as a constrained NAT instance

### Why it works here

AWS supports a NAT instance in a public subnet as an IPv4 egress path for resources in a
private subnet. The private route table sends `0.0.0.0/0` to the instance; the NAT
instance must have public internet access and must have source/destination checking
disabled
([AWS NAT instances](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_NAT_Instance.html),
[setup procedure](https://docs.aws.amazon.com/vpc/latest/userguide/work-with-nat-instances.html)).
The repository's WireGuard appliance already satisfies most of this: it is in the public
subnet with an Elastic IP, has `net.ipv4.ip_forward=1`, and has
`SourceDestCheck: false` ([template](../../template.yaml#L575-L605)).

The remaining design is:

```text
execution Lambda IPv4
  -> Lambda route table 0.0.0.0/0
  -> existing WireGuard EC2 gateway
  -> source NAT on its public interface
  -> internet gateway
  -> sqs.ca-central-1.amazonaws.com:443
```

The gateway bootstrap would install persistent NAT/forwarding rules; its security group
would accept forwarded TCP/443 only from `LambdaSubnetCidr`; and the Lambda security group
would retain TCP/443 egress. The current dedicated `10.200.0.0/24` route remains more
specific and continues to carry TigerBeetle traffic. If the operator's Lambda route table
already has usable IPv4 egress through an existing NAT, the stack should use that path
instead of attempting to add a duplicate default route.

### Cost

There is no additional endpoint, NAT Gateway, instance, or public IPv4 address: the
gateway instance and Elastic IP are already live whenever execution needs the WireGuard
path. Same-Region Lambda/SQS data transfer is free under SQS pricing
([SQS pricing](https://aws.amazon.com/sqs/pricing/)). A separate managed NAT Gateway would
be a poor cost substitute: the current Canada (Central) EC2 price list prices both its
hour and processed GB at **USD 0.05**, or USD 36.50/month before data and its required
public IPv4 address
([regional EC2 price list](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/current/ca-central-1/index.json)).
AWS also charges public IPv4 addresses USD 0.005/hour
([VPC pricing](https://aws.amazon.com/vpc/pricing/)).

### Security and operations

This can be constrained by source CIDR, state, TCP, and destination port, but it cannot be
cleanly constrained at the route/security-group layer to SQS alone. AWS's current managed
prefix-list catalog includes services such as S3 and DynamoDB but does **not** list SQS
([AWS-managed prefix lists](https://docs.aws.amazon.com/vpc/latest/userguide/working-with-aws-managed-prefix-lists.html)).
The practical rule is therefore HTTPS to public IPv4 destinations. IAM still restricts
the execution role to `sqs:SendMessage` on `CompletionQueue`, but the endpoint policy and
the ability to require `aws:SourceVpce` are lost. Endpoint policies are an additional
authorization layer and do not replace identity/resource policies
([VPC endpoint policies](https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-access.html)).

The instance becomes responsible for both WireGuard routing and SQS egress. AWS recommends
managed NAT Gateways over NAT instances for availability, bandwidth, and lower
administrative effort
([AWS NAT overview](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat.html)). That is
a material production concern, but a smaller concern here because the documented gateway
is already a replaceable, single development appliance and TigerBeetle connectivity
already depends on it ([gateway scope](../EC2-WireGuard-Gateway.md#L3-L14)).

### Implementation impact

This option would add or validate the default route and the gateway's constrained HTTPS
forwarding rules, remove the obsolete DynamoDB endpoint, and add no SQS endpoint/output.
Preflight would cover the gateway public-subnet/IGW path, route ownership, forwarding/NAT
configuration, and security groups. Cleanup would remove the default route before deleting
the instance and retain only the execution security group and Lambda ENI cleanup permissions
during detach; there would be no endpoint ENI to retain or classify.

## Alternative 2: dual-stack Lambda subnet plus an egress-only internet gateway

### Why it works

Lambda supports outbound IPv6 when every selected subnet is dual-stack and
`Ipv6AllowedForDualStack` is enabled
([Lambda IPv6 support](https://docs.aws.amazon.com/lambda/latest/dg/configuration-vpc.html),
[CloudFormation `VpcConfig`](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-properties-lambda-function-vpcconfig.html)).
For a private subnet, AWS's documented topology is a `::/0` route to an egress-only
internet gateway, which allows outbound IPv6 connections and rejects connections initiated
from outside the VPC
([Lambda internet access](https://docs.aws.amazon.com/lambda/latest/dg/configuration-vpc-internet.html),
[egress-only IGW](https://docs.aws.amazon.com/vpc/latest/userguide/egress-only-internet-gateway.html)).

Amazon SQS provides a dual-stack endpoint in Canada (Central), including
`sqs.ca-central-1.api.aws`
([SQS regional endpoints](https://docs.aws.amazon.com/general/latest/gr/sqs-service.html)).
The standard SDK switch is `AWS_USE_DUALSTACK_ENDPOINT=true`
([AWS SDK endpoint settings](https://docs.aws.amazon.com/sdkref/latest/guide/feature-endpoints.html)).
The vendored Zig SDK already reads that environment variable and resolves dual-stack
service hostnames
([SDK config](../../zig-pkg/aws_sdk-0.0.1-ApQSL17Y_xOC5IhLm247KBZKDcbCRU3qf7GiiiRHcrND/src/config.zig#L173-L185),
[endpoint resolution](../../zig-pkg/aws_sdk-0.0.1-ApQSL17Y_xOC5IhLm247KBZKDcbCRU3qf7GiiiRHcrND/src/endpoint.zig#L166-L194)).

The resulting path is:

```text
execution Lambda IPv6
  -> Lambda route table ::/0
  -> egress-only internet gateway
  -> sqs.ca-central-1.api.aws:443
```

### Cost

AWS charges nothing for an egress-only internet gateway; normal transfer pricing still
applies ([AWS VPC guide](https://docs.aws.amazon.com/vpc/latest/userguide/egress-only-internet-gateway.html)).
SQS does not charge data transfer for sends/receives when the resources are in the same
Region ([SQS pricing](https://aws.amazon.com/sqs/pricing/)). Thus the incremental network
resource and processing cost for this path is USD 0; SQS requests still apply.

### Constraints and security

The operator-owned VPC must have an IPv6 CIDR and `LambdaSubnetId` must have an IPv6 CIDR;
AWS permits adding IPv6 to existing VPCs and subnets, but that is an external-network
change rather than a narrow SAM endpoint change
([add IPv6 to a VPC](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-migrate-ipv6-add.html),
[associate subnet IPv6](https://docs.aws.amazon.com/vpc/latest/userguide/subnet-associate-ipv6-cidr.html)).
Only one egress-only internet gateway can be attached to a VPC, so a generic helper must
discover/reuse an existing gateway or fail on an ownership conflict
([VPC quotas](https://docs.aws.amazon.com/vpc/latest/userguide/amazon-vpc-limits.html)).

The execution security group would need TCP/443 egress to `::/0`; IPv4 HTTPS egress can be
removed if there is no IPv4 NAT path. Like the NAT design, this is a public service endpoint
and loses the private endpoint policy/`aws:SourceVpce` boundary. The egress-only gateway
prevents unsolicited inbound IPv6, but permitted code could connect to any public IPv6
HTTPS endpoint. SQS is absent from the AWS-managed destination prefix-list catalog, so IAM
remains the precise queue/action boundary.

### Implementation impact

This option would enable Lambda dual-stack egress, set the SDK dual-stack switch, add or
consume an egress-only internet gateway, add the `::/0` route, and replace the
security-group HTTPS rule with IPv6. Preflight would verify VPC/subnet IPv6, the existing
gateway/route ownership, DNS, and the SQS dual-stack endpoint. Cleanup would handle
route/gateway lifecycle but no endpoint ENIs. Because the stack consumes an existing VPC
and subnet, the safest interface is to make dual-stack topology an explicit prerequisite
rather than silently assign IPv6 space to operator-owned networking.

## Alternative 3: EventBridge Pipe with execution as an enrichment

### Why it removes the egress requirement

EventBridge Pipes can use SQS as a source, invoke Lambda as an enrichment, and send the
enrichment response to SQS as the target. Pipes uses its own IAM role for enrichment and
target API calls
([Pipes overview](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-pipes.html),
[Pipes targets and permissions](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-pipes-event-target.html)).
The topology would become:

```text
Operations SQS -> EventBridge Pipe
                    -> execution Lambda enrichment (VPC; TigerBeetle only)
                    -> Completion SQS target (sent by EventBridge)
```

Execution would return the encoded Completion message instead of calling SQS. The Pipe
role, not execution, would receive source-poll, `lambda:InvokeFunction`, and target
`sqs:SendMessage` permissions. No SQS route is needed inside the function VPC.

### The partial-failure limitation

Pipes can batch SQS source records and pass a JSON array to a Lambda enrichment. An
enrichment may return a shorter or longer array for a batchable SQS target, but **partial
batch failure handling is not supported for the enrichment stage**
([Pipes batching and partial failures](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-pipes-batching-concurrency.html)).
That conflicts directly with the current producer contract: one invocation may publish
terminal records while returning only transient source records for retry.

There are two coherent choices:

1. Use `BatchSize: 1`. A transient result fails that one Pipe execution and is retried;
   a terminal result is returned and sent to Completion SQS. This preserves per-record
   correctness but abandons execution-side multi-record aggregation and increases Lambda
   invocations/TigerBeetle request setup.
2. Keep batches and fail the whole enrichment when any record is transient. Idempotent
   TigerBeetle IDs make replay tolerable, but terminal records are re-executed and no
   completion reaches the target until the whole batch succeeds. This changes the current
   acknowledgement and retry behavior and needs new tests for malformed records and
   completion-message construction.

Pipes treats a successfully processed SQS source batch as complete and deletes its source
messages; on a processing error the messages become visible after the queue timeout
([SQS as a Pipes source](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-pipes-sqs.html)).
It is therefore unsafe to simply omit transient records from a successful enrichment
response without a carefully validated batch-size-one/drop contract.

### Cost and architecture impact

Pipes charges by 64 KB request chunk after filtering; AWS's current example rate is
**USD 0.40 per million requests**
([EventBridge pricing](https://aws.amazon.com/eventbridge/pricing/)). This is likely far
below an always-on interface endpoint for this demo, but it adds a new service, IAM role,
event schema, observability surface, and retry model.

This option is not a networking-only substitution. It reopens the execution handler
contract, IAM and source mapping, SAM resources, batch invariants, and their tests. It is
a reasonable future architecture if managed point-to-point orchestration is desired and
`BatchSize: 1` is acceptable, but it is not the best cost-only change to the current
architecture.

## Other choices that do not improve this topology

- A new managed NAT Gateway is more expensive than the one-AZ interface endpoint in
  Canada (Central) and exposes general IPv4 egress; it makes sense only if the VPC already
  has one and its fixed cost is sunk.
- A centralized interface endpoint can amortize hourly cost across many VPCs through
  Transit Gateway and shared DNS, but it still requires an endpoint somewhere and adds
  connectivity/DNS cost and administration. AWS documents it as a multi-VPC landing-zone
  pattern, not a small single-VPC optimization
  ([centralized endpoints](https://docs.aws.amazon.com/whitepapers/latest/building-scalable-secure-multi-vpc-network-infrastructure/centralized-access-to-vpc-private-endpoints.html)).
- Detaching execution from the VPC would restore Lambda's default public internet access,
  but it would also remove the private route to the WireGuard/TigerBeetle gateway. Making
  TigerBeetle reachable through a new public proxy/load balancer would broaden exposure
  and create a larger architecture than any option above.

## Recommendation for this repository

1. **If the gateway is enabled only for short test windows, use an SQS interface endpoint.** At
   USD 0.011/hour, teardown after testing is the lowest-risk optimization; the endpoint
   retains a private path, a queue/action-scoped endpoint policy, and the existing handler
   behavior.
2. **If zero additional fixed resource cost is a hard requirement, reuse the WireGuard EC2
   gateway as a constrained NAT instance.** It fits the demo's already-single-appliance
   topology and preserves the producer's partial-batch semantics.
   Fail closed if `LambdaRouteTableId` already has an unmanaged/conflicting default route.
   Keep the execution IAM permission scoped to only `CompletionQueue`, and document that
   HTTPS egress is not destination-restricted to SQS.
3. **Prefer the IPv6 design over NAT when the supplied VPC/subnet is already dual-stack.**
   It removes NAT state and the endpoint hourly charge, but should be an explicit topology
   mode because this stack does not own the VPC/subnet or its sole egress-only gateway.
4. **Do not choose EventBridge Pipes solely to save roughly USD 8/month.** Choose it only
   if `BatchSize: 1` and the broader producer/workflow redesign are independently desirable.

This recommendation is specific to the documented development gateway. For a production
deployment that requires private AWS-service traffic, destination-specific network policy,
and managed availability, the SQS interface endpoint remains the strongest of these
options despite its hourly charge.
