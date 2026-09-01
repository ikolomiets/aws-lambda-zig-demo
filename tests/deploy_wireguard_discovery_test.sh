#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../wireguard-gateway-setup.sh
source "$REPOSITORY_ROOT/wireguard-gateway-setup.sh"

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

run_topology_preflight() (
    local scenario="$1"

    REGION=ca-central-1
    STACK_NAME=example-stack
    VPC_ID=vpc-00000001
    GATEWAY_PUBLIC_SUBNET_ID=subnet-00000001
    LAMBDA_SUBNET_ID=subnet-00000002
    LAMBDA_ROUTE_TABLE_ID=rtb-00000002
    LAMBDA_SUBNET_CIDR=172.31.1.0/24
    WIREGUARD_EGRESS_RESOURCES_EXPECTED=0
    WIREGUARD_STACK_VPC_ID=""
    WIREGUARD_STACK_ROUTE_TABLE_ID=""

    aws() {
        local service="$1"
        local operation="$2"
        local arguments="$*"
        local query=""
        shift 2
        printf '%s\n' "$service $operation $*" >>"$MOCK_CALL_LOG"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --query)
                    query="$2"
                    shift 2
                    ;;
                *) shift ;;
            esac
        done

        case "$service $operation" in
            "ec2 describe-vpcs")
                case "$query" in
                    'Vpcs[0].VpcId')
                        case "$scenario" in
                            missing_vpc) printf 'None\n' ;;
                            *) printf 'vpc-00000001\n' ;;
                        esac
                        ;;
                    *Ipv6CidrBlockAssociationSet*)
                        case "$scenario" in
                            missing_vpc_ipv6) printf 'None\n' ;;
                            inactive_vpc_ipv6)
                                printf '2600:1f11:abcd:1200::/56\tassociating\n'
                                ;;
                            malformed_vpc_ipv6)
                                printf '2600:1f11:abcd:12zz::/56\tassociated\n'
                                ;;
                            ambiguous_vpc_ipv6)
                                printf '2600:1f11:abcd:1200::/56\tassociated\n'
                                printf '2600:1f11:abcd:1200::/60\tassociated\n'
                                ;;
                            non_containing_vpc_ipv6)
                                printf '2600:1f11:abcd:1300::/56\tassociated\n'
                                ;;
                            *) printf '2600:1f11:abcd:1200::/56\tassociated\n' ;;
                        esac
                        ;;
                    *) fail_test "unexpected VPC query: $query" ;;
                esac
                ;;
            "ec2 describe-subnets")
                case "$query" in
                    'Subnets[0].[SubnetId,VpcId,AvailabilityZone,CidrBlock]')
                        case "$arguments" in
                            *subnet-00000001*)
                                printf 'subnet-00000001\tvpc-00000001\tca-central-1a\t172.31.0.0/24\n'
                                ;;
                            *subnet-00000002*)
                                case "$scenario" in
                                    missing_lambda_subnet) printf 'None\n' ;;
                                    lambda_wrong_vpc)
                                        printf 'subnet-00000002\tvpc-00000009\tca-central-1a\t172.31.1.0/24\n'
                                        ;;
                                    *)
                                        printf 'subnet-00000002\tvpc-00000001\tca-central-1a\t172.31.1.0/24\n'
                                        ;;
                                esac
                                ;;
                            *) fail_test "unexpected subnet detail request: $arguments" ;;
                        esac
                        ;;
                    *Ipv6CidrBlockAssociationSet*)
                        case "$scenario" in
                            missing_subnet_ipv6) printf 'None\n' ;;
                            inactive_subnet_ipv6)
                                printf '2600:1f11:abcd:1201::/64\tassociating\n'
                                ;;
                            malformed_subnet_ipv6)
                                printf '2600:1f11:abcd:1201::1/64\tassociated\n'
                                ;;
                            ambiguous_subnet_ipv6)
                                printf '2600:1f11:abcd:1201::/64\tassociated\n'
                                printf '2600:1f11:abcd:1202::/64\tassociated\n'
                                ;;
                            *) printf '2600:1f11:abcd:1201::/64\tassociated\n' ;;
                        esac
                        ;;
                    *) fail_test "unexpected subnet query: $query" ;;
                esac
                ;;
            "ec2 describe-route-tables")
                case "$query" in
                    'RouteTables[0].[RouteTableId,VpcId]')
                        case "$scenario" in
                            missing_route_table) printf 'None\n' ;;
                            route_wrong_vpc) printf 'rtb-00000002\tvpc-00000009\n' ;;
                            *) printf 'rtb-00000002\tvpc-00000001\n' ;;
                        esac
                        ;;
                    'RouteTables[].RouteTableId')
                        case "$arguments" in
                            *Name=association.subnet-id,Values=subnet-00000001*)
                                printf 'rtb-00000001\n'
                                ;;
                            *Name=association.subnet-id,Values=subnet-00000002*)
                                case "$scenario" in
                                    main_route) printf 'None\n' ;;
                                    route_not_effective) printf 'rtb-00000009\n' ;;
                                    ambiguous_effective_route)
                                        printf 'rtb-00000002\trtb-00000003\n'
                                        ;;
                                    *) printf 'rtb-00000002\n' ;;
                                esac
                                ;;
                            *Name=association.main,Values=true*) printf 'rtb-00000002\n' ;;
                            *) fail_test "unexpected effective route-table request: $arguments" ;;
                        esac
                        ;;
                    *"DestinationCidrBlock=='0.0.0.0/0'"*) printf 'igw-00000001\n' ;;
                    *"DestinationIpv6CidrBlock=='::/0'"*) printf 'None\n' ;;
                    *"length(RouteTables[0].Routes"*) printf '0\n' ;;
                    *) fail_test "unexpected route-table query: $query" ;;
                esac
                ;;
            "ec2 describe-egress-only-internet-gateways") printf 'None\n' ;;
            "ec2 describe-network-acls")
                case "$query" in
                    *Entries*)
                        printf '100\tTrue\t-1\tallow\tNone\tNone\tNone\n'
                        printf '101\tTrue\t-1\tallow\t::/0\tNone\tNone\n'
                        printf '32767\tTrue\t-1\tdeny\tNone\tNone\tNone\n'
                        printf '32768\tTrue\t-1\tdeny\t::/0\tNone\tNone\n'
                        printf '100\tFalse\t-1\tallow\tNone\tNone\tNone\n'
                        printf '101\tFalse\t-1\tallow\t::/0\tNone\tNone\n'
                        printf '32767\tFalse\t-1\tdeny\tNone\tNone\tNone\n'
                        printf '32768\tFalse\t-1\tdeny\t::/0\tNone\tNone\n'
                        ;;
                    NetworkAcls*) printf 'acl-00000001\tvpc-00000001\t1\n' ;;
                    *) fail_test "unexpected network ACL query: $query" ;;
                esac
                ;;
            "ec2 describe-vpc-attribute")
                case "$arguments" in
                    *enableDnsSupport*)
                        case "$scenario" in
                            dns_support_disabled) printf 'False\n' ;;
                            malformed_dns_support) printf 'None\n' ;;
                            *) printf 'True\n' ;;
                        esac
                        ;;
                    *enableDnsHostnames*)
                        case "$scenario" in
                            dns_hostnames_disabled) printf 'False\n' ;;
                            *) printf 'True\n' ;;
                        esac
                        ;;
                    *) fail_test "unexpected VPC attribute request: $arguments" ;;
                esac
                ;;
            "sqs list-queues")
                [ "${AWS_USE_DUALSTACK_ENDPOINT:-}" = true ] ||
                    fail_test "topology preflight did not select the SQS dual-stack endpoint"
                printf '0\n'
                ;;
            *) fail_test "unexpected topology AWS call: $arguments" ;;
        esac
    }

    preflight_wireguard_gateway
)

