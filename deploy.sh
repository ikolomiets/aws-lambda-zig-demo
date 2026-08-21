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
ENABLE_WIREGUARD_GATEWAY="${ENABLE_WIREGUARD_GATEWAY:-0}"
VPC_ID="${VPC_ID:-}"
GATEWAY_PUBLIC_SUBNET_ID="${GATEWAY_PUBLIC_SUBNET_ID:-}"
LAMBDA_SUBNET_ID="${LAMBDA_SUBNET_ID:-}"
LAMBDA_ROUTE_TABLE_ID="${LAMBDA_ROUTE_TABLE_ID:-}"
LAMBDA_SUBNET_CIDR="${LAMBDA_SUBNET_CIDR:-}"
WIREGUARD_PRIVATE_KEY_PARAMETER_NAME="${WIREGUARD_PRIVATE_KEY_PARAMETER_NAME:-}"
WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION="${WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION:-}"
WIREGUARD_GATEWAY_PUBLIC_KEY="${WIREGUARD_GATEWAY_PUBLIC_KEY:-}"
WIREGUARD_WORKSTATION_PUBLIC_KEY="${WIREGUARD_WORKSTATION_PUBLIC_KEY:-}"
WIREGUARD_INSTANCE_TYPE="${WIREGUARD_INSTANCE_TYPE:-}"
WIREGUARD_KEY_DIR=""
DRY_RUN=0
CHECK_URL=1
USE_LOCAL_LIBS=0
MIGRATION_CHECK_ONLY=0
WIREGUARD_DEPLOYMENT_MODE=disabled
DEPLOYMENT_STARTED=0
DEPLOYMENT_ERROR_PHASE="deployment"

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
  --execution-function-name NAME
                         Execution Lambda name. Defaults to execution-lambda.
  --tigerbeetle-cluster-id ID
                         Unsigned decimal cluster ID. Defaults to 0.
  --tigerbeetle-addresses ADDRESSES
                         Comma-separated replica addresses. Defaults to 10.200.0.2:3000.
  --lambda-principal VALUE
                         LAMBDA_PRINCIPAL environment value. Defaults to *.
  --enable-wireguard-gateway
                         Provision the EC2 WireGuard gateway and VPC-attach execution.
  --vpc-id ID            Existing VPC for the gateway and execution Lambda.
  --gateway-public-subnet-id ID
                         Existing public subnet for the EC2 gateway.
  --lambda-subnet-id ID  Existing private subnet for the execution Lambda.
  --lambda-route-table-id ID
                         Optional assertion for the discovered route table.
  --lambda-subnet-cidr CIDR
                         Optional assertion for the discovered Lambda CIDR.
  --wireguard-private-key-parameter-name NAME
                         Absolute SSM path of the gateway private-key SecureString.
  --wireguard-private-key-parameter-version VERSION
                         Positive SSM parameter version. Defaults to current.
  --wireguard-gateway-public-key KEY
                         Padded Base64 public key derived from the gateway private key.
  --wireguard-workstation-public-key KEY
                         Padded Base64 public key of the workstation peer.
  --wireguard-instance-type TYPE
                         ARM64 EC2 gateway instance type. Defaults to t4g.nano.
  --use-local-libs       Use local dependency checkouts with zig build --fork.
                         aws_lambda defaults to ../aws-lambda-zig.
  --dry-run              Run local checks, build, package, and validation only.
  --migration-check-only Validate the existing intake function name, then exit.
  --no-url-check         Skip the post-deploy Function URL HTTP status check.
  -h, --help             Show this help.

Environment overrides:
  PROFILE, REGION, STACK_NAME, INTAKE_FUNCTION_NAME, QUERY_FUNCTION_NAME,
  EXECUTION_FUNCTION_NAME, TIGERBEETLE_CLUSTER_ID, TIGERBEETLE_ADDRESSES,
  LAMBDA_PRINCIPAL, PASETO_PRIVATE_KEY,
  PASETO_PUBLIC_KEY, LOCAL_AWS_LAMBDA_ROOT, ENABLE_WIREGUARD_GATEWAY,
  VPC_ID, GATEWAY_PUBLIC_SUBNET_ID, LAMBDA_SUBNET_ID,
  LAMBDA_ROUTE_TABLE_ID, LAMBDA_SUBNET_CIDR,
  WIREGUARD_PRIVATE_KEY_PARAMETER_NAME,
  WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION, WIREGUARD_GATEWAY_PUBLIC_KEY,
  WIREGUARD_WORKSTATION_PUBLIC_KEY, WIREGUARD_INSTANCE_TYPE

Authentication:
  Non-dry-run deployments require an SSO-backed AWS CLI profile. The script
  clears inherited static credentials, selects the configured profile, and
  always runs aws sso login to obtain a fresh token before AWS discovery or
  local build work. Dry runs make no AWS authentication calls.

Gateway resolution:
  Values resolve from CLI, environment, a previously enabled stack, then
  SSM/default discovery. With unique networking, first enablement needs only
  WIREGUARD_WORKSTATION_PUBLIC_KEY. Dry runs skip AWS discovery and key creation.
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

