# Deploy the intake and query Lambdas with SAM

This guide documents how to deploy the two Zig Lambda packages in this repository
using AWS SAM and `template.yaml`.

SAM deploys both Lambda functions as one CloudFormation-managed stack. It creates
their execution roles and public Function URLs plus the DynamoDB operations table
and SQS operations queue used only by the intake Lambda.

## Assumptions

- AWS CLI v2 and SAM CLI are installed.
- `zip`, `unzip`, and `file` are installed for package validation.
- `jq` is installed when using `lambda_logs.sh`.
- You have an IAM Identity Center / SSO profile named `dev`.
- The deployment region is `ca-central-1`.
- `template.yaml` exists in this repository.
- `intake-lambda.zip` and `query-lambda.zip` each contain one Linux ARM64
  executable named `bootstrap`.
- Both Lambda Function URLs are intentionally public for authenticated demo testing.
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

When using `deploy.sh`, this refresh is automatic when needed. Before building,
the helper resolves the selected profile to temporary environment credentials
and verifies them with STS. Valid cached credentials are reused without opening
a browser. If resolution or verification fails for a directly configured SSO
profile, the helper runs `aws sso login --profile <profile>` once and retries.
Direct `sam` and `aws` commands in this guide still require an active session.

## 2. Build and package the Zig Lambdas

Build the stripped, single-threaded, ReleaseSafe Lambda executables for AWS
Lambda ARM64.

```sh
zig build --release -Darch=arm
```

The build also installs the host-native `paseto` utility and the local command
implementations invoked by `persistence.sh` and `queue.sh`. Each Lambda zip
contains only its handler's root-level `bootstrap`.

Verify that both built artifacts are Linux ARM64 executables.

```sh
file zig-out/bin/intake/bootstrap zig-out/bin/query/bootstrap
```

Expected executable shape:

```text
ELF 64-bit LSB executable, ARM aarch64, statically linked, stripped
```

Create or refresh both packages.

```sh
zip -qj intake-lambda.zip zig-out/bin/intake/bootstrap
zip -qj query-lambda.zip zig-out/bin/query/bootstrap
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

Both functions share the runtime, architecture, memory, timeout, and environment
settings below. Only the intake function receives the inline DynamoDB and SQS policy:

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
      - Effect: Allow
        Action:
          - sqs:SendMessage
        Resource: !GetAtt OperationsQueue.Arn
Environment:
  Variables:
    LAMBDA_PRINCIPAL: !Ref LambdaPrincipal
    OPERATIONS_QUEUE_URL: !Ref OperationsQueue
    OPERATIONS_TABLE_NAME: !Ref OperationsTable
    PASETO_PUBLIC_KEY: !Ref PasetoPublicKey
```

The inline policy grants the intake function only `GetItem`, `PutItem`, and
`UpdateItem` access to this stack's operations table. The
`OPERATIONS_TABLE_NAME` environment variable contains the
CloudFormation-generated physical table name. `OPERATIONS_QUEUE_URL` contains
the stack queue's generated URL. Both are mandatory: before starting the Lambda
invocation loop, the bootstrap loads one shared AWS configuration and
initializes the Operation persistence and queue modules with the validated
table name and non-empty, at-most-2,048-byte queue URL. Each intake module privately
owns its respective DynamoDB or SQS client; both clients share the AWS
configuration and HTTP pool. The module values, configuration, pool, and intake
adapter are reused across warm invocations. Missing or invalid configuration
therefore prevents intake invocation handling. The query function mirrors the
table and queue environment variables only for display; it initializes no AWS
client and has no DynamoDB or SQS data-plane permissions. The local
persistence and queue command implementations use the same modules and
contracts.

Startup validation makes no DynamoDB or SQS request. A missing table or
insufficient DynamoDB permission is discovered by a POST persistence request
and returned as a sanitized HTTP 500. A missing queue, insufficient
`SendMessage` permission, or another SQS send failure is returned as a
sanitized HTTP 503.

