# Deploy `lambda.zip` to AWS Lambda with AWS CLI

This guide documents the successful AWS CLI flow used to deploy the compiled Zig Lambda package in this repository and expose it through a public Lambda Function URL.

## Assumptions

- AWS CLI v2 is installed.
- You have an IAM Identity Center / SSO profile named `dev`.
- The deployment region is `ca-central-1`.
- `lambda.zip` already exists and contains a Linux ARM64 `bootstrap` executable.
- The Lambda is intentionally exposed through a public Function URL for simple HTTP GET testing.
- `LAMBDA_PRINCIPAL` defaults to `'*'` unless you set a different value before
  creating or updating the function configuration.
- `PASETO_PUBLIC_KEY` contains the padded Base64 Ed25519 public key generated
  by `zig-out/bin/paseto keygen`. Keep the corresponding private key only in
  the token-signing environment.

## Resource names

```sh
PROFILE=dev
REGION=ca-central-1
FUNCTION_NAME=aws-lambda-zig-demo
ROLE_NAME=aws-lambda-zig-demo-role
LAMBDA_PRINCIPAL='*'
PASETO_PUBLIC_KEY='<public-key-from-keygen>'
ACCOUNT_ID=$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
```

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

## 2. Confirm the deployment artifact

Check that the package and executable exist, and that the executable is ARM64 Linux.

```sh
ls -lh lambda.zip zig-out/bin/bootstrap
file zig-out/bin/bootstrap
```

Expected executable shape:

```text
ELF 64-bit LSB executable, ARM aarch64, statically linked, stripped
```

## 3. Create the Lambda execution role

Create an IAM role that Lambda can assume.

```sh
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  --profile "$PROFILE"
```

Attach the managed policy that lets Lambda write logs to CloudWatch.

```sh
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole \
  --profile "$PROFILE"
```

Wait until IAM reports the role as available.

```sh
aws iam wait role-exists \
  --role-name "$ROLE_NAME" \
  --profile "$PROFILE"
```

## 4. Create the Lambda function

Deploy `lambda.zip` as a custom Amazon Linux 2023 runtime. The executable inside the zip must be named `bootstrap`.

```sh
aws lambda create-function \
  --function-name "$FUNCTION_NAME" \
  --runtime provided.al2023 \
  --handler bootstrap \
  --architectures arm64 \
  --role "$ROLE_ARN" \
  --environment \
    "Variables={LAMBDA_PRINCIPAL=${LAMBDA_PRINCIPAL},PASETO_PUBLIC_KEY=${PASETO_PUBLIC_KEY}}" \
  --zip-file fileb://lambda.zip \
  --profile "$PROFILE" \
  --region "$REGION"
```

`LAMBDA_PRINCIPAL` is a runtime environment variable visible to the function.
It does not change the Function URL resource permissions.
`PASETO_PUBLIC_KEY` is required by the handler to verify PASETO v4.public
bearer tokens.

Wait until the function is active.

```sh
aws lambda wait function-active-v2 \
  --function-name "$FUNCTION_NAME" \
  --profile "$PROFILE" \
  --region "$REGION"
```

## 5. Verify direct Lambda invocation

Invoke the function through the Lambda API before exposing it over HTTP. An
empty event has no authorization header and exercises the credential failure
response.

```sh
aws lambda invoke \
  --function-name "$FUNCTION_NAME" \
  --payload '{}' \
  /tmp/aws-lambda-zig-demo-invoke.json \
  --profile "$PROFILE" \
  --region "$REGION"
```

Read the response payload.

```sh
cat /tmp/aws-lambda-zig-demo-invoke.json
```

Expected response:

```json
{
  "statusCode": 401,
  "headers": {
    "Content-Type": "text/plain; charset=utf-8",
    "WWW-Authenticate": "Bearer"
  },
  "body": "Unauthorized\n"
}
```

## 6. Create a public Lambda Function URL