ipv4_cidr_overlaps_wireguard() {
    local cidr="$1"
    local ipv4 prefix prefix_value octet octet_value
    local ipv4_value block_size cidr_start cidr_end
    local wireguard_start wireguard_end
    local -a octets

    case "$cidr" in
        */*) ;;
        *) return 2 ;;
    esac
    ipv4="${cidr%/*}"
    prefix="${cidr#*/}"
    [[ "$ipv4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
        return 2
    [[ "$prefix" =~ ^([0-9]|[12][0-9]|3[0-2])$ ]] ||
        return 2

    IFS=. read -r -a octets <<<"$ipv4"
    [ "${#octets[@]}" -eq 4 ] ||
        return 2
    for octet in "${octets[@]}"; do
        octet_value=$((10#$octet))
        [ "$octet_value" -le 255 ] ||
            return 2
    done

    prefix_value=$((10#$prefix))
    ipv4_value=$((
        (10#${octets[0]} << 24) |
        (10#${octets[1]} << 16) |
        (10#${octets[2]} << 8) |
        10#${octets[3]}
    ))
    block_size=$((1 << (32 - prefix_value)))
    cidr_start=$((ipv4_value & (0xFFFFFFFF ^ (block_size - 1))))
    cidr_end=$((cidr_start + block_size - 1))
    wireguard_start=$(((10 << 24) | (200 << 16)))
    wireguard_end=$((wireguard_start + 255))

    if [ "$cidr_start" -le "$wireguard_end" ] &&
        [ "$wireguard_start" -le "$cidr_end" ]
    then
        return 0
    fi
    return 1
}

validate_ipv4_cidr() {
    local name="$1"
    local cidr="$2"

    if ipv4_cidr_overlaps_wireguard "$cidr"; then
        fail "$name must not overlap 10.200.0.0/24"
    else
        case "$?" in
            1) ;;
            *) fail "$name must use IPv4 CIDR syntax" ;;
        esac
    fi
}

validate_wireguard_gateway_syntax() {
    case "$ENABLE_WIREGUARD_GATEWAY" in
        0) return 0 ;;
        1) ;;
        *) fail "ENABLE_WIREGUARD_GATEWAY must be 0 or 1" ;;
    esac

    [ -z "$VPC_ID" ] || [[ "$VPC_ID" =~ ^vpc-([0-9a-f]{8}|[0-9a-f]{17})$ ]] ||
        fail "VPC_ID must be an EC2 VPC ID"
    [ -z "$GATEWAY_PUBLIC_SUBNET_ID" ] ||
        [[ "$GATEWAY_PUBLIC_SUBNET_ID" =~ ^subnet-([0-9a-f]{8}|[0-9a-f]{17})$ ]] ||
        fail "GATEWAY_PUBLIC_SUBNET_ID must be an EC2 subnet ID"
    [ -z "$LAMBDA_SUBNET_ID" ] ||
        [[ "$LAMBDA_SUBNET_ID" =~ ^subnet-([0-9a-f]{8}|[0-9a-f]{17})$ ]] ||
        fail "LAMBDA_SUBNET_ID must be an EC2 subnet ID"
    [ -z "$LAMBDA_ROUTE_TABLE_ID" ] ||
        [[ "$LAMBDA_ROUTE_TABLE_ID" =~ ^rtb-([0-9a-f]{8}|[0-9a-f]{17})$ ]] ||
        fail "LAMBDA_ROUTE_TABLE_ID must be an EC2 route table ID"
    [ -z "$LAMBDA_SUBNET_CIDR" ] ||
        validate_ipv4_cidr LAMBDA_SUBNET_CIDR "$LAMBDA_SUBNET_CIDR"
    [ -z "$WIREGUARD_PRIVATE_KEY_PARAMETER_NAME" ] ||
        [[ "$WIREGUARD_PRIVATE_KEY_PARAMETER_NAME" =~ ^/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$ ]] ||
        fail "WIREGUARD_PRIVATE_KEY_PARAMETER_NAME must be an absolute SSM path"
    if [ -n "$WIREGUARD_PRIVATE_KEY_PARAMETER_NAME" ]; then
        case "${WIREGUARD_PRIVATE_KEY_PARAMETER_NAME#/}" in
            [Aa][Ww][Ss]* | [Ss][Ss][Mm]*)
                fail "WIREGUARD_PRIVATE_KEY_PARAMETER_NAME must not begin with the reserved aws or ssm prefix"
                ;;
        esac
    fi
    [ -z "$WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION" ] ||
        [[ "$WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION" =~ ^[1-9][0-9]*$ ]] ||
        fail "WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION must be a positive integer"
    [ -z "$WIREGUARD_GATEWAY_PUBLIC_KEY" ] ||
        [[ "$WIREGUARD_GATEWAY_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] ||
        fail "WIREGUARD_GATEWAY_PUBLIC_KEY must be padded 44-character Base64"
    [ -z "$WIREGUARD_WORKSTATION_PUBLIC_KEY" ] ||
        [[ "$WIREGUARD_WORKSTATION_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] ||
        fail "WIREGUARD_WORKSTATION_PUBLIC_KEY must be padded 44-character Base64"
    [ -z "$WIREGUARD_INSTANCE_TYPE" ] ||
        [[ "$WIREGUARD_INSTANCE_TYPE" =~ ^[a-z0-9][a-z0-9.-]*$ ]] ||
        fail "WIREGUARD_INSTANCE_TYPE must use EC2 instance-type syntax"
    [ -z "$GATEWAY_PUBLIC_SUBNET_ID" ] || [ -z "$LAMBDA_SUBNET_ID" ] ||
        [ "$GATEWAY_PUBLIC_SUBNET_ID" != "$LAMBDA_SUBNET_ID" ] ||
        fail "GATEWAY_PUBLIC_SUBNET_ID and LAMBDA_SUBNET_ID must differ"
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

validate_wireguard_gateway_configuration() {
    [ "$ENABLE_WIREGUARD_GATEWAY" -eq 1 ] || return 0

    [ -n "$VPC_ID" ] || fail "VPC_ID was not resolved for the gateway"
    [ -n "$GATEWAY_PUBLIC_SUBNET_ID" ] ||
        fail "GATEWAY_PUBLIC_SUBNET_ID was not resolved for the gateway"
    [ -n "$LAMBDA_SUBNET_ID" ] ||
        fail "LAMBDA_SUBNET_ID was not resolved for the gateway"
    [ -n "$LAMBDA_ROUTE_TABLE_ID" ] ||
        fail "LAMBDA_ROUTE_TABLE_ID was not resolved for the gateway"
    [ -n "$LAMBDA_SUBNET_CIDR" ] ||
        fail "LAMBDA_SUBNET_CIDR was not resolved for the gateway"
    [ -n "$WIREGUARD_PRIVATE_KEY_PARAMETER_NAME" ] ||
        fail "WIREGUARD_PRIVATE_KEY_PARAMETER_NAME was not resolved for the gateway"
    [ -n "$WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION" ] ||
        fail "WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION was not resolved for the gateway"
    [ -n "$WIREGUARD_GATEWAY_PUBLIC_KEY" ] ||
        fail "WIREGUARD_GATEWAY_PUBLIC_KEY was not resolved for the gateway"
    [ -n "$WIREGUARD_WORKSTATION_PUBLIC_KEY" ] ||
        fail "WIREGUARD_WORKSTATION_PUBLIC_KEY is required on first enablement"
    [ -n "$WIREGUARD_INSTANCE_TYPE" ] ||
        fail "WIREGUARD_INSTANCE_TYPE was not resolved for the gateway"
    validate_wireguard_gateway_syntax
}

effective_route_table_id() {
    local subnet_id="$1"
    local vpc_id="$2"
    local route_table_id

    route_table_id="$(aws ec2 describe-route-tables \
        --filters "Name=association.subnet-id,Values=$subnet_id" \
        --query 'RouteTables[0].RouteTableId' \
        --output text \
        --region "$REGION")" || return 1
    case "$route_table_id" in
        "" | None)
            route_table_id="$(aws ec2 describe-route-tables \
                --filters \
                "Name=vpc-id,Values=$vpc_id" \
                "Name=association.main,Values=true" \
                --query 'RouteTables[0].RouteTableId' \
                --output text \
                --region "$REGION")" || return 1
            ;;
    esac
    case "$route_table_id" in
        "" | None) return 1 ;;
    esac
    printf '%s\n' "$route_table_id"
}

load_prior_wireguard_configuration() {
    local prior_parameters parameter_key parameter_value
    local prior_gateway_enabled=false
    local prior_vpc_id="" prior_gateway_subnet_id="" prior_lambda_subnet_id=""
    local prior_lambda_route_table_id="" prior_lambda_subnet_cidr=""
    local prior_private_parameter_name="" prior_private_parameter_version=""
    local prior_gateway_public_key="" prior_workstation_public_key=""
    local prior_instance_type=""

    prior_parameters="$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Parameters[].[ParameterKey,ParameterValue]' \
        --output text \
        --region "$REGION" 2>/dev/null)" || return 0

    while IFS=$'\t' read -r parameter_key parameter_value; do
        case "$parameter_key" in
            EnableWireGuardGateway) prior_gateway_enabled="$parameter_value" ;;
            VpcId) prior_vpc_id="$parameter_value" ;;
            GatewayPublicSubnetId) prior_gateway_subnet_id="$parameter_value" ;;
            LambdaSubnetId) prior_lambda_subnet_id="$parameter_value" ;;
            LambdaRouteTableId) prior_lambda_route_table_id="$parameter_value" ;;
            LambdaSubnetCidr) prior_lambda_subnet_cidr="$parameter_value" ;;
            WireGuardPrivateKeyParameterName)
                prior_private_parameter_name="$parameter_value"
                ;;
            WireGuardPrivateKeyParameterVersion)
                prior_private_parameter_version="$parameter_value"
                ;;
            WireGuardGatewayPublicKey) prior_gateway_public_key="$parameter_value" ;;
            WireGuardWorkstationPublicKey) prior_workstation_public_key="$parameter_value" ;;
            WireGuardInstanceType) prior_instance_type="$parameter_value" ;;
        esac
    done <<<"$prior_parameters"

    [ "$prior_gateway_enabled" = true ] || return 0

    [ -n "$VPC_ID" ] || VPC_ID="$prior_vpc_id"
    [ -n "$GATEWAY_PUBLIC_SUBNET_ID" ] ||
        GATEWAY_PUBLIC_SUBNET_ID="$prior_gateway_subnet_id"
    [ -n "$LAMBDA_SUBNET_ID" ] || LAMBDA_SUBNET_ID="$prior_lambda_subnet_id"
    [ -n "$LAMBDA_ROUTE_TABLE_ID" ] ||
        LAMBDA_ROUTE_TABLE_ID="$prior_lambda_route_table_id"
    [ -n "$LAMBDA_SUBNET_CIDR" ] || LAMBDA_SUBNET_CIDR="$prior_lambda_subnet_cidr"
    [ -n "$WIREGUARD_PRIVATE_KEY_PARAMETER_NAME" ] ||
        WIREGUARD_PRIVATE_KEY_PARAMETER_NAME="$prior_private_parameter_name"
    [ -n "$WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION" ] ||
        WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION="$prior_private_parameter_version"
    [ -n "$WIREGUARD_GATEWAY_PUBLIC_KEY" ] ||
        WIREGUARD_GATEWAY_PUBLIC_KEY="$prior_gateway_public_key"
    [ -n "$WIREGUARD_WORKSTATION_PUBLIC_KEY" ] ||
        WIREGUARD_WORKSTATION_PUBLIC_KEY="$prior_workstation_public_key"
    [ -n "$WIREGUARD_INSTANCE_TYPE" ] || WIREGUARD_INSTANCE_TYPE="$prior_instance_type"

    printf '==> Reused unspecified WireGuard values from the enabled stack\n'
}