for valid_scenario in valid main_route; do
    : >"$MOCK_CALL_LOG"
    valid_output="$(run_topology_preflight "$valid_scenario" 2>&1)" ||
        fail_test "$valid_scenario external topology was rejected: $valid_output"
    assert_contains "$valid_output" "WireGuard gateway VPC topology checks passed"
done

for rejected_scenario in \
    missing_vpc \
    missing_lambda_subnet \
    lambda_wrong_vpc \
    missing_route_table \
    route_wrong_vpc \
    route_not_effective \
    ambiguous_effective_route \
    missing_subnet_ipv6 \
    inactive_subnet_ipv6 \
    malformed_subnet_ipv6 \
    ambiguous_subnet_ipv6 \
    missing_vpc_ipv6 \
    inactive_vpc_ipv6 \
    malformed_vpc_ipv6 \
    ambiguous_vpc_ipv6 \
    non_containing_vpc_ipv6 \
    dns_support_disabled \
    dns_hostnames_disabled \
    malformed_dns_support
do
    : >"$MOCK_CALL_LOG"
    if rejected_output="$(run_topology_preflight "$rejected_scenario" 2>&1)"; then
        fail_test "$rejected_scenario external topology was accepted"
    fi
    case "$rejected_scenario" in
        missing_vpc) assert_contains "$rejected_output" "VPC_ID does not exist" ;;
        missing_lambda_subnet)
            assert_contains "$rejected_output" "LAMBDA_SUBNET_ID does not exist"
            ;;
        lambda_wrong_vpc)
            assert_contains "$rejected_output" "LAMBDA_SUBNET_ID does not belong to VPC_ID"
            ;;
        missing_route_table)
            assert_contains "$rejected_output" "LAMBDA_ROUTE_TABLE_ID does not exist"
            ;;
        route_wrong_vpc)
            assert_contains "$rejected_output" "LAMBDA_ROUTE_TABLE_ID does not belong to VPC_ID"
            ;;
        route_not_effective | ambiguous_effective_route)
            assert_contains "$rejected_output" "effective route table"
            ;;
        missing_subnet_ipv6)
            assert_contains "$rejected_output" "has no IPv6 CIDR association"
            ;;
        inactive_subnet_ipv6)
            assert_contains "$rejected_output" "has no active IPv6 /64"
            ;;
        malformed_subnet_ipv6)
            assert_contains "$rejected_output" "returned malformed IPv6 CIDR"
            ;;
        ambiguous_subnet_ipv6)
            assert_contains "$rejected_output" "more than one active IPv6 /64"
            ;;
        missing_vpc_ipv6)
            assert_contains "$rejected_output" "VPC_ID has no IPv6 CIDR association"
            ;;
        inactive_vpc_ipv6 | non_containing_vpc_ipv6)
            assert_contains "$rejected_output" "no active VPC IPv6 CIDR association contains"
            ;;
        malformed_vpc_ipv6)
            assert_contains "$rejected_output" "VPC_ID returned malformed IPv6 CIDR"
            ;;
        ambiguous_vpc_ipv6)
            assert_contains "$rejected_output" "more than one active VPC IPv6 CIDR association"
            ;;
        dns_support_disabled)
            assert_contains "$rejected_output" "enableDnsSupport enabled"
            ;;
        dns_hostnames_disabled)
            assert_contains "$rejected_output" "enableDnsHostnames enabled"
            ;;
        malformed_dns_support)
            assert_contains "$rejected_output" "malformed enableDnsSupport value"
            ;;
    esac
