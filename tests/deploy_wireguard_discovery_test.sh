#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../deploy.sh
source "$REPOSITORY_ROOT/deploy.sh"

TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/deploy-wireguard-test.XXXXXX")"
MOCK_CALL_LOG="$TEST_TMP_DIR/aws-calls.log"
trap 'rm -rf -- "$TEST_TMP_DIR"' EXIT

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local output="$1"
    local expected="$2"

    case "$output" in
        *"$expected"*) ;;
        *) fail_test "expected output to contain: $expected" ;;
    esac
}

mock_subnets() {
    case "$MOCK_SCENARIO" in
        zero)
            printf 'subnet-00000001\tvpc-00000001\tca-central-1a\t172.31.0.0/24\n'
            printf 'subnet-00000002\tvpc-00000001\tca-central-1b\t172.31.1.0/24\n'
            printf 'subnet-00000003\tvpc-00000001\tca-central-1a\t10.200.0.0/28\n'
            ;;
        unique | inspection_failure)
            printf 'subnet-00000001\tvpc-00000001\tca-central-1a\t172.31.0.0/24\n'
            printf 'subnet-00000002\tvpc-00000001\tca-central-1a\t172.31.1.0/24\n'
            ;;
        multiple)
            printf 'subnet-00000001\tvpc-00000001\tca-central-1a\t172.31.0.0/24\n'
            printf 'subnet-00000002\tvpc-00000001\tca-central-1a\t172.31.1.0/24\n'
            printf 'subnet-00000004\tvpc-00000001\tca-central-1a\t172.31.2.0/24\n'
            printf 'subnet-00000005\tvpc-00000001\tca-central-1a\t172.31.3.0/24\n'
            ;;
        *) fail_test "unknown mock scenario: $MOCK_SCENARIO" ;;
    esac
}

aws() {
    local arguments="$*"
    local argument subnet_id="" route_table_id=""

    case "$arguments" in
        "ec2 describe-subnets "*)
            mock_subnets
            return 0
            ;;
        "ec2 describe-route-tables "*)
            for argument in "$@"; do
                case "$argument" in
                    Name=association.subnet-id,Values=*)
                        subnet_id="${argument##*=}"
                        ;;
                    rtb-*) route_table_id="$argument" ;;
                esac
            done
            if [ -n "$subnet_id" ]; then
                printf '%s\n' "$subnet_id" >>"$MOCK_CALL_LOG"
                printf 'rtb-%s\n' "${subnet_id#subnet-}"
                return 0
            fi
            if [ "$MOCK_SCENARIO" = inspection_failure ] &&
                [ "$route_table_id" = rtb-00000001 ]
            then
                return 42
            fi
            case "$route_table_id" in
                rtb-00000001 | rtb-00000004) printf 'igw-00000001\n' ;;
                rtb-00000002 | rtb-00000005) printf 'None\n' ;;
                *) fail_test "unexpected route table inspection: $route_table_id" ;;
            esac
            return 0
            ;;
        "ec2 describe-vpc-endpoints "*)
            printf 'None\n'
            return 0
            ;;
        *) fail_test "unexpected mocked AWS call: $arguments" ;;
    esac
}

reset_discovery_inputs() {
    REGION=ca-central-1
    VPC_ID=""
    GATEWAY_PUBLIC_SUBNET_ID=""
    LAMBDA_SUBNET_ID=""
    LAMBDA_ROUTE_TABLE_ID=""
    LAMBDA_SUBNET_CIDR=""
    : >"$MOCK_CALL_LOG"
}

run_discovery() {
    MOCK_SCENARIO="$1"
    reset_discovery_inputs
    discover_wireguard_network
}

if zero_output="$(run_discovery zero 2>&1)"; then
    fail_test "zero-candidate discovery unexpectedly succeeded"
