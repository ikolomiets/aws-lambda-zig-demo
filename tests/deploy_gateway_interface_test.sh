#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../wireguard-gateway-setup.sh
source "$REPOSITORY_ROOT/wireguard-gateway-setup.sh"

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
        *"$unexpected"*) fail_test "output contained unexpected value: $unexpected" ;;
        *) ;;
    esac
}

joined_overrides() {
    local joined=" ${DEPLOYMENT_PARAMETER_OVERRIDES[*]} "

    printf '%s\n' "$joined"
}

test_source_guards() {
    local source_output

    source_output="$(bash -c \
        'source "$1/deploy.sh"; source "$1/wireguard-gateway-setup.sh"' \
        bash "$REPOSITORY_ROOT" 2>&1)" ||
        fail_test "deployment helpers could not be sourced safely"
    [ -z "$source_output" ] ||
        fail_test "sourcing deployment helpers produced output: $source_output"
}

test_setup_action_parsing() (
    WIREGUARD_INSTANCE_TYPE=t4g.nano
    WIREGUARD_ACTION=enable
    parse_wireguard_options --stack-name example --wireguard-instance-type t4g.small
    [ "$WIREGUARD_ACTION" = enable ] ||
        fail_test "setup did not select implicit enablement"
    [ "$WIREGUARD_INSTANCE_TYPE" = t4g.small ] ||
        fail_test "CLI gateway input did not override the environment value"
    [ " ${COMMON_DEPLOYMENT_ARGS[*]} " = " --stack-name example " ] ||
        fail_test "setup did not pass common options through the runner seam"

    parse_wireguard_options --disable --region us-east-1
    [ "$WIREGUARD_ACTION" = disable ] ||
        fail_test "setup did not select explicit disablement"
    [ " ${COMMON_DEPLOYMENT_ARGS[*]} " = " --region us-east-1 " ] ||
        fail_test "setup did not pass disablement's common options through"

    WIREGUARD_ENABLE_ENV_SUPPLIED=1
    WIREGUARD_ACTION_EXPLICIT=0
    ENABLE_WIREGUARD_GATEWAY=0
    WIREGUARD_ACTION=enable
    apply_wireguard_action
    [ "$WIREGUARD_ACTION" = disable ] && [ "$ENABLE_WIREGUARD_GATEWAY" -eq 0 ] ||
        fail_test "legacy ENABLE_WIREGUARD_GATEWAY=0 did not select teardown"

    WIREGUARD_ACTION_EXPLICIT=1
    WIREGUARD_ACTION=enable
    apply_wireguard_action
    [ "$ENABLE_WIREGUARD_GATEWAY" -eq 1 ] ||
        fail_test "explicit enablement did not override the legacy environment action"
)

test_enabled_stack_fills_only_unspecified_values() (
    aws() {
        printf 'EnableWireGuardGateway\ttrue\n'
        printf 'VpcId\tvpc-00000009\n'
        printf 'GatewayPublicSubnetId\tsubnet-00000009\n'
        printf 'LambdaSubnetId\tsubnet-00000002\n'
        printf 'LambdaRouteTableId\trtb-00000002\n'
        printf 'LambdaSubnetCidr\t172.31.1.0/24\n'
        printf 'WireGuardPrivateKeyParameterName\t/applications/example/wireguard/gateway-private-key\n'
        printf 'WireGuardPrivateKeyParameterVersion\t7\n'
        printf 'WireGuardGatewayPublicKey\tAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n'
        printf 'WireGuardWorkstationPublicKey\tBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=\n'
        printf 'WireGuardInstanceType\tt4g.nano\n'
    }

    VPC_ID=vpc-00000001
    GATEWAY_PUBLIC_SUBNET_ID=subnet-00000001
    LAMBDA_SUBNET_ID=""
    load_prior_wireguard_configuration >/dev/null
    [ "$VPC_ID" = vpc-00000001 ] ||
        fail_test "enabled-stack reuse overrode a supplied VPC"
    [ "$GATEWAY_PUBLIC_SUBNET_ID" = subnet-00000001 ] ||
        fail_test "enabled-stack reuse overrode a supplied gateway subnet"
    [ "$LAMBDA_SUBNET_ID" = subnet-00000002 ] ||
        fail_test "enabled-stack reuse did not fill an unspecified Lambda subnet"
)