lambda_subnet_has_dynamodb_access() {
    local route_table_id="$1"
    local vpc_id="$2"
    local nat_gateway_id endpoint_count

    nat_gateway_id="$(aws ec2 describe-route-tables \
        --route-table-ids "$route_table_id" \
        --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0' && State=='active'].NatGatewayId | [0]" \
        --output text \
        --region "$REGION")" || return 1
    case "$nat_gateway_id" in
        nat-*) return 0 ;;
    esac

    endpoint_count="$(aws ec2 describe-vpc-endpoints \
        --filters \
        "Name=vpc-id,Values=$vpc_id" \
        "Name=service-name,Values=com.amazonaws.$REGION.dynamodb" \
        "Name=vpc-endpoint-state,Values=available" \
        --query "length(VpcEndpoints[?contains(RouteTableIds, '$route_table_id')])" \
        --output text \
        --region "$REGION")" || return 1
    [[ "$endpoint_count" =~ ^[0-9]+$ ]] || return 1
    [ "$endpoint_count" -gt 0 ]
}

inspect_wireguard_subnet() {
    local subnet_id="$1"
    local vpc_id="$2"
    local availability_zone="$3"
    local cidr="$4"
    local inspect_dynamodb="$5"
    local cidr_overlaps=0 route_table_id route_targets
    local gateway_id=None nat_gateway_id=None dynamodb_access=0 endpoint_count

    if ipv4_cidr_overlaps_wireguard "$cidr"; then
        cidr_overlaps=1
    else
        case "$?" in
            1) ;;
            *)
                printf 'AWS inspection failed: subnet %s returned invalid IPv4 CIDR %s\n' \
                    "$subnet_id" "$cidr" >&2
                return 1
                ;;
        esac
    fi

    if [ "$cidr_overlaps" -eq 0 ]; then
        route_table_id="$(effective_route_table_id "$subnet_id" "$vpc_id")" || {
            printf 'AWS inspection failed: could not resolve the effective route table for subnet %s\n' \
                "$subnet_id" >&2
            return 1
        }
        route_targets="$(aws ec2 describe-route-tables \
            --route-table-ids "$route_table_id" \
            --query "RouteTables[0].[Routes[?DestinationCidrBlock=='0.0.0.0/0' && State=='active'].GatewayId | [0], Routes[?DestinationCidrBlock=='0.0.0.0/0' && State=='active'].NatGatewayId | [0]]" \
            --output text \
            --region "$REGION")" || {
            printf 'AWS inspection failed: could not inspect route table %s for subnet %s\n' \
                "$route_table_id" "$subnet_id" >&2
            return 1
        }
        read -r gateway_id nat_gateway_id <<<"$route_targets"
        gateway_id="${gateway_id:-None}"
        nat_gateway_id="${nat_gateway_id:-None}"

        if [ "$inspect_dynamodb" -eq 1 ]; then
            case "$nat_gateway_id" in
                nat-*) dynamodb_access=1 ;;
                *)
                    endpoint_count="$(aws ec2 describe-vpc-endpoints \
                        --filters \
                        "Name=vpc-id,Values=$vpc_id" \
                        "Name=service-name,Values=com.amazonaws.$REGION.dynamodb" \
                        "Name=vpc-endpoint-state,Values=available" \
                        --query "length(VpcEndpoints[?contains(RouteTableIds, '$route_table_id')])" \
                        --output text \
                        --region "$REGION")" || {
                        printf 'AWS inspection failed: could not inspect DynamoDB access for subnet %s\n' \
                            "$subnet_id" >&2
                        return 1
                    }
                    if ! [[ "$endpoint_count" =~ ^[0-9]+$ ]]; then
                        printf 'AWS inspection failed: invalid DynamoDB endpoint count for subnet %s\n' \
                            "$subnet_id" >&2
                        return 1
                    fi
                    [ "$endpoint_count" -eq 0 ] || dynamodb_access=1
                    ;;
            esac
        fi
    fi

    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$subnet_id" \
        "$vpc_id" \
        "$availability_zone" \
        "$cidr" \
        "$cidr_overlaps" \
        "${route_table_id:-None}" \
        "$gateway_id" \
        "$dynamodb_access"
}

print_wireguard_candidates() {
    local candidate gateway_subnet_id lambda_subnet_id vpc_id availability_zone
    local lambda_cidr lambda_route_table_id

    printf 'WireGuard subnet candidates:\n' >&2
    if [ "$#" -eq 0 ]; then
        printf '    (none)\n' >&2
        return 0
    fi
    for candidate in "$@"; do
        IFS='|' read -r \
            gateway_subnet_id \
            lambda_subnet_id \
            vpc_id \
            availability_zone \
            lambda_cidr \
            lambda_route_table_id <<<"$candidate"
        printf '    gateway=%s lambda=%s vpc=%s az=%s lambda-cidr=%s lambda-route-table=%s\n' \
            "$gateway_subnet_id" \
            "$lambda_subnet_id" \
            "$vpc_id" \
            "$availability_zone" \
            "$lambda_cidr" \
            "$lambda_route_table_id" >&2
    done
}

