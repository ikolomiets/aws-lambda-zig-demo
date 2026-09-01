#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../wireguard-gateway-setup.sh
source "$REPOSITORY_ROOT/wireguard-gateway-setup.sh"

TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/deploy-cleanup-test.XXXXXX")"
MOCK_CALL_LOG="$TEST_TMP_DIR/calls.log"
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

assert_not_contains() {
    local output="$1"
    local unexpected="$2"

    case "$output" in
        *"$unexpected"*) fail_test "expected output not to contain: $unexpected" ;;
        *) ;;
    esac
}

test_fresh_sso_login() (
    aws_call_count=0
    aws() {
        case "$*" in
            "sso login --profile dev")
                aws_call_count=$((aws_call_count + 1))
                return 0
                ;;
            *) fail_test "unexpected credential AWS call: $*" ;;
        esac
    }

    AWS_ACCESS_KEY_ID=expired-inherited
    AWS_SECRET_ACCESS_KEY=expired-inherited
    AWS_SESSION_TOKEN=expired-inherited
    AWS_CREDENTIAL_EXPIRATION=2000-01-01T00:00:00Z
    AWS_PROFILE=wrong-profile
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    export AWS_CREDENTIAL_EXPIRATION AWS_PROFILE

    prepare_aws_sso_session dev

    [ "$aws_call_count" -eq 1 ] ||
        fail_test "deployment did not perform exactly one fresh SSO login"

    [ "${AWS_PROFILE:-}" = dev ] ||
        fail_test "deployment did not select the dev SSO profile"
    [ -z "${AWS_ACCESS_KEY_ID:-}" ] ||
        fail_test "deployment retained a finite access-key snapshot"
    [ -z "${AWS_SECRET_ACCESS_KEY:-}" ] ||
        fail_test "deployment retained a finite secret-key snapshot"
    [ -z "${AWS_SESSION_TOKEN:-}" ] ||
        fail_test "deployment retained a finite session-token snapshot"
    [ -z "${AWS_CREDENTIAL_EXPIRATION:-}" ] ||
        fail_test "deployment retained a finite credential expiration"
)

test_in_progress_stack_guard() (
    aws() {
        case "$*" in
            "cloudformation describe-stacks "*)
                printf '%s\n' UPDATE_COMPLETE_CLEANUP_IN_PROGRESS
                ;;
            *) fail_test "unexpected stack-guard AWS call: $*" ;;
        esac
    }

    if guard_output="$(ensure_stack_not_in_progress 2>&1)"; then
        fail_test "active CloudFormation update did not stop deployment"
    fi
    assert_contains "$guard_output" "UPDATE_COMPLETE_CLEANUP_IN_PROGRESS"
    assert_contains "$guard_output" "wait for the active operation to reach a terminal state before retrying"
)

test_cloudformation_outcome_reporting() (
    aws() {
        printf '%s\n' "$MOCK_STACK_STATUS"
    }

    MOCK_STACK_STATUS=UPDATE_COMPLETE_CLEANUP_IN_PROGRESS
    outcome="$(report_cloudformation_outcome 'SAM waiter' 2>&1)"
    assert_contains "$outcome" "CloudFormation continues"
    assert_contains "$outcome" "do not start another deployment"

    MOCK_STACK_STATUS=UPDATE_ROLLBACK_COMPLETE
    outcome="$(report_cloudformation_outcome 'SAM deploy' 2>&1)"
    assert_contains "$outcome" "terminal failure state"

    MOCK_STACK_STATUS=UPDATE_COMPLETE
    outcome="$(report_cloudformation_outcome 'post-deployment checks' 2>&1)"
    assert_contains "$outcome" "CloudFormation reached UPDATE_COMPLETE"
    assert_contains "$outcome" "post-deployment checks failed"
)

