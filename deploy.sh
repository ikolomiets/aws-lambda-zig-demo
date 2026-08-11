#!/usr/bin/env bash
set -euo pipefail

PROFILE="${PROFILE:-dev}"
REGION="${REGION:-ca-central-1}"
STACK_NAME="${STACK_NAME:-aws-lambda-zig-demo}"
INTAKE_FUNCTION_NAME="${INTAKE_FUNCTION_NAME:-intake-lambda}"
QUERY_FUNCTION_NAME="${QUERY_FUNCTION_NAME:-query-lambda}"
LAMBDA_PRINCIPAL="${LAMBDA_PRINCIPAL:-*}"
PASETO_PUBLIC_KEY="${PASETO_PUBLIC_KEY:-}"
LOCAL_AWS_LAMBDA_ROOT="${LOCAL_AWS_LAMBDA_ROOT:-../aws-lambda-zig}"
DRY_RUN=0
CHECK_URL=1
USE_LOCAL_LIBS=0
MIGRATION_CHECK_ONLY=0

usage() {
    cat <<'EOF'
Usage: ./deploy.sh [options]

Build, package, validate, and deploy the Zig Lambdas with AWS SAM.

Options:
  --profile NAME         AWS CLI profile. Defaults to $PROFILE or dev.
  --region NAME          AWS region. Defaults to $REGION or ca-central-1.
  --stack-name NAME      CloudFormation stack name. Defaults to aws-lambda-zig-demo.
  --intake-function-name NAME
                         Intake Lambda name. Defaults to intake-lambda.
  --query-function-name NAME
                         Query Lambda name. Defaults to query-lambda.
  --lambda-principal VALUE
                         LAMBDA_PRINCIPAL environment value. Defaults to *.
  --use-local-libs       Use local dependency checkouts with zig build --fork.
                         aws_lambda defaults to ../aws-lambda-zig.
  --dry-run              Run local checks, build, package, and validation only.
  --migration-check-only Validate the existing intake function name, then exit.
  --no-url-check         Skip the post-deploy Function URL HTTP status check.
  -h, --help             Show this help.

Environment overrides:
  PROFILE, REGION, STACK_NAME, INTAKE_FUNCTION_NAME, QUERY_FUNCTION_NAME,
  LAMBDA_PRINCIPAL,
  PASETO_PRIVATE_KEY, PASETO_PUBLIC_KEY, LOCAL_AWS_LAMBDA_ROOT

Authentication:
  Non-dry-run deployments resolve and verify the selected profile credentials
  before building. Valid cached credentials are reused. If resolution or
  verification fails for an SSO-backed profile, the script runs aws sso login
  once and retries.
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

profile_uses_sso() {
    local profile="$1"

    if aws configure get sso_session --profile "$profile" >/dev/null 2>&1; then
        return 0
    fi
    aws configure get sso_start_url --profile "$profile" >/dev/null 2>&1
}

clear_aws_credentials() {
    unset AWS_ACCESS_KEY_ID
    unset AWS_SECRET_ACCESS_KEY
    unset AWS_SESSION_TOKEN
    unset AWS_SECURITY_TOKEN
    unset AWS_CREDENTIAL_EXPIRATION
}

load_aws_credentials() {
    local profile="$1"
    local credential_exports

    clear_aws_credentials
    credential_exports="$(
        aws configure export-credentials \
            --profile "$profile" \
            --format env
    )" || return 1

    [ -n "$credential_exports" ] || return 1
    eval "$credential_exports"
    unset credential_exports

    [ -n "${AWS_ACCESS_KEY_ID:-}" ] || return 1
    [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] || return 1
}

verify_aws_credentials() {
    aws sts get-caller-identity \
        --query Arn \
        --output text \
        >/dev/null 2>&1
}

