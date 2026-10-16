#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/deploy-development-test.XXXXXX")"
trap 'rm -rf -- "$TEST_TMP_DIR"' EXIT

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    case "$1" in
        *"$2"*) ;;
        *) fail_test "expected output to contain: $2" ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*) fail_test "unexpected output: $2" ;;
        *) ;;
    esac
}

# Run the real script in an isolated checkout with mocks only at command boundaries.
mkdir -p "$TEST_TMP_DIR/bin" "$TEST_TMP_DIR/zig/lib/std/Io/net"
touch "$TEST_TMP_DIR/zig/lib/std/Io/net/HostName.zig"
cat >"$TEST_TMP_DIR/bin/mock-command" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
command_name="${0##*/}"
printf '%s %s\n' "$command_name" "$*" >>"$MOCK_CALL_LOG"
if [ "${MOCK_FAILURE:-}" = "$command_name:${1:-}" ] ||
    [ "${MOCK_FAILURE:-}" = "$command_name:${1:-}:${2:-}" ]; then
    exit 42
fi
case "$command_name" in
    zig)
        case "$1" in
            version) printf '%s\n' "${MOCK_ZIG_VERSION:-0.16.0}" ;;
            build)
                for ((index=1; index<=$#; index++)); do
                    case "${!index}" in
                        --cache-dir | --global-cache-dir)
                            index=$((index + 1))
                            mkdir -p "${!index}"
                            printf 'cached\n' >"${!index}/retained"
                            ;;
                        --fork=*)
                            fork_argument="${!index}"
                            [ -f "${fork_argument#--fork=}/build.zig.zon" ] || exit 98
                            ;;
                    esac
                done
                mkdir -p zig-out/bin
                cat >zig-out/bin/paseto <<'PASETO'
#!/usr/bin/env bash
printf 'paseto %s\n' "$*" >>"$MOCK_CALL_LOG"
printf 'mock-token\n'
PASETO
                chmod +x zig-out/bin/paseto
                cat >zig-out/bin/ledger-counter <<'COUNTER'
#!/usr/bin/env bash
set -euo pipefail
printf 'ledger-counter %s table=%s\n' "$*" "$LEDGER_COUNTER_TABLE_NAME" >>"$MOCK_CALL_LOG"
[ "${MOCK_COUNTER_FAILURE:-0}" = 0 ] || exit 2
id="$2"
if [ "$3" = init ]; then
    jq --arg id "$id" 'if has($id) then . else .[$id] = 1000 end' "$MOCK_COUNTER_STATE" >"$MOCK_COUNTER_STATE.tmp"
    mv "$MOCK_COUNTER_STATE.tmp" "$MOCK_COUNTER_STATE"