fi
assert_contains "$zero_output" "WireGuard subnet candidates:"
assert_contains "$zero_output" "(none)"
assert_contains "$zero_output" "gateway routing: 1"
assert_contains "$zero_output" "Lambda endpoint management: 0"
assert_contains "$zero_output" "CIDR overlap: 1"
assert_contains "$zero_output" "subnet identity: 1"
assert_contains "$zero_output" "VPC: 0"
assert_contains "$zero_output" "Availability Zone: 1"
assert_contains "$zero_output" "no WireGuard subnet pair satisfies the required topology"

if multiple_output="$(run_discovery multiple 2>&1)"; then
    fail_test "multiple-candidate discovery unexpectedly succeeded"
fi
assert_contains "$multiple_output" "gateway=subnet-00000001 lambda=subnet-00000002"
assert_contains "$multiple_output" "gateway=subnet-00000004 lambda=subnet-00000005"
assert_contains "$multiple_output" "WireGuard subnet discovery is ambiguous"
assert_contains "$multiple_output" "--gateway-public-subnet-id and/or --lambda-subnet-id"

unique_output="$(run_discovery unique 2>&1)" ||
    fail_test "unique-candidate discovery failed"
assert_contains "$unique_output" "Gateway subnet: subnet-00000001"
assert_contains "$unique_output" "Lambda subnet: subnet-00000002"
assert_contains "$unique_output" "Lambda route table: rtb-00000002"
for inspected_id in subnet-00000001 subnet-00000002; do
    inspection_count="$(grep -c "^${inspected_id}$" "$MOCK_CALL_LOG")"
    [ "$inspection_count" -eq 1 ] ||
        fail_test "$inspected_id was inspected $inspection_count times; expected once"
done

if inspection_output="$(run_discovery inspection_failure 2>&1)"; then
    fail_test "AWS inspection failure unexpectedly became a topology result"
fi
assert_contains "$inspection_output" "AWS inspection failed: could not inspect route table"
assert_contains "$inspection_output" "could not complete WireGuard topology discovery because AWS inspection failed"
case "$inspection_output" in
    *"topology rejection counts"*)
        fail_test "AWS inspection failure was reported as ordinary topology rejection"
        ;;
esac

DEFAULT_ENDPOINT_POLICY='{"Version":"2008-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"*","Resource":"*"}]}'

run_endpoint_preflight() (
    local scenario="$1"
    local mock_endpoint_id=vpce-00000001

    REGION=ca-central-1
    STACK_NAME=example-stack
    VPC_ID=vpc-00000001
    LAMBDA_ROUTE_TABLE_ID=rtb-00000002

    dynamodb_gateway_endpoint_ids_for_route_table() {
        case "$scenario" in
            absent | separate_route) printf 'None\n' ;;
            duplicate) printf 'vpce-00000001\tvpce-00000002\n' ;;
            *) printf '%s\n' "$mock_endpoint_id" ;;
        esac
    }
    stack_dynamodb_gateway_endpoint_id() {
        case "$scenario" in
            stack_owned | stack_mismatched_route) printf '%s\n' "$mock_endpoint_id" ;;
            *) return 1 ;;
        esac
    }
    dynamodb_gateway_endpoint_details() {
        local details_vpc=vpc-00000001
        local details_service=com.amazonaws.ca-central-1.dynamodb
        local details_type=Gateway
        local details_state=available
        local route_table_count=1
        local has_route_table=True

        case "$scenario" in
            shared) route_table_count=2 ;;
            unavailable) details_state=pending ;;
            mismatched_vpc) details_vpc=vpc-00000009 ;;
            mismatched_service) details_service=com.amazonaws.ca-central-1.s3 ;;
            mismatched_type) details_type=Interface ;;
            stack_mismatched_route) has_route_table=False ;;
        esac
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$mock_endpoint_id" \
            "$details_vpc" \
            "$details_service" \
            "$details_type" \
            "$details_state" \
            "$route_table_count" \
            "$has_route_table"
    }
    dynamodb_gateway_endpoint_policy() {
        case "$scenario" in
            custom_policy)
                printf '%s\n' \
                    '{"Version":"2008-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"dynamodb:GetItem","Resource":"*"}]}'
                ;;
            *) printf '%s\n' "$DEFAULT_ENDPOINT_POLICY" ;;
        esac
    }

    preflight_dynamodb_gateway_endpoint
)

