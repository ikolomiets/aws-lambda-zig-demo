#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail_test() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

for tool in sam jq; do
    command -v "$tool" >/dev/null || fail_test "required command not found: $tool"
done

fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/sam-parameter-overrides.XXXXXX")"
trap 'rm -rf -- "$fixture_dir"' EXIT
printf '[profile fixture]\nregion = ca-central-1\n' >"$fixture_dir/aws-config"
printf '[fixture]\naws_access_key_id = fixture\naws_secret_access_key = fixture\n' >"$fixture_dir/aws-credentials"
# Keep SAM's version check offline using its temporary app state.
printf '{"lastVersionCheck":%s}\n' "$(date +%s)" >"$fixture_dir/metadata.json"
cat >"$fixture_dir/template.yaml" <<'YAML'
AWSTemplateFormatVersion: '2010-09-09'
Resources:
  Fixture:
    Type: AWS::CloudFormation::WaitConditionHandle
YAML

oauth_callback='https://operations.example.test/auth/github/callback'
origins='https://app.example.test,https://other.example.test:8443'
registrations="$(cat <<'JSON'
["https://app.example.test/sign-in?next=ParameterKey=fixture,ParameterValue=one&label='demo'","https://registered.example.test/return"]
JSON
)"

# Intercept the real deploy invocation and retain each override as one argument.
env -i PATH="$PATH" bash -s -- "$REPOSITORY_ROOT" "$fixture_dir" "$oauth_callback" "$origins" "$registrations" <<'BASH'
source "$1/deploy.sh"
fixture_dir="$2"
GITHUB_OAUTH_CALLBACK_URL="$3"
OPERATIONS_BROWSER_ORIGINS="$4"
GITHUB_BROWSER_REDIRECT_URIS="$5"
printf -v fixture_account '%012d' 0
GITHUB_CLIENT_ID=FixtureClient
GITHUB_CLIENT_SECRET_ARN="arn:aws:secretsmanager:ca-central-1:$fixture_account:secret:fixture-app-AbCd12"
PASETO_SIGNING_KEY_SECRET_ARN="arn:aws:secretsmanager:ca-central-1:$fixture_account:secret:fixture-key-DeFg34"
PASETO_PUBLIC_KEY=fixture
LEDGER_COUNTER_ID=fixture-counter

aws() { fail 'unexpected AWS call in SAM parser fixture'; }
load_preserved_allocator_binding() { PRESERVED_COUNTER_TABLE=fixture-counter-table; }
verify_deployment_counter() { :; }
sam() {
    [ "$1" = deploy ] || fail 'expected sam deploy'
    while [ "$#" -gt 0 ] && [ "$1" != --parameter-overrides ]; do shift; done
    [ "$#" -gt 1 ] || fail 'expected SAM parameter override arguments'
    shift
    printf '%s\0' "$@" >"$fixture_dir/deploy-arguments" || return 1
    printf 'No changes to deploy. Stack %s is up to date\n' "$STACK_NAME"
}

parse_deployment_options --enable-github-exchange
validate_github_exchange_configuration
deploy_stack_phase 'Capture fixture deployment arguments'
BASH

overrides=()
while IFS= read -r -d '' override; do
    overrides+=("$override")
done <"$fixture_dir/deploy-arguments"
[ "${#overrides[@]}" -gt 0 ] || fail_test 'no deployment overrides captured'

parse_overrides() {
    local case_name="$1"
    shift
    local config="$case_name.toml" log="$fixture_dir/$case_name.log"
    printf 'version = 0.1\n' >"$fixture_dir/$config"
    # The local resource listing uses the same option parser as deploy.
    # --save-params writes the parsed values to the temporary SAM config.
    if ! env -i PATH="$PATH" AWS_CONFIG_FILE="$fixture_dir/aws-config" \
        AWS_SHARED_CREDENTIALS_FILE="$fixture_dir/aws-credentials" AWS_EC2_METADATA_DISABLED=true \
        SAM_CLI_TELEMETRY=0 __SAM_CLI_APP_DIR="$fixture_dir" \
        sam list resources --template-file "$fixture_dir/template.yaml" \
        --config-file "$config" --profile fixture --region ca-central-1 --save-params \
        --parameter-overrides "$@" >"$log" 2>&1
    then
        cat "$log" >&2
        fail_test "SAM could not parse $case_name overrides"
    fi
    sed -n '/^\[default\.list_resources\.parameters\.parameter_overrides\]$/,/^\[/{ /^\[/d; p; }' \
        "$fixture_dir/$config"
}

assert_override() {
    local parsed="$1" key="$2" expected="$3" quoted
    # The fixture strings use the same basic-string escaping in JSON and TOML.
    quoted="$(jq -cn --arg value "$expected" '$value')"
    if ! grep -Fxq "$key = $quoted" <<<"$parsed"; then
        printf 'SAM did not preserve %s exactly.\n' "$key" >&2
        return 1
    fi
}

assert_adjacent_overrides() {
    assert_override "$1" GitHubOAuthCallbackUrl "$oauth_callback"
    assert_override "$1" OperationsBrowserOrigins "$origins"
    assert_override "$1" LedgerCounterId fixture-counter
}

parsed="$(parse_overrides current "${overrides[@]}")"
assert_override "$parsed" GitHubBrowserRedirectUris "$registrations"
assert_adjacent_overrides "$parsed"
if grep -q '^fixture =' <<<"$parsed"; then
    fail_test 'SAM parsed the embedded query text as an override'
fi
printf 'SAM preserved the exact callback URLs and adjacent overrides.\n'

legacy_overrides=()
for override in "${overrides[@]}"; do
    case "$override" in
        ParameterKey=GitHubBrowserRedirectUris,ParameterValue=*)
            legacy_overrides+=("GitHubBrowserRedirectUris=$registrations")
            ;;
        *) legacy_overrides+=("$override") ;;
    esac
done
parsed="$(parse_overrides legacy "${legacy_overrides[@]}")"
assert_adjacent_overrides "$parsed"
if assert_override "$parsed" GitHubBrowserRedirectUris "$registrations" 2>/dev/null; then
    fail_test 'negative control unexpectedly preserved the callback registration'
fi
if grep -q '^GitHubBrowserRedirectUris =' <<<"$parsed"; then
    fail_test 'negative control changed the callback registration instead of dropping it'
fi
assert_override "$parsed" fixture "one&label='demo'"
printf 'Negative control detected the lost GitHubBrowserRedirectUris registration.\n'
