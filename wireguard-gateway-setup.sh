#!/usr/bin/env bash
set -euo pipefail

WIREGUARD_ENABLE_ENV_SUPPLIED=0
if declare -p ENABLE_WIREGUARD_GATEWAY >/dev/null 2>&1; then
    WIREGUARD_ENABLE_ENV_SUPPLIED=1
fi
ENABLE_WIREGUARD_GATEWAY="${ENABLE_WIREGUARD_GATEWAY-1}"
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
WIREGUARD_ACTION=enable
WIREGUARD_ACTION_EXPLICIT=0
WIREGUARD_DEPLOYMENT_MODE=enabled
DEPLOYMENT_CONTROLLER=wireguard_gateway_controller

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy.sh
source "$SCRIPT_DIR/deploy.sh"

wireguard_usage() {
    cat <<'EOF'
Usage: ./wireguard-gateway-setup.sh [options]

Enable or reconfigure the WireGuard gateway, or resume its guarded teardown.
The gateway is enabled implicitly unless --disable is supplied.

Options:
  --disable              Detach, wait for Lambda VPC cleanup, and remove the gateway.
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
                         Accepted for compatibility; enablement is implicit.
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

dynamodb_gateway_endpoint_ids_for_route_table() {
    local route_table_id="$1"
    local vpc_id="$2"

    aws ec2 describe-vpc-endpoints \
        --filters \
        "Name=vpc-id,Values=$vpc_id" \
        "Name=service-name,Values=com.amazonaws.$REGION.dynamodb" \
        --query "VpcEndpoints[?contains(RouteTableIds, '$route_table_id')].VpcEndpointId" \
        --output text \
        --region "$REGION"
}

inspect_wireguard_subnet() {
    local subnet_id="$1"
    local vpc_id="$2"
    local availability_zone="$3"
    local cidr="$4"
    local inspect_dynamodb="$5"
    local cidr_overlaps=0 route_table_id gateway_id=None endpoint_ids endpoint_id
    local endpoint_count=0 endpoint_manageable=0

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
        gateway_id="$(aws ec2 describe-route-tables \
            --route-table-ids "$route_table_id" \
            --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0' && State=='active'].GatewayId | [0]" \
            --output text \
            --region "$REGION")" || {
            printf 'AWS inspection failed: could not inspect route table %s for subnet %s\n' \
                "$route_table_id" "$subnet_id" >&2
            return 1
        }
        gateway_id="${gateway_id:-None}"

        if [ "$inspect_dynamodb" -eq 1 ]; then
            endpoint_ids="$(dynamodb_gateway_endpoint_ids_for_route_table \
                "$route_table_id" \
                "$vpc_id")" || {
                printf 'AWS inspection failed: could not inspect DynamoDB endpoints for subnet %s\n' \
                    "$subnet_id" >&2
                return 1
            }
            case "$endpoint_ids" in
                "" | None) ;;
                *)
                    for endpoint_id in $endpoint_ids; do
                        [[ "$endpoint_id" =~ ^vpce-([0-9a-f]{8}|[0-9a-f]{17})$ ]] || {
                            printf 'AWS inspection failed: invalid DynamoDB endpoint ID for subnet %s\n' \
                                "$subnet_id" >&2
                            return 1
                        }
                        endpoint_count=$((endpoint_count + 1))
                    done
                    ;;
            esac
            [ "$endpoint_count" -le 1 ] || {
                printf 'AWS inspection failed: route table %s has more than one DynamoDB gateway endpoint route\n' \
                    "$route_table_id" >&2
                return 1
            }
            endpoint_manageable=1
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
        "$endpoint_manageable"
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
    local subnet_route_table_id subnet_gateway_id subnet_endpoint_manageable
    local gateway_id gateway_vpc_id gateway_az gateway_cidr gateway_route_table_id
    local lambda_id lambda_vpc_id lambda_az lambda_cidr lambda_route_table_id
    local resolved_gateway_id resolved_lambda_id resolved_vpc_id resolved_az
    local resolved_lambda_cidr resolved_lambda_route_table_id
    local gateway_allowed lambda_allowed
    local rejection_gateway_routing=0 rejection_lambda_endpoint=0
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
            subnet_endpoint_manageable <<<"$inspected_subnet"

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
            if [ "$subnet_endpoint_manageable" -eq 1 ]; then
                lambda_subnets+=(
                    "$subnet_id|$subnet_vpc_id|$subnet_az|$subnet_cidr|$subnet_route_table_id"
                )
            else
                rejection_lambda_endpoint=$((rejection_lambda_endpoint + 1))
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
            printf '    Lambda endpoint management: %s\n' "$rejection_lambda_endpoint" >&2
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

