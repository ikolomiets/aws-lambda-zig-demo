#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/deploy-owned-cleanup-test.XXXXXX")"
trap 'rm -rf -- "$TEST_TMP_DIR"' EXIT
mkdir -p "$TEST_TMP_DIR/bin"
cp "$REPOSITORY_ROOT/deploy.sh" "$TEST_TMP_DIR/deploy.sh"
cp "$REPOSITORY_ROOT/wireguard-gateway-setup.sh" "$TEST_TMP_DIR/wireguard-gateway-setup.sh"
export MOCK_CALL_LOG="$TEST_TMP_DIR/calls" MOCK_STATE="$TEST_TMP_DIR/state"
export PATH="$TEST_TMP_DIR/bin:$PATH"

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

cat >"$TEST_TMP_DIR/bin/aws" <<'MOCK'
#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

args = sys.argv[1:]
with open(os.environ['MOCK_CALL_LOG'], 'a') as log:
    log.write(' '.join(args) + '\n')
state_path = Path(os.environ['MOCK_STATE'])
state = json.loads(state_path.read_text())
command = ' '.join(args[:2])
stack_id = 'arn:aws:cloudformation:ca-central-1:example:stack/cleanup-stack/pinned'

def option(name, default=''):
    return args[args.index(name) + 1] if name in args else default

def save():
    state_path.write_text(json.dumps(state))

def fail(message):
    print(message, file=sys.stderr)
    sys.exit(42)

if os.environ.get('MOCK_FAILURE') == command:
    fail('mock AWS failure')
if command == 'sso login':
    if any(key in os.environ for key in ('AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN')):
        fail('inherited static credentials were not cleared')
elif command == 'cloudformation describe-stacks':
    if state['status'] == 'absent':
        fail('An error occurred (ValidationError) when calling the DescribeStacks operation: Stack with id ' + option('--stack-name') + ' does not exist')
    params = [
        {'ParameterKey': 'EnableWireGuardGateway', 'ParameterValue': state['gateway']},
        {'ParameterKey': 'RetainTigerBeetleProcessorVpcCleanupResources', 'ParameterValue': state['retained']},
        {'ParameterKey': 'VpcId', 'ParameterValue': 'vpc-00000001'},
        {'ParameterKey': 'LambdaSubnetId', 'ParameterValue': 'subnet-00000001'},
        {'ParameterKey': 'LambdaRouteTableId', 'ParameterValue': 'rtb-00000001'},
        {'ParameterKey': 'LedgerCounterId', 'ParameterValue': 'global'},
        {'ParameterKey': 'ExistingLedgerCounterTableName', 'ParameterValue': state['reference']},
        {'ParameterKey': 'PasetoPublicKey', 'ParameterValue': 'deployed-key'},
    ]
    query = option('--query')
    if query == 'Stacks[0].StackStatus':
        print(state['status'])
    elif query == 'Stacks[0].Parameters[].[ParameterKey,ParameterValue]':
        for param in params:
            print(param['ParameterKey'] + '\t' + param['ParameterValue'])
    elif query:
        fail('unexpected stack query: ' + query)
    else:
        print(json.dumps({'Stacks': [{'StackName': 'cleanup-stack', 'StackId': stack_id,
            'StackStatus': state['status'], 'Parameters': params}]}))
elif command == 'cloudformation describe-stack-resource':
    resource = option('--logical-resource-id')
    values = {
        'TigerBeetleProcessor': 'deployed-native-processor',
        'TigerBeetleProcessorSecurityGroup': 'sg-00000001',
        'TigerBeetleProcessorEgressOnlyInternetGateway': 'eigw-00000001\tCREATE_COMPLETE',
        'TigerBeetleProcessorSqsIpv6Route': 'CREATE_COMPLETE',
    }
    if resource not in values:
        fail('unexpected resource: ' + resource)
    print(values[resource])
elif command == 'ec2 describe-egress-only-internet-gateways':
    print('eigw-00000001\tvpc-00000001\tattached\t1')