fi
jq -e --arg id "$id" '.[$id] | type == "number" and . >= 1000 and . <= 4294967295 and floor == .' "$MOCK_COUNTER_STATE" >/dev/null
jq --arg id "$id" '{counter_id:$id,high_water:.[$id]}' "$MOCK_COUNTER_STATE"
COUNTER
                chmod +x zig-out/bin/ledger-counter
                ;;
        esac
        ;;
    file)
        if [ "${MOCK_BAD_BOOTSTRAP:-0}" -eq 1 ]; then
            printf 'invalid bootstrap\n'
            exit 0
        fi
        case "$1" in
            *tiger_beetle_processor/bootstrap) linkage='dynamically linked' ;;
            *) linkage='statically linked' ;;
        esac
        printf '%s: ELF 64-bit LSB executable, ARM aarch64, %s, stripped\n' "$1" "$linkage"
        ;;
    zip) printf 'archive\n' >"$2" ;;
    unzip) printf '%s\n' "${MOCK_ARCHIVE_CONTENTS:-bootstrap}" ;;
    sam)
        if [ "$1" = deploy ]; then
            selected_id=global
            reference="${MOCK_EXISTING_COUNTER_REFERENCE:-}"
            for argument in "$@"; do
                case "$argument" in
                    LedgerCounterId=*) selected_id="${argument#*=}" ;;
                    ExistingLedgerCounterTableName=*) reference="${argument#*=}" ;;
                esac
            done
            jq -n --arg id "${MOCK_PROPOSED_COUNTER_ID-$selected_id}" \
                --arg reference "${MOCK_PROPOSED_REFERENCE-$reference}" \
                '[{ParameterKey:"LedgerCounterId",ParameterValue:$id},{ParameterKey:"ExistingLedgerCounterTableName",ParameterValue:$reference}]' >"$MOCK_PARAMETERS"
            case "${MOCK_SAM_RESULT:-created}" in
                created) printf 'Changeset created successfully. arn:aws:cloudformation:ca-central-1:example:changeSet/proposed/exact-id\n' ;;
                empty) printf 'No changes to deploy. Stack mock-stack is up to date\n' ;;
                ambiguous) printf 'unexpected SAM response\n' ;;
            esac
        fi
        if [ "$1" = sync ] && [ "${MOCK_SAM_CONFIRMATION:-0}" -eq 1 ]; then
            read -r reply || exit 95
            [ "$reply" = Y ] || exit 96
            # Exactly one answer is supplied, so an additional prompt reaches EOF.
            if read -r reply; then
                exit 97
            fi
        fi
        ;;
    curl)
        if [ -n "${MOCK_HTTP_STATUS:-}" ]; then
            printf '%s' "$MOCK_HTTP_STATUS"
            exit 0
        fi
        case "$*" in
            *Authorization*00000000-0000-4000-8000-000000000000*) printf '404' ;;
            *'-X POST'*Authorization*query.example.invalid*) printf '405' ;;
            *'-X POST'*Authorization*intake.example.invalid*) printf '400' ;;
            *Authorization*) printf '405' ;;
            *) printf '401' ;;
        esac
        ;;
    aws)
        query=''
        logical_id=''
        next_token=''
        arguments="$*"
        service="$1"
        operation="$2"
        shift 2
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --query) query="$2"; shift 2 ;;
                --logical-resource-id) logical_id="$2"; shift 2 ;;
                --next-token) next_token="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        case "$service $operation" in
            'sso login')
                [ -z "${AWS_ACCESS_KEY_ID+x}" ] &&
                    [ -z "${AWS_SECRET_ACCESS_KEY+x}" ] &&
                    [ -z "${AWS_SESSION_TOKEN+x}" ] &&
                    [ "${AWS_PROFILE:-}" = dev-selected ] || exit 90
                ;;
            'cloudformation describe-stacks')
                case "$query" in
                    '')
                        if [ -n "${MOCK_STACK_INSPECTION_ERROR:-}" ]; then
                            printf '%s\n' "$MOCK_STACK_INSPECTION_ERROR" >&2
                            exit 1
                        fi
                        if [ "${MOCK_STACK_MISSING_UNTIL_EXECUTION:-0}" = 1 ] && [ ! -f "$MOCK_STACK_JSON" ]; then
                            printf 'An error occurred (ValidationError) when calling the DescribeStacks operation: Stack with id mock-stack does not exist\n' >&2
                            exit 1
                        fi
                        if [ -f "$MOCK_STACK_JSON" ]; then
                            cat "$MOCK_STACK_JSON"
                        else
                            jq -n --arg id "${MOCK_EXISTING_COUNTER_ID-global}" \
                                --arg reference "${MOCK_EXISTING_COUNTER_REFERENCE-}" \
                                '{Stacks:[{StackStatus:"UPDATE_COMPLETE",Parameters:[{ParameterKey:"LedgerCounterId",ParameterValue:$id},{ParameterKey:"ExistingLedgerCounterTableName",ParameterValue:$reference}],Outputs:[{OutputKey:"LedgerCounterTableName",OutputValue:(if $reference == "" then "mock-counters" else $reference end)},{OutputKey:"LedgerCounterId",OutputValue:$id}]}]}'
                        fi
                        ;;
                    'Stacks[0].StackStatus')
                        if [ "${MOCK_STACK_STATUS:-}" = missing ]; then
                            printf 'Stack does not exist\n' >&2
                            exit 1
                        fi
                        printf '%s\n' "${MOCK_STACK_STATUS:-UPDATE_COMPLETE}"
                        ;;
                    *Parameters*)
                        printf 'EnableWireGuardGateway|false\tRetainTigerBeetleProcessorVpcCleanupResources|false\n'
                        ;;
                    length*SeatReservationProcessorName*)
                        printf '%s\n' "${MOCK_SEAT_BASELINE_COUNT:-2}"
                        ;;
                    *IntakeFunctionName*)
                        printf 'IntakeFunctionName|intake-lambda\tQueryFunctionName|query-lambda\t'
                        printf 'TigerBeetleProcessorName|tiger-beetle-processor\t'
                        printf 'TigerBeetleCompletionProcessorName|tiger-beetle-completion-processor\t'
                        printf 'SeatReservationProcessorName|%s\t' "${SEAT_RESERVATION_PROCESSOR_NAME:-seat-reservation-processor}"
                        printf 'SeatReservationCompletionProcessorName|%s\n' "${SEAT_RESERVATION_COMPLETION_PROCESSOR_NAME:-seat-reservation-completion-processor}"
                        ;;
                    *IntakeFunctionUrl*) printf 'https://intake.example.invalid/\n' ;;
                    *QueryFunctionUrl*) printf 'https://query.example.invalid/\n' ;;
                    *LedgerCounterTableName*) printf '%s\n' "${MOCK_EXISTING_COUNTER_REFERENCE:-mock-counters}" ;;
                    *) printf 'unexpected AWS query: %s\n' "$query" >&2; exit 91 ;;
                esac
                ;;
            'cloudformation describe-stack-resource')
                case "$logical_id" in
                    IntakeFunction) printf 'intake-lambda\n' ;;
                    OperationsTable) printf 'mock-operations\n' ;;
                    LedgerCounterTable) printf 'mock-counters\n' ;;
                    TigerBeetleQueue) printf 'https://queue.example.invalid/\n' ;;
                    *) exit 92 ;;
                esac
                ;;
            'cloudformation describe-change-set')
                [ "${MOCK_CHANGESET_FAILURE_TOKEN:-never}" != "$next_token" ] || exit 42
                if [ -n "$next_token" ]; then
                    page="$MOCK_CHANGESET_PAGES/$next_token.json"
                else
                    page="$MOCK_CHANGESET_PAGES/first.json"
                fi
                jq --slurpfile parameters "$MOCK_PARAMETERS" '. + {Parameters:$parameters[0]}' "$page"
                ;;
            'cloudformation get-template') cat "$MOCK_PROPOSED_TEMPLATE" ;;
            'configure export-credentials')
                printf 'export AWS_ACCESS_KEY_ID=mock-key\nexport AWS_SECRET_ACCESS_KEY=mock-secret\nexport AWS_SESSION_TOKEN=mock-session\n'
                ;;
            'cloudformation execute-change-set')
                if [ -n "${MOCK_STACK_AFTER_EXECUTION:-}" ]; then
                    cp "$MOCK_STACK_AFTER_EXECUTION" "$MOCK_STACK_JSON"
                fi
                ;;
            'cloudformation wait') ;;
            'dynamodb wait') ;;
            'dynamodb describe-table')
                case "$query" in
                    'Table.'*) printf 'mock-operations ACTIVE PAY_PER_REQUEST 1 id S 1 id HASH 0 0\n' ;;
                    *) printf '{}\n' ;;
                esac
                ;;
            'sqs get-queue-attributes') printf '{}\n' ;;
            *) printf 'unexpected AWS command: %s\n' "$arguments" >&2; exit 93 ;;
        esac
        ;;
    *) exit 94 ;;
esac
MOCK
chmod +x "$TEST_TMP_DIR/bin/mock-command"
for command_name in aws sam zig file zip unzip curl; do
    ln -s mock-command "$TEST_TMP_DIR/bin/$command_name"
done