discover_wireguard_network() {
    local requested_vpc_id="$VPC_ID"
    local requested_lambda_cidr="$LAMBDA_SUBNET_CIDR"
    local requested_lambda_route_table_id="$LAMBDA_ROUTE_TABLE_ID"
    local subnets candidate inspected_subnet
    local subnet_id subnet_vpc_id subnet_az subnet_cidr subnet_cidr_overlaps
    local subnet_route_table_id subnet_gateway_id subnet_dynamodb_access
    local gateway_id gateway_vpc_id gateway_az gateway_cidr gateway_route_table_id
    local lambda_id lambda_vpc_id lambda_az lambda_cidr lambda_route_table_id
    local resolved_gateway_id resolved_lambda_id resolved_vpc_id resolved_az
    local resolved_lambda_cidr resolved_lambda_route_table_id
    local gateway_allowed lambda_allowed
    local rejection_gateway_routing=0 rejection_lambda_dynamodb=0
    local rejection_cidr_overlap=0 rejection_subnet_identity=0
    local rejection_vpc=0 rejection_availability_zone=0
    local -a candidates=()
    local -a gateway_subnets=()
    local -a lambda_subnets=()
    local -a subnet_filter_arguments=()

    printf '==> Discovering WireGuard gateway subnet pair\n'
    subnet_filter_arguments+=("Name=state,Values=available")
    if [ -n "$VPC_ID" ]; then
        subnet_filter_arguments+=("Name=vpc-id,Values=$VPC_ID")
    fi
    subnets="$(aws ec2 describe-subnets \
        --filters "${subnet_filter_arguments[@]}" \
        --query 'Subnets[?CidrBlock!=`null`].[SubnetId,VpcId,AvailabilityZone,CidrBlock]' \
        --output text \
        --region "$REGION")" || fail "could not list available IPv4 subnets in $REGION"

    while IFS=$'\t' read -r subnet_id subnet_vpc_id subnet_az subnet_cidr; do
        [ -n "$subnet_id" ] || continue
        gateway_allowed=0
        lambda_allowed=0
        if [ -z "$GATEWAY_PUBLIC_SUBNET_ID" ] ||
            [ "$subnet_id" = "$GATEWAY_PUBLIC_SUBNET_ID" ]
        then
            gateway_allowed=1
        fi
        if [ -z "$LAMBDA_SUBNET_ID" ] || [ "$subnet_id" = "$LAMBDA_SUBNET_ID" ]; then
            lambda_allowed=1
        fi
        [ "$gateway_allowed" -eq 1 ] || [ "$lambda_allowed" -eq 1 ] || continue

        inspected_subnet="$(inspect_wireguard_subnet \
            "$subnet_id" \
            "$subnet_vpc_id" \
            "$subnet_az" \
            "$subnet_cidr" \
            "$lambda_allowed")" ||
            fail "could not complete WireGuard topology discovery because AWS inspection failed"
        IFS='|' read -r \
            subnet_id \
            subnet_vpc_id \
            subnet_az \
            subnet_cidr \
            subnet_cidr_overlaps \
            subnet_route_table_id \
            subnet_gateway_id \
            subnet_dynamodb_access <<<"$inspected_subnet"

        if [ "$subnet_cidr_overlaps" -eq 1 ]; then
            rejection_cidr_overlap=$((rejection_cidr_overlap + 1))
            continue
        fi
        if [ "$gateway_allowed" -eq 1 ]; then
            case "$subnet_gateway_id" in
                igw-*)
                    gateway_subnets+=(
                        "$subnet_id|$subnet_vpc_id|$subnet_az|$subnet_cidr|$subnet_route_table_id"
                    )
                    ;;
                *) rejection_gateway_routing=$((rejection_gateway_routing + 1)) ;;
            esac
        fi
        if [ "$lambda_allowed" -eq 1 ]; then
            if [ "$subnet_dynamodb_access" -eq 1 ]; then
                lambda_subnets+=(
                    "$subnet_id|$subnet_vpc_id|$subnet_az|$subnet_cidr|$subnet_route_table_id"
                )
            else
                rejection_lambda_dynamodb=$((rejection_lambda_dynamodb + 1))
            fi
        fi
    done <<<"$subnets"

    for candidate in "${gateway_subnets[@]}"; do
        IFS='|' read -r \
            gateway_id gateway_vpc_id gateway_az gateway_cidr gateway_route_table_id \
            <<<"$candidate"
        for inspected_subnet in "${lambda_subnets[@]}"; do
            IFS='|' read -r \
                lambda_id lambda_vpc_id lambda_az lambda_cidr lambda_route_table_id \
                <<<"$inspected_subnet"
            if [ "$lambda_id" = "$gateway_id" ]; then
                rejection_subnet_identity=$((rejection_subnet_identity + 1))
                continue
            fi
            if [ "$lambda_vpc_id" != "$gateway_vpc_id" ]; then
                rejection_vpc=$((rejection_vpc + 1))
                continue
            fi
            if [ "$lambda_az" != "$gateway_az" ]; then
                rejection_availability_zone=$((rejection_availability_zone + 1))
                continue
            fi
            candidates+=(
                "$gateway_id|$lambda_id|$gateway_vpc_id|$gateway_az|$lambda_cidr|$lambda_route_table_id"
            )
        done
    done

    if [ "${#candidates[@]}" -ne 1 ]; then
        if [ "${#candidates[@]}" -eq 0 ]; then
            print_wireguard_candidates
            printf 'WireGuard topology rejection counts:\n' >&2
            printf '    gateway routing: %s\n' "$rejection_gateway_routing" >&2
            printf '    Lambda DynamoDB access: %s\n' "$rejection_lambda_dynamodb" >&2
            printf '    CIDR overlap: %s\n' "$rejection_cidr_overlap" >&2
            printf '    subnet identity: %s\n' "$rejection_subnet_identity" >&2
            printf '    VPC: %s\n' "$rejection_vpc" >&2
            printf '    Availability Zone: %s\n' \
                "$rejection_availability_zone" >&2
            fail "no WireGuard subnet pair satisfies the required topology"
        else
            print_wireguard_candidates "${candidates[@]}"
            fail "WireGuard subnet discovery is ambiguous; use --gateway-public-subnet-id and/or --lambda-subnet-id to select one pair"
        fi
    fi

    candidate="${candidates[0]}"
    IFS='|' read -r \
        resolved_gateway_id \
        resolved_lambda_id \
        resolved_vpc_id \
        resolved_az \
        resolved_lambda_cidr \
        resolved_lambda_route_table_id <<<"$candidate"

    [ -z "$requested_vpc_id" ] || [ "$requested_vpc_id" = "$resolved_vpc_id" ] ||
        fail "VPC_ID does not match the selected subnet pair"
    [ -z "$requested_lambda_cidr" ] ||
        [ "$requested_lambda_cidr" = "$resolved_lambda_cidr" ] ||
        fail "LAMBDA_SUBNET_CIDR does not match the selected Lambda subnet"
    [ -z "$requested_lambda_route_table_id" ] ||
        [ "$requested_lambda_route_table_id" = "$resolved_lambda_route_table_id" ] ||
        fail "LAMBDA_ROUTE_TABLE_ID is not the selected Lambda subnet effective route table"

    GATEWAY_PUBLIC_SUBNET_ID="$resolved_gateway_id"
    LAMBDA_SUBNET_ID="$resolved_lambda_id"
    VPC_ID="$resolved_vpc_id"
    LAMBDA_SUBNET_CIDR="$resolved_lambda_cidr"
    LAMBDA_ROUTE_TABLE_ID="$resolved_lambda_route_table_id"

    printf '==> Selected WireGuard network\n'
    printf '    VPC: %s\n' "$VPC_ID"
    printf '    Availability Zone: %s\n' "$resolved_az"
    printf '    Gateway subnet: %s\n' "$GATEWAY_PUBLIC_SUBNET_ID"
    printf '    Lambda subnet: %s\n' "$LAMBDA_SUBNET_ID"
    printf '    Lambda CIDR: %s\n' "$LAMBDA_SUBNET_CIDR"
    printf '    Lambda route table: %s\n' "$LAMBDA_ROUTE_TABLE_ID"
}

ssm_parameter_not_found() {
    case "$1" in
        *ParameterNotFound*) return 0 ;;
        *) return 1 ;;
    esac
}

read_private_parameter_metadata() {
    local parameter_name="$1"
    local parameter_version="${2:-}"
    local version_suffix=""

    [ -z "$parameter_version" ] || version_suffix=":$parameter_version"
    aws ssm get-parameter \
        --name "${parameter_name}${version_suffix}" \
        --no-with-decryption \
        --query 'Parameter.[Type,Version]' \
        --output text \
        --region "$REGION" 2>&1
}

read_public_parameter() {
    local parameter_name="$1"

    aws ssm get-parameter \
        --name "$parameter_name" \
        --no-with-decryption \
        --query 'Parameter.[Type,Version,Value]' \
        --output text \
        --region "$REGION" 2>&1
}

create_default_wireguard_keypair() {
    local private_parameter_name="$1"
    local public_parameter_name="$2"
    local private_request_file public_key private_version private_result

    need_command wg
    WIREGUARD_KEY_DIR="$(
        mktemp -d "${TMPDIR:-/tmp}/aws-lambda-zig-wireguard.XXXXXX"
    )" || fail "could not create a temporary WireGuard key directory"
    chmod 700 "$WIREGUARD_KEY_DIR"
    (
        umask 077
        wg genkey >"$WIREGUARD_KEY_DIR/gateway.private"
        wg pubkey <"$WIREGUARD_KEY_DIR/gateway.private" \
            >"$WIREGUARD_KEY_DIR/gateway.public"
    ) || fail "could not generate the WireGuard gateway keypair"
    [ "$(stat -f '%Lp' "$WIREGUARD_KEY_DIR" 2>/dev/null || stat -c '%a' "$WIREGUARD_KEY_DIR")" = 700 ] ||
        fail "temporary WireGuard key directory is not mode 0700"

    public_key="$(tr -d '\r\n' <"$WIREGUARD_KEY_DIR/gateway.public")"
    [[ "$public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] ||
        fail "wg generated a malformed public key"
    private_request_file="$WIREGUARD_KEY_DIR/private-put.json"
    (
        umask 077
        {
            printf '{"Name":"%s","Description":"WireGuard gateway private key","Type":"SecureString","KeyId":"alias/aws/ssm","Value":"' \
                "$private_parameter_name"
            tr -d '\r\n' <"$WIREGUARD_KEY_DIR/gateway.private"
            printf '"}\n'
        } >"$private_request_file"
    )

    printf '==> Creating default WireGuard gateway keypair in SSM\n'
    if ! private_result="$(aws ssm put-parameter \
        --cli-input-json "file://$private_request_file" \
        --query Version \
        --output text \
        --region "$REGION" 2>/dev/null)"
    then
        fail "could not create $private_parameter_name; no parameter was overwritten"
    fi
    private_version="$private_result"
    if ! [[ "$private_version" =~ ^[1-9][0-9]*$ ]]; then
        if ! aws ssm delete-parameter \
            --name "$private_parameter_name" \
            --region "$REGION" >/dev/null 2>&1
        then
            fail "private parameter creation returned an invalid version and rollback failed; delete $private_parameter_name manually"
        fi
        fail "private parameter creation returned an invalid version; rolled back $private_parameter_name"
    fi

    if ! aws ssm put-parameter \
        --name "$public_parameter_name" \
        --description 'WireGuard gateway public key' \
        --type String \
        --value "$public_key" \
        --region "$REGION" >/dev/null 2>&1
    then
        if ! aws ssm delete-parameter \
            --name "$private_parameter_name" \
            --region "$REGION" >/dev/null 2>&1
        then
            fail "public parameter creation failed and rollback failed; delete $private_parameter_name manually"
        fi
        fail "public parameter creation failed; rolled back $private_parameter_name"
    fi

    WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION="$private_version"
    WIREGUARD_GATEWAY_PUBLIC_KEY="$public_key"
    rm -rf -- "$WIREGUARD_KEY_DIR"
    WIREGUARD_KEY_DIR=""
    printf '==> Created %s version %s and %s\n' \
        "$private_parameter_name" \
        "$WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION" \
        "$public_parameter_name"
}

