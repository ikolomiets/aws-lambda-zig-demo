# Deploy `lambda.zip` to AWS Lambda with SAM

This guide documents how to deploy the Zig Lambda package in this repository using AWS SAM and `template.yaml`.

SAM deploys the Lambda function as a CloudFormation-managed stack. It creates the Lambda function, execution role, public Function URL, and Function URL permissions.

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

- `DemoFunction`: `AWS::Serverless::Function`
- `DemoFunctionUrl`: `AWS::Lambda::Url`
- `FunctionUrlInvokeFunctionUrlPermission`: allows `lambda:InvokeFunctionUrl`
- `FunctionUrlInvokeFunctionPermission`: allows `lambda:InvokeFunction` only through the Function URL

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
Environment:
  Variables:
    LAMBDA_PRINCIPAL: !Ref LambdaPrincipal
    PASETO_PUBLIC_KEY: !Ref PasetoPublicKey
```

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

After the first guided deployment, SAM can reuse `samconfig.toml`, so future deployments are usually:

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
PASETO_PUBLIC_KEY='<public-key-from-keygen>' ./deploy.sh
```

Override the environment value with either form:

```sh
LAMBDA_PRINCIPAL='<lambda-principal>' ./deploy.sh
./deploy.sh --lambda-principal '<lambda-principal>'
```

`deploy.sh` reads the required `PASETO_PUBLIC_KEY` from the host environment and
passes it as the `PasetoPublicKey` SAM parameter. Use
`PASETO_PUBLIC_KEY='<public-key-from-keygen>' ./deploy.sh --dry-run` to run the
local checks, rebuild `lambda.zip`, and validate `template.yaml` without
deploying to AWS.

Use
`PASETO_PUBLIC_KEY='<public-key-from-keygen>' ./deploy.sh --dry-run --use-local-libs`
to build with local dependency checkouts. The `aws_lambda` checkout defaults
to `../aws-lambda-zig`; override it with `LOCAL_AWS_LAMBDA_ROOT` when needed.

## 7. Read the Function URL output

After deployment, SAM prints stack outputs. Look for:

```text
FunctionUrl
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
  --data '{"id":"00112233-4455-6677-8899-aabbccddeeff","name":"echo","body":{"message":"hello","count":2}}' \
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

## 9. Update the deployed Lambda code

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

## 10. Delete the SAM stack

To remove the SAM-managed function, role, Function URL, and permissions:

```sh
sam delete \
  --stack-name aws-lambda-zig-demo \
  --profile dev \
  --region ca-central-1
```

This deletes only resources owned by the SAM stack.

## Security note

This demo intentionally creates a publicly reachable Lambda Function URL, and
the handler requires a valid PASETO bearer token. For production, consider
combining application authentication with stricter infrastructure
authorization, narrower IAM policies, or an API Gateway/CloudFront layer.