new_checkout() {
    CHECKOUT="$TEST_TMP_DIR/$1"
    mkdir -p "$CHECKOUT"
    cp "$REPOSITORY_ROOT/deploy.sh" "$CHECKOUT/deploy.sh"
    cp "$REPOSITORY_ROOT/ledger-counter.sh" "$CHECKOUT/ledger-counter.sh"
    MOCK_STACK_JSON="$CHECKOUT/stack.json"
    MOCK_COUNTER_STATE="$CHECKOUT/counters.json"
    MOCK_PARAMETERS="$CHECKOUT/parameters.json"
    MOCK_PROPOSED_TEMPLATE="$CHECKOUT/template.json"
    MOCK_CHANGESET_PAGES="$CHECKOUT/pages"
    export MOCK_STACK_JSON MOCK_COUNTER_STATE MOCK_PARAMETERS MOCK_PROPOSED_TEMPLATE MOCK_CHANGESET_PAGES
    printf '{"global":1205,"other-sequence":6400,"sequence.B":2048}\n' >"$MOCK_COUNTER_STATE"
    cp "$REPOSITORY_ROOT/tests/fixtures/deployment-preservation-template.json" "$MOCK_PROPOSED_TEMPLATE"
    mkdir -p "$MOCK_CHANGESET_PAGES"
    printf '%s\n' '{"ChangeSetId":"arn:aws:cloudformation:ca-central-1:example:changeSet/proposed/exact-id","StackName":"mock-stack","Status":"CREATE_COMPLETE","ExecutionStatus":"AVAILABLE","Changes":[{"Type":"Resource","ResourceChange":{"ResourceType":"AWS::Lambda::Function","Action":"Modify"}}]}' >"$MOCK_CHANGESET_PAGES/first.json"
    MOCK_CALL_LOG="$CHECKOUT/calls.log"
    : >"$MOCK_CALL_LOG"
    export MOCK_CALL_LOG
}

run_script() {
    env PATH="$TEST_TMP_DIR/bin:$PATH" \
        PROFILE=dev-selected REGION=ca-central-1 STACK_NAME=mock-stack \
        PASETO_PUBLIC_KEY="${MOCK_PUBLIC_KEY-mock-public}" \
        PASETO_PRIVATE_KEY="${MOCK_PRIVATE_KEY-mock-private}" \
        AWS_ACCESS_KEY_ID=inherited AWS_SECRET_ACCESS_KEY=inherited AWS_SESSION_TOKEN=inherited \
        bash "$CHECKOUT/deploy.sh" "$@" >"$CHECKOUT/output.log" 2>&1
}

test_full_deployment_baseline() {
    local calls stages expected
    new_checkout full
    mkdir -p "$CHECKOUT/.zig-cache-dev" "$CHECKOUT/.zig-global-cache-dev"
    touch "$CHECKOUT/.zig-cache-dev/previous" "$CHECKOUT/.zig-global-cache-dev/previous"
    run_script || fail_test "full deployment failed: $(cat "$CHECKOUT/output.log")"
    calls="$(cat "$MOCK_CALL_LOG")"
    stages="$(sed -n -e '/^zig /p' -e '/^sam /p' "$MOCK_CALL_LOG")"
    expected='zig build fmt-check --cache-dir .zig-cache-deploy --global-cache-dir .zig-global-cache-deploy
zig build test --cache-dir .zig-cache-deploy --global-cache-dir .zig-global-cache-deploy
zig build --cache-dir .zig-cache-deploy --global-cache-dir .zig-global-cache-deploy --release -Darch=arm
sam validate --template-file template.yaml --region ca-central-1
sam validate --lint --template-file template.yaml --region ca-central-1'
    assert_contains "$stages" "$expected"
    assert_contains "$calls" 'sam deploy --template-file template.yaml --stack-name mock-stack'
    assert_contains "$calls" '--no-execute-changeset'
    assert_contains "$calls" 'EnableWireGuardGateway=false RetainTigerBeetleProcessorVpcCleanupResources=false'
    assert_contains "$calls" 'SeatReservationProcessorName=seat-reservation-processor'
    assert_contains "$calls" 'SeatReservationCompletionProcessorName=seat-reservation-completion-processor'
    assert_contains "$calls" 'LedgerCounterId=global'
    assert_contains "$calls" 'paseto issue --subject deploy-query-test-'
    [ "$(sed -n '1p' "$MOCK_CALL_LOG")" = 'aws sso login --profile dev-selected' ] ||
        fail_test 'full deployment did not authenticate first'
    [ "$(sed -n '/^curl /p' "$MOCK_CALL_LOG" | wc -l | tr -d ' ')" = 6 ] ||
        fail_test 'full deployment did not retain all six HTTP probes'
    [ ! -e "$CHECKOUT/.zig-cache-deploy" ] && [ ! -e "$CHECKOUT/.zig-global-cache-deploy" ] ||
        fail_test 'full deployment retained temporary caches'
    [ -f "$CHECKOUT/.zig-cache-dev/previous" ] && [ -f "$CHECKOUT/.zig-global-cache-dev/previous" ] ||
        fail_test 'full deployment removed development caches'
}

test_selected_seat_configuration() {
    local calls
    new_checkout selected-seat
    MOCK_EXISTING_COUNTER_ID=sequence.B MOCK_EXISTING_COUNTER_REFERENCE=shared-ledgers \
        SEAT_RESERVATION_PROCESSOR_NAME=seat-submit-chosen \
        SEAT_RESERVATION_COMPLETION_PROCESSOR_NAME=seat-complete-chosen \
        run_script --seat-reservation-processor-name seat-submit-chosen \
        --seat-reservation-completion-processor-name=seat-complete-chosen \
        --existing-ledger-counter-table-name shared-ledgers --ledger-counter-id=sequence.B || \
        fail_test "selected seat configuration failed: $(cat "$CHECKOUT/output.log")"
    calls="$(cat "$MOCK_CALL_LOG")"
    assert_contains "$calls" 'SeatReservationProcessorName=seat-submit-chosen'
    assert_contains "$calls" 'SeatReservationCompletionProcessorName=seat-complete-chosen'
    assert_contains "$calls" 'ExistingLedgerCounterTableName=shared-ledgers LedgerCounterId=sequence.B'
}