resolve_default_wireguard_keypair() {
    local private_parameter_name="$1"
    local public_parameter_name="$2"
    local private_metadata public_parameter exact_private_metadata
    local private_type current_private_version public_type public_version stored_public_key
    local private_exists=0 public_exists=0
    local requested_private_version="$WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION"
    local requested_public_key="$WIREGUARD_GATEWAY_PUBLIC_KEY"

    if private_metadata="$(read_private_parameter_metadata "$private_parameter_name")"; then
        private_exists=1
    elif ! ssm_parameter_not_found "$private_metadata"; then
        fail "could not inspect $private_parameter_name"
    fi
    if public_parameter="$(read_public_parameter "$public_parameter_name")"; then
        public_exists=1
    elif ! ssm_parameter_not_found "$public_parameter"; then
        fail "could not inspect $public_parameter_name"
    fi

    if [ "$private_exists" -ne "$public_exists" ]; then
        fail "default WireGuard SSM pair is incomplete; repair or delete both $private_parameter_name and $public_parameter_name, then retry"
    fi
    if [ "$private_exists" -eq 0 ]; then
        if [ -n "$requested_private_version" ] || [ -n "$requested_public_key" ]; then
            fail "default WireGuard SSM pair is absent but key overrides were supplied; create both parameters together or remove the overrides"
        fi
        create_default_wireguard_keypair "$private_parameter_name" "$public_parameter_name"
        return 0
    fi

    read -r private_type current_private_version <<<"$private_metadata"
    read -r public_type public_version stored_public_key <<<"$public_parameter"
    [ "$private_type" = SecureString ] ||
        fail "$private_parameter_name must be an SSM SecureString"
    [ "$public_type" = String ] || fail "$public_parameter_name must be an SSM String"
    [[ "$current_private_version" =~ ^[1-9][0-9]*$ ]] ||
        fail "$private_parameter_name returned an invalid version"
    [[ "$public_version" =~ ^[1-9][0-9]*$ ]] ||
        fail "$public_parameter_name returned an invalid version"
    [[ "$stored_public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] ||
        fail "$public_parameter_name does not contain a padded 44-character WireGuard public key"

    if [ -z "$requested_private_version" ]; then
        WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION="$current_private_version"
        if [ -n "$requested_public_key" ] &&
            [ "$requested_public_key" != "$stored_public_key" ]
        then
            fail "WIREGUARD_GATEWAY_PUBLIC_KEY differs from the stored public key; also pin its matching private parameter version"
        fi
    else
        exact_private_metadata="$(read_private_parameter_metadata \
            "$private_parameter_name" \
            "$requested_private_version")" ||
            fail "$private_parameter_name version $requested_private_version does not exist"
        read -r private_type _ <<<"$exact_private_metadata"
        [ "$private_type" = SecureString ] ||
            fail "$private_parameter_name version $requested_private_version must be a SecureString"
        if [ -z "$requested_public_key" ] &&
            [ "$requested_private_version" != "$current_private_version" ]
        then
            fail "a non-current private parameter version requires its matching WIREGUARD_GATEWAY_PUBLIC_KEY"
        fi
    fi
    [ -n "$requested_public_key" ] || WIREGUARD_GATEWAY_PUBLIC_KEY="$stored_public_key"
    printf '==> Using existing default WireGuard SSM keypair (private version %s)\n' \
        "$WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION"
}

resolve_custom_wireguard_key() {
    local private_metadata private_type resolved_version

    [ -n "$WIREGUARD_GATEWAY_PUBLIC_KEY" ] ||
        fail "WIREGUARD_GATEWAY_PUBLIC_KEY is required with a custom private-key parameter path"
    private_metadata="$(read_private_parameter_metadata \
        "$WIREGUARD_PRIVATE_KEY_PARAMETER_NAME" \
        "$WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION")" ||
        fail "custom WireGuard private-key parameter or selected version does not exist"
    read -r private_type resolved_version <<<"$private_metadata"
    [ "$private_type" = SecureString ] ||
        fail "$WIREGUARD_PRIVATE_KEY_PARAMETER_NAME must be an SSM SecureString"
    [[ "$resolved_version" =~ ^[1-9][0-9]*$ ]] ||
        fail "$WIREGUARD_PRIVATE_KEY_PARAMETER_NAME returned an invalid version"
    [ -n "$WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION" ] ||
        WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION="$resolved_version"
    printf '==> Using custom WireGuard private-key parameter version %s\n' \
        "$WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION"
}

resolve_wireguard_key_configuration() {
    local default_private_parameter_name="/applications/$STACK_NAME/wireguard/gateway-private-key"
    local default_public_parameter_name="/applications/$STACK_NAME/wireguard/gateway-public-key"

    [ -n "$WIREGUARD_PRIVATE_KEY_PARAMETER_NAME" ] ||
        WIREGUARD_PRIVATE_KEY_PARAMETER_NAME="$default_private_parameter_name"
    if [ "$WIREGUARD_PRIVATE_KEY_PARAMETER_NAME" = "$default_private_parameter_name" ]; then
        resolve_default_wireguard_keypair \
            "$default_private_parameter_name" \
            "$default_public_parameter_name"
    else
        resolve_custom_wireguard_key
    fi
}

stack_owns_wireguard_route() {
    local route_table_id="$1"
    local route_instance_id="$2"
    local stack_gateway_enabled stack_route_table_id
    local stack_route_status stack_instance_id

    stack_gateway_enabled="$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query "Stacks[0].Parameters[?ParameterKey=='EnableWireGuardGateway'].ParameterValue | [0]" \
        --output text \
        --region "$REGION" 2>/dev/null)" || return 1
    [ "$stack_gateway_enabled" = true ] || return 1
    stack_route_table_id="$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query "Stacks[0].Parameters[?ParameterKey=='LambdaRouteTableId'].ParameterValue | [0]" \
        --output text \
        --region "$REGION" 2>/dev/null)" || return 1
    [ "$stack_route_table_id" = "$route_table_id" ] || return 1
    stack_route_status="$(aws cloudformation describe-stack-resource \
        --stack-name "$STACK_NAME" \
        --logical-resource-id WireGuardLambdaRoute \
        --query StackResourceDetail.ResourceStatus \
        --output text \
        --region "$REGION" 2>/dev/null)" || return 1
    case "$stack_route_status" in
        *_COMPLETE) ;;
        *) return 1 ;;
    esac
    stack_instance_id="$(aws cloudformation describe-stack-resource \
        --stack-name "$STACK_NAME" \
        --logical-resource-id WireGuardGatewayInstance \
        --query StackResourceDetail.PhysicalResourceId \
        --output text \
        --region "$REGION" 2>/dev/null)" || return 1
    [ "$stack_instance_id" = "$route_instance_id" ]
}