done

run_egress_preflight() (
    local scenario="$1"
    local resources_expected="$2"
    local preflight_kind="${3:-enabled}"

    PROFILE=dev
    REGION=ca-central-1
    STACK_NAME=example-stack
    VPC_ID=vpc-00000001
    LAMBDA_SUBNET_ID=subnet-00000002
    LAMBDA_ROUTE_TABLE_ID=rtb-00000002
    WIREGUARD_EGRESS_RESOURCES_EXPECTED="$resources_expected"
    WIREGUARD_STACK_VPC_ID=vpc-00000001
    WIREGUARD_STACK_ROUTE_TABLE_ID=rtb-00000002

    aws() {
        local service="$1"
        local operation="$2"
        local query=""
        shift 2
        printf '%s\n' "$service $operation $*" >>"$MOCK_CALL_LOG"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --query)
                    query="$2"
                    shift 2
                    ;;
                *) shift ;;
            esac
        done

        case "$service $operation" in
            "ec2 describe-egress-only-internet-gateways")
                case "$scenario" in
                    missing_eigw) printf 'None\n' ;;
                    unmanaged_eigw)
                        printf 'eigw-00000001\tvpc-00000001\tattached\t1\n'
                        ;;
                    malformed_eigw)
                        printf 'eigw-invalid\tvpc-00000001\tattached\t1\n'
                        ;;
                    multiple_eigw)
                        printf 'eigw-00000001\tvpc-00000001\tattached\t1\n'
                        printf 'eigw-00000002\tvpc-00000001\tattached\t1\n'
                        ;;
                    detached_eigw)
                        printf 'eigw-00000001\tvpc-00000001\tdetached\t1\n'
                        ;;
                    wrong_vpc)
                        printf 'eigw-00000001\tvpc-00000009\tattached\t1\n'
                        ;;
                    *)
                        if [ "$resources_expected" -eq 1 ]; then
                            printf 'eigw-00000001\tvpc-00000001\tattached\t1\n'
                        else
                            printf 'None\n'
                        fi
                        ;;
                esac
                ;;
            "ec2 describe-route-tables")
                case "$scenario" in
                    missing_route) printf 'None\n' ;;
                    unmanaged_route)
                        printf 'eigw-00000009\tactive\tCreateRoute\t::/0\n'
                        ;;
                    mismatched_route)
                        printf 'eigw-00000009\tactive\tCreateRoute\t::/0\n'
                        ;;
                    blackhole_route)
                        printf 'eigw-00000001\tblackhole\tCreateRoute\t::/0\n'
                        ;;
                    malformed_route) printf 'eigw-00000001\tactive\n' ;;
                    duplicate_route)
                        printf 'eigw-00000001\tactive\tCreateRoute\t::/0\n'
                        printf 'eigw-00000001\tactive\tCreateRoute\t::/0\n'
                        ;;
                    *)
                        if [ "$resources_expected" -eq 1 ]; then
                            printf 'eigw-00000001\tactive\tCreateRoute\t::/0\n'
                        else
                            printf 'None\n'
                        fi
                        ;;
                esac
                ;;
            "cloudformation describe-stack-resource")
                case "$query" in
                    *PhysicalResourceId*)
                        case "$scenario" in
                            stack_mismatch) printf 'eigw-00000009\tCREATE_COMPLETE\n' ;;
                            *) printf 'eigw-00000001\tCREATE_COMPLETE\n' ;;
                        esac
                        ;;
                    StackResourceDetail.ResourceStatus)
                        case "$scenario" in
                            route_bad_status) printf 'UPDATE_IN_PROGRESS\n' ;;
                            *) printf 'CREATE_COMPLETE\n' ;;
                        esac
                        ;;
                    *) fail_test "unexpected stack-resource query: $query" ;;
                esac
                ;;
            "ec2 describe-network-acls")
                case "$query" in
                    *Entries*)
                        case "$scenario" in
                            incompatible_nacl)
                                printf '100\tTrue\t-1\tdeny\t::/0\tNone\tNone\n'
                                printf '100\tFalse\t-1\tdeny\t::/0\tNone\tNone\n'
                                ;;
                            nontrivial_nacl)
                                printf '50\tTrue\t6\tdeny\t2600:1f11:abcd:1200::/56\t443\t443\n'
                                printf '100\tTrue\t-1\tallow\t::/0\tNone\tNone\n'
                                printf '100\tFalse\t-1\tallow\t::/0\tNone\tNone\n'
                                ;;
                            malformed_implicit_nacl)
                                printf '100\tTrue\t-1\tallow\t::/0\tNone\tNone\n'
                                printf '100\tFalse\t-1\tallow\t::/0\tNone\tNone\n'
                                printf '32768\tTrue\t-1\tallow\t::/0\tNone\tNone\n'
                                ;;
                            *)
                                printf '100\tTrue\t-1\tallow\tNone\tNone\tNone\n'
                                printf '101\tTrue\t-1\tallow\t::/0\tNone\tNone\n'
                                printf '32767\tTrue\t-1\tdeny\tNone\tNone\tNone\n'
                                printf '32768\tTrue\t-1\tdeny\t::/0\tNone\tNone\n'
                                printf '100\tFalse\t-1\tallow\tNone\tNone\tNone\n'
                                printf '101\tFalse\t-1\tallow\t::/0\tNone\tNone\n'
                                printf '32767\tFalse\t-1\tdeny\tNone\tNone\tNone\n'
                                printf '32768\tFalse\t-1\tdeny\t::/0\tNone\tNone\n'
                                ;;
                        esac
                        ;;
                    NetworkAcls*) printf 'acl-00000001\tvpc-00000001\t1\n' ;;
                    *) fail_test "unexpected network ACL query: $query" ;;
                esac
                ;;
            "sqs list-queues")
                [ "${AWS_USE_DUALSTACK_ENDPOINT:-}" = true ] ||
                    fail_test "SQS availability probe did not select the dual-stack endpoint"
                if [ "$scenario" = unsupported_region ]; then
                    return 254
                fi
                printf '0\n'
                ;;
            *) fail_test "unexpected egress AWS call: $service $operation" ;;
        esac
    }

    case "$preflight_kind" in
        enabled) preflight_ipv6_egress ;;
        retained) preflight_retained_ipv6_egress ;;
        *) fail_test "unknown preflight kind: $preflight_kind" ;;
    esac
)