prepare_aws_credentials() {
    local profile="$1"

    unset AWS_PROFILE
    unset AWS_DEFAULT_PROFILE

    printf '==> Resolving AWS credentials for profile %s\n' "$profile"
    if load_aws_credentials "$profile"
    then
        printf '==> Verifying resolved AWS credentials\n'
        if verify_aws_credentials; then
            return 0
        fi
    fi

    clear_aws_credentials
    profile_uses_sso "$profile" ||
        fail "AWS credential resolution failed for non-SSO profile $profile"

    printf '==> Refreshing AWS SSO session for profile %s\n' "$profile"
    aws sso login --profile "$profile" ||
        fail "AWS SSO login failed for profile $profile"

    printf '==> Re-resolving AWS credentials for profile %s\n' "$profile"
    load_aws_credentials "$profile" ||
        fail "AWS credential resolution failed after SSO login for profile $profile"

    printf '==> Verifying resolved AWS credentials\n'
    verify_aws_credentials ||
        fail "AWS credential verification failed after SSO login for profile $profile"
}

validate_existing_intake_name() {
    local requested_name="$1"
    local physical_name

    if physical_name="$(
        aws cloudformation describe-stack-resource \
            --stack-name "$STACK_NAME" \
            --logical-resource-id IntakeFunction \
            --query StackResourceDetail.PhysicalResourceId \
            --output text \
            --region "$REGION" \
            2>&1
    )"
    then
        case "$physical_name" in
            "" | None)
                fail "stack $STACK_NAME returned no physical IntakeFunction name"
                ;;
        esac
        if [ "$physical_name" != "$requested_name" ]; then
            fail "existing IntakeFunction is $physical_name; set INTAKE_FUNCTION_NAME=$physical_name to update it in place"
        fi
        printf '==> Existing IntakeFunction name matches: %s\n' "$physical_name"
        return 0
    fi

    case "$physical_name" in
        *"does not exist"*)
            printf '==> Stack %s does not exist; no intake-name migration is required\n' \
                "$STACK_NAME"
            ;;
        *)
            fail "could not inspect IntakeFunction in stack $STACK_NAME"
            ;;
    esac
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
        --intake-function-name)
            need_value "$1" "${2:-}"
            INTAKE_FUNCTION_NAME="$2"
            shift 2
            ;;
        --intake-function-name=*)
            INTAKE_FUNCTION_NAME="${1#*=}"
            [ -n "$INTAKE_FUNCTION_NAME" ] ||
                fail "empty value for --intake-function-name"
            shift
            ;;
        --query-function-name)
            need_value "$1" "${2:-}"
            QUERY_FUNCTION_NAME="$2"
            shift 2
            ;;
        --query-function-name=*)
            QUERY_FUNCTION_NAME="${1#*=}"
            [ -n "$QUERY_FUNCTION_NAME" ] ||
                fail "empty value for --query-function-name"
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
        --migration-check-only)
            MIGRATION_CHECK_ONLY=1
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

[ "$DRY_RUN" -eq 0 ] || [ "$MIGRATION_CHECK_ONLY" -eq 0 ] ||
    fail "--dry-run and --migration-check-only cannot be combined"

if [ "$DRY_RUN" -eq 0 ]; then
    need_command aws
    prepare_aws_credentials "$PROFILE"
    validate_existing_intake_name "$INTAKE_FUNCTION_NAME"
fi
if [ "$MIGRATION_CHECK_ONLY" -eq 1 ]; then
    printf '==> Intake-name migration check complete. Skipped build and deploy.\n'
    exit 0
fi

[ -n "$PASETO_PUBLIC_KEY" ] ||
    fail "PASETO_PUBLIC_KEY is required; generate one with: zig-out/bin/paseto keygen"
if [ "$DRY_RUN" -eq 0 ] && [ "$CHECK_URL" -eq 1 ]; then
    [ -n "${PASETO_PRIVATE_KEY:-}" ] ||
        fail "PASETO_PRIVATE_KEY is required for the authenticated Function URL check"
fi

need_command zig
need_command zip
need_command unzip
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
zig fmt --check \
    build.zig \
    src/intake_lambda.zig \
    src/lambda_auth.zig \
    src/paseto.zig \
    src/paseto_cli.zig \
    src/query_lambda.zig

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

printf '==> Removing obsolete root Lambda bootstrap\n'
rm -f zig-out/bin/bootstrap

printf '==> Building Linux ARM64 Lambda bootstraps\n'
zig build "${ZIG_BUILD_ARGS[@]}" --release -Darch=arm