test_phase_selection() {
    local mode

    mode="$(select_wireguard_deployment_mode 0 true false)"
    [ "$mode" = detach-then-cleanup ] ||
        fail_test "enabled-to-disabled transition did not select detach first"

    mode="$(select_wireguard_deployment_mode 0 false true)"
    [ "$mode" = resume-cleanup ] ||
        fail_test "retained cleanup resources did not resume cleanup"

    mode="$(select_wireguard_deployment_mode 0 false false)"
    [ "$mode" = disabled ] ||
        fail_test "steady disabled deployment selected the wrong mode"

    mode="$(select_wireguard_deployment_mode 1 false true)"
    [ "$mode" = enabled ] ||
        fail_test "explicit enablement did not select enabled mode"
}

test_tigerbeetle_configuration() (
    TIGERBEETLE_CLUSTER_ID=0
    TIGERBEETLE_ADDRESSES=10.200.0.2:3000
    validate_tigerbeetle_configuration

    TIGERBEETLE_CLUSTER_ID=340282366920938463463374607431768211455
    TIGERBEETLE_ADDRESSES=127.0.0.1:3000,127.0.0.1:3001
    validate_tigerbeetle_configuration
    build_wireguard_parameter_overrides false
    build_sam_parameter_overrides
    joined_overrides=" ${SAM_PARAMETER_OVERRIDES[*]} "
    assert_contains "$joined_overrides" \
        " TigerBeetleClusterId=340282366920938463463374607431768211455 "
    assert_contains "$joined_overrides" \
        " TigerBeetleAddresses=127.0.0.1:3000,127.0.0.1:3001 "

    TIGERBEETLE_CLUSTER_ID=340282366920938463463374607431768211456
    if validation_output="$(validate_tigerbeetle_configuration 2>&1)"; then
        fail_test "out-of-range TigerBeetle cluster ID was accepted"
    fi
    assert_contains "$validation_output" "unsigned 128-bit integer"
    TIGERBEETLE_CLUSTER_ID=0
    TIGERBEETLE_ADDRESSES="127.0.0.1:3000 127.0.0.1:3001"
    if validation_output="$(validate_tigerbeetle_configuration 2>&1)"; then
        fail_test "TigerBeetle addresses containing whitespace were accepted"
    fi
    assert_contains "$validation_output" "must not contain whitespace"
)

test_enabled_stack_detach_plan() (
    aws() {
        case "$*" in
            "cloudformation describe-stacks "*)
                printf 'EnableWireGuardGateway\ttrue\n'
                printf 'VpcId\tvpc-00000001\n'
                printf 'LambdaSubnetId\tsubnet-00000002\n'
                printf 'LambdaRouteTableId\trtb-00000001\n'
                ;;
            *) fail_test "unexpected lifecycle-plan AWS call: $*" ;;
        esac
    }

    ENABLE_WIREGUARD_GATEWAY=0
    VPC_ID=""
    PASETO_PUBLIC_KEY=test-public-key
    plan_wireguard_deployment
    [ "$WIREGUARD_DEPLOYMENT_MODE" = detach-then-cleanup ] ||
        fail_test "enabled stack did not plan detach-then-cleanup"
    [ "$VPC_ID" = vpc-00000001 ] ||
        fail_test "detach phase did not reuse the enabled stack VPC"
    [ "$LAMBDA_ROUTE_TABLE_ID" = rtb-00000001 ] ||
        fail_test "detach phase did not reuse the enabled stack Lambda route table"
    [ "$WIREGUARD_CLEANUP_VPC_ID" = vpc-00000001 ] ||
        fail_test "detach plan did not preserve the stack VPC"
    [ "$WIREGUARD_CLEANUP_LAMBDA_SUBNET_ID" = subnet-00000002 ] ||
        fail_test "detach plan did not preserve the stack Lambda subnet"
    [ "$WIREGUARD_CLEANUP_ROUTE_TABLE_ID" = rtb-00000001 ] ||
        fail_test "detach plan did not preserve the stack Lambda route table"

    build_wireguard_parameter_overrides true
    build_sam_parameter_overrides
    joined_overrides=" ${SAM_PARAMETER_OVERRIDES[*]} "
    assert_contains "$joined_overrides" " EnableWireGuardGateway=false "
    assert_contains "$joined_overrides" " RetainExecutionVpcCleanupResources=true "
    assert_contains "$joined_overrides" " VpcId=vpc-00000001 "
    assert_contains "$joined_overrides" " LambdaRouteTableId=rtb-00000001 "
)