test_allocator_rebinding_is_refused() {
    local id table
    for id in absent-sequence other-sequence; do
        new_checkout "id-rebinding-$id"
        if run_script --ledger-counter-id "$id"; then
            fail_test 'full deployment switched an established counter ID'
        fi
        assert_contains "$(cat "$CHECKOUT/output.log")" 'refusing to change the established counter ID'
        assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'sam deploy'
    done
    for table in another-table mock-counters; do
        new_checkout "table-rebinding-$table"
        if run_script --existing-ledger-counter-table-name "$table"; then
            fail_test 'full deployment changed owned/referenced table identity'
        fi
        assert_contains "$(cat "$CHECKOUT/output.log")" 'refusing to change the established counter table'
        assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'cloudformation execute-change-set'
    done
}

update_json() {
    jq "$2" "$1" >"$1.tmp"
    mv "$1.tmp" "$1"
}

two_page_changeset() {
    cp "$MOCK_CHANGESET_PAGES/first.json" "$MOCK_CHANGESET_PAGES/second.json"
    update_json "$MOCK_CHANGESET_PAGES/first.json" '.NextToken = "second"'
}

assert_deployment_refused() {
    if run_script --no-url-check "$@"; then
        fail_test "unsafe deployment succeeded: $(cat "$CHECKOUT/output.log")"
    fi
    assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'cloudformation execute-change-set'
    assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'ledger-counter --counter-id global init'
}

test_repeated_paginated_deployment_preserves_data() {
    local calls first_inspection execution second_inspection
    new_checkout repeated-deployment
    two_page_changeset
    update_json "$MOCK_CHANGESET_PAGES/second.json" '.Changes = [{Type:"Resource",ResourceChange:{LogicalResourceId:"SeatEventsTable",PhysicalResourceId:"saved-events",ResourceType:"AWS::DynamoDB::Table",Action:"Modify",Replacement:"False",Details:[{Target:{Attribute:"Tags",RequiresRecreation:"Never"}}]}}]'
    cp "$MOCK_COUNTER_STATE" "$CHECKOUT/original-counters.json"
    run_script --no-url-check || fail_test "first preserved deployment failed: $(cat "$CHECKOUT/output.log")"
    calls="$(cat "$MOCK_CALL_LOG")"
    assert_contains "$calls" 'cloudformation describe-change-set --change-set-name arn:aws:cloudformation:ca-central-1:example:changeSet/proposed/exact-id'
    assert_contains "$calls" '--no-paginate --next-token second'
    assert_contains "$calls" 'cloudformation execute-change-set --change-set-name arn:aws:cloudformation:ca-central-1:example:changeSet/proposed/exact-id'
    first_inspection="$(sed -n '/describe-change-set/=' "$MOCK_CALL_LOG" | head -n 1)"
    second_inspection="$(sed -n '/--next-token second/=' "$MOCK_CALL_LOG")"
    execution="$(sed -n '/execute-change-set/=' "$MOCK_CALL_LOG")"
    [ "$first_inspection" -lt "$second_inspection" ] && [ "$second_inspection" -lt "$execution" ] ||
        fail_test 'executed before inspecting every page'
    run_script --no-url-check --tigerbeetle-cluster-id 7 ||
        fail_test 'native cluster change did not preserve the allocator'
    cmp "$MOCK_COUNTER_STATE" "$CHECKOUT/original-counters.json" || fail_test 'redeployment changed persistent counters'
    calls="$(cat "$MOCK_CALL_LOG")"
    assert_not_contains "$calls" ' init'
    assert_not_contains "$calls" 'delete-table'
    assert_not_contains "$calls" 'delete-stack'
    assert_not_contains "$calls" 'delete-item'
}

test_every_unsafe_table_change_is_refused() {
    local logical_id change
    for logical_id in OperationsTable SeatEventsTable LedgerCounterTable; do
        for change in \
            '{Action:"Remove"}' \
            '{Action:"Modify",Replacement:"True"}' \
            '{Action:"Modify",Replacement:"Conditional"}' \
            '{Action:"Modify",Replacement:"Unknown"}' \
            '{Action:"Modify"}' \
            '{Action:"Modify",Replacement:"False",Details:[]}' \
            '{Action:"Modify",Replacement:"False",Details:[{Target:{Attribute:"Properties",Name:"KeySchema",RequiresRecreation:"Never"}}]}' \
            '{Action:"Modify",Replacement:"False",Details:[{Target:{Attribute:"Properties",Name:"AttributeDefinitions",RequiresRecreation:"Never"}}]}' \
            '{Action:"Modify",Replacement:"False",Details:[{Target:{Attribute:"Properties",Name:"TableName",RequiresRecreation:"Never"}}]}' \
            '{Action:"Modify",Replacement:"False",Details:[{Target:{Attribute:"Properties",Name:"TimeToLiveSpecification",RequiresRecreation:"Never"}}]}' \
            '{Action:"Modify",Replacement:"False",Details:[{Target:{Attribute:"Properties",RequiresRecreation:"Never"}}]}'; do
            new_checkout unsafe-table
            two_page_changeset
            update_json "$MOCK_CHANGESET_PAGES/second.json" \
                ".Changes = [{Type:\"Resource\",ResourceChange:({LogicalResourceId:\"$logical_id\",ResourceType:\"AWS::DynamoDB::Table\"} + $change)}]"
            assert_deployment_refused
            assert_contains "$(cat "$CHECKOUT/output.log")" 'refusing unsafe or ambiguous change set'
        done
    done
}

