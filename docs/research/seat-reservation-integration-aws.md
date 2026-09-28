# Seat reservation integration: AWS constraints

Verified against official AWS documentation on 2026-09-26. This note supports
the integration decision; it does not change deployment or application code.
No AWS account or deployed resources were queried.

## Transaction IAM permissions

| Request contents | IAM actions on the affected table resources |
| --- | --- |
| `TransactWriteItems` containing two `Update` actions | `dynamodb:UpdateItem` on both tables |
| `TransactGetItems` containing `Get` actions | `dynamodb:GetItem` on every read table |
| A distinct transactional `ConditionCheck` action, if added | `dynamodb:ConditionCheckItem` |

AWS authorizes transactional work through the constituent item operations.
`TransactWriteItems` and `TransactGetItems` are API names, not the IAM action
names to grant here. An `Update` with its own condition expression remains an
`Update`; it does not add a separate `ConditionCheck` action. Policies can use
`dynamodb:EnclosingOperation` when transactional-only access is desired.
Sources: [transaction IAM documentation](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/transaction-apis-iam.html),
[service authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_dynamodb.html).

## Inspect the change set that will actually execute

`sam deploy --no-execute-changeset` creates a CloudFormation change set without
applying its stack changes. SAM documents rerunning without the flag as one way
to deploy. For an automated safety check, executing the exact inspected change
set instead avoids relying on a newly computed one. Sources:
[SAM deploy](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/sam-cli-command-reference-sam-deploy.html),
[execute-change-set](https://docs.aws.amazon.com/cli/latest/reference/cloudformation/execute-change-set.html).

`aws cloudformation describe-change-set` returns the proposed resource changes;
it is paginated, so inspection must cover every page. The relevant fields are
`ResourceType`, `Action`, `Replacement`, and `PolicyAction`. `Replacement` can be
`True`, `False`, or `Conditional`; `Action` can be `Dynamic` when the exact
operation cannot be determined. Sources:
[describe-change-set](https://docs.aws.amazon.com/cli/latest/reference/cloudformation/describe-change-set.html),
[ResourceChange](https://docs.aws.amazon.com/AWSCloudFormation/latest/APIReference/API_ResourceChange.html).

Implementation consequence of the user's preservation requirement: normal
redeployment must reject removal or possible replacement of an existing
`AWS::DynamoDB::Table` before execution, including `Conditional` replacement and
unknown/dynamic outcomes. Retaining a removed or replaced table is insufficient:
the running application could switch to a fresh empty table while old data is
left behind. Stable logical resource identities and table identities are needed
as well as stable schemas. Execute only the inspected change-set identifier and
wait for completion. This is a derived deployment requirement, not an AWS
automatic guarantee.

## Preservation and explicit cleanup have different scopes

`DeletionPolicy` controls stack deletion and removal of a resource definition
during a stack update. It does not control the old physical resource when a
property update replaces that resource. `Delete` removes the resource and its
contents; `Retain` leaves it outside the deleted stack's management. Source:
[DeletionPolicy](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-attribute-deletionpolicy.html).

`UpdateReplacePolicy` controls that replacement case. `Retain` leaves the old
physical resource outside CloudFormation management; references point to the
new physical resource. It does not preserve continuity of the application's
data. Omitting the policy defaults to deleting the replaced resource. Source:
[UpdateReplacePolicy](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-attribute-updatereplacepolicy.html).

An explicit full-cleanup operation can delete a stack, but it must account for
its resources' deletion policies. A retained resource is not removed by ordinary
stack deletion. If DynamoDB deletion protection is enabled, it must be disabled
before table deletion can succeed. Sources:
[delete-stack](https://docs.aws.amazon.com/cli/latest/reference/cloudformation/delete-stack.html),
[DeletionPolicy](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-attribute-deletionpolicy.html),
[DynamoDB table resource](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-dynamodb-table.html).

The user's two requirements are compatible: default deployment updates the
existing stack without removing/replacing persistent tables, while a separate,
explicit full-cleanup mode removes owned resources and persisted data. Merely
setting `Retain` does not satisfy the no-abandoned-resources requirement.

## Initialize the counter without overwriting it

A DynamoDB `PutItem` with `ConditionExpression` using `attribute_not_exists` on
the partition-key attribute creates the initial item only when that key does
not exist. Without that condition, `PutItem` replaces an existing item.
Source: [PutItem](https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_PutItem.html).

Applied to the selected counter contract, bootstrap may conditionally create
the value `1000`; a condition failure because it already exists must preserve
the existing value. Normal redeployment must never perform an unconditional
seed/reset. Counter storage must remain associated with the same actual
TigerBeetle cluster across deployments; these AWS mechanisms do not establish
that cluster identity by themselves.
