# Deploy `lambda.zip` to AWS Lambda with SAM

This guide documents how to deploy the Zig Lambda package in this repository
using AWS SAM and `template.yaml`.

SAM deploys the Lambda function as a CloudFormation-managed stack. It creates
the Lambda function, execution role, DynamoDB operations table, public Function
URL, and Function URL permissions.

## Assumptions

- AWS CLI v2 and SAM CLI are installed.
- You have an IAM Identity Center / SSO profile named `dev`.
- The deployment region is `ca-central-1`.
- `template.yaml` exists in this repository.
- `lambda.zip` exists and contains a Linux ARM64 executable named `bootstrap`.
- The Lambda Function URL is intentionally public for demo HTTP GET and POST testing.
- `LAMBDA_PRINCIPAL` defaults to `'*'` unless you override the
  `LambdaPrincipal` template parameter.
- `PASETO_PUBLIC_KEY` contains the padded Base64 Ed25519 public key generated
  by `zig-out/bin/paseto keygen`. The corresponding private key remains only
  in the token-signing environment.

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

## 2. Build and package the Zig Lambda

Build the stripped, single-threaded, ReleaseSafe Lambda executable for AWS
Lambda ARM64.

```sh
zig build --release -Darch=arm
```

Verify that the built artifact is a Linux ARM64 executable.

```sh
file zig-out/bin/bootstrap
```

Expected executable shape:

```text
ELF 64-bit LSB executable, ARM aarch64, statically linked, stripped
```

Create or refresh `lambda.zip`.

```sh
zip -qj lambda.zip zig-out/bin/bootstrap
```

SAM reads this zip from the `CodeUri: lambda.zip` property in `template.yaml`.

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
- `DemoFunction`: `AWS::Serverless::Function`
- `DemoFunctionUrl`: `AWS::Lambda::Url`
- `FunctionUrlInvokeFunctionUrlPermission`: allows `lambda:InvokeFunctionUrl`
- `FunctionUrlInvokeFunctionPermission`: allows `lambda:InvokeFunction` only
  through the Function URL

The function settings are:

```yaml
Runtime: provided.al2023
Handler: bootstrap
Architectures:
  - arm64
MemorySize: 128
Timeout: 3
Policies:
  - AWSLambdaBasicExecutionRole
  - Version: "2012-10-17"
    Statement:
      - Effect: Allow
        Action:
          - dynamodb:GetItem
          - dynamodb:PutItem
          - dynamodb:UpdateItem
        Resource: !GetAtt OperationsTable.Arn
Environment:
  Variables:
    LAMBDA_PRINCIPAL: !Ref LambdaPrincipal
    OPERATIONS_TABLE_NAME: !Ref OperationsTable
    PASETO_PUBLIC_KEY: !Ref PasetoPublicKey
```

The inline policy grants the function only `GetItem`, `PutItem`, and
`UpdateItem` access to this stack's operations table. The
`OPERATIONS_TABLE_NAME` environment variable contains the
CloudFormation-generated physical table name. The host-native `operation` CLI
uses the active persistence adapter and the same table contract. The current
Lambda handler still validates and returns POST input without calling
DynamoDB.

The operations table uses on-demand `PAY_PER_REQUEST` billing and has one
string partition key named `id`. It has no sort key, secondary indexes,
streams, TTL, provisioned capacity, or explicit table name. Point-in-time
recovery is explicitly disabled, and omitting `SSESpecification` selects
DynamoDB's default AWS-owned encryption.

The DynamoDB item contract enforced by `src/operation_persistence.zig` is:

| Attribute | DynamoDB type | Contract |
| --- | --- | --- |
| `id` | `S` | Always present; partition key; canonical lowercase hyphenated Operation UUID. |
| `name` | `S` | Always present. |
| `state` | `S` | One of `NEW`, `SUBMITTED`, `RUNNING`, `SUCCEEDED`, or `FAILED`. |
| `last_updated` | `N` | Unix epoch seconds. |
| `hash` | `S` | 64-character lowercase BLAKE3-256 hexadecimal value. |
| `result` | `S` | Terminal states only; exact serialized JSON; at most 4,096 UTF-8 bytes. |

The Operation hash covers only a JSON envelope containing `name` and `body`.
The body is parsed and re-serialized before hashing, so insignificant
whitespace and equivalent string escapes do not change the hash, while object
member order remains significant. The `id`, `state`, `last_updated`, and
`result` fields are excluded.