test_topology_change_selection() (
    WIREGUARD_PRIOR_GATEWAY_ENABLED=true
    WIREGUARD_CLEANUP_VPC_ID=vpc-00000001
    WIREGUARD_CLEANUP_LAMBDA_SUBNET_ID=subnet-00000002
    WIREGUARD_CLEANUP_ROUTE_TABLE_ID=rtb-00000001

    VPC_ID=vpc-00000001
    LAMBDA_SUBNET_ID=subnet-00000002
    LAMBDA_ROUTE_TABLE_ID=rtb-00000001
    WIREGUARD_DEPLOYMENT_MODE=enabled
    plan_wireguard_topology_change
    [ "$WIREGUARD_DEPLOYMENT_MODE" = enabled ] ||
        fail_test "same-topology reconfiguration did not remain idempotent"

    VPC_ID=vpc-00000009
    WIREGUARD_DEPLOYMENT_MODE=enabled
    plan_wireguard_topology_change
    [ "$WIREGUARD_DEPLOYMENT_MODE" = detach-then-reconfigure ] ||
        fail_test "VPC change did not select guarded reconfiguration"

    VPC_ID=vpc-00000001
    LAMBDA_SUBNET_ID=subnet-00000009
    WIREGUARD_DEPLOYMENT_MODE=enabled
    plan_wireguard_topology_change
    [ "$WIREGUARD_DEPLOYMENT_MODE" = detach-then-reconfigure ] ||
        fail_test "Lambda subnet change did not select guarded reconfiguration"

    LAMBDA_SUBNET_ID=subnet-00000002
    LAMBDA_ROUTE_TABLE_ID=rtb-00000009
    WIREGUARD_DEPLOYMENT_MODE=enabled
    plan_wireguard_topology_change
    [ "$WIREGUARD_DEPLOYMENT_MODE" = detach-then-reconfigure ] ||
        fail_test "route-table change did not select guarded reconfiguration"
)