mock_preserved_stack() {
    local enabled="$1"

    printf 'EnableWireGuardGateway|%s\t' "$enabled"
    printf 'RetainExecutionVpcCleanupResources|false\t'
    printf 'VpcId|vpc-00000001\t'
    printf 'GatewayPublicSubnetId|subnet-00000001\t'
    printf 'LambdaSubnetId|subnet-00000002\t'
    printf 'LambdaRouteTableId|rtb-00000002\t'
    printf 'LambdaSubnetCidr|172.31.1.0/24\t'
    printf 'WireGuardPrivateKeyParameterName|/applications/example/wireguard/gateway-private-key\t'
    printf 'WireGuardPrivateKeyParameterVersion|7\t'
    printf 'WireGuardGatewayPublicKey|AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\t'
    printf 'WireGuardWorkstationPublicKey|BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=\t'
    printf 'WireGuardAmiId|/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64\t'
    printf 'WireGuardInstanceType|t4g.nano\n'
}

test_ordinary_deployment_preserves_gateway_state() (
    aws() {
        mock_preserved_stack "$MOCK_ENABLED"
    }

    for MOCK_ENABLED in true false; do
        load_preserved_wireguard_parameters
        overrides="$(joined_overrides)"
        assert_contains "$overrides" " EnableWireGuardGateway=$MOCK_ENABLED "
        assert_contains "$overrides" " RetainExecutionVpcCleanupResources=false "
        assert_contains "$overrides" " VpcId=vpc-00000001 "
        assert_contains "$overrides" " GatewayPublicSubnetId=subnet-00000001 "
        assert_contains "$overrides" " LambdaSubnetId=subnet-00000002 "
        assert_contains "$overrides" " LambdaRouteTableId=rtb-00000002 "
        assert_contains "$overrides" " LambdaSubnetCidr=172.31.1.0/24 "
        assert_contains "$overrides" " WireGuardPrivateKeyParameterVersion=7 "
        assert_contains "$overrides" " WireGuardInstanceType=t4g.nano "
        [ "${#DEPLOYMENT_PARAMETER_OVERRIDES[@]}" -eq 13 ] ||
            fail_test "ordinary deployment did not preserve all 13 gateway parameters"
    done
)

test_new_stack_defaults_disabled() (
    aws() {
        printf 'ValidationError: Stack with id example does not exist\n' >&2
        return 255
    }

    load_preserved_wireguard_parameters
    overrides="$(joined_overrides)"
    assert_contains "$overrides" " EnableWireGuardGateway=false "
    assert_contains "$overrides" " RetainExecutionVpcCleanupResources=false "
    [ "${#DEPLOYMENT_PARAMETER_OVERRIDES[@]}" -eq 2 ] ||
        fail_test "new stack received unexpected gateway parameters"
)

test_ordinary_deployment_rejects_transition() (
    aws() {
        printf 'EnableWireGuardGateway|false\n'
        printf 'RetainExecutionVpcCleanupResources|true\n'
        printf 'VpcId|vpc-00000001\n'
        printf 'LambdaRouteTableId|rtb-00000002\n'
    }

    if transition_output="$(load_preserved_wireguard_parameters 2>&1)"; then
        fail_test "ordinary deployment accepted retained cleanup state"
    fi
    assert_contains "$transition_output" "wireguard-gateway-setup.sh --disable"
)

test_deploy_gateway_configuration_boundary() {
    local legacy_output

    if legacy_output="$(
        cd "$REPOSITORY_ROOT"
        ./deploy.sh --enable-wireguard-gateway 2>&1
    )"; then
        fail_test "deploy.sh accepted a legacy gateway option"
    fi
    assert_contains "$legacy_output" "no longer accepted by deploy.sh"
    assert_contains "$legacy_output" "wireguard-gateway-setup.sh"

    if legacy_output="$(
        cd "$REPOSITORY_ROOT"
        TIGERBEETLE_CLUSTER_ID=invalid \
        WIREGUARD_WORKSTATION_PUBLIC_KEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB= \
            bash -c 'source ./deploy.sh; validate_tigerbeetle_configuration' 2>&1
    )"; then
        fail_test "sourced deploy.sh accepted an invalid TigerBeetle cluster ID"
    fi
    assert_contains "$legacy_output" "TIGERBEETLE_CLUSTER_ID must be an unsigned decimal integer"
    assert_not_contains "$legacy_output" "WIREGUARD_WORKSTATION_PUBLIC_KEY"
}

mock_peer_outputs() {
    case "$*" in
        *"Outputs"*)
            printf 'WireGuardGatewayElasticIp|203.0.113.42\t'
            printf 'WireGuardGatewayEndpoint|203.0.113.42:51820\t'
            printf 'WireGuardGatewayPublicKey|AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\t'
            printf 'WireGuardWorkstationAddress|10.200.0.2/24\t'
            printf 'TigerBeetleEndpoint|10.200.0.2:3000\n'
            ;;
        *"LambdaSubnetCidr"*) printf '172.31.1.0/24\n' ;;
        *) fail_test "unexpected peer-output AWS call: $*" ;;
    esac
}