stack_dynamodb_gateway_endpoint_id() {
    local endpoint_id

    if endpoint_id="$(aws cloudformation describe-stack-resource \
        --stack-name "$STACK_NAME" \
        --logical-resource-id ExecutionDynamoDBGatewayEndpoint \
        --query StackResourceDetail.PhysicalResourceId \
        --output text \
        --region "$REGION" 2>&1)"
    then
        case "$endpoint_id" in
            "" | None) return 2 ;;
        esac
        printf '%s\n' "$endpoint_id"
        return 0
    fi

    case "$endpoint_id" in
        *"does not exist"* | *"Unable to find details"*) return 1 ;;
        *) return 2 ;;
    esac
}

dynamodb_gateway_endpoint_details() {
    local endpoint_id="$1"
    local route_table_id="$2"

    aws ec2 describe-vpc-endpoints \
        --vpc-endpoint-ids "$endpoint_id" \
        --query "VpcEndpoints[0].[VpcEndpointId,VpcId,ServiceName,VpcEndpointType,State,length(RouteTableIds),contains(RouteTableIds, '$route_table_id')]" \
        --output text \
        --region "$REGION"
}

dynamodb_gateway_endpoint_policy() {
    local endpoint_id="$1"

    aws ec2 describe-vpc-endpoints \
        --vpc-endpoint-ids "$endpoint_id" \
        --query 'VpcEndpoints[0].PolicyDocument' \
        --output text \
        --region "$REGION"
}

endpoint_policy_is_default_full_access() {
    local policy="$1"
    local compact_policy

    compact_policy="$(printf '%s' "$policy" | tr -d '[:space:]')"
    [ "$compact_policy" = \
        '{"Version":"2008-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"*","Resource":"*"}]}' ]
}

validate_dynamodb_gateway_endpoint() {
    local endpoint_id="$1"
    local require_default_policy="$2"
    local endpoint_details actual_endpoint_id endpoint_vpc_id service_name
    local endpoint_type endpoint_state route_table_count has_route_table policy

    endpoint_details="$(dynamodb_gateway_endpoint_details \
        "$endpoint_id" \
        "$LAMBDA_ROUTE_TABLE_ID")" ||
        fail "could not inspect DynamoDB gateway endpoint $endpoint_id"
    read -r \
        actual_endpoint_id \
        endpoint_vpc_id \
        service_name \
        endpoint_type \
        endpoint_state \
        route_table_count \
        has_route_table <<<"$endpoint_details"

    [ "$actual_endpoint_id" = "$endpoint_id" ] ||
        fail "DynamoDB gateway endpoint $endpoint_id does not exist in $REGION"
    [ "$endpoint_vpc_id" = "$VPC_ID" ] ||
        fail "DynamoDB gateway endpoint $endpoint_id does not belong to VPC_ID"
    [ "$service_name" = "com.amazonaws.$REGION.dynamodb" ] ||
        fail "DynamoDB gateway endpoint $endpoint_id has a mismatched service"
    [ "$endpoint_type" = Gateway ] ||
        fail "DynamoDB gateway endpoint $endpoint_id is not a Gateway endpoint"
    [ "$endpoint_state" = available ] ||
        fail "DynamoDB gateway endpoint $endpoint_id is $endpoint_state; expected available"
    [[ "$route_table_count" =~ ^[0-9]+$ ]] ||
        fail "DynamoDB gateway endpoint $endpoint_id returned an invalid route-table count"
    [ "$route_table_count" -eq 1 ] && [ "$has_route_table" = True ] ||
        fail "DynamoDB gateway endpoint $endpoint_id must be associated exclusively with LAMBDA_ROUTE_TABLE_ID"

    [ "$require_default_policy" = true ] || return 0
    policy="$(dynamodb_gateway_endpoint_policy "$endpoint_id")" ||
        fail "could not inspect the policy for DynamoDB gateway endpoint $endpoint_id"
    endpoint_policy_is_default_full_access "$policy" ||
        fail "unmanaged DynamoDB gateway endpoint $endpoint_id has a custom policy and cannot be imported safely"
}