test_stack_owned_ipv6_egress_cleanup_condition() {
    local parameter_rules role_template security_group_template
    local eigw_template route_template cleanup_condition

    parameter_rules="$(sed -n \
        '/^Parameters:/,/^Conditions:/p' \
        "$REPOSITORY_ROOT/template.yaml")"
    assert_not_contains "$parameter_rules" "EgressOnlyInternetGatewayId"

    eigw_template="$(sed -n \
        '/^  ExecutionEgressOnlyInternetGateway:/,/^  ExecutionSqsIpv6Route:/p' \
        "$REPOSITORY_ROOT/template.yaml")"
    assert_contains "$eigw_template" \
        "Type: AWS::EC2::EgressOnlyInternetGateway"
    assert_contains "$eigw_template" \
        "Condition: ExecutionVpcCleanupResourcesRetained"
    assert_contains "$eigw_template" "DeletionPolicy: Delete"
    assert_contains "$eigw_template" "UpdateReplacePolicy: Delete"
    assert_contains "$eigw_template" "VpcId: !Ref VpcId"

    security_group_template="$(sed -n \
        '/^  ExecutionLambdaSecurityGroup:/,/^  ExecutionEgressOnlyInternetGateway:/p' \
        "$REPOSITORY_ROOT/template.yaml")"
    assert_contains "$security_group_template" \
        "Condition: ExecutionVpcCleanupResourcesRetained"

    route_template="$(sed -n \
        '/^  ExecutionSqsIpv6Route:/,/^  WireGuardGatewaySecurityGroup:/p' \
        "$REPOSITORY_ROOT/template.yaml")"
    assert_contains "$route_template" "Type: AWS::EC2::Route"
    assert_contains "$route_template" \
        "Condition: ExecutionVpcCleanupResourcesRetained"
    assert_contains "$route_template" "DeletionPolicy: Delete"
    assert_contains "$route_template" "UpdateReplacePolicy: Delete"
    assert_contains "$route_template" "RouteTableId: !Ref LambdaRouteTableId"
    assert_contains "$route_template" 'DestinationIpv6CidrBlock: "::/0"'
    assert_contains "$route_template" \
        "EgressOnlyInternetGatewayId: !Ref ExecutionEgressOnlyInternetGateway"

    cleanup_condition="$(sed -n \
        '/^  ExecutionVpcCleanupResourcesRetained:/,/^Resources:/p' \
        "$REPOSITORY_ROOT/template.yaml")"
    assert_contains "$cleanup_condition" "!Condition WireGuardGatewayEnabled"
    assert_contains "$cleanup_condition" \
        '!Equals [!Ref RetainExecutionVpcCleanupResources, "true"]'

    role_template="$(sed -n \
        '/^  ExecutionFunctionRole:/,/^  ExecutionFunction:/p' \
        "$REPOSITORY_ROOT/template.yaml")"
    assert_contains "$role_template" "ExecutionVpcCleanupResourcesRetained"
    assert_contains "$role_template" "ec2:CreateNetworkInterface"
    assert_contains "$role_template" "ec2:DeleteNetworkInterface"
}

MOCK_CONFIGURED_VERSION_COUNT=0
MOCK_ENI_COUNT=0
MOCK_AWS_ERROR=0
MOCK_FUNCTION_VPC_ATTACHED=0
aws() {
    case "$*" in
        "lambda get-function-configuration "*)
            [ "$MOCK_AWS_ERROR" -eq 0 ] || return 255
            if [ "$MOCK_FUNCTION_VPC_ATTACHED" -eq 1 ]; then
                printf 'Active\tSuccessful\t12\t1\t1\n'
            else
                printf 'Active\tSuccessful\t0\t0\t0\n'
            fi
            ;;
        "lambda list-versions-by-function "*)
            printf '%s\n' "$MOCK_CONFIGURED_VERSION_COUNT"
            ;;
        "cloudformation describe-stack-resource "*)
            printf '%s\n' sg-00000001
            ;;
        "ec2 describe-network-interfaces "*)
            assert_contains "$*" "Name=group-id,Values=sg-00000001"
            assert_contains "$*" "Name=interface-type,Values=lambda"
            printf '%s\n' "$MOCK_ENI_COUNT"
            ;;
        *) fail_test "unexpected cleanup AWS call: $*" ;;
    esac
}

test_cleanup_readiness() {
    MOCK_FUNCTION_VPC_ATTACHED=1
    MOCK_CONFIGURED_VERSION_COUNT=0
    MOCK_ENI_COUNT=0
    if execution_vpc_cleanup_ready; then
        fail_test "cleanup became ready while the function retained VPC configuration"
    fi

    MOCK_FUNCTION_VPC_ATTACHED=0
    MOCK_CONFIGURED_VERSION_COUNT=1
    MOCK_ENI_COUNT=0
    if execution_vpc_cleanup_ready; then
        fail_test "cleanup became ready while a Lambda version retained VPC configuration"
    fi

    MOCK_CONFIGURED_VERSION_COUNT=0
    MOCK_ENI_COUNT=1
    if execution_vpc_cleanup_ready; then
        fail_test "cleanup became ready while an ENI retained the security group"
    fi

    MOCK_CONFIGURED_VERSION_COUNT=0
    MOCK_ENI_COUNT=0
    execution_vpc_cleanup_ready ||
        fail_test "cleanup was not ready after Lambda versions detached and ENIs reached zero"
}

