#!/usr/bin/env bash
set -euo pipefail

PROFILE="${PROFILE:-dev}"
REGION="${REGION:-ca-central-1}"
STACK_NAME="${STACK_NAME:-aws-lambda-zig-demo}"
FUNCTION_NAME="${FUNCTION_NAME:-aws-lambda-zig-demo}"
LAMBDA_PRINCIPAL="${LAMBDA_PRINCIPAL:-*}"
PASETO_PUBLIC_KEY="${PASETO_PUBLIC_KEY:-}"
LOCAL_AWS_LAMBDA_ROOT="${LOCAL_AWS_LAMBDA_ROOT:-../aws-lambda-zig}"
DRY_RUN=0
CHECK_URL=1
USE_LOCAL_LIBS=0

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
  --use-local-libs       Use local dependency checkouts with zig build --fork.
                         aws_lambda defaults to ../aws-lambda-zig.
  --dry-run              Run local checks, build, package, and validation only.
  --no-url-check         Skip the post-deploy Function URL HTTP status check.
  -h, --help             Show this help.

Environment overrides:
  PROFILE, REGION, STACK_NAME, FUNCTION_NAME, LAMBDA_PRINCIPAL,
  PASETO_PRIVATE_KEY, PASETO_PUBLIC_KEY, LOCAL_AWS_LAMBDA_ROOT
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
        --use-local-libs)
            USE_LOCAL_LIBS=1
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

if [ "$DRY_RUN" -eq 0 ]; then
    need_command aws

    printf '==> Verifying AWS profile %s\n' "$PROFILE"
    aws sts get-caller-identity --profile "$PROFILE" --query Arn --output text >/dev/null ||
        fail "AWS profile check failed. Run: aws sso login --profile $PROFILE"
fi

[ -n "$PASETO_PUBLIC_KEY" ] ||
    fail "PASETO_PUBLIC_KEY is required; generate one with: zig-out/bin/paseto keygen"
if [ "$DRY_RUN" -eq 0 ] && [ "$CHECK_URL" -eq 1 ]; then
    [ -n "${PASETO_PRIVATE_KEY:-}" ] ||
        fail "PASETO_PRIVATE_KEY is required for the authenticated Function URL check"
fi

need_command zig
need_command zip
need_command file
need_command sam
if [ "$DRY_RUN" -eq 0 ]; then
    if [ "$CHECK_URL" -eq 1 ]; then
        need_command curl
    fi
fi

LOCAL_FORKS=()
if [ "$USE_LOCAL_LIBS" -eq 1 ]; then
    [ -d "$LOCAL_AWS_LAMBDA_ROOT" ] ||
        fail "local aws_lambda checkout not found: $LOCAL_AWS_LAMBDA_ROOT"
    [ -f "$LOCAL_AWS_LAMBDA_ROOT/build.zig.zon" ] ||
        fail "local aws_lambda checkout missing build.zig.zon: $LOCAL_AWS_LAMBDA_ROOT"
    [ -f "$LOCAL_AWS_LAMBDA_ROOT/src/root.zig" ] ||
        fail "local aws_lambda checkout missing src/root.zig: $LOCAL_AWS_LAMBDA_ROOT"

    LOCAL_FORKS+=("$LOCAL_AWS_LAMBDA_ROOT")
fi

CACHE_DIR=".zig-cache-deploy"
GLOBAL_CACHE_DIR=".zig-global-cache-deploy"
cleanup() {
    rm -rf "$CACHE_DIR" "$GLOBAL_CACHE_DIR"
}
trap cleanup EXIT

printf '==> Checking Zig formatting\n'
zig fmt --check build.zig src/main.zig src/paseto.zig src/paseto_cli.zig

ZIG_BUILD_ARGS=(
    --cache-dir "$CACHE_DIR"
    --global-cache-dir "$GLOBAL_CACHE_DIR"
)
if [ "${#LOCAL_FORKS[@]}" -gt 0 ]; then
    printf '==> Using local Zig package forks\n'
    for path in "${LOCAL_FORKS[@]}"; do
        printf '    %s\n' "$path"
        ZIG_BUILD_ARGS+=(--fork="$path")
    done
fi

printf '==> Running Zig tests\n'
zig build test "${ZIG_BUILD_ARGS[@]}"

printf '==> Building Linux ARM64 Lambda bootstrap\n'
zig build "${ZIG_BUILD_ARGS[@]}" --release -Darch=arm

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
    "LambdaPrincipal=$LAMBDA_PRINCIPAL" \
    "PasetoPublicKey=$PASETO_PUBLIC_KEY"

printf '==> Stack status\n'
aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query 'Stacks[0].StackStatus' \
    --output text \
    --profile "$PROFILE" \
    --region "$REGION"

OPERATIONS_TABLE_NAME="$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='OperationsTableName'].OutputValue | [0]" \
    --output text \
    --profile "$PROFILE" \
    --region "$REGION")"

case "$OPERATIONS_TABLE_NAME" in
    "" | None)
        fail "stack output OperationsTableName is missing or empty"
        ;;
esac