test_processed_template_and_inspection_fail_closed() {
    local mutation failure
    for mutation in \
        '.TemplateBody.Resources.SeatEventsTable.Properties.KeySchema[0].AttributeName = "other"' \
        '.TemplateBody.Resources.SeatEventsTable.Properties.TimeToLiveSpecification = {AttributeName:"expires_at",Enabled:true}' \
        '.TemplateBody.Resources.SeatReservationProcessor.Properties.Environment.Variables.LEDGER_COUNTER_ID = "other-sequence"' \
        '.TemplateBody.Resources.SeatReservationProcessor.Properties.Environment.Variables.LEDGER_COUNTER_TABLE_NAME = "other-table"' \
        '.TemplateBody.Outputs.LedgerCounterTableName.Value = "other-table"' \
        '.TemplateBody.Conditions.OwnLedgerCounterTable = false'; do
        new_checkout unsafe-template
        update_json "$MOCK_PROPOSED_TEMPLATE" "$mutation"
        assert_deployment_refused
    done
    for mutation in \
        '.ChangeSetId = "another-id"' \
        '.StackName = "another-stack"' \
        '.Status = "FAILED"' \
        '.ExecutionStatus = "OBSOLETE"' \
        '.Changes = null' \
        '.NextToken = 42'; do
        new_checkout ambiguous-inspection
        update_json "$MOCK_CHANGESET_PAGES/first.json" "$mutation"
        assert_deployment_refused
    done
    new_checkout repeated-pagination
    two_page_changeset
    update_json "$MOCK_CHANGESET_PAGES/second.json" '.NextToken = "second"'
    assert_deployment_refused
    new_checkout failed-second-page
    two_page_changeset
    MOCK_CHANGESET_FAILURE_TOKEN=second assert_deployment_refused
    for failure in aws:cloudformation:describe-change-set aws:cloudformation:get-template aws:configure:export-credentials; do
        new_checkout failed-inspection
        MOCK_FAILURE="$failure" assert_deployment_refused
    done
    new_checkout malformed-json
    printf 'not json\n' >"$MOCK_CHANGESET_PAGES/first.json"
    assert_deployment_refused
    new_checkout ambiguous-sam
    MOCK_SAM_RESULT=ambiguous assert_deployment_refused
}

test_selected_setup_and_missing_or_corrupt_counters() {
    local value
    for value in null '"corrupt"' 999 4294967296 1000.5; do
        new_checkout bad-counter
        update_json "$MOCK_COUNTER_STATE" ".global = $value"
        cp "$MOCK_COUNTER_STATE" "$CHECKOUT/before.json"
        assert_deployment_refused
        cmp "$MOCK_COUNTER_STATE" "$CHECKOUT/before.json" || fail_test 'deployment repaired a bad counter'
        assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'sam deploy'
    done
    new_checkout selected-explicit-setup
    update_json "$MOCK_COUNTER_STATE" 'del(.["sequence.B"])'
    MOCK_EXISTING_COUNTER_ID=sequence.B MOCK_EXISTING_COUNTER_REFERENCE=shared-ledgers \
        assert_deployment_refused --ledger-counter-id sequence.B
    cp "$MOCK_COUNTER_STATE" "$CHECKOUT/unselected.json"
    env PATH="$TEST_TMP_DIR/bin:$PATH" MOCK_EXISTING_COUNTER_REFERENCE=shared-ledgers \
        bash "$CHECKOUT/ledger-counter.sh" --profile dev-selected --stack-name mock-stack \
        --counter-id sequence.B init >"$CHECKOUT/setup.json" || fail_test 'explicit selected setup failed'
    jq -e '.counter_id == "sequence.B" and .high_water == 1000' "$CHECKOUT/setup.json" >/dev/null ||
        fail_test 'setup did not initialize only the selected ID at 1000'
    jq 'del(.["sequence.B"])' "$MOCK_COUNTER_STATE" >"$CHECKOUT/after-unselected.json"
    cmp "$CHECKOUT/unselected.json" "$CHECKOUT/after-unselected.json" || fail_test 'setup changed another counter'
    MOCK_EXISTING_COUNTER_ID=sequence.B MOCK_EXISTING_COUNTER_REFERENCE=shared-ledgers \
        run_script --no-url-check --ledger-counter-id sequence.B --tigerbeetle-cluster-id 9 || fail_test 'selected setup did not unblock deployment'
    MOCK_EXISTING_COUNTER_ID=sequence.B MOCK_EXISTING_COUNTER_REFERENCE=shared-ledgers \
        run_script --no-url-check --ledger-counter-id sequence.B --tigerbeetle-cluster-id 10 || fail_test 'shared binding changed with native cluster selection'
    jq -e '.global == 1205 and .["other-sequence"] == 6400 and .["sequence.B"] == 1000' "$MOCK_COUNTER_STATE" >/dev/null ||
        fail_test 'shared deployments changed independent counters'
    new_checkout uncertain-counter
    MOCK_COUNTER_FAILURE=1 assert_deployment_refused
}

test_empty_changeset_preserves_setup() {
    new_checkout empty-changeset
    MOCK_SAM_RESULT=empty run_script --no-url-check || fail_test 'empty change set was not successful'
    assert_contains "$(cat "$CHECKOUT/output.log")" 'does not establish Lambda code equality'
    assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'cloudformation execute-change-set'
    assert_contains "$(cat "$MOCK_CALL_LOG")" 'ledger-counter --counter-id global read table=mock-counters'
}