deploy_stack_phase() {
    local phase_description="$1"
    local joined_overrides=" ${DEPLOYMENT_PARAMETER_OVERRIDES[*]} "
    local call_name reset_override reset_file reset_contents

    case "$phase_description" in
        "Detaching execution Lambda from the VPC")
            call_name=retained
            assert_contains "$joined_overrides" " EnableWireGuardGateway=false "
            assert_contains "$joined_overrides" \
                " RetainExecutionVpcCleanupResources=true "
            assert_contains "$joined_overrides" \
                " VpcId=$WIREGUARD_CLEANUP_VPC_ID "
            assert_contains "$joined_overrides" \
                " LambdaRouteTableId=$WIREGUARD_CLEANUP_ROUTE_TABLE_ID "
            ;;
        "Removing retained VPC cleanup resources")
            call_name=cleanup
            assert_contains "$joined_overrides" " EnableWireGuardGateway=false "
            assert_contains "$joined_overrides" \
                " RetainExecutionVpcCleanupResources=false "
            assert_contains "$joined_overrides" \
                " VpcId=$WIREGUARD_CLEANUP_VPC_ID "
            assert_contains "$joined_overrides" \
                " LambdaRouteTableId=$WIREGUARD_CLEANUP_ROUTE_TABLE_ID "
            ;;
        "Clearing saved WireGuard inputs")
            call_name=reset
            assert_contains "$joined_overrides" " EnableWireGuardGateway=false "
            assert_contains "$joined_overrides" \
                " RetainExecutionVpcCleanupResources=false "
            for reset_override in "${DEPLOYMENT_PARAMETER_OVERRIDES[@]}"; do
                case "$reset_override" in
                    file://*) reset_file="${reset_override#file://}" ;;
                esac
            done
            [ -n "$reset_file" ] && [ -f "$reset_file" ] ||
                fail_test "parameter reset deploy omitted its reset file"
            reset_contents="$(<"$reset_file")"
            assert_contains "$reset_contents" "VpcId:"
            assert_contains "$reset_contents" "GatewayPublicSubnetId:"
            assert_contains "$reset_contents" "LambdaSubnetId:"
            assert_contains "$reset_contents" "LambdaRouteTableId:"
            assert_contains "$reset_contents" "WireGuardPrivateKeyParameterName:"
            assert_contains "$reset_contents" "WireGuardGatewayPublicKey:"
            assert_contains "$reset_contents" "WireGuardWorkstationPublicKey:"
            ;;
        "Deploying reconfigured WireGuard stack")
            call_name=enabled
            assert_contains "$joined_overrides" " EnableWireGuardGateway=true "
            assert_contains "$joined_overrides" \
                " RetainExecutionVpcCleanupResources=false "
            assert_contains "$joined_overrides" " VpcId=$VPC_ID "
            assert_contains "$joined_overrides" \
                " LambdaRouteTableId=$LAMBDA_ROUTE_TABLE_ID "
            assert_not_contains "$joined_overrides" "EgressOnlyInternetGatewayId="
            ;;
        *) fail_test "unexpected mocked deploy phase: $phase_description" ;;
    esac
    printf 'deploy:%s\n' "$call_name" >>"$MOCK_CALL_LOG"
    [ "${MOCK_DEPLOY_FAILURE_PHASE:-}" != "$call_name" ]
}

set_mock_cleanup_topology() {
    WIREGUARD_CLEANUP_VPC_ID=vpc-00000001
    WIREGUARD_CLEANUP_LAMBDA_SUBNET_ID=subnet-00000002
    WIREGUARD_CLEANUP_ROUTE_TABLE_ID=rtb-00000001
}

preflight_wireguard_gateway() {
    printf 'preflight:target\n' >>"$MOCK_CALL_LOG"
}

