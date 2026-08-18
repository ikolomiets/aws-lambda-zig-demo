#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../deploy.sh
source "$REPOSITORY_ROOT/deploy.sh"

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

test_refreshable_profile_credentials() (
    aws() {
        case "$*" in
            "sts get-caller-identity --profile dev "*) return 0 ;;
            "sts get-caller-identity --query Arn --output text") return 0 ;;
            "configure export-credentials "*)
                printf '%s\n' 'export AWS_ACCESS_KEY_ID=finite-snapshot'
                printf '%s\n' 'export AWS_SECRET_ACCESS_KEY=finite-secret'
                printf '%s\n' 'export AWS_SESSION_TOKEN=finite-session'
                printf '%s\n' 'export AWS_CREDENTIAL_EXPIRATION=2000-01-01T00:00:00Z'
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

    prepare_aws_credentials dev

    [ "${AWS_PROFILE:-}" = dev ] ||
        fail_test "deployment did not select the refreshable dev profile"
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

test_enabled_stack_detach_plan() (
    aws() {
        case "$*" in
            "cloudformation describe-stacks "*)
                printf 'EnableWireGuardGateway\ttrue\n'
                printf 'VpcId\tvpc-00000001\n'
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

    build_sam_parameter_overrides true
    joined_overrides=" ${SAM_PARAMETER_OVERRIDES[*]} "
    assert_contains "$joined_overrides" " EnableWireGuardGateway=false "
    assert_contains "$joined_overrides" " RetainExecutionVpcCleanupResources=true "
    assert_contains "$joined_overrides" " VpcId=vpc-00000001 "
)

MOCK_CONFIGURED_VERSION_COUNT=0
MOCK_ENI_COUNT=0
aws() {
    case "$*" in
        "lambda get-function-configuration "*)
            printf 'Active\tSuccessful\t0\t0\t0\n'
            ;;
        "lambda list-versions-by-function "*)
            printf '%s\n' "$MOCK_CONFIGURED_VERSION_COUNT"
            ;;
        "cloudformation describe-stack-resource "*)
            printf '%s\n' sg-00000001
            ;;
        "ec2 describe-network-interfaces "*)
            printf '%s\n' "$MOCK_ENI_COUNT"
            ;;
        *) fail_test "unexpected cleanup AWS call: $*" ;;
    esac
}

test_cleanup_readiness() {
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
    printf 'deploy:%s\n' "$1" >>"$MOCK_CALL_LOG"
}

test_cleanup_refuses_blocking_eni() {
    : >"$MOCK_CALL_LOG"
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

test_detach_precedes_cleanup() {
    : >"$MOCK_CALL_LOG"
    MOCK_CONFIGURED_VERSION_COUNT=0
    MOCK_ENI_COUNT=0

    VPC_CLEANUP_MAX_ATTEMPTS=1 \
        VPC_CLEANUP_POLL_SECONDS=0 \
        run_wireguard_deployment detach-then-cleanup >/dev/null

    expected_calls=$'deploy:true\ndeploy:false'
    actual_calls="$(<"$MOCK_CALL_LOG")"
    [ "$actual_calls" = "$expected_calls" ] ||
        fail_test "detach and cleanup phases ran in the wrong order: $actual_calls"
}

test_refreshable_profile_credentials
test_in_progress_stack_guard
test_cloudformation_outcome_reporting
test_phase_selection
test_enabled_stack_detach_plan
test_cleanup_readiness
test_cleanup_refuses_blocking_eni
test_detach_precedes_cleanup

printf 'PASS: deploy cleanup lifecycle regression tests\n'
