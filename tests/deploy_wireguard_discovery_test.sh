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
                rtb-00000001 | rtb-00000004) printf 'igw-00000001\tNone\n' ;;
                rtb-00000002 | rtb-00000005) printf 'None\tNone\n' ;;
                *) fail_test "unexpected route table inspection: $route_table_id" ;;
            esac
            return 0
            ;;
        "ec2 describe-vpc-endpoints "*)
            case "$arguments" in
                *rtb-00000002* | *rtb-00000005*) printf '1\n' ;;
                *) printf '0\n' ;;
            esac
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
assert_contains "$zero_output" "Lambda DynamoDB access: 1"
assert_contains "$zero_output" "CIDR overlap: 1"
assert_contains "$zero_output" "subnet identity: 0"
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