test_cleanup_refuses_blocking_eni() {
    : >"$MOCK_CALL_LOG"
    set_mock_cleanup_topology
    MOCK_CONFIGURED_VERSION_COUNT=0
    MOCK_ENI_COUNT=1

    if cleanup_output="$(
        VPC_CLEANUP_MAX_ATTEMPTS=1 \
            VPC_CLEANUP_POLL_SECONDS=0 \
            run_wireguard_deployment resume-cleanup 2>&1
    )"; then
        fail_test "cleanup phase unexpectedly started while an ENI remained"
    fi
    assert_contains "$cleanup_output" "did not finish"
    [ ! -s "$MOCK_CALL_LOG" ] ||
        fail_test "cleanup deploy ran while an ENI retained the security group"
}

test_detach_timeout_keeps_retained_resources() {
    : >"$MOCK_CALL_LOG"
    set_mock_cleanup_topology
    MOCK_CONFIGURED_VERSION_COUNT=0
    MOCK_ENI_COUNT=1

    if cleanup_output="$(
        VPC_CLEANUP_MAX_ATTEMPTS=1 \
            VPC_CLEANUP_POLL_SECONDS=0 \
            run_wireguard_deployment detach-then-cleanup 2>&1
    )"; then
        fail_test "detach cleanup unexpectedly completed while an ENI remained"
    fi
    assert_contains "$cleanup_output" "retained EIGW"
    actual_calls="$(<"$MOCK_CALL_LOG")"
    [ "$actual_calls" = deploy:retained ] ||
        fail_test "timeout did not stop after retained detach: $actual_calls"
}

test_cleanup_aws_error_keeps_retained_resources() {
    : >"$MOCK_CALL_LOG"
    set_mock_cleanup_topology
    MOCK_AWS_ERROR=1
    MOCK_ENI_COUNT=0

    if cleanup_output="$(
        VPC_CLEANUP_MAX_ATTEMPTS=1 \
            VPC_CLEANUP_POLL_SECONDS=0 \
            run_wireguard_deployment detach-then-cleanup 2>&1
    )"; then
        fail_test "detach cleanup ignored an AWS inspection error"
    fi
    assert_contains "$cleanup_output" "could not verify execution Lambda VPC cleanup"
    actual_calls="$(<"$MOCK_CALL_LOG")"
    [ "$actual_calls" = deploy:retained ] ||
        fail_test "AWS error did not leave the retained detach in place: $actual_calls"
    MOCK_AWS_ERROR=0
}

test_cleanup_failure_does_not_clear_parameters() {
    : >"$MOCK_CALL_LOG"
    set_mock_cleanup_topology
    MOCK_CONFIGURED_VERSION_COUNT=0
    MOCK_ENI_COUNT=0
    MOCK_DEPLOY_FAILURE_PHASE=cleanup

    if VPC_CLEANUP_MAX_ATTEMPTS=1 \
        VPC_CLEANUP_POLL_SECONDS=0 \
        run_wireguard_deployment resume-cleanup >/dev/null 2>&1
    then
        fail_test "failed resource cleanup unexpectedly reported success"
    fi
    actual_calls="$(<"$MOCK_CALL_LOG")"
    [ "$actual_calls" = deploy:cleanup ] ||
        fail_test "saved inputs were cleared after failed cleanup: $actual_calls"
    MOCK_DEPLOY_FAILURE_PHASE=""
}

test_detach_precedes_cleanup() {
    : >"$MOCK_CALL_LOG"
    set_mock_cleanup_topology
    MOCK_CONFIGURED_VERSION_COUNT=0
    MOCK_ENI_COUNT=0

    VPC_CLEANUP_MAX_ATTEMPTS=1 \
        VPC_CLEANUP_POLL_SECONDS=0 \
        run_wireguard_deployment detach-then-cleanup >/dev/null

    expected_calls=$'deploy:retained\ndeploy:cleanup\ndeploy:reset'
    actual_calls="$(<"$MOCK_CALL_LOG")"
    [ "$actual_calls" = "$expected_calls" ] ||
        fail_test "detach and cleanup phases ran in the wrong order: $actual_calls"
    wireguard_cleanup
}