The second inline-policy statement grants the function only `SendMessage`
access to this stack's operations queue. The handler sends full compact
`SUBMITTED` Operation JSON, but has no receive, delete, purge, or
queue-management permissions. The template defines no consumer or Lambda event
source mapping. The `queue.sh` command can operate on this queue using the local
caller's AWS identity; it does not expand the Lambda execution role.

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
the bound. The adapter serializes result Values into fixed request buffers and
validates immediately before every `PutItem` or `UpdateItem`. On reads, it
parses the stored string once into the caller's arena and requires the string
to equal the compact reserialization, rejecting malformed, duplicate-key,
explicit-null, oversized, or noncanonical items. Creates use
`attribute_not_exists(id)` and request `ALL_OLD` when that condition fails. A
failed create condition succeeds as an idempotent retry only when the returned
item has the submitted tenant and Operation hash, regardless of its current state;
otherwise it is an Operation conflict. Reads are strongly consistent. Updates
condition on the previously read snapshot, including the old `expires_at`,
preserve `id`, `tenant`, `name`, and `hash`, and return and validate `ALL_NEW`.
New items and every successful update set `expires_at` to
`last_updated + 86,400`.
Result-size validation remains in the application rather than a DynamoDB
condition expression.

Tenant is metadata and part of idempotency identity. UUIDs and the `id`
partition key remain globally scoped, so reusing a UUID under another tenant
changes the hash and returns an Operation conflict. This contract does not add
tenant-scoped keys, secondary indexes, or new read authorization behavior.

DynamoDB TTL deletion is asynchronous. An item becomes eligible for deletion
at `expires_at` but may remain readable until DynamoDB removes it. Legacy rows
without tenant are rejected by the strict item decoder and must be deleted and
recreated before deploying this version; there is no fallback decoder or
application migration path. CloudFormation configures TTL, so the Lambda role
does not need an additional DynamoDB control-plane permission.

The Function URLs use `AuthType: NONE` and buffered invocation. CORS is not
configured because the service targets non-browser HTTP clients. The handlers
enforce the supported methods: intake allows only POST and query allows only
GET. Their public permissions use the existing intake logical IDs and new
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

## 5. Preserve the intake function name and choose environment values

The template defaults to:

```text
intake-lambda
query-lambda
```

They are controlled by `IntakeFunctionName` and `QueryFunctionName`. Before
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
`QueryFunctionName=query-lambda` if parameter overrides are saved there. The
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
    LambdaPrincipal='*' \
    PasetoPublicKey="$PASETO_PUBLIC_KEY"
```

Recommended guided answers:

```text
Stack Name: aws-lambda-zig-demo
AWS Region: ca-central-1
Parameter IntakeFunctionName: <existing-physical-name-or-intake-lambda>
Parameter QueryFunctionName: query-lambda
Parameter LambdaPrincipal: *
Parameter PasetoPublicKey: <public-key-from-keygen>
Confirm changes before deploy: Y
Allow SAM CLI IAM role creation: Y
Disable rollback: N
Save arguments to configuration file: Y
SAM configuration file: samconfig.toml
SAM configuration environment: default
```

`CAPABILITY_IAM` is required because SAM creates IAM execution roles for both functions.

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
    IntakeFunctionName="$intake_function_name" \
    QueryFunctionName=query-lambda \
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
passes it as the `PasetoPublicKey` SAM parameter. When post-deploy checks are
enabled, it also requires the corresponding `PASETO_PRIVATE_KEY` to issue a
short-lived test token. It verifies unauthenticated HTTP 401 for both URLs,
authenticated query GET 200, authenticated wrong methods 405, and an
authenticated bodyless intake POST 400. The private key and test token are not printed or passed to the
Lambda environment. Use
`PASETO_PUBLIC_KEY='<public-key-from-keygen>' ./deploy.sh --dry-run` to run the
local checks, rebuild both Lambda zip archives, and validate `template.yaml` without
deploying to AWS.

For non-dry-run deployments, the helper resolves and verifies the selected AWS
profile before starting local work. It exports the resolved credentials only to
the script process and its children, so SAM and the post-deploy AWS commands use
the same credential snapshot instead of resolving the SSO profile again. When
resolution or STS verification fails for a profile configured with `sso_session`
or the legacy `sso_start_url`, it runs one interactive `aws sso login`, resolves
the credentials again, and stops if login, resolution, or verification fails.
Non-SSO profile failures stop without attempting SSO login. Dry runs make no AWS
authentication calls, and the helper does not print or write resolved
credentials.

After a successful deployment, `deploy.sh` resolves the
`OperationsTable` physical resource, waits for the table to exist, and prints a
concise table summary. It fails unless the table is active, uses on-demand
billing, has only the `id` string partition key, and has no local or global
secondary indexes. It then resolves the `OperationsQueue` physical resource and calls
`GetQueueAttributes` to print a concise SQS summary. This probe verifies that
the deployed queue can be queried but does not enforce SQS attribute values.
The intake and query Function URL checks then run.

Use
`PASETO_PUBLIC_KEY='<public-key-from-keygen>' ./deploy.sh --dry-run --use-local-libs`
to build with local dependency checkouts. The `aws_lambda` checkout defaults
to `../aws-lambda-zig`; override it with `LOCAL_AWS_LAMBDA_ROOT` when needed.

## 7. Read the stack outputs

After deployment, SAM prints stack outputs. Look for:

```text
IntakeFunctionName
IntakeFunctionArn
IntakeFunctionUrl
QueryFunctionName
QueryFunctionArn
QueryFunctionUrl
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

