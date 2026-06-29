# Deploy `lambda.zip` to AWS Lambda with SAM

This guide documents how to deploy the Zig Lambda package in this repository using AWS SAM and `template.yaml`.

SAM deploys the Lambda function as a CloudFormation-managed stack. It creates the Lambda function, execution role, public Function URL, and Function URL permissions.

## Assumptions

- AWS CLI v2 and SAM CLI are installed.
- You have an IAM Identity Center / SSO profile named `dev`.
- The deployment region is `ca-central-1`.
- `template.yaml` exists in this repository.
- `lambda.zip` exists and contains a Linux ARM64 executable named `bootstrap`.
- The Lambda Function URL is intentionally public for demo HTTP GET testing.

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

Build the Lambda executable for AWS Lambda ARM64.

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

- `HelloFunction`: `AWS::Serverless::Function`
- `HelloFunctionUrl`: `AWS::Lambda::Url`
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
  AllowHeaders:
    - "*"
```

`AuthType: NONE` and `Principal: "*"` make the Function URL public.

## 5. Choose the function name

The template defaults to:

```text
aws-lambda-zig-hello
```

You can keep the default or override it during deployment with the `FunctionName` parameter.

## 6. Deploy with SAM guided mode

Run:

```sh
sam deploy --guided \
  --template-file template.yaml \
  --profile dev \
  --region ca-central-1 \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides FunctionName=aws-lambda-zig-hello
```

Recommended guided answers:

```text
Stack Name: aws-lambda-zig-hello
AWS Region: ca-central-1
Parameter FunctionName: aws-lambda-zig-hello
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
  --stack-name aws-lambda-zig-hello \
  --profile dev \
  --region ca-central-1 \
  --capabilities CAPABILITY_IAM \
  --resolve-s3 \
  --no-confirm-changeset \
  --no-fail-on-empty-changeset \
  --parameter-overrides FunctionName=aws-lambda-zig-hello
```

## 7. Read the Function URL output

After deployment, SAM prints stack outputs. Look for:

```text
FunctionUrl
```

You can also query it later with CloudFormation:

```sh
aws cloudformation describe-stacks \
  --stack-name aws-lambda-zig-hello \
  --query "Stacks[0].Outputs[?OutputKey=='FunctionUrl'].OutputValue" \
  --output text \
  --profile dev \
  --region ca-central-1
```

## 8. Test HTTP GET

Call the Function URL returned by SAM.

```sh
curl -L <FunctionUrl>
```

Expected response:

```text
Hello, world!
```

The response should render directly in a browser because the handler returns:

```text
Content-Type: text/plain; charset=utf-8
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
  --stack-name aws-lambda-zig-hello \
  --profile dev \
  --region ca-central-1
```

This deletes only resources owned by the SAM stack.

## Security note

This demo intentionally creates a public Lambda Function URL. For production, prefer a stricter authorization model, narrower IAM policies, or an API Gateway/CloudFront layer depending on the use case.