test_reconfiguration_uses_guarded_cleanup() {
    : >"$MOCK_CALL_LOG"
    set_mock_cleanup_topology
    MOCK_CONFIGURED_VERSION_COUNT=0
    MOCK_ENI_COUNT=0
    ENABLE_WIREGUARD_GATEWAY=1
    VPC_ID=vpc-00000009
    GATEWAY_PUBLIC_SUBNET_ID=subnet-00000008
    LAMBDA_SUBNET_ID=subnet-00000009
    LAMBDA_ROUTE_TABLE_ID=rtb-00000009
    LAMBDA_SUBNET_CIDR=172.31.9.0/24
    WIREGUARD_PRIVATE_KEY_PARAMETER_NAME=/applications/example/wireguard/gateway-private-key
    WIREGUARD_PRIVATE_KEY_PARAMETER_VERSION=1
    WIREGUARD_GATEWAY_PUBLIC_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
    WIREGUARD_WORKSTATION_PUBLIC_KEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
    WIREGUARD_INSTANCE_TYPE=t4g.nano

    VPC_CLEANUP_MAX_ATTEMPTS=1 \
        VPC_CLEANUP_POLL_SECONDS=0 \
        run_wireguard_deployment detach-then-reconfigure >/dev/null

    expected_calls=$'deploy:retained\ndeploy:cleanup\ndeploy:reset\npreflight:target\ndeploy:enabled'
    actual_calls="$(<"$MOCK_CALL_LOG")"
    [ "$actual_calls" = "$expected_calls" ] ||
        fail_test "reconfiguration bypassed guarded cleanup: $actual_calls"
    wireguard_cleanup
}

test_helper_has_no_obsolete_endpoint_or_direct_ipv6_lifecycle() {
    local helper_source

    helper_source="$(<"$REPOSITORY_ROOT/wireguard-gateway-setup.sh")"
    assert_not_contains "$helper_source" "ExecutionDynamoDBGatewayEndpoint"
    assert_not_contains "$helper_source" "ExecutionSqsInterfaceEndpoint"
    assert_not_contains "$helper_source" "describe-vpc-endpoints"
    assert_not_contains "$helper_source" "create-egress-only-internet-gateway"
    assert_not_contains "$helper_source" "delete-egress-only-internet-gateway"
    assert_not_contains "$helper_source" "associate-vpc-cidr-block"
    assert_not_contains "$helper_source" "disassociate-vpc-cidr-block"
    assert_not_contains "$helper_source" "associate-subnet-cidr-block"
    assert_not_contains "$helper_source" "disassociate-subnet-cidr-block"
}

test_steady_disabled_deployment_clears_saved_inputs() {
    : >"$MOCK_CALL_LOG"
    WIREGUARD_PARAMETER_RESET_FILE=""

    run_wireguard_deployment disabled >/dev/null

    actual_calls="$(<"$MOCK_CALL_LOG")"
    [ "$actual_calls" = deploy:reset ] ||
        fail_test "steady disabled deployment did not clear saved inputs: $actual_calls"
    wireguard_cleanup
}

test_fresh_sso_login
test_in_progress_stack_guard
test_cloudformation_outcome_reporting
test_phase_selection
test_tigerbeetle_configuration
test_enabled_stack_detach_plan
test_topology_change_selection
test_stack_owned_ipv6_egress_cleanup_condition
test_cleanup_readiness
test_cleanup_refuses_blocking_eni
test_detach_timeout_keeps_retained_resources
test_cleanup_aws_error_keeps_retained_resources
test_cleanup_failure_does_not_clear_parameters
test_detach_precedes_cleanup
test_reconfiguration_uses_guarded_cleanup
test_helper_has_no_obsolete_endpoint_or_direct_ipv6_lifecycle
test_steady_disabled_deployment_clears_saved_inputs

printf 'PASS: deploy cleanup lifecycle regression tests\n'