Create an unauthenticated Function URL and limit CORS methods to `GET` for browser testing.

```sh
aws lambda create-function-url-config \
  --function-name "$FUNCTION_NAME" \
  --auth-type NONE \
  --cors '{"AllowOrigins":["*"],"AllowMethods":["GET"],"AllowHeaders":["*"]}' \
  --profile "$PROFILE" \
  --region "$REGION"
```

Save the returned `FunctionUrl` value. You can query it later with:

```sh
FUNCTION_URL=$(aws lambda get-function-url-config \
  --function-name "$FUNCTION_NAME" \
  --query FunctionUrl \
  --output text \
  --profile "$PROFILE" \
  --region "$REGION")
```

## 7. Allow public Function URL invocation

For public Lambda Function URLs, add both resource policy statements below. The first allows Function URL invocation. The second allows Lambda invocation only when the request arrives through the Function URL.

```sh
aws lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --statement-id FunctionURLAllowPublicAccess \
  --action lambda:InvokeFunctionUrl \
  --principal '*' \
  --function-url-auth-type NONE \
  --profile "$PROFILE" \
  --region "$REGION"
```

```sh
aws lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --statement-id FunctionURLInvokeAllowPublicAccess \
  --action lambda:InvokeFunction \
  --principal '*' \
  --invoked-via-function-url \
  --profile "$PROFILE" \
  --region "$REGION"
```

## 8. Test HTTP GET

Query the Function URL if it is not already in your shell, then call it.

```sh
FUNCTION_URL=$(aws lambda get-function-url-config \
  --function-name "$FUNCTION_NAME" \
  --query FunctionUrl \
  --output text \
  --profile "$PROFILE" \
  --region "$REGION")

curl -i -L "$FUNCTION_URL"
```

Expected unauthenticated response:

```text
HTTP/2 401
WWW-Authenticate: Bearer
```

Issue a short-lived token using the corresponding private key:

```sh
TOKEN="$(
  PASETO_PRIVATE_KEY='<private-key-from-keygen>' \
    zig-out/bin/paseto issue --subject 'example-user' --ttl-seconds 300
)"
```

Call the Function URL with the bearer token:

```sh
curl -L -H "Authorization: Bearer $TOKEN" "$FUNCTION_URL"
```

Expected authenticated response:

```text
ConfigMeta
...

RequestMeta
...

Environment
LAMBDA_PRINCIPAL=*
PASETO_PUBLIC_KEY=<public-key-from-keygen>
...
```

## Updating the deployed code

After rebuilding and repackaging `lambda.zip`, update the existing function code with:

```sh
aws lambda update-function-code \
  --function-name "$FUNCTION_NAME" \
  --zip-file fileb://lambda.zip \
  --profile "$PROFILE" \
  --region "$REGION"
```

Then wait for the update:

```sh
aws lambda wait function-updated-v2 \
  --function-name "$FUNCTION_NAME" \
  --profile "$PROFILE" \
  --region "$REGION"
```

To change `LAMBDA_PRINCIPAL` or rotate the PASETO public key on an existing
function, update the function configuration. AWS replaces the complete
environment map, so provide both values:

```sh
LAMBDA_PRINCIPAL='<lambda-principal>'
PASETO_PUBLIC_KEY='<public-key-from-keygen>'

aws lambda update-function-configuration \
  --function-name "$FUNCTION_NAME" \
  --environment \
    "Variables={LAMBDA_PRINCIPAL=${LAMBDA_PRINCIPAL},PASETO_PUBLIC_KEY=${PASETO_PUBLIC_KEY}}" \
  --profile "$PROFILE" \
  --region "$REGION"
```

## Security note

`--auth-type NONE` and `--principal '*'` make the Function URL publicly
reachable, while the handler requires a valid PASETO bearer token. For
production, consider combining application authentication with stricter
infrastructure authorization, narrower IAM policies, or an API
Gateway/CloudFront layer.