preflight_dynamodb_gateway_endpoint() {
    local endpoint_ids endpoint_id stack_endpoint_id="" stack_endpoint_status
    local -a route_endpoint_ids=()

    endpoint_ids="$(dynamodb_gateway_endpoint_ids_for_route_table \
        "$LAMBDA_ROUTE_TABLE_ID" \
        "$VPC_ID")" ||
        fail "could not inspect DynamoDB endpoints for LAMBDA_ROUTE_TABLE_ID"
    case "$endpoint_ids" in
        "" | None) ;;
        *)
            for endpoint_id in $endpoint_ids; do
                [[ "$endpoint_id" =~ ^vpce-([0-9a-f]{8}|[0-9a-f]{17})$ ]] ||
                    fail "LAMBDA_ROUTE_TABLE_ID returned an invalid DynamoDB endpoint ID"
                route_endpoint_ids+=("$endpoint_id")
            done
            ;;
    esac
    [ "${#route_endpoint_ids[@]}" -le 1 ] ||
        fail "LAMBDA_ROUTE_TABLE_ID has more than one DynamoDB gateway endpoint route"

    if stack_endpoint_id="$(stack_dynamodb_gateway_endpoint_id)"; then
        stack_endpoint_status=0
    else
        stack_endpoint_status=$?
    fi
    case "$stack_endpoint_status" in
        0)
            [[ "$stack_endpoint_id" =~ ^vpce-([0-9a-f]{8}|[0-9a-f]{17})$ ]] ||
                fail "stack resource ExecutionDynamoDBGatewayEndpoint has an invalid physical ID"
            validate_dynamodb_gateway_endpoint "$stack_endpoint_id" false
            [ "${#route_endpoint_ids[@]}" -eq 1 ] &&
                [ "${route_endpoint_ids[0]}" = "$stack_endpoint_id" ] ||
                fail "stack-owned DynamoDB gateway endpoint does not match LAMBDA_ROUTE_TABLE_ID"
            printf '==> Reusing stack-owned DynamoDB gateway endpoint %s\n' \
                "$stack_endpoint_id"
            ;;
        1)
            if [ "${#route_endpoint_ids[@]}" -eq 0 ]; then
                printf '==> LAMBDA_ROUTE_TABLE_ID is eligible for a stack-managed DynamoDB gateway endpoint\n'
                return 0
            fi
            endpoint_id="${route_endpoint_ids[0]}"
            validate_dynamodb_gateway_endpoint "$endpoint_id" true
            fail "unmanaged DynamoDB gateway endpoint $endpoint_id must be imported as ExecutionDynamoDBGatewayEndpoint before deployment; see docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md"
            ;;
        *) fail "could not inspect stack ownership of ExecutionDynamoDBGatewayEndpoint" ;;
    esac
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
    preflight_dynamodb_gateway_endpoint

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
    local prior_vpc_id="" prior_lambda_route_table_id=""

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
                WIREGUARD_DEPLOYMENT_MODE="$(select_wireguard_deployment_mode \
                    "$ENABLE_WIREGUARD_GATEWAY" false false)"
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
            LambdaRouteTableId) prior_lambda_route_table_id="$parameter_value" ;;
        esac
    done <<<"$prior_parameters"

    if [ "$ENABLE_WIREGUARD_GATEWAY" -eq 1 ] &&
        [ "$prior_gateway_enabled" = false ] &&
        [ "$prior_cleanup_retained" = true ]
    then
        fail "stack $STACK_NAME is midway through retained WireGuard cleanup; run ./wireguard-gateway-setup.sh --disable to complete it before enabling"
    fi

    WIREGUARD_DEPLOYMENT_MODE="$(select_wireguard_deployment_mode \
        "$ENABLE_WIREGUARD_GATEWAY" \
        "$prior_gateway_enabled" \
        "$prior_cleanup_retained")"

    case "$WIREGUARD_DEPLOYMENT_MODE" in
        detach-then-cleanup | resume-cleanup)
            [[ "$prior_vpc_id" =~ ^vpc-([0-9a-f]{8}|[0-9a-f]{17})$ ]] ||
                fail "enabled stack has no valid VpcId for retained cleanup resources"
            [[ "$prior_lambda_route_table_id" =~ ^rtb-([0-9a-f]{8}|[0-9a-f]{17})$ ]] ||
                fail "enabled stack has no valid LambdaRouteTableId for retained cleanup resources"
            VPC_ID="$prior_vpc_id"
            LAMBDA_ROUTE_TABLE_ID="$prior_lambda_route_table_id"
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

    fail "execution Lambda VPC cleanup did not finish within the bounded wait; the retained DynamoDB endpoint, permissions, and security group remain"
}