absent_output="$(run_endpoint_preflight absent 2>&1)" ||
    fail_test "absent endpoint was not eligible for stack creation"
assert_contains "$absent_output" "eligible for a stack-managed DynamoDB gateway endpoint"

separate_output="$(run_endpoint_preflight separate_route 2>&1)" ||
    fail_test "endpoint on another route table blocked stack creation"
assert_contains "$separate_output" "eligible for a stack-managed DynamoDB gateway endpoint"

stack_owned_output="$(run_endpoint_preflight stack_owned 2>&1)" ||
    fail_test "correct stack-owned endpoint was rejected"
assert_contains "$stack_owned_output" "Reusing stack-owned DynamoDB gateway endpoint"

if unmanaged_output="$(run_endpoint_preflight unmanaged 2>&1)"; then
    fail_test "unmanaged importable endpoint was accepted for normal deployment"
fi
assert_contains "$unmanaged_output" "must be imported as ExecutionDynamoDBGatewayEndpoint"

for rejected_scenario in \
    shared \
    unavailable \
    duplicate \
    mismatched_vpc \
    mismatched_service \
    mismatched_type \
    stack_mismatched_route \
    custom_policy
do
    if rejected_output="$(run_endpoint_preflight "$rejected_scenario" 2>&1)"; then
        fail_test "$rejected_scenario DynamoDB endpoint was accepted"
    fi
    case "$rejected_scenario" in
        shared | stack_mismatched_route) assert_contains "$rejected_output" "associated exclusively" ;;
        unavailable) assert_contains "$rejected_output" "expected available" ;;
        duplicate) assert_contains "$rejected_output" "more than one DynamoDB gateway endpoint route" ;;
        mismatched_vpc) assert_contains "$rejected_output" "does not belong to VPC_ID" ;;
        mismatched_service) assert_contains "$rejected_output" "mismatched service" ;;
        mismatched_type) assert_contains "$rejected_output" "is not a Gateway endpoint" ;;
        custom_policy) assert_contains "$rejected_output" "custom policy" ;;
    esac
done

resolve_default_wireguard_keypair() {
    printf '%s\n%s\n' "$1" "$2"
}
STACK_NAME=example-stack
WIREGUARD_PRIVATE_KEY_PARAMETER_NAME=""
default_paths="$(resolve_wireguard_key_configuration)"
assert_contains "$default_paths" "/applications/example-stack/wireguard/gateway-private-key"
assert_contains "$default_paths" "/applications/example-stack/wireguard/gateway-public-key"

validate_parameter_path() (
    ENABLE_WIREGUARD_GATEWAY=1
    VPC_ID=""
    GATEWAY_PUBLIC_SUBNET_ID=""
    LAMBDA_SUBNET_ID=""
    LAMBDA_ROUTE_TABLE_ID=""
    LAMBDA_SUBNET_CIDR=""
    WIREGUARD_PRIVATE_KEY_PARAMETER_NAME="$1"
    WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION=""
    WIREGUARD_GATEWAY_PUBLIC_KEY=""
    WIREGUARD_WORKSTATION_PUBLIC_KEY=""
    WIREGUARD_INSTANCE_TYPE=""
    validate_wireguard_gateway_syntax
)

validate_parameter_path /applications/example/wireguard/private ||
    fail_test "valid /applications path was rejected"
for reserved_path in /aws/example/private /AWSExample/private /ssm/example/private; do
    if reserved_output="$(validate_parameter_path "$reserved_path" 2>&1)"; then
        fail_test "reserved SSM path unexpectedly succeeded: $reserved_path"
    fi
    assert_contains "$reserved_output" "reserved aws or ssm prefix"
done

printf 'PASS: deploy WireGuard discovery regression tests\n'
