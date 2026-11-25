#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf 'deploy-demo-web: %s\n' "$1" >&2
    exit 1
}

cloudflare_request() {
    local step="$1" token="$2" status error_codes
    shift 2
    # Pass the Authorization header on stdin so tokens stay out of command arguments.
    if ! status="$(printf 'Authorization: Bearer %s\n' "$token" |
        curl --disable --silent --show-error --proto '=https' \
            --connect-timeout 15 --max-time 300 --header @- \
            --output response.json --write-out '%{http_code}' "$@")"; then
        fail "$step failed during the HTTP request."
    fi
    if [[ "$status" != 2[0-9][0-9] ]] || ! jq -e '.success == true' response.json >/dev/null 2>&1; then
        error_codes="$(jq -r '[.errors[]?.code | numbers] | join(", ")' response.json 2>/dev/null || :)"
        fail "$step failed (HTTP $status${error_codes:+, Cloudflare errors $error_codes})."
    fi
}

if [[ $# -eq 1 && ( $1 == -h || $1 == --help ) ]]; then
    printf '%s\n' 'Usage: ./deploy-demo-web.sh' \
        'Deploys demo-web to the existing electrit-demo Cloudflare Worker.' \
        'Set CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN before running.'
    exit 0
fi
if [[ $# -ne 0 ]]; then
    printf '%s\n' 'Usage: ./deploy-demo-web.sh' >&2
    exit 2
fi

account_id="${CLOUDFLARE_ACCOUNT_ID:-}"
account_token="${CLOUDFLARE_API_TOKEN:-}"
unset CLOUDFLARE_API_TOKEN
[[ "$account_id" =~ ^[0-9a-fA-F]{32}$ ]] || fail 'Set CLOUDFLARE_ACCOUNT_ID to the 32-character Cloudflare account ID.'
[[ -n "$account_token" && "$account_token" != *$'\n'* && "$account_token" != *$'\r'* ]] ||
    fail 'Set CLOUDFLARE_API_TOKEN to a Cloudflare API token with Workers Scripts Write permission.'
for utility in curl jq file shasum base64; do
    command -v "$utility" >/dev/null 2>&1 || fail "Required command '$utility' is missing."
done

CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/demo-web"
[[ -d assets && ! -L assets ]] || fail 'Missing demo-web/assets directory.'
umask 077
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/demo-web-deploy.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT

# Match the public files selected by .assetsignore. Snapshot each file so the
# manifest and uploads use the same bytes even if the working tree changes.
{
    printf '%s\0' index.html style.css sign-in.js
    find assets -type f -print0
} >"$work_dir/files"
while IFS= read -r -d '' asset; do
    [[ -f "$asset" && ! -L "$asset" ]] || fail "Missing regular asset file: $asset"
    cp -- "$asset" "$work_dir/source"
    size="$(wc -c <"$work_dir/source")"
    base64 <"$work_dir/source" | tr -d '\r\n' >"$work_dir/encoded"

    filename="${asset##*/}"
    extension=''
    if [[ "$filename" == *.* ]]; then extension="${filename##*.}"; fi
    digest="$({ cat "$work_dir/encoded"; printf '%s' "$extension"; } | shasum -a 256)"
    hash="${digest:0:32}"
    case "$extension" in
        html) content_type=text/html ;;
        css) content_type=text/css ;;
        js) content_type=text/javascript ;;
        svg) content_type=image/svg+xml ;;
        woff2) content_type=font/woff2 ;;
        txt) content_type=text/plain ;;
        *) content_type="$(file --brief --mime-type "$work_dir/source")" ;;
    esac
    printf '%s\n' "$content_type" >"$work_dir/$hash.mime"
    mv "$work_dir/encoded" "$work_dir/$hash"
    jq -cn --arg path "/$asset" --arg hash "$hash" --argjson size "$size" \
        '{($path): {hash: $hash, size: $size}}'
done <"$work_dir/files" >"$work_dir/manifest-entries"

cd "$work_dir"
jq -s '{manifest: add}' manifest-entries >manifest.json
worker_name=electrit-demo
workers_url="https://api.cloudflare.com/client/v4/accounts/$account_id/workers"
script_url="$workers_url/scripts/$worker_name"

cloudflare_request 'Reading existing Worker settings' "$account_token" "$script_url/settings"
mv response.json worker-settings.json
cloudflare_request 'Starting asset upload' "$account_token" \
    --header 'Content-Type: application/json' --data-binary @manifest.json "$script_url/assets-upload-session"
upload_token="$(jq -er '.result.jwt | strings | select(length > 0)' response.json)" ||
    fail 'Cloudflare returned no token for the asset upload session.'
buckets="$(jq -er '.result.buckets
    | select(type == "array" and all(.[]; type == "array"
        and all(.[]; type == "string" and test("^[a-f0-9]{32}$"))))
    | map(select(length > 0) | join(" ")) | join("\n")' response.json)" ||
    fail 'Cloudflare returned invalid asset upload buckets.'

completion_token="$upload_token"
if [[ -n "$buckets" ]]; then
    completion_token=''
    while IFS=' ' read -r -a hashes; do
        upload_args=()
        for hash in "${hashes[@]}"; do
            [[ -f "$hash" ]] || fail "Cloudflare requested an unknown asset hash: $hash"
            content_type="$(<"$hash.mime")"
            upload_args+=(--form "$hash=@$hash;type=$content_type")
        done
        cloudflare_request 'Uploading an asset batch' "$upload_token" \
            "${upload_args[@]}" "$workers_url/assets/upload?base64=true"
        batch_token="$(jq -r '.result.jwt | strings' response.json)"
        if [[ -n "$batch_token" ]]; then completion_token="$batch_token"; fi
    done <<<"$buckets"
    [[ -n "$completion_token" ]] || fail 'Cloudflare returned no asset completion token.'
fi

printf '%s' "$completion_token" | jq -Rs --slurpfile settings worker-settings.json '
    . as $jwt | $settings[0].result
    | {compatibility_date: .compatibility_date[:10], compatibility_flags}
    | with_entries(select(.value != null)) + {assets: {jwt: $jwt}}
' >version.json
cloudflare_request 'Deploying the Worker version' "$account_token" \
    --header 'Content-Type: application/json' --data-binary @version.json \
    "$workers_url/workers/$worker_name/versions?deploy=true"
version_id="$(jq -er '.result.id | strings | select(length > 0)' response.json)" ||
    fail 'Cloudflare returned no ID for the deployed Worker version.'
printf 'Deployed %s version %s.\n' "$worker_name" "$version_id"