build_wireguard_parameter_overrides() {
    local retain_cleanup_resources="$1"

    case "$retain_cleanup_resources" in
        true | false) ;;
        *) fail "internal cleanup-retention value must be true or false" ;;
    esac

    DEPLOYMENT_PARAMETER_OVERRIDES=(
        "RetainExecutionVpcCleanupResources=$retain_cleanup_resources"
    )
    if [ "$ENABLE_WIREGUARD_GATEWAY" -eq 1 ]; then
        DEPLOYMENT_PARAMETER_OVERRIDES+=(
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
        DEPLOYMENT_PARAMETER_OVERRIDES+=("EnableWireGuardGateway=false")
        if [ "$retain_cleanup_resources" = true ]; then
            DEPLOYMENT_PARAMETER_OVERRIDES+=(
                "VpcId=$VPC_ID"
                "LambdaRouteTableId=$LAMBDA_ROUTE_TABLE_ID"
            )
        fi
    fi
}

deploy_wireguard_stack_phase() {
    local retain_cleanup_resources="$1"
    local phase_description="$2"

    build_wireguard_parameter_overrides "$retain_cleanup_resources"
    deploy_stack_phase "$phase_description"
}

run_wireguard_deployment() {
    local deployment_mode="$1"

    case "$deployment_mode" in
        enabled)
            deploy_wireguard_stack_phase false "Deploying enabled WireGuard stack"
            ;;
        detach-then-cleanup)
            deploy_wireguard_stack_phase true "Detaching execution Lambda from the VPC" ||
                return
            DEPLOYMENT_ERROR_PHASE="execution Lambda VPC cleanup wait"
            wait_for_execution_vpc_cleanup || return
            deploy_wireguard_stack_phase false "Removing retained VPC cleanup resources"
            ;;
        resume-cleanup)
            DEPLOYMENT_ERROR_PHASE="execution Lambda VPC cleanup wait"
            wait_for_execution_vpc_cleanup || return
            deploy_wireguard_stack_phase false "Removing retained VPC cleanup resources"
            ;;
        disabled)
            deploy_wireguard_stack_phase false "Deploying disabled WireGuard stack"
            ;;
        *) fail "unknown WireGuard deployment mode: $deployment_mode" ;;
    esac
}

wireguard_cleanup() {
    if [ -n "$WIREGUARD_KEY_DIR" ] && [ -d "$WIREGUARD_KEY_DIR" ]; then
        rm -rf -- "$WIREGUARD_KEY_DIR"
    fi
}

