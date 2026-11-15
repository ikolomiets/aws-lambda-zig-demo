#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT/scripts/check_aws_privacy.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/aws-privacy-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
checks=0
output="$test_root/output"

fail_test() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
git_fixture() {
    git --literal-pathspecs -c user.name='Privacy Test' -c user.email=test@example.invalid \
        -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
new_repository() {
    cd "$(mktemp -d "$test_root/repo.XXXXXX")"
    git_fixture init --quiet
    printf 'unchanged\n' >existing.txt
    commit_fixture
}
commit_fixture() {
    git_fixture add --all
    git_fixture commit --quiet -m fixture
}
run_scan() {
    local expected="$1" actual=0
    shift
    bash "$CHECKER" "$@" >"$output" 2>&1 || actual=$?
    [ "$actual" -eq "$expected" ] ||
        fail_test "privacy check $checks returned $actual instead of $expected"
    checks=$((checks + 1))
}
contains_output() { grep -Fq -- "$1" "$output" || fail_test 'missing candidate location/category'; }
absent_value() {
    if grep -Fq -- "$1" "$output"; then
        fail_test 'privacy output disclosed a matched value'
    fi
}

printf -v suffix '%016d' 0
suffix="${suffix//0/Z}"
key="AKIA$suffix"
account="731""468""209""573"
secret="$(printf '%040d' 0 | tr 0 x)"
token="$(printf '%060d' 0 | tr 0 y)"
host=demo
bucket=private-demo-bucket

# Exercise all detection categories through the real staged-content boundary.
new_repository
private_examples=(
    "$key" "ASIA$suffix" "AIDA${suffix}R" "$account"
    "arn:aws:sts::$account:assumed-role/demo/session"
    "aws_secret_access_key = $secret" "\"awsSessionToken\": \"$token\""
    "${host}.lambda-url.ca-central-1.on.aws"
    "${host}.execute-api.ca-central-1.amazonaws.com"
    "s3://$bucket/path" "${host}.s3.ca-central-1.amazonaws.com"
    "https://s3.ca-central-1.amazonaws.com/$bucket/path"
    "BucketName: $bucket" "S3_BUCKET=$bucket"
)
for example in "${private_examples[@]}"; do
    printf '%s\n' "$example" >candidate.txt
    git_fixture add candidate.txt
    run_scan 1 --staged
    absent_value "$example"
done

safe_examples=(
    '00112233-4455-6677-8899-123456789012'
    'AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}'
    'aws_session_token = "<session-token>"'
    'arn:${AWS::Partition}:lambda:${AWS::Region}:${AWS::AccountId}:function:<name>'
    'https://${OperationsApi}.execute-api.${AWS::Region}.${AWS::URLSuffix}'
    'https://<IntakeFunctionUrl>' 's3://<bucket-name>/path'
    'BucketName: !Ref ArtifactsBucket' 'BucketName: ${ARTIFACTS_BUCKET}'
    'arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole'
)
for example in "${safe_examples[@]}"; do
    printf '%s\n' "$example" >candidate.txt
    git_fixture add candidate.txt
    run_scan 0 --staged
done
printf '00112233-4455-6677-8899-123456789012 %s\n' "$account" >candidate.txt
git_fixture add candidate.txt
run_scan 1 --staged
contains_output 'AWS account ID'

# New files are scanned completely and findings never include the value.
new_repository
for ((line = 0; line < 300; line++)); do printf 'safe\n'; done >private.txt
printf '%s\n' "$key" >>private.txt
git_fixture add private.txt
run_scan 1 --staged
contains_output '"private.txt":301:'
absent_value "$key"

# Staged content and unstaged content remain independent.
new_repository
printf '%s\n' "$key" >existing.txt
git_fixture add existing.txt
printf 'safe\n' >existing.txt
run_scan 1 --staged
printf 'safe\n' >existing.txt
git_fixture add existing.txt
printf '%s\n' "$key" >existing.txt
run_scan 0 --staged

# Existing private-looking lines are excluded unless they are added again.
new_repository
printf '%s\nold\n' "$key" >existing.txt
commit_fixture
printf '%s\nnew\n' "$key" >existing.txt
git_fixture add existing.txt
run_scan 0 --staged
printf '%s\nnew\n%s\n' "$key" "$account" >existing.txt
git_fixture add existing.txt
run_scan 1 --staged
contains_output '"existing.txt":3:'
absent_value "$account"
new_repository
printf '%s\n' "$key" >old.txt
commit_fixture
rm old.txt
git_fixture add --all
run_scan 0 --staged

# Range mode reads immutable trees, regardless of index/working-tree contents.
new_repository
base="$(git_fixture rev-parse HEAD)"
printf '%s\n' "$key" >private.txt
commit_fixture
head="$(git_fixture rev-parse HEAD)"
printf 'safe\n' >private.txt
git_fixture add private.txt
run_scan 1 --base "$base" --head "$head"
absent_value "$key"
run_scan 1 "--base=$base" "--head=$head"
empty_tree="$(git_fixture hash-object -t tree --stdin < /dev/null)"
run_scan 1 --base "$empty_tree"

new_repository
mkdir .aws
: >.aws/credentials
git_fixture add .aws/credentials
run_scan 1 --staged
contains_output 'AWS credential/config/cache file'

new_repository
printf '\0%s' "$key" >artifact.bin
git_fixture add artifact.bin
run_scan 1 --staged
commit_fixture
printf '\0%s\0changed' "$key" >artifact.bin
git_fixture add artifact.bin
run_scan 1 --staged

new_repository
odd_name=$'space\tand\nnewline.txt'
printf '%s\n' "$key" >"$odd_name"
git_fixture add --all
run_scan 1 --staged
contains_output '"space\tand\nnewline.txt":1:'
new_repository
printf 'old\n' >'literal[1].txt'
commit_fixture
printf '%s\n' "$key" >'literal[1].txt'
git_fixture add --all
run_scan 1 --staged
run_scan 2 --base does-not-exist
run_scan 2 --staged --head HEAD
run_scan 2
run_scan 0 --help

# A rejected commit preserves both HEAD and the index. Check privacy first so
# whitespace diagnostics cannot print a credential with trailing spaces.
new_repository
mkdir .githooks scripts
cp "$ROOT/.githooks/pre-commit" .githooks/pre-commit
cp "$CHECKER" scripts/check_aws_privacy.sh
chmod +x .githooks/pre-commit
git_fixture config core.hooksPath .githooks
printf '%s  \n' "$key" >existing.txt
git_fixture add existing.txt
before_head="$(git_fixture rev-parse HEAD)"
before_index="$(git_fixture show :existing.txt)"
if git -c user.name='Privacy Test' -c user.email=test@example.invalid \
    -c commit.gpgsign=false commit -m 'must fail' >"$output" 2>&1; then
    fail_test 'hook accepted a private value'
fi
[ "$(git_fixture rev-parse HEAD)" = "$before_head" ] || fail_test 'hook changed HEAD'
[ "$(git_fixture show :existing.txt)" = "$before_index" ] || fail_test 'hook changed the index'
absent_value "$key"
checks=$((checks + 1))
printf 'AWS privacy tests passed (%s checks).\n' "$checks"