elif command == 'ec2 describe-route-tables':
    print('eigw-00000001\tactive\tCreateRoute\t::/0')
elif command == 'lambda get-function-configuration':
    if option('--function-name') != 'deployed-native-processor':
        fail('cleanup used configured default instead of deployed function')
    print('Active\tSuccessful\t' + ('12\t1\t1' if os.environ.get('MOCK_FUNCTION_ATTACHED') else '0\t0\t0'))
elif command == 'lambda list-versions-by-function':
    print(os.environ.get('MOCK_VERSIONS', '0'))
elif command == 'ec2 describe-network-interfaces':
    if 'Name=group-id,Values=sg-00000001' not in args or 'Name=interface-type,Values=lambda' not in args:
        fail('incorrect ENI scope')
    state['eni_checks'] += 1
    save()
    mode = os.environ.get('MOCK_ENI_MODE', '')
    print(1 if mode == 'blocked' or (mode == 'delayed' and state['eni_checks'] == 1) else 0)
elif command == 'cloudformation update-stack':
    if option('--stack-name') != stack_id or '--use-previous-template' not in args:
        fail('cleanup did not reuse the pinned deployed template')
    parameters = json.loads(option('--parameters'))
    for parameter in parameters:
        key = parameter['ParameterKey']
        if key not in ('EnableWireGuardGateway', 'RetainTigerBeetleProcessorVpcCleanupResources'):
            if parameter != {'ParameterKey': key, 'UsePreviousValue': True}:
                fail('cleanup changed deployed configuration: ' + key)
    state['gateway'] = next(p['ParameterValue'] for p in parameters if p['ParameterKey'] == 'EnableWireGuardGateway')
    state['retained'] = next(p['ParameterValue'] for p in parameters if p['ParameterKey'] == 'RetainTigerBeetleProcessorVpcCleanupResources')
    if state['retained'] == 'false' and (os.environ.get('MOCK_VERSIONS', '0') != '0' or os.environ.get('MOCK_ENI_MODE') == 'blocked'):
        fail('dependent resources deleted before prerequisites')
    state['status'] = 'UPDATE_IN_PROGRESS'
    save()
elif command == 'cloudformation delete-stack':
    if option('--stack-name') != stack_id or state['gateway'] != 'false' or state['retained'] != 'false':
        fail('stack deleted before prerequisites or without pinned ID')
    state['status'] = 'DELETE_IN_PROGRESS'
    save()
elif command == 'cloudformation wait':
    if option('--stack-name') != stack_id:
        fail('wait did not use pinned stack ID')
    if args[2] == 'stack-update-complete':
        state['status'] = 'UPDATE_COMPLETE'
    elif args[2] == 'stack-delete-complete':
        if os.environ.get('MOCK_DELETE_TIMEOUT'):
            fail('waiter timed out')
        state['status'] = 'DELETE_COMPLETE'
        state['owned_data'] = {}
    else:
        fail('unexpected waiter')
    save()
elif command == 'cloudformation list-stack-resources':
    resources = ['OperationsTable', 'SeatEventsTable']
    if not state['reference']:
        resources += ['LedgerCounterTable']
    print(json.dumps({'StackResourceSummaries': [
        {'LogicalResourceId': name, 'ResourceType': 'AWS::DynamoDB::Table',
         'ResourceStatus': os.environ.get('MOCK_RESOURCE_STATUS', 'DELETE_COMPLETE')}
        for name in resources]}))
else:
    fail('unexpected AWS call: ' + ' '.join(args))
MOCK
chmod +x "$TEST_TMP_DIR/bin/aws"
for command_name in sam zig zip curl; do
    cat >"$TEST_TMP_DIR/bin/$command_name" <<'FORBIDDEN'
#!/usr/bin/env bash
printf 'unexpected build/deployment command: %s\n' "$0 $*" >&2
exit 99
FORBIDDEN
    chmod +x "$TEST_TMP_DIR/bin/$command_name"
done