print_wireguard_peer_configuration() {
    local stack_outputs line output_key output_value lambda_subnet_cidr
    local gateway_elastic_ip="" gateway_endpoint="" gateway_public_key=""
    local workstation_address=""
    local endpoint_address octet octet_value
    local -a endpoint_octets

    stack_outputs="$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='ExecutionDynamoDBGatewayEndpointId' || OutputKey=='WireGuardGatewayInstanceId' || OutputKey=='WireGuardGatewayElasticIp' || OutputKey=='WireGuardGatewayEndpoint' || OutputKey=='WireGuardGatewayPublicKey' || OutputKey=='WireGuardGatewayAddress' || OutputKey=='WireGuardWorkstationAddress' || OutputKey=='TigerBeetleEndpoint'].join('|', [OutputKey,OutputValue])" \
        --output text \
        --profile "$PROFILE" \
        --region "$REGION")" ||
        fail "could not resolve WireGuard gateway stack outputs"
    lambda_subnet_cidr="$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query "Stacks[0].Parameters[?ParameterKey=='LambdaSubnetCidr'].ParameterValue | [0]" \
        --output text \
        --profile "$PROFILE" \
        --region "$REGION")" ||
        fail "could not resolve LambdaSubnetCidr from the deployed stack"

    printf '==> WireGuard gateway stack outputs\n'
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            *'|'*)
                output_key="${line%%|*}"
                output_value="${line#*|}"
                ;;
            *)
                IFS=$'\t' read -r output_key output_value <<<"$line"
                ;;
        esac
        printf '%s: %s\n' "$output_key" "$output_value"
        case "$output_key" in
            WireGuardGatewayElasticIp) gateway_elastic_ip="$output_value" ;;
            WireGuardGatewayEndpoint) gateway_endpoint="$output_value" ;;
            WireGuardGatewayPublicKey) gateway_public_key="$output_value" ;;
            WireGuardWorkstationAddress) workstation_address="$output_value" ;;
        esac
    # AWS CLI's text formatter separates a projected list of scalar strings
    # with tabs on one line. Normalize those separators before parsing each
    # joined OutputKey|OutputValue record.
    done <<<"${stack_outputs//$'\t'/$'\n'}"

    case "$gateway_endpoint" in
        *:51820) endpoint_address="${gateway_endpoint%:51820}" ;;
        *) fail "stack output WireGuardGatewayEndpoint is missing or malformed" ;;
    esac
    [[ "$endpoint_address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
        fail "stack output WireGuardGatewayEndpoint is missing or malformed"
    IFS=. read -r -a endpoint_octets <<<"$endpoint_address"
    [ "${#endpoint_octets[@]}" -eq 4 ] ||
        fail "stack output WireGuardGatewayEndpoint is missing or malformed"
    for octet in "${endpoint_octets[@]}"; do
        octet_value=$((10#$octet))
        [ "$octet_value" -le 255 ] ||
            fail "stack output WireGuardGatewayEndpoint is missing or malformed"
    done
    [ "$gateway_elastic_ip" = "$endpoint_address" ] ||
        fail "stack outputs WireGuardGatewayElasticIp and WireGuardGatewayEndpoint do not match"
    [[ "$gateway_public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] ||
        fail "stack output WireGuardGatewayPublicKey is missing or malformed"
    [ "$workstation_address" = 10.200.0.2/24 ] ||
        fail "stack output WireGuardWorkstationAddress is missing or malformed"
    case "$lambda_subnet_cidr" in
        "" | None) fail "stack parameter LambdaSubnetCidr is missing or malformed" ;;
    esac
    validate_ipv4_cidr LambdaSubnetCidr "$lambda_subnet_cidr"

    printf '%s\n' '-----BEGIN WIREGUARD PEER CONFIGURATION-----'
    printf '%s\n' '[Interface]'
    printf 'Address = %s\n' "$workstation_address"
    printf '%s\n\n' 'PrivateKey = <wireguard-peer-private-key>'
    printf '%s\n' '[Peer]'
    printf 'PublicKey = %s\n' "$gateway_public_key"
    printf 'Endpoint = %s\n' "$gateway_endpoint"
    printf 'AllowedIPs = %s\n' "$lambda_subnet_cidr"
    printf '%s\n' 'PersistentKeepalive = 25'
    printf '%s\n' '-----END WIREGUARD PEER CONFIGURATION-----'
    printf '%s\n' 'Replace <wireguard-peer-private-key> with the private key matching the supplied WireGuardWorkstationPublicKey.'
}

wireguard_gateway_controller() {
    local phase="$1"

    case "$phase" in
        plan)
            validate_wireguard_gateway_syntax
            if [ "$DRY_RUN" -eq 1 ]; then
                WIREGUARD_DEPLOYMENT_MODE="$(select_wireguard_deployment_mode \
                    "$ENABLE_WIREGUARD_GATEWAY" false false)"
                printf '==> Deferred WireGuard gateway AWS discovery, SSM key resolution, and topology preflight for dry run\n'
                return 0
            fi
            plan_wireguard_deployment
            if [ "$ENABLE_WIREGUARD_GATEWAY" -eq 1 ]; then
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
            ;;
        deploy) run_wireguard_deployment "$WIREGUARD_DEPLOYMENT_MODE" ;;
        outputs)
            if [ "$WIREGUARD_DEPLOYMENT_MODE" = enabled ]; then
                print_wireguard_peer_configuration
            fi
            ;;
        cleanup) wireguard_cleanup ;;
        *) fail "unknown WireGuard gateway controller phase: $phase" ;;
    esac
}