test_exact_peer_configuration() (
    local output configuration expected secret_sentinel

    secret_sentinel='PRIVATE-SSM-OR-PEER-KEY-MUST-NOT-LEAK'
    WIREGUARD_PRIVATE_KEY_PARAMETER_NAME="$secret_sentinel"
    WIREGUARD_WORKSTATION_PUBLIC_KEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
    aws() {
        mock_peer_outputs "$@"
    }

    output="$(print_wireguard_peer_configuration)" ||
        fail_test "valid peer configuration was not printed"
    assert_contains "$output" "WireGuardGatewayElasticIp: 203.0.113.42"
    assert_contains "$output" "WireGuardGatewayEndpoint: 203.0.113.42:51820"
    assert_contains "$output" \
        "WireGuardGatewayPublicKey: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    assert_not_contains "$output" $'\t'
    configuration="$(sed -n \
        '/^-----BEGIN WIREGUARD PEER CONFIGURATION-----$/,/^-----END WIREGUARD PEER CONFIGURATION-----$/p' \
        <<<"$output")"
    expected='-----BEGIN WIREGUARD PEER CONFIGURATION-----
[Interface]
Address = 10.200.0.2/24
PrivateKey = <wireguard-peer-private-key>

[Peer]
PublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Endpoint = 203.0.113.42:51820
AllowedIPs = 172.31.1.0/24
PersistentKeepalive = 25
-----END WIREGUARD PEER CONFIGURATION-----'
    [ "$configuration" = "$expected" ] ||
        fail_test "peer configuration did not match the copy-ready contract"
    assert_contains "$output" \
        "Replace <wireguard-peer-private-key> with the private key matching the supplied WireGuardWorkstationPublicKey."
    assert_not_contains "$output" "$secret_sentinel"
    assert_not_contains "$output" "$WIREGUARD_WORKSTATION_PUBLIC_KEY"
    assert_not_contains "$output" "AllowedIPs = 10.200.0.0/24"
)

test_peer_configuration_omission() (
    aws() {
        case "$*" in
            *"Outputs"*)
                printf 'WireGuardGatewayPublicKey|AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n'
                printf 'WireGuardWorkstationAddress|10.200.0.2/24\n'
                ;;
            *"LambdaSubnetCidr"*) printf '172.31.1.0/24\n' ;;
        esac
    }

    if failure_output="$(print_wireguard_peer_configuration 2>&1)"; then
        fail_test "missing endpoint unexpectedly produced a peer configuration"
    fi
    assert_not_contains "$failure_output" "BEGIN WIREGUARD PEER CONFIGURATION"

    WIREGUARD_DEPLOYMENT_MODE=disabled
    disable_output="$(wireguard_gateway_controller outputs)"
    [ -z "$disable_output" ] ||
        fail_test "disablement printed a peer configuration"

    DRY_RUN=1
    ENABLE_WIREGUARD_GATEWAY=1
    dry_run_output="$(wireguard_gateway_controller plan)"
    assert_contains "$dry_run_output" "Deferred WireGuard gateway AWS discovery"
    assert_not_contains "$dry_run_output" "BEGIN WIREGUARD PEER CONFIGURATION"
)

test_failed_deployment_omits_peer_configuration() (
    failing_controller() {
        case "$1" in
            deploy) return 29 ;;
            outputs) printf '%s\n' '-----BEGIN WIREGUARD PEER CONFIGURATION-----' ;;
        esac
    }
    report_cloudformation_outcome() {
        printf 'reported deployment failure\n'
    }

    DEPLOYMENT_CONTROLLER=failing_controller
    if failure_output="$(deploy_stack_and_resolve_controller_outputs 2>&1)"; then
        fail_test "failing deployment unexpectedly succeeded"
    fi
    assert_contains "$failure_output" "reported deployment failure"
    assert_not_contains "$failure_output" "BEGIN WIREGUARD PEER CONFIGURATION"
)

test_source_guards
test_setup_action_parsing
test_enabled_stack_fills_only_unspecified_values
test_ordinary_deployment_preserves_gateway_state
test_new_stack_defaults_disabled
test_ordinary_deployment_rejects_transition
test_deploy_gateway_configuration_boundary
test_exact_peer_configuration
test_peer_configuration_omission
test_failed_deployment_omits_peer_configuration

printf 'PASS: deployment gateway interface regression tests\n'
