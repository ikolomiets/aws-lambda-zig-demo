#!/usr/bin/env bash
set -euo pipefail

PROFILE="${PROFILE:-dev}"
REGION="${REGION:-ca-central-1}"
STACK_NAME="${STACK_NAME:-aws-lambda-zig-demo}"
INTAKE_FUNCTION_NAME="${INTAKE_FUNCTION_NAME:-intake-lambda}"
QUERY_FUNCTION_NAME="${QUERY_FUNCTION_NAME:-query-lambda}"
EXECUTION_FUNCTION_NAME="${EXECUTION_FUNCTION_NAME:-execution-lambda}"
TIGERBEETLE_CLUSTER_ID="${TIGERBEETLE_CLUSTER_ID:-0}"
TIGERBEETLE_ADDRESSES="${TIGERBEETLE_ADDRESSES:-10.200.0.2:3000}"
LAMBDA_PRINCIPAL="${LAMBDA_PRINCIPAL:-*}"
PASETO_PUBLIC_KEY="${PASETO_PUBLIC_KEY:-}"
LOCAL_AWS_LAMBDA_ROOT="${LOCAL_AWS_LAMBDA_ROOT:-../aws-lambda-zig}"
DRY_RUN=0
CHECK_URL=1
USE_LOCAL_LIBS=0
MIGRATION_CHECK_ONLY=0
DEPLOYMENT_STARTED=0
DEPLOYMENT_ERROR_PHASE="deployment"
DEPLOYMENT_CONTROLLER="${DEPLOYMENT_CONTROLLER:-preserve_wireguard_state}"
DEPLOYMENT_PARAMETER_OVERRIDES=()
SAM_PARAMETER_OVERRIDES=()

usage() {
    cat <<'EOF'
Usage: ./deploy.sh [options]

Build, package, validate, and deploy the Zig Lambdas with AWS SAM. Existing
WireGuard gateway parameters are preserved. Use wireguard-gateway-setup.sh to
enable, reconfigure, or disable the gateway.

Options:
  --profile NAME         AWS CLI profile. Defaults to $PROFILE or dev.
  --region NAME          AWS region. Defaults to $REGION or ca-central-1.
  --stack-name NAME      CloudFormation stack name. Defaults to aws-lambda-zig-demo.
  --intake-function-name NAME
                         Intake Lambda name. Defaults to intake-lambda.
  --query-function-name NAME
                         Query Lambda name. Defaults to query-lambda.
  --execution-function-name NAME
                         Execution Lambda name. Defaults to execution-lambda.
  --tigerbeetle-cluster-id ID
                         Unsigned decimal cluster ID. Defaults to 0.
  --tigerbeetle-addresses ADDRESSES
                         Comma-separated replica addresses. Defaults to 10.200.0.2:3000.
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
  EXECUTION_FUNCTION_NAME, TIGERBEETLE_CLUSTER_ID, TIGERBEETLE_ADDRESSES,
  LAMBDA_PRINCIPAL, PASETO_PRIVATE_KEY, PASETO_PUBLIC_KEY,
  LOCAL_AWS_LAMBDA_ROOT

Authentication:
  Non-dry-run deployments require an SSO-backed AWS CLI profile. The script
  clears inherited static credentials, selects the configured profile, and
  always runs aws sso login to obtain a fresh token before AWS inspection or
  local build work. Dry runs make no AWS authentication calls.
EOF
}

fail() {
    printf 'error: %s\n' "$1" >&2
    if [ "${DEPLOYMENT_STARTED:-0}" -eq 1 ] &&
        declare -F report_cloudformation_outcome >/dev/null
    then
        trap - ERR
        report_cloudformation_outcome "$DEPLOYMENT_ERROR_PHASE"
    fi
    exit 1
}

