# aws-lambda-zig

A minimal AWS Lambda Function URL demo written in Zig.

The function builds a custom `provided.al2023` Lambda runtime executable named
`bootstrap`. The handler returns a plain-text `Hello, world!` response through
the `aws-lambda-zig` runtime package.

## Requirements

- Zig 0.16.0 or newer within the supported 0.16.x line.
- AWS CLI v2 for manual AWS operations.
- AWS SAM CLI for the SAM deployment flow.
- An AWS profile with permission to create Lambda, IAM, and CloudFormation
  resources.

The deployment docs use:

- AWS profile: `dev`
- Region: `ca-central-1`
- Function name: `aws-lambda-zig-hello`

Adjust those values for your AWS account as needed.

## Build

Build the stripped, single-threaded, ReleaseSafe Linux ARM64 Lambda executable:

```sh
zig build --release -Darch=arm
```

Verify that the output is a statically linked ARM64 Linux executable:

```sh
file zig-out/bin/bootstrap
```

Expected shape:

```text
ELF 64-bit LSB executable, ARM aarch64, statically linked, stripped
```

Package the executable for Lambda:

```sh
zip -qj lambda.zip zig-out/bin/bootstrap
```

`lambda.zip` is intentionally ignored by Git because it is a generated
deployment artifact.

## Deploy

The preferred deployment path is AWS SAM:

```sh
sam validate --template-file template.yaml --region ca-central-1
sam validate --lint --template-file template.yaml --region ca-central-1
sam deploy --guided \
  --template-file template.yaml \
  --profile dev \
  --region ca-central-1 \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides FunctionName=aws-lambda-zig-hello
```

See [docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md](docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md)
for the full SAM workflow.

There is also a manual AWS CLI deployment guide:
[docs/DEPLOY_AWS_LAMBDA_WITH_CLI.md](docs/DEPLOY_AWS_LAMBDA_WITH_CLI.md).

## Test The Function URL

After deployment, call the Function URL printed by SAM or the AWS CLI:

```sh
curl -L <FunctionUrl>
```

Expected response:

```text
Hello, world!
```

The template intentionally creates a public Function URL for demo HTTP GET
testing. Production endpoints should use stricter authorization, narrower IAM
policies, or a fronting layer such as API Gateway or CloudFront.

## Project Layout

- `src/main.zig`: Lambda entrypoint and request handler.
- `build.zig`: Zig build graph for the `bootstrap` executable.
- `build.zig.zon`: package metadata and `aws-lambda-zig` dependency.
- `template.yaml`: SAM template for the Lambda, Function URL, and permissions.
- `docs/`: deployment guides and the Zig style reference.
- `AGENTS.md`: repository guidance for coding agents.

## Development Notes

Run formatting checks before committing Zig changes:

```sh
zig fmt --check build.zig src/main.zig
```

Zig code in this repository should follow
[docs/TIGER_STYLE.md](docs/TIGER_STYLE.md).