test_first_deployment_requires_explicit_setup() {
    new_checkout first-deployment
    MOCK_STACK_MISSING_UNTIL_EXECUTION=1
    export MOCK_STACK_MISSING_UNTIL_EXECUTION
    MOCK_STACK_AFTER_EXECUTION="$CHECKOUT/created-stack.json"
    export MOCK_STACK_AFTER_EXECUTION
    jq -n '{Stacks:[{StackStatus:"CREATE_COMPLETE",Parameters:[{ParameterKey:"LedgerCounterId",ParameterValue:"global"},{ParameterKey:"ExistingLedgerCounterTableName",ParameterValue:""}],Outputs:[{OutputKey:"LedgerCounterTableName",OutputValue:"mock-counters"},{OutputKey:"LedgerCounterId",OutputValue:"global"}]}]}' >"$MOCK_STACK_AFTER_EXECUTION"
    update_json "$MOCK_COUNTER_STATE" 'del(.global)'
    if run_script --no-url-check; then
        fail_test 'first deployment silently initialized its new counter'
    fi
    assert_contains "$(cat "$MOCK_CALL_LOG")" 'cloudformation wait stack-create-complete'
    assert_contains "$(cat "$CHECKOUT/output.log")" 'selected allocator setup is missing'
    jq -e 'has("global") | not' "$MOCK_COUNTER_STATE" >/dev/null || fail_test 'first deployment repaired missing setup'
    env PATH="$TEST_TMP_DIR/bin:$PATH" bash "$CHECKOUT/ledger-counter.sh" \
        --stack-name mock-stack --counter-id global init >"$CHECKOUT/setup.json" || fail_test 'new owned allocator setup failed'
    run_script --no-url-check || fail_test 'repeat after explicit setup failed'
    assert_contains "$(cat "$MOCK_CALL_LOG")" 'cloudformation wait stack-update-complete'
    unset MOCK_STACK_AFTER_EXECUTION
    unset MOCK_STACK_MISSING_UNTIL_EXECUTION
}

test_proposed_binding_and_active_states_are_refused() {
    local status mutation
    new_checkout proposed-id-change
    MOCK_PROPOSED_COUNTER_ID=other-sequence assert_deployment_refused
    new_checkout proposed-table-change
    MOCK_PROPOSED_REFERENCE=other-table assert_deployment_refused
    for status in UPDATE_IN_PROGRESS UPDATE_COMPLETE_CLEANUP_IN_PROGRESS UPDATE_ROLLBACK_IN_PROGRESS DELETE_IN_PROGRESS; do
        new_checkout active-state
        MOCK_STACK_STATUS="$status" assert_deployment_refused
        assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'sam deploy'
    done
    new_checkout incomplete-binding
    printf '{"Stacks":[{"StackStatus":"UPDATE_COMPLETE","Parameters":[],"Outputs":[{"OutputKey":"SeatReservationProcessorName","OutputValue":"seat"}]}]}\n' >"$MOCK_STACK_JSON"
    assert_deployment_refused
    new_checkout ambiguous-stack-error
    MOCK_STACK_INSPECTION_ERROR='Role does not exist' assert_deployment_refused
    assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'sam deploy'
    for mutation in \
        '.Stacks[0].Outputs[1].OutputValue = null' \
        '.Stacks[0].Parameters[0].ParameterValue = null' \
        '.Stacks[0].Parameters[1].ParameterValue = null'; do
        new_checkout null-binding
        jq -n '{Stacks:[{StackStatus:"UPDATE_COMPLETE",Parameters:[{ParameterKey:"LedgerCounterId",ParameterValue:"global"},{ParameterKey:"ExistingLedgerCounterTableName",ParameterValue:""}],Outputs:[{OutputKey:"LedgerCounterTableName",OutputValue:"mock-counters"},{OutputKey:"LedgerCounterId",OutputValue:"global"}]}]}' >"$MOCK_STACK_JSON"
        update_json "$MOCK_STACK_JSON" "$mutation"
        assert_deployment_refused
        assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'sam deploy'
    done
    new_checkout json-string-template
    update_json "$MOCK_PROPOSED_TEMPLATE" '.TemplateBody |= tojson'
    run_script --no-url-check || fail_test 'JSON-string processed template was refused'
}

test_development_dry_run() {
    local calls
    new_checkout dev-dry
    MOCK_PUBLIC_KEY='' MOCK_PRIVATE_KEY='' run_script --dev --dry-run ||
        fail_test "development dry run failed: $(cat "$CHECKOUT/output.log")"
    calls="$(cat "$MOCK_CALL_LOG")"
    assert_contains "$calls" 'zig build fmt-check --cache-dir .zig-cache-dev --global-cache-dir .zig-global-cache-dev'
    assert_contains "$calls" 'zig build --cache-dir .zig-cache-dev --global-cache-dir .zig-global-cache-dev --release -Darch=arm'
    assert_contains "$calls" 'zip -qj tiger-beetle-completion-processor.zip'
    assert_contains "$calls" 'file zig-out/bin/seat_reservation_processor/bootstrap'
    assert_contains "$calls" 'file zig-out/bin/seat_reservation_completion_processor/bootstrap'
    assert_contains "$calls" 'zip -qj seat-reservation-processor.zip zig-out/bin/seat_reservation_processor/bootstrap'
    assert_contains "$calls" 'zip -qj seat-reservation-completion-processor.zip zig-out/bin/seat_reservation_completion_processor/bootstrap'
    assert_contains "$calls" 'unzip -Z1 seat-reservation-processor.zip'
    assert_contains "$calls" 'unzip -Z1 seat-reservation-completion-processor.zip'
    assert_not_contains "$calls" 'zig build test'
    assert_not_contains "$calls" 'aws '
    assert_not_contains "$calls" 'sam '
    [ -f "$CHECKOUT/.zig-cache-dev/retained" ] && [ -f "$CHECKOUT/.zig-global-cache-dev/retained" ] ||
        fail_test 'development caches were not retained'
    touch "$CHECKOUT/.zig-cache-dev/previous" "$CHECKOUT/.zig-global-cache-dev/previous"
    run_script --dry-run --dev || fail_test 'repeated development dry run failed'
    [ -f "$CHECKOUT/.zig-cache-dev/previous" ] && [ -f "$CHECKOUT/.zig-global-cache-dev/previous" ] ||
        fail_test 'repeated development run removed previous caches'
}