need_value() {
    if [ "$#" -lt 2 ]; then
        fail "missing value for $1"
    fi
    if [ -z "$2" ]; then
        fail "empty value for $1"
    fi
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

validate_tigerbeetle_configuration() {
    local cluster_id_normalized="$TIGERBEETLE_CLUSTER_ID"
    local cluster_id_max=340282366920938463463374607431768211455

    [[ "$TIGERBEETLE_CLUSTER_ID" =~ ^[0-9]+$ ]] ||
        fail "TIGERBEETLE_CLUSTER_ID must be an unsigned decimal integer"
    while [ "${#cluster_id_normalized}" -gt 1 ] &&
        [ "${cluster_id_normalized#0}" != "$cluster_id_normalized" ]
    do
        cluster_id_normalized="${cluster_id_normalized#0}"
    done
    if [ "${#cluster_id_normalized}" -gt "${#cluster_id_max}" ]; then
        fail "TIGERBEETLE_CLUSTER_ID must fit in an unsigned 128-bit integer"
    fi
    if [ "${#cluster_id_normalized}" -eq "${#cluster_id_max}" ] &&
        [[ "$cluster_id_normalized" > "$cluster_id_max" ]]
    then
        fail "TIGERBEETLE_CLUSTER_ID must fit in an unsigned 128-bit integer"
    fi

    [ -n "$TIGERBEETLE_ADDRESSES" ] ||
        fail "TIGERBEETLE_ADDRESSES must not be empty"
    [ "${#TIGERBEETLE_ADDRESSES}" -le 4096 ] ||
        fail "TIGERBEETLE_ADDRESSES must be at most 4096 characters"
    [[ ! "$TIGERBEETLE_ADDRESSES" =~ [[:space:]] ]] ||
        fail "TIGERBEETLE_ADDRESSES must not contain whitespace"
}

clear_aws_credentials() {
    unset AWS_ACCESS_KEY_ID
    unset AWS_SECRET_ACCESS_KEY
    unset AWS_SESSION_TOKEN
    unset AWS_SECURITY_TOKEN
    unset AWS_CREDENTIAL_EXPIRATION
}

prepare_aws_sso_session() {
    local profile="$1"

    clear_aws_credentials
    unset AWS_DEFAULT_PROFILE
    AWS_PROFILE="$profile"
    export AWS_PROFILE

    printf '==> Obtaining fresh AWS SSO token for profile %s\n' "$profile"
    aws sso login --profile "$profile" ||
        fail "AWS SSO login failed for profile $profile"
}

ensure_stack_not_in_progress() {
    local stack_status

    if ! stack_status="$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].StackStatus' \
        --output text \
        --profile "$PROFILE" \
        --region "$REGION" \
        2>&1)"
    then
        case "$stack_status" in
            *"does not exist"*) return 0 ;;
            *) fail "could not inspect CloudFormation stack $STACK_NAME before deployment" ;;
        esac
    fi

    case "$stack_status" in
        *_IN_PROGRESS)
            fail "stack $STACK_NAME is $stack_status; wait for the active operation to reach a terminal state before retrying"
            ;;
    esac
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
        *) fail "could not inspect IntakeFunction in stack $STACK_NAME" ;;
    esac
}

load_preserved_wireguard_parameters() {
    local stack_parameters line parameter_key parameter_value
    local enable_wireguard_gateway=false
    local retain_cleanup_resources=false

    DEPLOYMENT_PARAMETER_OVERRIDES=()
    if ! stack_parameters="$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query "Stacks[0].Parameters[?ParameterKey=='EnableWireGuardGateway' || ParameterKey=='RetainExecutionVpcCleanupResources' || ParameterKey=='VpcId' || ParameterKey=='GatewayPublicSubnetId' || ParameterKey=='LambdaSubnetId' || ParameterKey=='LambdaRouteTableId' || ParameterKey=='LambdaSubnetCidr' || ParameterKey=='WireGuardPrivateKeyParameterName' || ParameterKey=='WireGuardPrivateKeyParameterVersion' || ParameterKey=='WireGuardGatewayPublicKey' || ParameterKey=='WireGuardWorkstationPublicKey' || ParameterKey=='WireGuardAmiId' || ParameterKey=='WireGuardInstanceType'].join('|', [ParameterKey,ParameterValue])" \
        --output text \
        --profile "$PROFILE" \
        --region "$REGION" \
        2>&1)"
    then
        case "$stack_parameters" in
            *"does not exist"*)
                DEPLOYMENT_PARAMETER_OVERRIDES=(
                    "EnableWireGuardGateway=false"
                    "RetainExecutionVpcCleanupResources=false"
                )
                return 0
                ;;
            *) fail "could not inspect prior WireGuard deployment state" ;;
        esac
    fi

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            *'|'*)
                parameter_key="${line%%|*}"
                parameter_value="${line#*|}"
                ;;
            *)
                IFS=$'\t' read -r parameter_key parameter_value <<<"$line"
                ;;
        esac
        case "$parameter_key" in
            EnableWireGuardGateway)
                enable_wireguard_gateway="$parameter_value"
                ;;
            RetainExecutionVpcCleanupResources)
                retain_cleanup_resources="$parameter_value"
                ;;
            VpcId | GatewayPublicSubnetId | LambdaSubnetId | \
                LambdaRouteTableId | LambdaSubnetCidr | \
                WireGuardPrivateKeyParameterName | \
                WireGuardPrivateKeyParameterVersion | \
                WireGuardGatewayPublicKey | WireGuardWorkstationPublicKey | \
                WireGuardAmiId | WireGuardInstanceType)
                ;;
            *) fail "stack returned an unexpected WireGuard parameter: $parameter_key" ;;
        esac
        # Omitting an empty value on update preserves that exact prior value and
        # avoids relying on SAM's shorthand parser to encode an empty string.
        if [ -n "$parameter_value" ]; then
            DEPLOYMENT_PARAMETER_OVERRIDES+=("$parameter_key=$parameter_value")
        fi
    # AWS CLI's text formatter separates a projected list of scalar strings
    # with tabs on one line. Accept newlines as well so mocked and captured
    # output use the same record parser.
    done <<<"${stack_parameters//$'\t'/$'\n'}"

    case "$enable_wireguard_gateway" in
        true | false) ;;
        *) fail "stack returned an invalid EnableWireGuardGateway value" ;;
    esac
    case "$retain_cleanup_resources" in
        true | false) ;;
        *) fail "stack returned an invalid RetainExecutionVpcCleanupResources value" ;;
    esac

    if [ "$enable_wireguard_gateway" = false ] &&
        [ "$retain_cleanup_resources" = true ]
    then
        fail "stack $STACK_NAME is midway through retained WireGuard cleanup; run ./wireguard-gateway-setup.sh --disable to complete it"
    fi
}