reset_state() {
    unset MOCK_FAILURE MOCK_VERSIONS MOCK_ENI_MODE MOCK_FUNCTION_ATTACHED MOCK_RESOURCE_STATUS MOCK_DELETE_TIMEOUT
    jq -n --arg status "${1:-UPDATE_COMPLETE}" --arg gateway "${2:-false}" \
        --arg retained "${3:-false}" --arg reference "${4:-}" \
        '{status:$status,gateway:$gateway,retained:$retained,reference:$reference,eni_checks:0,
        owned_data:{operations:["operation"],events:["event"],counters:{global:1200,other:1600}},
        external:{network:"external-vpc",ssm:"external-pair",native_accounts:["capacity","availability"],
        shared_counters:{global:5000,other:6000}}}' >"$MOCK_STATE"
    jq -c .external "$MOCK_STATE" >"$TEST_TMP_DIR/external-before"
    : >"$MOCK_CALL_LOG"
}

run_cleanup() {
    bash "$TEST_TMP_DIR/deploy.sh" --cleanup --stack-name cleanup-stack --profile cleanup-profile --region ca-central-1 "$@"
}

assert_external_preserved() {
    jq -c .external "$MOCK_STATE" >"$TEST_TMP_DIR/external-after"
    cmp "$TEST_TMP_DIR/external-before" "$TEST_TMP_DIR/external-after" || fail_test 'external data changed'
}

reset_state
if ! output="$(run_cleanup 2>&1)"; then
    fail_test "cleanup of a stack without WireGuard failed: $output"
fi
[[ "$output" = *'permanently deletes'* ]] || fail_test 'missing owned-data loss warning'
[[ "$output" = *'Verified deletion'* ]] || fail_test 'missing verified completion'
calls="$(cat "$MOCK_CALL_LOG")"
[[ "$calls" = *'cloudformation delete-stack --stack-name arn:aws:cloudformation:'* ]] ||
    fail_test 'cleanup did not delete the inspected stack ID'
[[ "$calls" = *'cloudformation wait stack-delete-complete'* ]] || fail_test 'cleanup did not wait'
[[ "$calls" != *'execute-change-set'* && "$calls" != *'dynamodb '* && "$calls" != *'ec2 '* ]] ||
    fail_test 'no-WireGuard cleanup mutated unrelated resources'
jq -e '.owned_data == {}' "$MOCK_STATE" >/dev/null || fail_test 'owned data remains'
assert_external_preserved

# The active gateway must detach before the retained network resources disappear.
reset_state UPDATE_COMPLETE true false
export VPC_CLEANUP_MAX_ATTEMPTS=2 VPC_CLEANUP_POLL_SECONDS=0 MOCK_ENI_MODE=delayed
if ! output="$(run_cleanup 2>&1)"; then
    fail_test "active WireGuard cleanup failed: $output"
fi
[[ "$output" = *'Lambda VPC cleanup is complete'* ]] || fail_test 'missing VPC cleanup confirmation'
[ "$(grep -c '^cloudformation update-stack' "$MOCK_CALL_LOG")" -eq 2 ] || fail_test 'wrong WireGuard cleanup phases'
assert_external_preserved

# Published versions, current function attachment, ENI delays, and AWS errors all
# stop before deleting retained resources. Retrying resumes the persisted phase.
for blocker in versions function eni aws; do
    reset_state UPDATE_COMPLETE true false shared-counter-table
    case "$blocker" in
        versions) export MOCK_VERSIONS=1 ;;
        function) export MOCK_FUNCTION_ATTACHED=1 ;;
        eni) export MOCK_ENI_MODE=blocked ;;
        aws) export MOCK_FAILURE='ec2 describe-network-interfaces' ;;
    esac
    if output="$(run_cleanup 2>&1)"; then
        fail_test "$blocker blocker did not stop teardown"
    fi
    [[ "$(cat "$MOCK_CALL_LOG")" != *'cloudformation delete-stack'* ]] || fail_test 'stack deleted with unresolved prerequisites'
    jq -e '.gateway == "false" and .retained == "true" and .owned_data.counters.other == 1600' \
        "$MOCK_STATE" >/dev/null || fail_test 'interruption did not preserve retained state and data'
    unset MOCK_VERSIONS MOCK_FUNCTION_ATTACHED MOCK_ENI_MODE MOCK_FAILURE
    : >"$MOCK_CALL_LOG"
    if ! output="$(run_cleanup 2>&1)"; then
        fail_test "resuming $blocker cleanup failed: $output"
    fi
    [ "$(grep -c '^cloudformation update-stack' "$MOCK_CALL_LOG")" -eq 1 ] || fail_test 'resume repeated detachment'
    assert_external_preserved