test_local_forks_reach_all_build_steps() {
    local mode fork_root stages expected
    local options
    for mode in deploy dev; do
        new_checkout "fork-$mode"
        fork_root="$CHECKOUT/local aws-lambda"
        mkdir -p "$fork_root/src"
        touch "$fork_root/build.zig.zon" "$fork_root/src/root.zig"
        options=(--dry-run --use-local-libs)
        if [ "$mode" = dev ]; then
            options+=(--dev)
        fi
        LOCAL_AWS_LAMBDA_ROOT="$fork_root" run_script "${options[@]}" ||
            fail_test "local fork $mode run failed: $(cat "$CHECKOUT/output.log")"
        stages="$(sed -n '/^zig build /p' "$MOCK_CALL_LOG")"
        expected="zig build fmt-check --cache-dir .zig-cache-$mode --global-cache-dir .zig-global-cache-$mode --fork=$fork_root"
        if [ "$mode" = deploy ]; then
            expected+="
zig build test --cache-dir .zig-cache-$mode --global-cache-dir .zig-global-cache-$mode --fork=$fork_root"
        fi
        expected+="
zig build --cache-dir .zig-cache-$mode --global-cache-dir .zig-global-cache-$mode --fork=$fork_root --release -Darch=arm"
        [ "$stages" = "$expected" ] || fail_test "unexpected local fork $mode build steps: $stages"
    done
}

test_development_code_sync() {
    local calls
    new_checkout dev-sync
    MOCK_SAM_CONFIRMATION=1 run_script \
        --dev --profile=dev-selected --region us-east-1 --stack-name=dev-code-stack </dev/null ||
        fail_test "development sync failed: $(cat "$CHECKOUT/output.log")"
    calls="$(cat "$MOCK_CALL_LOG")"
    assert_contains "$calls" 'sam sync --template-file template.yaml --stack-name dev-code-stack --region us-east-1 --profile dev-selected --code --no-watch --no-dependency-layer --resource-id IntakeFunction --resource-id QueryFunction --resource-id TigerBeetleProcessor --resource-id TigerBeetleCompletionProcessor'
    assert_contains "$calls" '--resource-id SeatReservationProcessor --resource-id SeatReservationCompletionProcessor'
    assert_not_contains "$calls" 'sam deploy '
    assert_not_contains "$calls" 'sam validate '
    assert_not_contains "$calls" 'zig build test '
    assert_not_contains "$calls" 'Stacks[0].Parameters'
    assert_not_contains "$calls" '--parameter-overrides'
    assert_contains "$calls" 'aws cloudformation describe-stacks --stack-name dev-code-stack --query Stacks[0].StackStatus --output text --profile dev-selected --region us-east-1'
    [ "$(sed -n '1p' "$MOCK_CALL_LOG")" = 'aws sso login --profile dev-selected' ] ||
        fail_test 'development sync did not authenticate first'
    [ "$(sed -n '/^curl /p' "$MOCK_CALL_LOG" | wc -l | tr -d ' ')" = 6 ] ||
        fail_test 'development sync did not retain all six HTTP probes'
    [ -f "$CHECKOUT/.zig-cache-dev/retained" ] && [ -f "$CHECKOUT/.zig-global-cache-dev/retained" ] ||
        fail_test 'development sync removed its caches'
}

test_development_rejects_configuration_and_lifecycle_options() {
    local option
    for option in \
        --intake-function-name --query-function-name \
        --tiger-beetle-processor-name --tiger-beetle-completion-processor-name \
        --seat-reservation-processor-name --seat-reservation-completion-processor-name \
        --existing-ledger-counter-table-name --ledger-counter-id \
        --tigerbeetle-cluster-id --tigerbeetle-addresses --lambda-principal
    do
        new_checkout invalid
        if run_script --dev "$option" ignored; then
            fail_test "development accepted configuration option: $option"
        fi
        [ ! -s "$MOCK_CALL_LOG" ] || fail_test 'invalid development options performed work'
        assert_contains "$(cat "$CHECKOUT/output.log")" 'full deployment'
        if run_script "$option=ignored" --dev; then
            fail_test "development accepted configuration option before --dev: $option"
        fi
        [ ! -s "$MOCK_CALL_LOG" ] || fail_test 'invalid development options performed work'
    done
    for option in --cleanup --disable --enable-wireguard-gateway --wireguard-ami-id=ami-00000001; do
        new_checkout invalid-lifecycle
        if run_script --dev "$option"; then
            fail_test "development accepted lifecycle option: $option"
        fi
        [ ! -s "$MOCK_CALL_LOG" ] || fail_test 'invalid lifecycle options performed work'
    done
    new_checkout invalid-controller
    if DEPLOYMENT_CONTROLLER=wireguard_gateway_controller run_script --dev; then
        fail_test 'development accepted a WireGuard deployment controller'
    fi
    [ ! -s "$MOCK_CALL_LOG" ] || fail_test 'development controller rejection performed work'
    assert_contains "$(cat "$CHECKOUT/output.log")" 'full deployment'
}

test_missing_seat_baseline_and_invalid_configuration() {
    local counter_id
    new_checkout missing-seat-baseline
    if MOCK_SEAT_BASELINE_COUNT=0 run_script --dev; then
        fail_test 'development sync accepted a four-function baseline'
    fi
    assert_contains "$(cat "$CHECKOUT/output.log")" 'full deployment'
    assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'sam sync'
    for counter_id in '' '-global' 'a/b' 'é' "$(printf '%129s' a | tr ' ' a)"; do
        new_checkout invalid-counter-id
        if LEDGER_COUNTER_ID="$counter_id" run_script --dry-run; then
            fail_test 'invalid configured counter ID accepted'
        fi
        [ ! -s "$MOCK_CALL_LOG" ] || fail_test 'invalid counter ID performed work'
    done
}