preserve_wireguard_state() {
    local phase="$1"

    case "$phase" in
        plan)
            if [ "$DRY_RUN" -eq 0 ]; then
                load_preserved_wireguard_parameters
            else
                DEPLOYMENT_PARAMETER_OVERRIDES=(
                    "EnableWireGuardGateway=false"
                    "RetainExecutionVpcCleanupResources=false"
                )
            fi
            ;;
        deploy) deploy_stack_phase "Deploying stack" ;;
        outputs | cleanup) ;;
        *) fail "unknown deployment-controller phase: $phase" ;;
    esac
}

invoke_deployment_controller() {
    local phase="$1"

    declare -F "$DEPLOYMENT_CONTROLLER" >/dev/null ||
        fail "deployment controller is not defined: $DEPLOYMENT_CONTROLLER"
    "$DEPLOYMENT_CONTROLLER" "$phase"
}

build_sam_parameter_overrides() {
    SAM_PARAMETER_OVERRIDES=(
        "IntakeFunctionName=$INTAKE_FUNCTION_NAME"
        "QueryFunctionName=$QUERY_FUNCTION_NAME"
        "ExecutionFunctionName=$EXECUTION_FUNCTION_NAME"
        "TigerBeetleClusterId=$TIGERBEETLE_CLUSTER_ID"
        "TigerBeetleAddresses=$TIGERBEETLE_ADDRESSES"
        "LambdaPrincipal=$LAMBDA_PRINCIPAL"
        "PasetoPublicKey=$PASETO_PUBLIC_KEY"
    )
    SAM_PARAMETER_OVERRIDES+=("${DEPLOYMENT_PARAMETER_OVERRIDES[@]}")
}

deploy_stack_phase() {
    local phase_description="$1"

    build_sam_parameter_overrides
    DEPLOYMENT_ERROR_PHASE="$phase_description"
    printf '==> %s for stack %s in %s\n' \
        "$phase_description" "$STACK_NAME" "$REGION"
    sam deploy \
        --template-file template.yaml \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --profile "$PROFILE" \
        --capabilities CAPABILITY_IAM \
        --resolve-s3 \
        --no-confirm-changeset \
        --no-fail-on-empty-changeset \
        --no-progressbar \
        --parameter-overrides \
        "${SAM_PARAMETER_OVERRIDES[@]}"
}