printf '==> Waiting for DynamoDB table %s\n' "$OPERATIONS_TABLE_NAME"
aws dynamodb wait table-exists \
    --table-name "$OPERATIONS_TABLE_NAME" \
    --profile "$PROFILE" \
    --region "$REGION"

printf '==> DynamoDB table summary\n'
aws dynamodb describe-table \
    --table-name "$OPERATIONS_TABLE_NAME" \
    --query '{TableName:Table.TableName,TableStatus:Table.TableStatus,BillingMode:Table.BillingModeSummary.BillingMode,AttributeDefinitions:Table.AttributeDefinitions,KeySchema:Table.KeySchema,LocalSecondaryIndexesPresent:length(not_null(Table.LocalSecondaryIndexes, `[]`)) > `0`,GlobalSecondaryIndexesPresent:length(not_null(Table.GlobalSecondaryIndexes, `[]`)) > `0`}' \
    --output json \
    --profile "$PROFILE" \
    --region "$REGION"

TABLE_VALIDATION="$(aws dynamodb describe-table \
    --table-name "$OPERATIONS_TABLE_NAME" \
    --query 'Table.[TableName,TableStatus,BillingModeSummary.BillingMode,length(AttributeDefinitions),AttributeDefinitions[0].AttributeName,AttributeDefinitions[0].AttributeType,length(KeySchema),KeySchema[0].AttributeName,KeySchema[0].KeyType,length(not_null(LocalSecondaryIndexes, `[]`)),length(not_null(GlobalSecondaryIndexes, `[]`))]' \
    --output text \
    --profile "$PROFILE" \
    --region "$REGION")"

read -r \
    ACTUAL_TABLE_NAME \
    TABLE_STATUS \
    BILLING_MODE \
    ATTRIBUTE_COUNT \
    ATTRIBUTE_NAME \
    ATTRIBUTE_TYPE \
    KEY_COUNT \
    KEY_NAME \
    KEY_TYPE \
    LOCAL_INDEX_COUNT \
    GLOBAL_INDEX_COUNT <<<"$TABLE_VALIDATION"

[ "$ACTUAL_TABLE_NAME" = "$OPERATIONS_TABLE_NAME" ] ||
    fail "DynamoDB table name $ACTUAL_TABLE_NAME does not match stack output $OPERATIONS_TABLE_NAME"
[ "$TABLE_STATUS" = ACTIVE ] ||
    fail "DynamoDB table status is $TABLE_STATUS; expected ACTIVE"
[ "$BILLING_MODE" = PAY_PER_REQUEST ] ||
    fail "DynamoDB billing mode is $BILLING_MODE; expected PAY_PER_REQUEST"
[ "$ATTRIBUTE_COUNT" = 1 ] ||
    fail "DynamoDB table has $ATTRIBUTE_COUNT attribute definitions; expected 1"
[ "$ATTRIBUTE_NAME" = id ] ||
    fail "DynamoDB attribute name is $ATTRIBUTE_NAME; expected id"
[ "$ATTRIBUTE_TYPE" = S ] ||
    fail "DynamoDB id attribute type is $ATTRIBUTE_TYPE; expected S"
[ "$KEY_COUNT" = 1 ] ||
    fail "DynamoDB table has $KEY_COUNT key schema entries; expected 1"
[ "$KEY_NAME" = id ] ||
    fail "DynamoDB key name is $KEY_NAME; expected id"
[ "$KEY_TYPE" = HASH ] ||
    fail "DynamoDB id key type is $KEY_TYPE; expected HASH"
[ "$LOCAL_INDEX_COUNT" = 0 ] ||
    fail "DynamoDB table has $LOCAL_INDEX_COUNT local secondary indexes; expected 0"
[ "$GLOBAL_INDEX_COUNT" = 0 ] ||
    fail "DynamoDB table has $GLOBAL_INDEX_COUNT global secondary indexes; expected 0"

FUNCTION_URL="$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='FunctionUrl'].OutputValue | [0]" \
    --output text \
    --profile "$PROFILE" \
    --region "$REGION")"

printf 'FunctionUrl: %s\n' "$FUNCTION_URL"

if [ "$CHECK_URL" -eq 1 ]; then
    printf '==> Checking unauthenticated Function URL status\n'
    HTTP_STATUS="$(curl -L -sS -o /dev/null -w '%{http_code}' "$FUNCTION_URL")"
    [ "$HTTP_STATUS" = 401 ] ||
        fail "unauthenticated Function URL returned HTTP $HTTP_STATUS; expected 401"
    printf 'HTTP %s (expected 401)\n' "$HTTP_STATUS"

    printf '==> Checking authenticated Function URL status\n'
    PASETO_TOKEN="$(
        ./zig-out/bin/paseto issue --subject deploy-test --ttl-seconds 10
    )"
    HTTP_STATUS="$(curl -L -sS -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${PASETO_TOKEN}" \
        "$FUNCTION_URL")"
    [ "$HTTP_STATUS" = 200 ] ||
        fail "authenticated Function URL returned HTTP $HTTP_STATUS; expected 200"
    printf 'HTTP %s (expected 200)\n' "$HTTP_STATUS"
fi