preflight_wireguard_gateway() {
    local actual_vpc_id gateway_subnet lambda_subnet lambda_route_table
    local gateway_subnet_id gateway_vpc_id gateway_az gateway_subnet_cidr
    local lambda_subnet_id lambda_vpc_id lambda_az lambda_subnet_cidr
    local lambda_route_table_id lambda_route_table_vpc_id
    local effective_lambda_route_table_id effective_gateway_route_table_id
    local gateway_default_route_target wireguard_route_count
    local wireguard_route_instance_id

    printf '==> Checking WireGuard gateway VPC topology\n'
    actual_vpc_id="$(aws ec2 describe-vpcs \
        --vpc-ids "$VPC_ID" \
        --query 'Vpcs[0].VpcId' \
        --output text \
        --region "$REGION")" || fail "VPC_ID does not exist in $REGION"
    [ "$actual_vpc_id" = "$VPC_ID" ] || fail "VPC_ID does not exist in $REGION"

    gateway_subnet="$(aws ec2 describe-subnets \
        --subnet-ids "$GATEWAY_PUBLIC_SUBNET_ID" \
        --query 'Subnets[0].[SubnetId,VpcId,AvailabilityZone,CidrBlock]' \
        --output text \
        --region "$REGION")" ||
        fail "GATEWAY_PUBLIC_SUBNET_ID does not exist in $REGION"
    read -r gateway_subnet_id gateway_vpc_id gateway_az gateway_subnet_cidr \
        <<<"$gateway_subnet"
    [ "$gateway_subnet_id" = "$GATEWAY_PUBLIC_SUBNET_ID" ] ||
        fail "GATEWAY_PUBLIC_SUBNET_ID does not exist in $REGION"
    [ "$gateway_vpc_id" = "$VPC_ID" ] ||
        fail "GATEWAY_PUBLIC_SUBNET_ID does not belong to VPC_ID"
    validate_ipv4_cidr GATEWAY_PUBLIC_SUBNET_CIDR "$gateway_subnet_cidr"

    lambda_subnet="$(aws ec2 describe-subnets \
        --subnet-ids "$LAMBDA_SUBNET_ID" \
        --query 'Subnets[0].[SubnetId,VpcId,AvailabilityZone,CidrBlock]' \
        --output text \
        --region "$REGION")" || fail "LAMBDA_SUBNET_ID does not exist in $REGION"
    read -r lambda_subnet_id lambda_vpc_id lambda_az lambda_subnet_cidr \
        <<<"$lambda_subnet"
    [ "$lambda_subnet_id" = "$LAMBDA_SUBNET_ID" ] ||
        fail "LAMBDA_SUBNET_ID does not exist in $REGION"
    [ "$lambda_vpc_id" = "$VPC_ID" ] ||
        fail "LAMBDA_SUBNET_ID does not belong to VPC_ID"
    [ "$lambda_az" = "$gateway_az" ] ||
        fail "gateway and Lambda subnets must be in the same availability zone"
    [ "$lambda_subnet_cidr" = "$LAMBDA_SUBNET_CIDR" ] ||
        fail "LAMBDA_SUBNET_CIDR does not equal the subnet primary IPv4 CIDR"

    lambda_route_table="$(aws ec2 describe-route-tables \
        --route-table-ids "$LAMBDA_ROUTE_TABLE_ID" \
        --query 'RouteTables[0].[RouteTableId,VpcId]' \
        --output text \
        --region "$REGION")" ||
        fail "LAMBDA_ROUTE_TABLE_ID does not exist in $REGION"
    read -r lambda_route_table_id lambda_route_table_vpc_id <<<"$lambda_route_table"
    [ "$lambda_route_table_id" = "$LAMBDA_ROUTE_TABLE_ID" ] ||
        fail "LAMBDA_ROUTE_TABLE_ID does not exist in $REGION"
    [ "$lambda_route_table_vpc_id" = "$VPC_ID" ] ||
        fail "LAMBDA_ROUTE_TABLE_ID does not belong to VPC_ID"

    effective_lambda_route_table_id="$(
        effective_route_table_id "$LAMBDA_SUBNET_ID" "$VPC_ID"
    )" || fail "could not resolve the Lambda subnet effective route table"
    [ "$effective_lambda_route_table_id" = "$LAMBDA_ROUTE_TABLE_ID" ] ||
        fail "LAMBDA_ROUTE_TABLE_ID is not the Lambda subnet effective route table"
    lambda_subnet_has_dynamodb_access "$LAMBDA_ROUTE_TABLE_ID" "$VPC_ID" ||
        fail "Lambda subnet has no DynamoDB access through NAT or a DynamoDB gateway endpoint"

    effective_gateway_route_table_id="$(
        effective_route_table_id "$GATEWAY_PUBLIC_SUBNET_ID" "$VPC_ID"
    )" || fail "could not resolve the gateway subnet effective route table"
    gateway_default_route_target="$(aws ec2 describe-route-tables \
        --route-table-ids "$effective_gateway_route_table_id" \
        --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0' && State=='active'].GatewayId | [0]" \
        --output text \
        --region "$REGION")" ||
        fail "could not inspect the gateway subnet effective route table"
    case "$gateway_default_route_target" in
        igw-*) ;;
        *) fail "gateway subnet has no active 0.0.0.0/0 route to an internet gateway" ;;
    esac

    wireguard_route_count="$(aws ec2 describe-route-tables \
        --route-table-ids "$LAMBDA_ROUTE_TABLE_ID" \
        --query "length(RouteTables[0].Routes[?DestinationCidrBlock=='10.200.0.0/24'])" \
        --output text \
        --region "$REGION")" || fail "could not inspect LAMBDA_ROUTE_TABLE_ID"
    if [ "$wireguard_route_count" -ne 0 ]; then
        wireguard_route_instance_id="$(aws ec2 describe-route-tables \
            --route-table-ids "$LAMBDA_ROUTE_TABLE_ID" \
            --query "RouteTables[0].Routes[?DestinationCidrBlock=='10.200.0.0/24'].InstanceId | [0]" \
            --output text \
            --region "$REGION")" || fail "could not inspect the existing WireGuard route"
        stack_owns_wireguard_route \
            "$LAMBDA_ROUTE_TABLE_ID" \
            "$wireguard_route_instance_id" ||
            fail "LAMBDA_ROUTE_TABLE_ID has a conflicting 10.200.0.0/24 route"
    fi
    printf '==> WireGuard gateway VPC topology checks passed\n'
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

select_wireguard_deployment_mode() {
    local requested_enabled="$1"
    local prior_enabled="$2"
    local prior_cleanup_retained="$3"

    if [ "$requested_enabled" -eq 1 ]; then
        printf '%s\n' enabled
    elif [ "$prior_enabled" = true ]; then
        printf '%s\n' detach-then-cleanup
    elif [ "$prior_cleanup_retained" = true ]; then
        printf '%s\n' resume-cleanup
    else
        printf '%s\n' disabled
    fi
}

plan_wireguard_deployment() {
    local prior_parameters parameter_key parameter_value
    local prior_gateway_enabled=false
    local prior_cleanup_retained=false
    local prior_vpc_id=""

    if [ "$ENABLE_WIREGUARD_GATEWAY" -eq 1 ]; then
        WIREGUARD_DEPLOYMENT_MODE=enabled
        return 0
    fi

    if ! prior_parameters="$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Parameters[].[ParameterKey,ParameterValue]' \
        --output text \
        --profile "$PROFILE" \
        --region "$REGION" \
        2>&1)"
    then
        case "$prior_parameters" in
            *"does not exist"*)
                WIREGUARD_DEPLOYMENT_MODE=disabled
                return 0
                ;;
            *) fail "could not inspect prior WireGuard deployment state" ;;
        esac
    fi

    while IFS=$'\t' read -r parameter_key parameter_value; do
        case "$parameter_key" in
            EnableWireGuardGateway) prior_gateway_enabled="$parameter_value" ;;
            RetainExecutionVpcCleanupResources)
                prior_cleanup_retained="$parameter_value"
                ;;
            VpcId) prior_vpc_id="$parameter_value" ;;
        esac
    done <<<"$prior_parameters"

    WIREGUARD_DEPLOYMENT_MODE="$(select_wireguard_deployment_mode \
        "$ENABLE_WIREGUARD_GATEWAY" \
        "$prior_gateway_enabled" \
        "$prior_cleanup_retained")"

    case "$WIREGUARD_DEPLOYMENT_MODE" in
        detach-then-cleanup | resume-cleanup)
            [[ "$prior_vpc_id" =~ ^vpc-([0-9a-f]{8}|[0-9a-f]{17})$ ]] ||
                fail "enabled stack has no valid VpcId for retained cleanup resources"
            VPC_ID="$prior_vpc_id"
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
        *)
            fail "could not inspect IntakeFunction in stack $STACK_NAME"
            ;;
    esac
}