report_cloudformation_outcome() {
    local local_phase="$1"
    local stack_status

    if ! stack_status="$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].StackStatus' \
        --output text \
        --profile "$PROFILE" \
        --region "$REGION" \
        2>/dev/null)"
    then
        printf 'error: local %s failed; CloudFormation status could not be resolved\n' \
            "$local_phase" >&2
        return 0
    fi

    case "$stack_status" in
        *_IN_PROGRESS)
            printf 'error: local %s failed while CloudFormation continues in %s; do not start another deployment\n' \
                "$local_phase" "$stack_status" >&2
            ;;
        CREATE_COMPLETE | UPDATE_COMPLETE | IMPORT_COMPLETE)
            printf 'error: CloudFormation reached %s, but local %s failed\n' \
                "$stack_status" "$local_phase" >&2
            ;;
        *FAILED | *ROLLBACK_COMPLETE | *ROLLBACK_FAILED)
            printf 'error: CloudFormation reached terminal failure state %s during local %s\n' \
                "$stack_status" "$local_phase" >&2
            ;;
        *)
            printf 'error: local %s failed; CloudFormation is %s\n' \
                "$local_phase" "$stack_status" >&2
            ;;
    esac
}

deployment_error_handler() {
    local exit_status="$?"

    trap - ERR
    report_cloudformation_outcome "$DEPLOYMENT_ERROR_PHASE"
    exit "$exit_status"
}

deployment_cleanup() {
    invoke_deployment_controller cleanup || true
    rm -rf -- "${CACHE_DIR:-.zig-cache-deploy}" \
        "${GLOBAL_CACHE_DIR:-.zig-global-cache-deploy}"
}

deploy_stack_and_resolve_controller_outputs() {
    DEPLOYMENT_STARTED=1
    set +e
    invoke_deployment_controller deploy
    DEPLOYMENT_EXIT_STATUS=$?
    set -e
    if [ "$DEPLOYMENT_EXIT_STATUS" -ne 0 ]; then
        report_cloudformation_outcome "$DEPLOYMENT_ERROR_PHASE"
        return "$DEPLOYMENT_EXIT_STATUS"
    fi
    DEPLOYMENT_ERROR_PHASE="post-deployment checks"
    trap deployment_error_handler ERR

    printf '==> Stack status\n'
    aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].StackStatus' \
        --output text \
        --region "$REGION"

    invoke_deployment_controller outputs
}

parse_deployment_options() {
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
            --execution-function-name)
                need_value "$1" "${2:-}"
                EXECUTION_FUNCTION_NAME="$2"
                shift 2
                ;;
            --execution-function-name=*)
                EXECUTION_FUNCTION_NAME="${1#*=}"
                [ -n "$EXECUTION_FUNCTION_NAME" ] ||
                    fail "empty value for --execution-function-name"
                shift
                ;;
            --tigerbeetle-cluster-id)
                need_value "$1" "${2:-}"
                TIGERBEETLE_CLUSTER_ID="$2"
                shift 2
                ;;
            --tigerbeetle-cluster-id=*)
                TIGERBEETLE_CLUSTER_ID="${1#*=}"
                [ -n "$TIGERBEETLE_CLUSTER_ID" ] ||
                    fail "empty value for --tigerbeetle-cluster-id"
                shift
                ;;
            --tigerbeetle-addresses)
                need_value "$1" "${2:-}"
                TIGERBEETLE_ADDRESSES="$2"
                shift 2
                ;;
            --tigerbeetle-addresses=*)
                TIGERBEETLE_ADDRESSES="${1#*=}"
                [ -n "$TIGERBEETLE_ADDRESSES" ] ||
                    fail "empty value for --tigerbeetle-addresses"
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
            --enable-wireguard-gateway | --vpc-id | --vpc-id=* | \
                --gateway-public-subnet-id | --gateway-public-subnet-id=* | \
                --lambda-subnet-id | --lambda-subnet-id=* | \
                --lambda-route-table-id | --lambda-route-table-id=* | \
                --lambda-subnet-cidr | --lambda-subnet-cidr=* | \
                --wireguard-private-key-parameter-name | \
                --wireguard-private-key-parameter-name=* | \
                --wireguard-private-key-parameter-version | \
                --wireguard-private-key-parameter-version=* | \
                --wireguard-gateway-public-key | \
                --wireguard-gateway-public-key=* | \
                --wireguard-workstation-public-key | \
                --wireguard-workstation-public-key=* | \
                --wireguard-instance-type | --wireguard-instance-type=*)
                fail "$1 is no longer accepted by deploy.sh; use wireguard-gateway-setup.sh"
                ;;
            *) fail "unknown option: $1" ;;
        esac
    done
}