test_development_gates_and_failure_propagation() {
    local failure
    for failure in zig:build:fmt-check zig:build:--cache-dir file:zig-out/bin/intake/bootstrap zip:-qj unzip:-Z1 sam:sync; do
        new_checkout failure
        if MOCK_FAILURE="$failure" run_script --dev; then
            fail_test "development succeeded after command failure: $failure"
        fi
        assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'curl '
        if [ "$failure" = zig:build:fmt-check ]; then
            assert_not_contains "$(cat "$MOCK_CALL_LOG")" '--release -Darch=arm'
            assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'zip '
        fi
        if [ "$failure" != sam:sync ]; then
            assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'sam sync '
        fi
        assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'sam deploy '
    done
    assert_contains "$(cat "$CHECKOUT/output.log")" 'some functions may already have updated'
    [ -f "$CHECKOUT/.zig-cache-dev/retained" ] && [ -f "$CHECKOUT/.zig-global-cache-dev/retained" ] ||
        fail_test 'failed development sync removed its caches'

    new_checkout invalid-bootstrap
    if MOCK_BAD_BOOTSTRAP=1 run_script --dev --dry-run; then
        fail_test 'development accepted an invalid bootstrap'
    fi
    assert_contains "$(cat "$CHECKOUT/output.log")" 'unexpected bootstrap artifact type'
    assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'zip '

    new_checkout invalid-archive
    if MOCK_ARCHIVE_CONTENTS='nested/bootstrap' run_script --dev --dry-run; then
        fail_test 'development accepted an invalid archive'
    fi
    assert_contains "$(cat "$CHECKOUT/output.log")" 'must contain only a root-level bootstrap'

    new_checkout failed-smoke
    if MOCK_HTTP_STATUS=500 run_script --dev; then
        fail_test 'development accepted a failing HTTP smoke check'
    fi
    assert_contains "$(cat "$CHECKOUT/output.log")" 'expected 401'
}

test_development_authentication_and_stack_guards() {
    local status
    for status in UPDATE_IN_PROGRESS missing; do
        new_checkout stack-guard
        if MOCK_STACK_STATUS="$status" run_script --dev; then
            fail_test "development accepted stack status: $status"
        fi
        assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'zig '
        assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'sam '
    done
    assert_contains "$(cat "$CHECKOUT/output.log")" 'run a full deployment first'
    new_checkout failed-login
    if MOCK_FAILURE=aws:sso run_script --dev; then
        fail_test 'development accepted failed SSO login'
    fi
    [ "$(cat "$MOCK_CALL_LOG")" = 'aws sso login --profile dev-selected' ] ||
        fail_test 'development proceeded after failed authentication'
}

test_development_prerequisites_and_smoke_opt_out() {
    new_checkout wrong-zig
    if MOCK_ZIG_VERSION=0.15.2 run_script --dev --dry-run; then
        fail_test 'development accepted the wrong Zig version'
    fi
    assert_contains "$(cat "$CHECKOUT/output.log")" 'require Zig 0.16.0'
    assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'zig build '

    new_checkout missing-stdlib
    rm "$TEST_TMP_DIR/zig/lib/std/Io/net/HostName.zig"
    if run_script --dev --dry-run; then
        fail_test 'development accepted a missing sibling standard library'
    fi
    touch "$TEST_TMP_DIR/zig/lib/std/Io/net/HostName.zig"
    assert_contains "$(cat "$CHECKOUT/output.log")" 'required sibling Zig standard library missing'
    assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'zig build '

    new_checkout no-smoke
    MOCK_PUBLIC_KEY='' MOCK_PRIVATE_KEY='' run_script --dev --no-url-check ||
        fail_test 'development smoke opt-out still required PASETO keys'
    assert_contains "$(cat "$MOCK_CALL_LOG")" 'sam sync '
    assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'curl '
    assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'paseto '
}

test_full_dry_run_and_failed_build_cleanup() {
    new_checkout full-dry
    run_script --dry-run || fail_test 'ordinary dry run failed'
    assert_contains "$(cat "$MOCK_CALL_LOG")" 'zig build test '
    assert_contains "$(cat "$MOCK_CALL_LOG")" 'sam validate --lint '
    assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'aws '
    assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'sam deploy '
    [ ! -e "$CHECKOUT/.zig-cache-deploy" ] && [ ! -e "$CHECKOUT/.zig-global-cache-deploy" ] ||
        fail_test 'ordinary dry run retained temporary caches'

    new_checkout full-format-failure
    mkdir -p "$CHECKOUT/.zig-cache-deploy" "$CHECKOUT/.zig-global-cache-deploy"
    if MOCK_FAILURE=zig:build:fmt-check run_script --dry-run; then
        fail_test 'full deployment succeeded after failed formatting'
    fi
    [ ! -e "$CHECKOUT/.zig-cache-deploy" ] && [ ! -e "$CHECKOUT/.zig-global-cache-deploy" ] ||
        fail_test 'failed formatting retained temporary caches'
    assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'zig build test '
    assert_not_contains "$(cat "$MOCK_CALL_LOG")" '--release -Darch=arm'
    assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'zip '
    assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'sam '

    new_checkout full-failure
    mkdir -p "$CHECKOUT/.zig-cache-deploy" "$CHECKOUT/.zig-global-cache-deploy"
    if MOCK_FAILURE=zig:build:test run_script --dry-run; then
        fail_test 'full deployment succeeded after failed tests'
    fi
    [ ! -e "$CHECKOUT/.zig-cache-deploy" ] && [ ! -e "$CHECKOUT/.zig-global-cache-deploy" ] ||
        fail_test 'failed full deployment retained temporary caches'
    assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'zip '
}

test_allocator_rebinding_is_refused
test_repeated_paginated_deployment_preserves_data
test_every_unsafe_table_change_is_refused
test_processed_template_and_inspection_fail_closed
test_selected_setup_and_missing_or_corrupt_counters
test_empty_changeset_preserves_setup
test_first_deployment_requires_explicit_setup
test_proposed_binding_and_active_states_are_refused
test_full_deployment_baseline
test_selected_seat_configuration
test_missing_seat_baseline_and_invalid_configuration
test_development_dry_run
test_local_forks_reach_all_build_steps
test_development_code_sync
test_development_rejects_configuration_and_lifecycle_options
test_development_gates_and_failure_propagation
test_development_authentication_and_stack_guards
test_development_prerequisites_and_smoke_opt_out
test_full_dry_run_and_failed_build_cleanup
printf 'PASS: development deployment regression tests\n'