for bootstrap in zig-out/bin/intake/bootstrap zig-out/bin/query/bootstrap; do
    artifact_type="$(file "$bootstrap")"
    case "$artifact_type" in
        *"ELF 64-bit LSB executable"*aarch64*"statically linked"*"stripped"*) ;;
        *) fail "unexpected bootstrap artifact type: $artifact_type" ;;
    esac
    printf '%s\n' "$artifact_type"
done
[ ! -e zig-out/bin/bootstrap ] || fail "obsolete zig-out/bin/bootstrap was recreated"

printf '==> Refreshing Lambda zip archives\n'
rm -f intake-lambda.zip query-lambda.zip
zip -qj intake-lambda.zip zig-out/bin/intake/bootstrap
zip -qj query-lambda.zip zig-out/bin/query/bootstrap
for archive in intake-lambda.zip query-lambda.zip; do
    archive_contents="$(unzip -Z1 "$archive")"
    [ "$archive_contents" = bootstrap ] ||
        fail "$archive must contain only a root-level bootstrap"
done

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
    --region "$REGION" \
    --capabilities CAPABILITY_IAM \
    --resolve-s3 \
    --no-confirm-changeset \
    --no-fail-on-empty-changeset \
    --no-progressbar \
    --parameter-overrides \
    "IntakeFunctionName=$INTAKE_FUNCTION_NAME" \
    "QueryFunctionName=$QUERY_FUNCTION_NAME" \
    "LambdaPrincipal=$LAMBDA_PRINCIPAL" \
    "PasetoPublicKey=$PASETO_PUBLIC_KEY"

printf '==> Stack status\n'
aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query 'Stacks[0].StackStatus' \
    --output text \
    --region "$REGION"

OPERATIONS_TABLE_NAME="$(aws cloudformation describe-stack-resource \
    --stack-name "$STACK_NAME" \
    --logical-resource-id OperationsTable \
    --query StackResourceDetail.PhysicalResourceId \
    --output text \
    --region "$REGION")"

case "$OPERATIONS_TABLE_NAME" in
    "" | None)
        fail "stack resource OperationsTable has no physical name"
        ;;
esac

printf '==> Waiting for DynamoDB table %s\n' "$OPERATIONS_TABLE_NAME"
aws dynamodb wait table-exists \
    --table-name "$OPERATIONS_TABLE_NAME" \
    --region "$REGION"

printf '==> DynamoDB table summary\n'
aws dynamodb describe-table \
    --table-name "$OPERATIONS_TABLE_NAME" \
    --query '{TableName:Table.TableName,TableStatus:Table.TableStatus,BillingMode:Table.BillingModeSummary.BillingMode,AttributeDefinitions:Table.AttributeDefinitions,KeySchema:Table.KeySchema,LocalSecondaryIndexesPresent:length(not_null(Table.LocalSecondaryIndexes, `[]`)) > `0`,GlobalSecondaryIndexesPresent:length(not_null(Table.GlobalSecondaryIndexes, `[]`)) > `0`}' \
    --output json \
    --region "$REGION"

TABLE_VALIDATION="$(aws dynamodb describe-table \
    --table-name "$OPERATIONS_TABLE_NAME" \
    --query 'Table.[TableName,TableStatus,BillingModeSummary.BillingMode,length(AttributeDefinitions),AttributeDefinitions[0].AttributeName,AttributeDefinitions[0].AttributeType,length(KeySchema),KeySchema[0].AttributeName,KeySchema[0].KeyType,length(not_null(LocalSecondaryIndexes, `[]`)),length(not_null(GlobalSecondaryIndexes, `[]`))]' \
    --output text \
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
    fail "DynamoDB table name $ACTUAL_TABLE_NAME does not match stack resource $OPERATIONS_TABLE_NAME"
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

OPERATIONS_QUEUE_URL="$(aws cloudformation describe-stack-resource \
    --stack-name "$STACK_NAME" \
    --logical-resource-id OperationsQueue \
    --query StackResourceDetail.PhysicalResourceId \
    --output text \
    --region "$REGION")"

