#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/deploy-demo-web-test.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
project="$test_dir/checkout with spaces"
mkdir -p "$test_dir/bin" "$project/demo-web/assets/nested"
cp "$repo_root/deploy-demo-web.sh" "$project/"
printf 'abc' >"$project/demo-web/index.html"
printf 'abc' >"$project/demo-web/style.css"
printf 'export {}' >"$project/demo-web/sign-in.js"
printf '<svg/>' >"$project/demo-web/assets/nested/test mark.svg"
printf 'Internal notes' >"$project/demo-web/README.md"
ln -s ../README.md "$project/demo-web/assets/notes.txt"

cat >"$test_dir/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == --disable ]]
[[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]
body= content_type=
forms=()
while [[ $# -gt 1 ]]; do
    case "$1" in
        --disable|--silent|--show-error) shift ;;
        --proto|--connect-timeout|--max-time|--write-out) shift 2 ;;
        --output) output="$2"; shift 2 ;;
        --header)
            case "$2" in
                @-) IFS= read -r authorization ;;
                'Content-Type: application/json') content_type=json ;;
                *) exit 90 ;;
            esac
            shift 2 ;;
        --data-binary) body="${2#@}"; shift 2 ;;
        --form) forms+=("$2"); shift 2 ;;
        *) exit 90 ;;
    esac
done
prefix="https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/"
[[ "$1" == "$prefix"* ]]
path="${1#"$prefix"}"
case "$path" in
    scripts/electrit-demo/settings)
        printf 'settings\n' >>"$CURL_LOG"
        [[ "$authorization" == 'Authorization: Bearer fixture-api-token' && -z "$body" ]]
        if [[ "$SCENARIO" == missing-worker ]]; then
            printf '{"success":false,"errors":[{"code":10092}]}' >"$output"
            printf 404
            exit 0
        fi
        printf '{"success":true,"result":{"compatibility_date":"2026-11-25T00:00:00Z","compatibility_flags":["fixture_flag"]}}' >"$output"
        ;;
    scripts/electrit-demo/assets-upload-session)
        printf 'session\n' >>"$CURL_LOG"
        [[ "$authorization" == 'Authorization: Bearer fixture-api-token' && "$content_type" == json ]]
        jq -e --arg html "$HTML_HASH" --arg css "$CSS_HASH" '
            .manifest | keys == ["/assets/nested/test mark.svg", "/index.html", "/sign-in.js", "/style.css"]
            and .["/index.html"] == {hash: $html, size: 3}
            and .["/style.css"] == {hash: $css, size: 3}
        ' "$body" >/dev/null
        svg_hash="$(jq -er '.manifest["/assets/nested/test mark.svg"].hash' "$body")"
        printf '%s\n' "$svg_hash" >"$CURL_LOG.svg"
        case "$SCENARIO" in
            cached) printf '{"success":true,"result":{"jwt":"cached-completion-token","buckets":[]}}' >"$output" ;;
            unknown-hash) printf '{"success":true,"result":{"jwt":"session-token","buckets":[["ffffffffffffffffffffffffffffffff"]]}}' >"$output" ;;
            *) jq -n --arg html "$HTML_HASH" --arg css "$CSS_HASH" --arg svg "$svg_hash" \
                '{success: true, result: {jwt: "session-token", buckets: [[$html, $css], [$svg]]}}' >"$output" ;;
        esac
        ;;
    'assets/upload?base64=true')
        printf 'upload\n' >>"$CURL_LOG"
        [[ "$authorization" == 'Authorization: Bearer session-token' && -z "$body" ]]
        if [[ "${forms[0]}" == "$HTML_HASH"=* ]]; then
            [[ "${#forms[@]}" -eq 2 ]]
            [[ "${forms[0]}" == "$HTML_HASH=@$HTML_HASH;type=text/html" ]]
            [[ "${forms[1]}" == "$CSS_HASH=@$CSS_HASH;type=text/css" ]]
            [[ "$(<"$HTML_HASH")" == YWJj && "$(<"$CSS_HASH")" == YWJj ]]
            printf '{"success":true,"result":null}' >"$output"
        else
            svg_hash="$(<"$CURL_LOG.svg")"
            [[ "${#forms[@]}" -eq 1 && "${forms[0]}" == "$svg_hash=@$svg_hash;type=image/svg+xml" ]]
            [[ "$(<"$svg_hash")" == PHN2Zy8+ ]]
            case "$SCENARIO" in
                upload-error) printf '{"success":false,"errors":[{"code":10001}]}' >"$output" ;;
                incomplete) printf '{"success":true,"result":{}}' >"$output" ;;
                *) printf '{"success":true,"result":{"jwt":"upload-completion-token"}}' >"$output" ;;
            esac
        fi
        ;;
    'workers/electrit-demo/versions?deploy=true')
        printf 'version\n' >>"$CURL_LOG"
        [[ "$authorization" == 'Authorization: Bearer fixture-api-token' && "$content_type" == json ]]
        completion_token=upload-completion-token
        if [[ "$SCENARIO" == cached ]]; then completion_token=cached-completion-token; fi
        jq -e --arg token "$completion_token" '
            . == {compatibility_date: "2026-11-25", compatibility_flags: ["fixture_flag"], assets: {jwt: $token}}
        ' "$body" >/dev/null
        printf '{"success":true,"result":{"id":"fixture-version"}}' >"$output"
        ;;
    *) exit 91 ;;
esac
printf 200
MOCK
chmod +x "$test_dir/bin/curl"
export PATH="$test_dir/bin:$PATH" CURL_LOG="$test_dir/calls"
export CLOUDFLARE_ACCOUNT_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa CLOUDFLARE_API_TOKEN=fixture-api-token
HTML_HASH="$(printf YWJjhtml | shasum -a 256 | cut -c 1-32)"
CSS_HASH="$(printf YWJjcss | shasum -a 256 | cut -c 1-32)"
export HTML_HASH CSS_HASH

run_deploy() {
    : >"$CURL_LOG"
    "$project/deploy-demo-web.sh" "$@" >actual 2>&1
}

assert_calls() {
    printf '%s\n' "$@" | diff -u - "$CURL_LOG"
}

cd "$test_dir"
run_deploy --help
[[ ! -s "$CURL_LOG" ]]
if CLOUDFLARE_API_TOKEN='' run_deploy; then exit 1; fi
[[ ! -s "$CURL_LOG" && "$(<actual)" == *CLOUDFLARE_API_TOKEN* ]]

SCENARIO=upload run_deploy
assert_calls settings session upload upload version
[[ "$(<actual)" == 'Deployed electrit-demo version fixture-version.' ]]

SCENARIO=cached run_deploy
assert_calls settings session version

if SCENARIO=missing-worker run_deploy; then exit 1; fi
assert_calls settings
[[ "$(<actual)" == *'HTTP 404, Cloudflare errors 10092'* ]]

if SCENARIO=unknown-hash run_deploy; then exit 1; fi
assert_calls settings session
[[ "$(<actual)" == *'unknown asset hash'* ]]

if SCENARIO=incomplete run_deploy; then exit 1; fi
assert_calls settings session upload upload
[[ "$(<actual)" == *'no asset completion token'* ]]

if SCENARIO=upload-error run_deploy; then exit 1; fi
assert_calls settings session upload upload
[[ "$(<actual)" == *'HTTP 200, Cloudflare errors 10001'* ]]
printf '%s\n' 'Demo web deployment checks passed.'