done

# An already-retained deployment and DELETE_FAILED both remain resumable.
reset_state UPDATE_COMPLETE false true
run_cleanup >/dev/null
assert_external_preserved
reset_state DELETE_FAILED
run_cleanup >/dev/null
assert_external_preserved

# A waiter timeout leaves deletion in progress; the next run only waits/verifies.
reset_state
export MOCK_DELETE_TIMEOUT=1
if output="$(run_cleanup 2>&1)"; then
    fail_test 'deletion timeout was reported as complete'
fi
[[ "$output" = *'resources may remain'* ]] || fail_test 'timeout omitted partial deletion warning'
unset MOCK_DELETE_TIMEOUT
: >"$MOCK_CALL_LOG"
run_cleanup >/dev/null
[[ "$(cat "$MOCK_CALL_LOG")" != *'cloudformation delete-stack'* ]] || fail_test 'in-progress deletion was reissued'

reset_state absent
output="$(run_cleanup)"
[[ "$output" = *'already absent'* ]] || fail_test 'absent stack was not distinguished'
[[ "$(cat "$MOCK_CALL_LOG")" != *'cloudformation delete-stack'* ]] || fail_test 'absent stack triggered deletion'

for status in DELETE_SKIPPED DELETE_FAILED UNKNOWN; do
    reset_state
    export MOCK_RESOURCE_STATUS="$status"
    if output="$(run_cleanup 2>&1)"; then
        fail_test "$status resource was reported as verified deletion"
    fi
    [[ "$output" = *'cleanup is incomplete'* ]] || fail_test 'missing incomplete-resource diagnostic'
done

for failure in 'cloudformation describe-stacks' 'cloudformation delete-stack' 'cloudformation list-stack-resources'; do
    reset_state
    export MOCK_FAILURE="$failure"
    if output="$(run_cleanup 2>&1)"; then
        fail_test "$failure was reported as cleanup success"
    fi
    [[ "$output" != *'already absent'* && "$output" != *'Verified deletion'* ]] || fail_test 'unknown AWS error treated as completion'
done

reset_state UPDATE_IN_PROGRESS
if output="$(run_cleanup 2>&1)"; then
    fail_test 'active update did not stop cleanup'
fi
[[ "$(cat "$MOCK_CALL_LOG")" != *'cloudformation delete-stack'* ]] || fail_test 'active update triggered deletion'

reset_state UNKNOWN
if output="$(run_cleanup 2>&1)"; then
    fail_test 'unknown stack status was accepted for deletion'
fi
[[ "$(cat "$MOCK_CALL_LOG")" != *'cloudformation delete-stack'* ]] || fail_test 'unknown status triggered deletion'

for option in --dev --dry-run --use-local-libs --no-url-check '--ledger-counter-id other' '--existing-ledger-counter-table-name shared'; do
    reset_state
    # Deliberate word splitting supplies the option and its test value.
    if output="$(run_cleanup $option 2>&1)"; then
        fail_test "incompatible cleanup option was accepted: $option"
    fi
    [ ! -s "$MOCK_CALL_LOG" ] || fail_test 'invalid options triggered AWS calls'
done
reset_state
if output="$(DEPLOYMENT_CONTROLLER=wireguard_gateway_controller run_cleanup 2>&1)"; then
    fail_test 'cleanup accepted an incompatible deployment controller'
fi
[ ! -s "$MOCK_CALL_LOG" ] || fail_test 'incompatible controller triggered AWS calls'
printf 'PASS: owned resource cleanup regression tests\n'