: >"$MOCK_CALL_LOG"
initial_egress_output="$(run_egress_preflight valid 0)" ||
    fail_test "clean first-enablement IPv6 egress was rejected"
assert_contains "$initial_egress_output" "Stack-owned IPv6 SQS egress checks passed"

for existing_state in enabled retained; do
    : >"$MOCK_CALL_LOG"
    existing_output="$(run_egress_preflight valid 1 "$existing_state")" ||
        fail_test "$existing_state stack-owned IPv6 egress was rejected"
    assert_contains "$existing_output" "IPv6 SQS egress checks passed"
done

for rejected_egress_scenario in \
    unmanaged_eigw \
    unmanaged_route
do
    : >"$MOCK_CALL_LOG"
    if rejected_output="$(run_egress_preflight "$rejected_egress_scenario" 0 2>&1)"; then
        fail_test "$rejected_egress_scenario first-enablement conflict was accepted"
    fi
    assert_contains "$rejected_output" "unmanaged"
done

for rejected_egress_scenario in \
    missing_eigw \
    malformed_eigw \
    multiple_eigw \
    detached_eigw \
    wrong_vpc \
    stack_mismatch \
    missing_route \
    mismatched_route \
    blackhole_route \
    malformed_route \
    duplicate_route \
    route_bad_status \
    incompatible_nacl \
    malformed_implicit_nacl \
    unsupported_region