parse_wireguard_options() {
    local option_name option_value

    COMMON_DEPLOYMENT_ARGS=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --disable)
                WIREGUARD_ACTION=disable
                WIREGUARD_ACTION_EXPLICIT=1
                shift
                ;;
            --enable-wireguard-gateway)
                WIREGUARD_ACTION=enable
                WIREGUARD_ACTION_EXPLICIT=1
                shift
                ;;
            --vpc-id | --gateway-public-subnet-id | --lambda-subnet-id | \
                --lambda-route-table-id | --lambda-subnet-cidr | \
                --wireguard-private-key-parameter-name | \
                --wireguard-private-key-parameter-version | \
                --wireguard-gateway-public-key | \
                --wireguard-workstation-public-key | \
                --wireguard-instance-type)
                need_value "$1" "${2:-}"
                case "$1" in
                    --vpc-id) VPC_ID="$2" ;;
                    --gateway-public-subnet-id) GATEWAY_PUBLIC_SUBNET_ID="$2" ;;
                    --lambda-subnet-id) LAMBDA_SUBNET_ID="$2" ;;
                    --lambda-route-table-id) LAMBDA_ROUTE_TABLE_ID="$2" ;;
                    --lambda-subnet-cidr) LAMBDA_SUBNET_CIDR="$2" ;;
                    --wireguard-private-key-parameter-name)
                        WIREGUARD_PRIVATE_KEY_PARAMETER_NAME="$2"
                        ;;
                    --wireguard-private-key-parameter-version)
                        WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION="$2"
                        ;;
                    --wireguard-gateway-public-key)
                        WIREGUARD_GATEWAY_PUBLIC_KEY="$2"
                        ;;
                    --wireguard-workstation-public-key)
                        WIREGUARD_WORKSTATION_PUBLIC_KEY="$2"
                        ;;
                    --wireguard-instance-type) WIREGUARD_INSTANCE_TYPE="$2" ;;
                esac
                shift 2
                ;;
            --vpc-id=* | --gateway-public-subnet-id=* | --lambda-subnet-id=* | \
                --lambda-route-table-id=* | --lambda-subnet-cidr=* | \
                --wireguard-private-key-parameter-name=* | \
                --wireguard-private-key-parameter-version=* | \
                --wireguard-gateway-public-key=* | \
                --wireguard-workstation-public-key=* | \
                --wireguard-instance-type=*)
                option_name="${1%%=*}"
                option_value="${1#*=}"
                [ -n "$option_value" ] || fail "empty value for $option_name"
                case "$option_name" in
                    --vpc-id) VPC_ID="$option_value" ;;
                    --gateway-public-subnet-id) GATEWAY_PUBLIC_SUBNET_ID="$option_value" ;;
                    --lambda-subnet-id) LAMBDA_SUBNET_ID="$option_value" ;;
                    --lambda-route-table-id) LAMBDA_ROUTE_TABLE_ID="$option_value" ;;
                    --lambda-subnet-cidr) LAMBDA_SUBNET_CIDR="$option_value" ;;
                    --wireguard-private-key-parameter-name)
                        WIREGUARD_PRIVATE_KEY_PARAMETER_NAME="$option_value"
                        ;;
                    --wireguard-private-key-parameter-version)
                        WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION="$option_value"
                        ;;
                    --wireguard-gateway-public-key)
                        WIREGUARD_GATEWAY_PUBLIC_KEY="$option_value"
                        ;;
                    --wireguard-workstation-public-key)
                        WIREGUARD_WORKSTATION_PUBLIC_KEY="$option_value"
                        ;;
                    --wireguard-instance-type) WIREGUARD_INSTANCE_TYPE="$option_value" ;;
                esac
                shift
                ;;
            -h | --help)
                wireguard_usage
                exit 0
                ;;
            *)
                COMMON_DEPLOYMENT_ARGS+=("$1")
                case "$1" in
                    --profile | --region | --stack-name | \
                        --intake-function-name | --query-function-name | \
                        --execution-function-name | --tigerbeetle-cluster-id | \
                        --tigerbeetle-addresses | --lambda-principal)
                        need_value "$1" "${2:-}"
                        COMMON_DEPLOYMENT_ARGS+=("$2")
                        shift 2
                        ;;
                    *) shift ;;
                esac
                ;;
        esac
    done
}

apply_wireguard_action() {
    if [ "$WIREGUARD_ACTION_EXPLICIT" -eq 0 ] &&
        [ "$WIREGUARD_ENABLE_ENV_SUPPLIED" -eq 1 ]
    then
        case "$ENABLE_WIREGUARD_GATEWAY" in
            0) WIREGUARD_ACTION=disable ;;
            1) WIREGUARD_ACTION=enable ;;
            *) fail "ENABLE_WIREGUARD_GATEWAY must be 0 or 1" ;;
        esac
    fi
    case "$WIREGUARD_ACTION" in
        enable) ENABLE_WIREGUARD_GATEWAY=1 ;;
        disable) ENABLE_WIREGUARD_GATEWAY=0 ;;
        *) fail "unknown WireGuard action: $WIREGUARD_ACTION" ;;
    esac
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

parse_wireguard_options "$@"
apply_wireguard_action
run_deployment "${COMMON_DEPLOYMENT_ARGS[@]}"
exit $?