run_deployment() {
    parse_deployment_options "$@"

    cd "$(dirname "${BASH_SOURCE[0]}")"
    CACHE_DIR=".zig-cache-deploy"
    GLOBAL_CACHE_DIR=".zig-global-cache-deploy"
    trap deployment_cleanup EXIT

    [ "$DRY_RUN" -eq 0 ] || [ "$MIGRATION_CHECK_ONLY" -eq 0 ] ||
        fail "--dry-run and --migration-check-only cannot be combined"

    if [ "$MIGRATION_CHECK_ONLY" -eq 0 ]; then
        validate_tigerbeetle_configuration
    fi

    if [ "$DRY_RUN" -eq 0 ]; then
        need_command aws
        prepare_aws_sso_session "$PROFILE"
        ensure_stack_not_in_progress
        validate_existing_intake_name "$INTAKE_FUNCTION_NAME"
    fi
    if [ "$MIGRATION_CHECK_ONLY" -eq 1 ]; then
        printf '==> Intake-name migration check complete. Skipped build and deploy.\n'
        return 0
    fi

    [ -n "$PASETO_PUBLIC_KEY" ] ||
        fail "PASETO_PUBLIC_KEY is required; generate one with: zig-out/bin/paseto keygen"
    if [ "$DRY_RUN" -eq 0 ] && [ "$CHECK_URL" -eq 1 ]; then
        [ -n "${PASETO_PRIVATE_KEY:-}" ] ||
            fail "PASETO_PRIVATE_KEY is required for the authenticated Function URL check"
    fi

    invoke_deployment_controller plan

    need_command zig
    need_command zip
    need_command unzip
    need_command file
    need_command sam
    if [ "$DRY_RUN" -eq 0 ] && [ "$CHECK_URL" -eq 1 ]; then
        need_command curl
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

    printf '==> Checking Zig formatting\n'
    zig fmt --check \
        build.zig \
        src/execution_lambda.zig \
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

    for bootstrap in \
        zig-out/bin/intake/bootstrap \
        zig-out/bin/query/bootstrap
    do
        artifact_type="$(file "$bootstrap")"
        case "$artifact_type" in
            *"ELF 64-bit LSB executable"*aarch64*"statically linked"*"stripped"*) ;;
            *) fail "unexpected bootstrap artifact type: $artifact_type" ;;
        esac
        printf '%s\n' "$artifact_type"
    done
    execution_artifact_type="$(file zig-out/bin/execution/bootstrap)"
    case "$execution_artifact_type" in
        *"ELF 64-bit LSB executable"*aarch64*"dynamically linked"*"stripped"*) ;;
        *) fail "unexpected execution bootstrap artifact type: $execution_artifact_type" ;;
    esac
    printf '%s\n' "$execution_artifact_type"
    [ ! -e zig-out/bin/bootstrap ] || fail "obsolete zig-out/bin/bootstrap was recreated"

    printf '==> Refreshing Lambda zip archives\n'
    rm -f intake-lambda.zip query-lambda.zip execution-lambda.zip
    zip -qj intake-lambda.zip zig-out/bin/intake/bootstrap
    zip -qj query-lambda.zip zig-out/bin/query/bootstrap
    zip -qj execution-lambda.zip zig-out/bin/execution/bootstrap
    for archive in intake-lambda.zip query-lambda.zip execution-lambda.zip; do
        archive_contents="$(unzip -Z1 "$archive")"
        [ "$archive_contents" = bootstrap ] ||
            fail "$archive must contain only a root-level bootstrap"
    done

    printf '==> Validating SAM template\n'
    sam validate --template-file template.yaml --region "$REGION"
    sam validate --lint --template-file template.yaml --region "$REGION"

    if [ "$DRY_RUN" -eq 1 ]; then
        printf '==> Dry run complete. Skipped SAM deploy.\n'
        return 0
    fi

    deploy_stack_and_resolve_controller_outputs

    OPERATIONS_TABLE_NAME="$(aws cloudformation describe-stack-resource \
        --stack-name "$STACK_NAME" \
        --logical-resource-id OperationsTable \
        --query StackResourceDetail.PhysicalResourceId \
        --output text \
        --region "$REGION")"
    case "$OPERATIONS_TABLE_NAME" in
        "" | None) fail "stack resource OperationsTable has no physical name" ;;
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
        "" | None) fail "stack resource OperationsQueue has no physical URL" ;;
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

    trap - ERR
    DEPLOYMENT_STARTED=0
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

run_deployment "$@"