Never persist `body`. The 4,096-byte `result` bound is an application-enforced
constraint because DynamoDB and CloudFormation cannot enforce a per-attribute
size limit. The adapter validates immediately before every `PutItem` or
`UpdateItem` and after decoding every read. Creates use
`attribute_not_exists(id)` and request `ALL_OLD` when that condition fails. A
failed create condition succeeds as an idempotent retry only when the returned
item has the submitted Operation hash, regardless of its current state;
otherwise it is an Operation conflict. Reads are strongly consistent. Updates
condition on the previously read snapshot, preserve `id`, `name`, and `hash`,
and return and validate `ALL_NEW`. Result-size validation remains in the
application rather than a DynamoDB condition expression.

The Function URL settings are:

```yaml
AuthType: NONE
InvokeMode: BUFFERED
Cors:
  AllowOrigins:
    - "*"
  AllowMethods:
    - GET
    - POST
  AllowHeaders:
    - "*"
```

`AuthType: NONE` and `Principal: "*"` make the Function URL public.

`LambdaPrincipal` configures only the `LAMBDA_PRINCIPAL` environment variable
inside the function. It does not change the Function URL resource permissions.

`PasetoPublicKey` is a required parameter that configures the
`PASETO_PUBLIC_KEY` used by the handler to verify PASETO v4.public bearer
tokens.

## 5. Choose the function name and environment values

The template defaults to:

```text
aws-lambda-zig-demo
```

You can keep the default or override it during deployment with the `FunctionName` parameter.

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

## 6. Deploy with SAM guided mode

Run:

```sh
sam deploy --guided \
  --template-file template.yaml \
  --profile dev \
  --region ca-central-1 \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    FunctionName=aws-lambda-zig-demo \
    LambdaPrincipal='*' \
    PasetoPublicKey="$PASETO_PUBLIC_KEY"
```

Recommended guided answers:

```text
Stack Name: aws-lambda-zig-demo
AWS Region: ca-central-1
Parameter FunctionName: aws-lambda-zig-demo
Parameter LambdaPrincipal: *
Parameter PasetoPublicKey: <public-key-from-keygen>
Confirm changes before deploy: Y
Allow SAM CLI IAM role creation: Y
Disable rollback: N
Save arguments to configuration file: Y
SAM configuration file: samconfig.toml
SAM configuration environment: default
```

`CAPABILITY_IAM` is required because SAM creates an IAM execution role for the Lambda function.

After the first guided deployment, SAM can reuse `samconfig.toml`, so future
deployments are usually:

```sh
sam deploy --profile dev --region ca-central-1
```

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
    FunctionName=aws-lambda-zig-demo \
    LambdaPrincipal='*' \
    PasetoPublicKey="$PASETO_PUBLIC_KEY"
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

`deploy.sh` reads the required `PASETO_PUBLIC_KEY` from the host environment and
passes it as the `PasetoPublicKey` SAM parameter. When the post-deploy Function
URL check is enabled, it also requires the corresponding `PASETO_PRIVATE_KEY`
to issue a 10-second test token. It first verifies that an unauthenticated
request returns HTTP 401, then verifies that the authenticated request returns
HTTP 200. The private key and test token are not printed or passed to the
Lambda environment. Use
`PASETO_PUBLIC_KEY='<public-key-from-keygen>' ./deploy.sh --dry-run` to run the
local checks, rebuild `lambda.zip`, and validate `template.yaml` without
deploying to AWS.

After a successful deployment, `deploy.sh` reads the
`OperationsTableName` stack output, waits for the table to exist, and prints a
concise table summary. It fails unless the table is active, uses on-demand
billing, has only the `id` string partition key, and has no local or global
secondary indexes. The existing stack-status and Function URL checks then
continue as usual.

Use
`PASETO_PUBLIC_KEY='<public-key-from-keygen>' ./deploy.sh --dry-run --use-local-libs`
to build with local dependency checkouts. The `aws_lambda` checkout defaults
to `../aws-lambda-zig`; override it with `LOCAL_AWS_LAMBDA_ROOT` when needed.

## 7. Read the Function URL output

After deployment, SAM prints stack outputs. Look for:

```text
FunctionUrl
OperationsTableName
```

You can also query it later with CloudFormation:

```sh
aws cloudformation describe-stacks \
  --stack-name aws-lambda-zig-demo \
  --query "Stacks[0].Outputs[?OutputKey=='FunctionUrl'].OutputValue" \
  --output text \
  --profile dev \
  --region ca-central-1
```

Discover and export the operations table for the host CLI:

```sh
export OPERATIONS_TABLE_NAME="$(
  aws cloudformation describe-stacks \
    --stack-name aws-lambda-zig-demo \
    --query "Stacks[0].Outputs[?OutputKey=='OperationsTableName'].OutputValue" \
    --output text \
    --profile dev \
    --region ca-central-1
)"
```

## 8. Test HTTP GET and POST

Call the Function URL returned by SAM.

```sh
curl -i -L <FunctionUrl>
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

Send the token in the authorization header:

```sh
curl -L -H "Authorization: Bearer $token" <FunctionUrl>
```

Expected authenticated response:

```text
Hello, example-user!