execution_vpc_cleanup_ready() {
    local function_configuration function_state last_update_status
    local vpc_id_length subnet_count security_group_count
    local configured_version_count execution_security_group_id eni_count

    function_configuration="$(aws lambda get-function-configuration \
        --function-name "$EXECUTION_FUNCTION_NAME" \
        --query '[State,LastUpdateStatus,length(VpcConfig.VpcId),length(VpcConfig.SubnetIds),length(VpcConfig.SecurityGroupIds)]' \
        --output text \
        --profile "$PROFILE" \
        --region "$REGION")" || return 2
    read -r \
        function_state \
        last_update_status \
        vpc_id_length \
        subnet_count \
        security_group_count <<<"$function_configuration"

    [[ "$vpc_id_length" =~ ^[0-9]+$ ]] || return 2
    [[ "$subnet_count" =~ ^[0-9]+$ ]] || return 2
    [[ "$security_group_count" =~ ^[0-9]+$ ]] || return 2
    if [ "$function_state" != Active ] ||
        [ "$last_update_status" != Successful ] ||
        [ "$vpc_id_length" -ne 0 ] ||
        [ "$subnet_count" -ne 0 ] ||
        [ "$security_group_count" -ne 0 ]
    then
        printf '==> Waiting for the execution Lambda VPC configuration to detach\n'
        return 1
    fi

    configured_version_count="$(aws lambda list-versions-by-function \
        --function-name "$EXECUTION_FUNCTION_NAME" \
        --query "length(Versions[?VpcConfig.VpcId!=''])" \
        --output json \
        --profile "$PROFILE" \
        --region "$REGION")" || return 2
    [[ "$configured_version_count" =~ ^[0-9]+$ ]] || return 2
    if [ "$configured_version_count" -ne 0 ]; then
        printf '==> Waiting for all execution Lambda versions to detach from the VPC\n'
        return 1
    fi

    execution_security_group_id="$(aws cloudformation describe-stack-resource \
        --stack-name "$STACK_NAME" \
        --logical-resource-id ExecutionLambdaSecurityGroup \
        --query StackResourceDetail.PhysicalResourceId \
        --output text \
        --profile "$PROFILE" \
        --region "$REGION")" || return 2
    [[ "$execution_security_group_id" =~ ^sg-([0-9a-f]{8}|[0-9a-f]{17})$ ]] ||
        return 2

    eni_count="$(aws ec2 describe-network-interfaces \
        --filters "Name=group-id,Values=$execution_security_group_id" \
        --query 'length(NetworkInterfaces)' \
        --output json \
        --profile "$PROFILE" \
        --region "$REGION")" || return 2
    [[ "$eni_count" =~ ^[0-9]+$ ]] || return 2
    if [ "$eni_count" -ne 0 ]; then
        printf '==> Waiting for Lambda to delete %s retained network interface(s)\n' \
            "$eni_count"
        return 1
    fi

    return 0
}

wait_for_execution_vpc_cleanup() {
    local max_attempts="${VPC_CLEANUP_MAX_ATTEMPTS:-121}"
    local poll_seconds="${VPC_CLEANUP_POLL_SECONDS:-10}"
    local attempt readiness_status

    [[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] ||
        fail "VPC_CLEANUP_MAX_ATTEMPTS must be a positive integer"
    [[ "$poll_seconds" =~ ^[0-9]+$ ]] ||
        fail "VPC_CLEANUP_POLL_SECONDS must be a non-negative integer"

    printf '==> Waiting for Lambda VPC cleanup before removing retained resources\n'
    for ((attempt = 1; attempt <= 10#$max_attempts; attempt++)); do
        if execution_vpc_cleanup_ready; then
            printf '==> Lambda VPC cleanup is complete\n'
            return 0
        else
            readiness_status=$?
        fi
        [ "$readiness_status" -eq 1 ] ||
            fail "could not verify execution Lambda VPC cleanup"
        if [ "$attempt" -lt "$max_attempts" ]; then
            sleep "$poll_seconds"
        fi
    done

    fail "execution Lambda VPC cleanup did not finish within the bounded wait; retained permissions and security group remain"
}

build_sam_parameter_overrides() {
    local retain_cleanup_resources="$1"

    case "$retain_cleanup_resources" in
        true | false) ;;
        *) fail "internal cleanup-retention value must be true or false" ;;
    esac

    SAM_PARAMETER_OVERRIDES=(
        "IntakeFunctionName=$INTAKE_FUNCTION_NAME"
        "QueryFunctionName=$QUERY_FUNCTION_NAME"
        "ExecutionFunctionName=$EXECUTION_FUNCTION_NAME"
        "TigerBeetleClusterId=$TIGERBEETLE_CLUSTER_ID"
        "TigerBeetleAddresses=$TIGERBEETLE_ADDRESSES"
        "LambdaPrincipal=$LAMBDA_PRINCIPAL"
        "PasetoPublicKey=$PASETO_PUBLIC_KEY"
        "RetainExecutionVpcCleanupResources=$retain_cleanup_resources"
    )
    if [ "$ENABLE_WIREGUARD_GATEWAY" -eq 1 ]; then
        SAM_PARAMETER_OVERRIDES+=(
            "EnableWireGuardGateway=true"
            "VpcId=$VPC_ID"
            "GatewayPublicSubnetId=$GATEWAY_PUBLIC_SUBNET_ID"
            "LambdaSubnetId=$LAMBDA_SUBNET_ID"
            "LambdaRouteTableId=$LAMBDA_ROUTE_TABLE_ID"
            "LambdaSubnetCidr=$LAMBDA_SUBNET_CIDR"
            "WireGuardPrivateKeyParameterName=$WIREGUARD_PRIVATE_KEY_PARAMETER_NAME"
            "WireGuardPrivateKeyParameterVersion=$WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION"
            "WireGuardGatewayPublicKey=$WIREGUARD_GATEWAY_PUBLIC_KEY"
            "WireGuardWorkstationPublicKey=$WIREGUARD_WORKSTATION_PUBLIC_KEY"
            "WireGuardInstanceType=$WIREGUARD_INSTANCE_TYPE"
        )
    else
        SAM_PARAMETER_OVERRIDES+=("EnableWireGuardGateway=false")
        if [ "$retain_cleanup_resources" = true ]; then
            SAM_PARAMETER_OVERRIDES+=("VpcId=$VPC_ID")
        fi
    fi
}

deploy_stack_phase() {
    local retain_cleanup_resources="$1"
    local phase_description="$2"

    build_sam_parameter_overrides "$retain_cleanup_resources"
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

run_wireguard_deployment() {
    local deployment_mode="$1"

    case "$deployment_mode" in
        enabled)
            deploy_stack_phase false "Deploying enabled WireGuard stack"
            ;;
        detach-then-cleanup)
            deploy_stack_phase true "Detaching execution Lambda from the VPC" ||
                return
            DEPLOYMENT_ERROR_PHASE="execution Lambda VPC cleanup wait"
            wait_for_execution_vpc_cleanup || return
            deploy_stack_phase false "Removing retained VPC cleanup resources"
            ;;
        resume-cleanup)
            DEPLOYMENT_ERROR_PHASE="execution Lambda VPC cleanup wait"
            wait_for_execution_vpc_cleanup || return
            deploy_stack_phase false "Removing retained VPC cleanup resources"
            ;;
        disabled)
            deploy_stack_phase false "Deploying disabled WireGuard stack"
            ;;
        *) fail "unknown WireGuard deployment mode: $deployment_mode" ;;
    esac
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

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

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
        --enable-wireguard-gateway)
            ENABLE_WIREGUARD_GATEWAY=1
            shift
            ;;
        --vpc-id)
            need_value "$1" "${2:-}"
            VPC_ID="$2"
            shift 2
            ;;
        --vpc-id=*)
            VPC_ID="${1#*=}"
            [ -n "$VPC_ID" ] || fail "empty value for --vpc-id"
            shift
            ;;
        --gateway-public-subnet-id)
            need_value "$1" "${2:-}"
            GATEWAY_PUBLIC_SUBNET_ID="$2"
            shift 2
            ;;
        --gateway-public-subnet-id=*)
            GATEWAY_PUBLIC_SUBNET_ID="${1#*=}"
            [ -n "$GATEWAY_PUBLIC_SUBNET_ID" ] ||
                fail "empty value for --gateway-public-subnet-id"
            shift
            ;;
        --lambda-subnet-id)
            need_value "$1" "${2:-}"
            LAMBDA_SUBNET_ID="$2"
            shift 2
            ;;
        --lambda-subnet-id=*)
            LAMBDA_SUBNET_ID="${1#*=}"
            [ -n "$LAMBDA_SUBNET_ID" ] || fail "empty value for --lambda-subnet-id"
            shift
            ;;
        --lambda-route-table-id)
            need_value "$1" "${2:-}"
            LAMBDA_ROUTE_TABLE_ID="$2"
            shift 2
            ;;
        --lambda-route-table-id=*)
            LAMBDA_ROUTE_TABLE_ID="${1#*=}"
            [ -n "$LAMBDA_ROUTE_TABLE_ID" ] ||
                fail "empty value for --lambda-route-table-id"
            shift
            ;;
        --lambda-subnet-cidr)
            need_value "$1" "${2:-}"
            LAMBDA_SUBNET_CIDR="$2"
            shift 2
            ;;
        --lambda-subnet-cidr=*)
            LAMBDA_SUBNET_CIDR="${1#*=}"
            [ -n "$LAMBDA_SUBNET_CIDR" ] || fail "empty value for --lambda-subnet-cidr"
            shift
            ;;
        --wireguard-private-key-parameter-name)
            need_value "$1" "${2:-}"
            WIREGUARD_PRIVATE_KEY_PARAMETER_NAME="$2"
            shift 2
            ;;
        --wireguard-private-key-parameter-name=*)
            WIREGUARD_PRIVATE_KEY_PARAMETER_NAME="${1#*=}"
            [ -n "$WIREGUARD_PRIVATE_KEY_PARAMETER_NAME" ] ||
                fail "empty value for --wireguard-private-key-parameter-name"
            shift
            ;;
        --wireguard-private-key-parameter-version)
            need_value "$1" "${2:-}"
            WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION="$2"
            shift 2
            ;;
        --wireguard-private-key-parameter-version=*)
            WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION="${1#*=}"
            [ -n "$WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION" ] ||
                fail "empty value for --wireguard-private-key-parameter-version"
            shift
            ;;
        --wireguard-gateway-public-key)
            need_value "$1" "${2:-}"
            WIREGUARD_GATEWAY_PUBLIC_KEY="$2"
            shift 2
            ;;
        --wireguard-gateway-public-key=*)
            WIREGUARD_GATEWAY_PUBLIC_KEY="${1#*=}"
            [ -n "$WIREGUARD_GATEWAY_PUBLIC_KEY" ] ||
                fail "empty value for --wireguard-gateway-public-key"
            shift
            ;;
        --wireguard-workstation-public-key)
            need_value "$1" "${2:-}"
            WIREGUARD_WORKSTATION_PUBLIC_KEY="$2"
            shift 2
            ;;
        --wireguard-workstation-public-key=*)
            WIREGUARD_WORKSTATION_PUBLIC_KEY="${1#*=}"
            [ -n "$WIREGUARD_WORKSTATION_PUBLIC_KEY" ] ||
                fail "empty value for --wireguard-workstation-public-key"
            shift
            ;;
        --wireguard-instance-type)
            need_value "$1" "${2:-}"
            WIREGUARD_INSTANCE_TYPE="$2"
            shift 2
            ;;
        --wireguard-instance-type=*)
            WIREGUARD_INSTANCE_TYPE="${1#*=}"
            [ -n "$WIREGUARD_INSTANCE_TYPE" ] ||
                fail "empty value for --wireguard-instance-type"
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