do
    : >"$MOCK_CALL_LOG"
    if rejected_output="$(run_egress_preflight "$rejected_egress_scenario" 1 2>&1)"; then
        fail_test "$rejected_egress_scenario IPv6 egress state was accepted"
    fi
    case "$rejected_egress_scenario" in
        missing_eigw) assert_contains "$rejected_output" "EIGW is missing" ;;
        malformed_eigw) assert_contains "$rejected_output" "malformed EIGW ID" ;;
        multiple_eigw) assert_contains "$rejected_output" "multiple attached EIGWs" ;;
        detached_eigw) assert_contains "$rejected_output" "not in the attached state" ;;
        wrong_vpc) assert_contains "$rejected_output" "wrong VPC" ;;
        stack_mismatch) assert_contains "$rejected_output" "not owned by this stack" ;;
        missing_route) assert_contains "$rejected_output" "::/0 route is missing" ;;
        mismatched_route) assert_contains "$rejected_output" "targets the wrong EIGW" ;;
        blackhole_route) assert_contains "$rejected_output" "not active" ;;
        malformed_route) assert_contains "$rejected_output" "malformed ::/0 route" ;;
        duplicate_route) assert_contains "$rejected_output" "duplicate ::/0 routes" ;;
        route_bad_status) assert_contains "$rejected_output" "route is not in a complete state" ;;
        incompatible_nacl) assert_contains "$rejected_output" "plainly blocks" ;;
        malformed_implicit_nacl)
            assert_contains "$rejected_output" "malformed or unbounded"
            ;;
        unsupported_region) assert_contains "$rejected_output" "SQS dual-stack endpoint" ;;
    esac
done

: >"$MOCK_CALL_LOG"
nontrivial_output="$(run_egress_preflight nontrivial_nacl 1 2>&1)" ||
    fail_test "nontrivial NACL policy was rejected instead of warned"
assert_contains "$nontrivial_output" "nontrivial ordered IPv6 policy"
assert_contains "$nontrivial_output" "operator verification is required"

if grep -Eq '(^| )(associate|disassociate)-(vpc|subnet)-cidr-block( |$)' \
    "$MOCK_CALL_LOG"
then
    fail_test "topology preflight attempted to mutate an IPv6 CIDR association"
fi

helper_source="$(<"$REPOSITORY_ROOT/wireguard-gateway-setup.sh")"
for removed_workflow in \
    describe-vpc-endpoints \
    preflight_dynamodb_gateway_endpoint \
    endpoint_policy_is_default_full_access \
    ExecutionSqsInterfaceEndpoint \
    associate-vpc-cidr-block \
    disassociate-vpc-cidr-block \
    associate-subnet-cidr-block \
    disassociate-subnet-cidr-block \
    create-egress-only-internet-gateway \
    delete-egress-only-internet-gateway
do
    case "$helper_source" in
        *"$removed_workflow"*)
            fail_test "obsolete endpoint workflow remains in the helper: $removed_workflow"
            ;;
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