ConfigMeta
...

RequestMeta
...

Environment
LAMBDA_PRINCIPAL=*
PASETO_PUBLIC_KEY=<public-key-from-keygen>
...
```

The response should render directly in a browser because the handler returns:

```text
Content-Type: text/plain; charset=utf-8
```

POST an Operation JSON document with the same bearer token:

```sh
curl -L \
  -H "Authorization: Bearer $token" \
  -H "Content-Type: application/json" \
  --data \
    '{"id":"00112233-4455-6677-8899-aabbccddeeff",'\
'"name":"echo","body":{"message":"hello","count":2}}' \
  <FunctionUrl>
```

The handler returns the Operation output view with `NEW` state, the invocation
timestamp, and its stable hash. It omits the input body:

```json
{
  "id": "00112233-4455-6677-8899-aabbccddeeff",
  "name": "echo",
  "state": "NEW",
  "last_updated": 1700000000,
  "hash": "ab9a059eb68c36bddaffb5bdd23aa7177c3a97dc34f9af54eb06f1c488ac3662"
}
```

## 9. Create, read, and update persisted Operations

Builds install the host-native utility at `zig-out/bin/operation`. It requires
the table environment variable above and follows standard AWS configuration
for credentials, region, profile, and endpoint. These examples select the same
profile and region used for deployment:

```sh
export AWS_PROFILE=dev
export AWS_REGION=ca-central-1
```

Create an Operation from its input JSON view:

```sh
operation_json='{"id":"00112233-4455-6677-8899-aabbccddeeff",'\
'"name":"echo","body":{"message":"hello","count":2}}'
printf '%s\n' "$operation_json" | zig-out/bin/operation create
```

Retry create with the original UUID, name, and body. When the UUID already
identifies an Operation with the same Operation hash, create returns the current
stored Operation, including its state, `last_updated`, and terminal result when
present. A different hash returns `operation: operation conflict` with exit code
`1`.

Read the persistent output view:

```sh
zig-out/bin/operation read \
  --id 00112233-4455-6677-8899-aabbccddeeff
```

Pending states require empty standard input. Terminal states require a
non-null JSON result no larger than 4,096 serialized bytes:

```sh
zig-out/bin/operation update \
  --id 00112233-4455-6677-8899-aabbccddeeff \
  --state RUNNING \
  </dev/null

printf '%s\n' '{"message":"done"}' \
  | zig-out/bin/operation update \
      --id 00112233-4455-6677-8899-aabbccddeeff \
      --state SUCCEEDED
```

Lifecycle ordering is intentionally not enforced: any valid state may replace
any previous state, including a same-state update. Exit code `1` means the item
was missing or a create/update conflict occurred. Both conflict paths emit
`operation: operation conflict`. Exit code `2` means invocation, validation,
configuration, AWS, or internal failure.

The caller running the host CLI needs `dynamodb:GetItem`, `dynamodb:PutItem`,
and `dynamodb:UpdateItem` permissions for the table. The Lambda execution
role's inline policy does not grant permissions to the local AWS identity.

### Troubleshoot Operation CLI configuration

`operation: missing or invalid configuration` is emitted before Operation JSON
is parsed when `OPERATIONS_TABLE_NAME` is missing or invalid, or when the AWS
configuration chain cannot resolve settings such as the region or profile.
Confirm table discovery succeeded without printing the account-specific name:

```sh
test -n "${OPERATIONS_TABLE_NAME:-}" && printf 'table configured\n'
```

If this prints nothing, repeat the `OperationsTableName` CloudFormation query
in section 7. Also confirm `AWS_PROFILE` and `AWS_REGION` are set as shown
above. Profiles backed by IAM Identity Center may need a refreshed session:

```sh
aws sso login --profile "$AWS_PROFILE"
```

Changing the piped Operation JSON cannot fix this diagnostic because command
configuration is checked before input parsing. Failures encountered while
calling DynamoDB after configuration loading instead report
`operation: AWS request failed`.

## 10. Update the deployed Lambda code

After changing Zig source code, rebuild and repackage:

```sh
zig build --release -Darch=arm
zip -qj lambda.zip zig-out/bin/bootstrap
```

Then redeploy the stack:

```sh
sam deploy --profile dev --region ca-central-1
```

SAM uploads the new `lambda.zip` and updates the CloudFormation-managed Lambda function.

## 11. Delete the SAM stack

To remove the SAM-managed function, role, operations table, Function URL, and
permissions:

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

## Security note

This demo intentionally creates a publicly reachable Lambda Function URL, and
the handler requires a valid PASETO bearer token. For production, consider
combining application authentication with stricter infrastructure
authorization, narrower IAM policies, or an API Gateway/CloudFront layer.