CACHE_DIR=".zig-cache-deploy"
GLOBAL_CACHE_DIR=".zig-global-cache-deploy"
cleanup() {
    if [ -n "$WIREGUARD_KEY_DIR" ] && [ -d "$WIREGUARD_KEY_DIR" ]; then
        rm -rf -- "$WIREGUARD_KEY_DIR"
    fi
    rm -rf -- "$CACHE_DIR" "$GLOBAL_CACHE_DIR"
}
trap cleanup EXIT

[ "$DRY_RUN" -eq 0 ] || [ "$MIGRATION_CHECK_ONLY" -eq 0 ] ||
    fail "--dry-run and --migration-check-only cannot be combined"

if [ "$MIGRATION_CHECK_ONLY" -eq 0 ]; then
    validate_tigerbeetle_configuration
    validate_wireguard_gateway_syntax
fi

if [ "$DRY_RUN" -eq 0 ]; then
    need_command aws
    prepare_aws_sso_session "$PROFILE"
    ensure_stack_not_in_progress
    validate_existing_intake_name "$INTAKE_FUNCTION_NAME"
fi
if [ "$MIGRATION_CHECK_ONLY" -eq 1 ]; then
    printf '==> Intake-name migration check complete. Skipped build and deploy.\n'
    exit 0
fi

if [ "$DRY_RUN" -eq 0 ]; then
    plan_wireguard_deployment
else
    WIREGUARD_DEPLOYMENT_MODE="$(select_wireguard_deployment_mode \
        "$ENABLE_WIREGUARD_GATEWAY" false false)"
fi

[ -n "$PASETO_PUBLIC_KEY" ] ||
    fail "PASETO_PUBLIC_KEY is required; generate one with: zig-out/bin/paseto keygen"
if [ "$DRY_RUN" -eq 0 ] && [ "$CHECK_URL" -eq 1 ]; then
    [ -n "${PASETO_PRIVATE_KEY:-}" ] ||
        fail "PASETO_PRIVATE_KEY is required for the authenticated Function URL check"
fi
if [ "$ENABLE_WIREGUARD_GATEWAY" -eq 1 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '==> Deferred WireGuard gateway AWS discovery, SSM key resolution, and topology preflight for dry run\n'
    else
        load_prior_wireguard_configuration
        [ -n "$WIREGUARD_INSTANCE_TYPE" ] || WIREGUARD_INSTANCE_TYPE=t4g.nano
        validate_wireguard_gateway_syntax
        [ -n "$WIREGUARD_WORKSTATION_PUBLIC_KEY" ] ||
            fail "WIREGUARD_WORKSTATION_PUBLIC_KEY is required on first enablement"
        discover_wireguard_network
        preflight_wireguard_gateway
        resolve_wireguard_key_configuration
        validate_wireguard_gateway_configuration
    fi
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
    exit 0
fi

DEPLOYMENT_STARTED=1
set +e
run_wireguard_deployment "$WIREGUARD_DEPLOYMENT_MODE"
DEPLOYMENT_EXIT_STATUS=$?
set -e
if [ "$DEPLOYMENT_EXIT_STATUS" -ne 0 ]; then
    report_cloudformation_outcome "$DEPLOYMENT_ERROR_PHASE"
    exit "$DEPLOYMENT_EXIT_STATUS"
fi
DEPLOYMENT_ERROR_PHASE="post-deployment checks"
trap deployment_error_handler ERR

printf '==> Stack status\n'
aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query 'Stacks[0].StackStatus' \
    --output text \
    --region "$REGION"

if [ "$ENABLE_WIREGUARD_GATEWAY" -eq 1 ]; then
    printf '==> WireGuard gateway stack outputs\n'
    aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='WireGuardGatewayInstanceId' || OutputKey=='WireGuardGatewayElasticIp' || OutputKey=='WireGuardGatewayEndpoint' || OutputKey=='WireGuardGatewayPublicKey' || OutputKey=='WireGuardGatewayAddress' || OutputKey=='WireGuardWorkstationAddress' || OutputKey=='TigerBeetleEndpoint'].[OutputKey,OutputValue]" \
        --output table \
        --region "$REGION"
fi

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

trap - ERR
DEPLOYMENT_STARTED=0
