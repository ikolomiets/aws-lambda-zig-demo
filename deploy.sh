#!/usr/bin/env bash
set -euo pipefail

PROFILE="${PROFILE:-dev}"
REGION="${REGION:-ca-central-1}"
STACK_NAME="${STACK_NAME:-aws-lambda-zig-demo}"
FUNCTION_NAME="${FUNCTION_NAME:-aws-lambda-zig-demo}"
LAMBDA_PRINCIPAL="${LAMBDA_PRINCIPAL:-*}"
DRY_RUN=0
CHECK_URL=1

usage() {
    cat <<'EOF'
Usage: ./deploy.sh [options]

Build, package, validate, and deploy the Zig Lambda with AWS SAM.

Options:
  --profile NAME         AWS CLI profile. Defaults to $PROFILE or dev.
  --region NAME          AWS region. Defaults to $REGION or ca-central-1.
  --stack-name NAME      CloudFormation stack name. Defaults to aws-lambda-zig-demo.
  --function-name NAME   Lambda function name. Defaults to aws-lambda-zig-demo.
  --lambda-principal VALUE
                         LAMBDA_PRINCIPAL environment value. Defaults to *.
  --dry-run              Run local checks, build, package, and validation only.
  --no-url-check         Skip the post-deploy Function URL HTTP status check.
  -h, --help             Show this help.

Environment overrides:
  PROFILE, REGION, STACK_NAME, FUNCTION_NAME, LAMBDA_PRINCIPAL
EOF
}

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

need_value() {
    if [ "$#" -eq 0 ]; then
        fail "missing value for $1"
    fi
    if [ -z "$2" ]; then
        fail "empty value for $1"
    fi
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --profile)
            need_value "$1" "${2:-}"
            PROFILE="$2"
            shift 2
            ;;
        --profile=*)
            PROFILE="${1#*=}"
            [ -n "$PROFILE" ] || fail "empty value for --profile"
            shift
            ;;
        --region)
            need_value "$1" "${2:-}"
            REGION="$2"
            shift 2
            ;;
        --region=*)
            REGION="${1#*=}"
            [ -n "$REGION" ] || fail "empty value for --region"
            shift
            ;;
        --stack-name)
            need_value "$1" "${2:-}"
            STACK_NAME="$2"
            shift 2
            ;;
        --stack-name=*)
            STACK_NAME="${1#*=}"
            [ -n "$STACK_NAME" ] || fail "empty value for --stack-name"
            shift
            ;;
        --function-name)
            need_value "$1" "${2:-}"
            FUNCTION_NAME="$2"
            shift 2
            ;;
        --function-name=*)
            FUNCTION_NAME="${1#*=}"
            [ -n "$FUNCTION_NAME" ] || fail "empty value for --function-name"
            shift
            ;;
        --lambda-principal)
            need_value "$1" "${2:-}"
            LAMBDA_PRINCIPAL="$2"
            shift 2
            ;;
        --lambda-principal=*)
            LAMBDA_PRINCIPAL="${1#*=}"
            [ -n "$LAMBDA_PRINCIPAL" ] || fail "empty value for --lambda-principal"
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --no-url-check)
            CHECK_URL=0
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

cd "$(dirname "$0")"

need_command zig
need_command zip
need_command file
need_command sam
if [ "$DRY_RUN" -eq 0 ]; then
    need_command aws
    if [ "$CHECK_URL" -eq 1 ]; then
        need_command curl
    fi
fi

LAMBDA_ROOT=""
for path in zig-pkg/aws_lambda-*; do
    if [ -d "$path" ]; then
        LAMBDA_ROOT="$path"
        break
    fi
done
[ -n "$LAMBDA_ROOT" ] || fail "vendored aws_lambda package not found under zig-pkg/"

CACHE_DIR=".zig-cache-deploy"
GLOBAL_CACHE_DIR=".zig-global-cache-deploy"
cleanup() {
    rm -rf "$CACHE_DIR" "$GLOBAL_CACHE_DIR"
}
trap cleanup EXIT

printf '==> Checking Zig formatting\n'
zig fmt --check build.zig src/main.zig

printf '==> Running Zig tests\n'
zig test \
    --cache-dir "$CACHE_DIR" \
    --global-cache-dir "$GLOBAL_CACHE_DIR" \
    --dep aws-lambda \
    -Mroot=src/main.zig \
    -Maws-lambda="$LAMBDA_ROOT/src/root.zig"

printf '==> Building Linux ARM64 Lambda bootstrap\n'
zig build --global-cache-dir "$GLOBAL_CACHE_DIR" --release -Darch=arm

artifact_type="$(file zig-out/bin/bootstrap)"
case "$artifact_type" in
    *"ELF 64-bit LSB executable"*aarch64*"statically linked"*"stripped"*) ;;
    *) fail "unexpected bootstrap artifact type: $artifact_type" ;;
esac
printf '%s\n' "$artifact_type"

printf '==> Refreshing lambda.zip\n'
zip -qj lambda.zip zig-out/bin/bootstrap

printf '==> Validating SAM template\n'
sam validate --template-file template.yaml --region "$REGION"
sam validate --lint --template-file template.yaml --region "$REGION"

if [ "$DRY_RUN" -eq 1 ]; then
    printf '==> Dry run complete. Skipped SAM deploy.\n'
    exit 0
fi

printf '==> Verifying AWS profile %s\n' "$PROFILE"
aws sts get-caller-identity --profile "$PROFILE" --query Arn --output text >/dev/null ||
    fail "AWS profile check failed. Run: aws sso login --profile $PROFILE"

printf '==> Deploying stack %s to %s\n' "$STACK_NAME" "$REGION"
sam deploy \
    --template-file template.yaml \
    --stack-name "$STACK_NAME" \
    --profile "$PROFILE" \
    --region "$REGION" \
    --capabilities CAPABILITY_IAM \
    --resolve-s3 \
    --no-confirm-changeset \
    --no-fail-on-empty-changeset \
    --no-progressbar \
    --parameter-overrides \
    "FunctionName=$FUNCTION_NAME" \
    "LambdaPrincipal=$LAMBDA_PRINCIPAL"

printf '==> Stack status\n'
aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query 'Stacks[0].StackStatus' \
    --output text \
    --profile "$PROFILE" \
    --region "$REGION"

FUNCTION_URL="$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='FunctionUrl'].OutputValue | [0]" \
    --output text \
    --profile "$PROFILE" \
    --region "$REGION")"

printf 'FunctionUrl: %s\n' "$FUNCTION_URL"

if [ "$CHECK_URL" -eq 1 ]; then
    printf '==> Checking Function URL status\n'
    curl -L -sS -o /dev/null -w 'HTTP %{http_code} %{content_type}\n' "$FUNCTION_URL"
fi