case "$OPERATIONS_QUEUE_URL" in
    "" | None)
        fail "stack resource OperationsQueue has no physical URL"
        ;;
esac

printf '==> SQS queue summary\n'
aws sqs get-queue-attributes \
    --queue-url "$OPERATIONS_QUEUE_URL" \
    --attribute-names \
    QueueArn \
    SqsManagedSseEnabled \
    VisibilityTimeout \
    MessageRetentionPeriod \
    ReceiveMessageWaitTimeSeconds \
    --query Attributes \
    --output json \
    --region "$REGION"

INTAKE_FUNCTION_URL="$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='IntakeFunctionUrl'].OutputValue | [0]" \
    --output text \
    --region "$REGION")"
QUERY_FUNCTION_URL="$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='QueryFunctionUrl'].OutputValue | [0]" \
    --output text \
    --region "$REGION")"

case "$INTAKE_FUNCTION_URL" in
    "" | None) fail "stack output IntakeFunctionUrl is missing or empty" ;;
esac
case "$QUERY_FUNCTION_URL" in
    "" | None) fail "stack output QueryFunctionUrl is missing or empty" ;;
esac

printf 'IntakeFunctionUrl: %s\n' "$INTAKE_FUNCTION_URL"
printf 'QueryFunctionUrl: %s\n' "$QUERY_FUNCTION_URL"

if [ "$CHECK_URL" -eq 1 ]; then
    printf '==> Checking unauthenticated intake and query statuses\n'
    for function_url in "$INTAKE_FUNCTION_URL" "$QUERY_FUNCTION_URL"; do
        HTTP_STATUS="$(curl -L -sS -o /dev/null -w '%{http_code}' "$function_url")"
        [ "$HTTP_STATUS" = 401 ] ||
            fail "unauthenticated Function URL returned HTTP $HTTP_STATUS; expected 401"
        printf 'HTTP %s (expected 401)\n' "$HTTP_STATUS"
    done

    printf '==> Checking authenticated tenant-scoped query GET status\n'
    PASETO_SUBJECT="deploy-query-test-${RANDOM}-${RANDOM}"
    PASETO_TOKEN="$(
        ./zig-out/bin/paseto issue --subject "$PASETO_SUBJECT" --ttl-seconds 60
    )"
    HTTP_STATUS="$(curl -L -sS -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${PASETO_TOKEN}" \
        "${QUERY_FUNCTION_URL%/}/00000000-0000-4000-8000-000000000000")"
    [ "$HTTP_STATUS" = 404 ] ||
        fail "authenticated query GET returned HTTP $HTTP_STATUS; expected 404"
    printf 'HTTP %s (expected tenant-safe 404)\n' "$HTTP_STATUS"

    printf '==> Checking authenticated wrong-method statuses\n'
    HTTP_STATUS="$(curl -L -sS -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${PASETO_TOKEN}" \
        "$INTAKE_FUNCTION_URL")"
    [ "$HTTP_STATUS" = 405 ] ||
        fail "authenticated intake GET returned HTTP $HTTP_STATUS; expected 405"
    printf 'Intake GET: HTTP %s (expected 405)\n' "$HTTP_STATUS"
    HTTP_STATUS="$(curl -L -sS -o /dev/null -w '%{http_code}' \
        -X POST \
        -H "Authorization: Bearer ${PASETO_TOKEN}" \
        "$QUERY_FUNCTION_URL")"
    [ "$HTTP_STATUS" = 405 ] ||
        fail "authenticated query POST returned HTTP $HTTP_STATUS; expected 405"
    printf 'Query POST: HTTP %s (expected 405)\n' "$HTTP_STATUS"

    printf '==> Checking authenticated bodyless intake POST status\n'
    HTTP_STATUS="$(curl -L -sS -o /dev/null -w '%{http_code}' \
        -X POST \
        -H "Authorization: Bearer ${PASETO_TOKEN}" \
        "$INTAKE_FUNCTION_URL")"
    [ "$HTTP_STATUS" = 400 ] ||
        fail "authenticated bodyless intake POST returned HTTP $HTTP_STATUS; expected 400"
    printf 'HTTP %s (expected 400)\n' "$HTTP_STATUS"
fi