`lambda_logs.sh` resolves the explicit intake or query function-name output.
`persistence.sh` and `queue.sh` resolve the `OperationsTable` and
`OperationsQueue` physical resources directly because those data-plane names
are intentionally not public stack outputs. Normal local command use does not
require exporting those values.

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

Send the token in the authorization header:

```sh
curl -L -H "Authorization: Bearer $token" <QueryFunctionUrl>
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
OPERATIONS_QUEUE_URL=<CloudFormation-generated-queue-url>
OPERATIONS_TABLE_NAME=<CloudFormation-generated-table-name>
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
Operation ID and hash idempotently.

## 9. Download Lambda logs

Run the stack-aware log helper with an explicit Lambda selection:

```sh
./lambda_logs.sh intake
./lambda_logs.sh query
```

The stack name is fixed as `aws-lambda-zig-demo`. The helper resolves
`IntakeFunctionName` or `QueryFunctionName` and writes a root-level file named
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

### Troubleshoot Lambda intake initialization

The SAM template supplies `OPERATIONS_TABLE_NAME`, `OPERATIONS_QUEUE_URL`, and
their scoped IAM policies together. Removing either variable, configuring an
empty or oversized queue URL, or configuring an invalid DynamoDB table name
makes the bootstrap exit during Lambda INIT, before it requests an invocation.
Check the deployed template and function configuration; no HTTP response can
be produced for an INIT failure.

A syntactically valid but nonexistent table, or missing `PutItem` permission,
does not fail INIT because startup makes no DynamoDB request. The first valid,
authenticated POST returns a sanitized HTTP 500 in those cases; inspect Lambda
logs and the SAM-managed stack resources without recording live table names or
account-specific identifiers in this repository. Likewise, a syntactically
valid but nonexistent queue or missing `SendMessage` permission is discovered
only when POST attempts submission and returns a sanitized HTTP 503.

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
permissions are independent of the Lambda role, which remains send-only for
SQS.

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
```

Then redeploy the stack:

```sh
sam deploy --profile dev --region ca-central-1
```

SAM uploads both packages and updates their CloudFormation-managed Lambda functions.

## 13. Delete the SAM stack

To remove both SAM-managed functions, roles, the operations table and queue,
Function URLs, and permissions:

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

## Security note

This demo intentionally creates two publicly reachable Lambda Function URLs,
and both handlers require a valid PASETO bearer token. For production, consider
combining application authentication with stricter infrastructure
authorization, narrower IAM policies, or an API Gateway/CloudFront layer.
