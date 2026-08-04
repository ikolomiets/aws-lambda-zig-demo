# Manual AWS CLI deployment is retired

This Lambda requires the DynamoDB operations table, `OPERATIONS_TABLE_NAME`
environment variable, and table-scoped IAM permissions managed by
`template.yaml`. A Lambda-only manual deployment does not create a runnable
stack and is no longer supported.

Use the [AWS SAM deployment guide](DEPLOY_AWS_LAMBDA_WITH_SAM.md) to build,
validate, deploy, update, or delete this demo.
