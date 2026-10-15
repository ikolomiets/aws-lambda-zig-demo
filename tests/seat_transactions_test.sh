#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image='amazon/dynamodb-local:3.3.0@sha256:d89f8fcc6b1a39cb35976c248ed42a28c66ae00dc043099210f5571e42648ab4'
keep=false
case "${1:-}" in
    '') ;;
    --keep) keep=true ;;
    *) printf 'Usage: %s [--keep]\n' "$0" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then printf 'Unexpected arguments.\n' >&2; exit 2; fi
for tool in docker curl zig; do
    command -v "$tool" >/dev/null || { printf 'Missing prerequisite: %s\n' "$tool" >&2; exit 2; }
done
docker image inspect "$image" >/dev/null 2>&1 || {
    printf 'Provision the pinned test image first:\n  docker pull %s\n' "$image" >&2
    exit 2
}
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/seat-transactions.XXXXXX")"
container_id=''
cleanup() {
    status=$?
    if [ -n "$container_id" ]; then
        docker logs "$container_id" >"$fixture_dir/service.log" 2>&1 || true
        if [ "$keep" = true ]; then
            printf 'Preserved local fixture: %s\nContainer: %s\nEndpoint: %s\n' \
                "$fixture_dir" "$container_id" "${SEAT_TRANSACTION_ENDPOINT:-unavailable}"
            printf 'Cleanup: docker rm --force %s\n' "$container_id"
        else
            docker rm --force "$container_id" >/dev/null || true
        fi
    fi
    if [ "$keep" = false ] && [ "$status" -eq 0 ]; then rm -rf -- "$fixture_dir"; fi
    if [ "$status" -ne 0 ]; then printf 'Failure logs: %s\n' "$fixture_dir" >&2; fi
}
trap cleanup EXIT
container_id="$(docker run --detach --publish 127.0.0.1::8000 "$image" \
    -jar DynamoDBLocal.jar -sharedDb -disableTelemetry)"
binding="$(docker port "$container_id" 8000/tcp)"
case "$binding" in 127.0.0.1:*) ;; *) printf 'Unexpected local binding.\n' >&2; exit 1 ;; esac
export SEAT_TRANSACTION_ENDPOINT="http://$binding"
ready=false
for ((attempt=0; attempt<60; attempt++)); do
    if curl --silent --max-time 1 --output /dev/null "$SEAT_TRANSACTION_ENDPOINT"; then
        ready=true
        break
    fi
    sleep 1
done
if [ "$ready" = false ]; then printf 'Local service startup deadline exceeded.\n' >&2; exit 1; fi
printf 'DynamoDB Local 3.3.0 at %s\n' "$SEAT_TRANSACTION_ENDPOINT"
cd "$repository_root"
zig build test-seat-transactions --system "${CHECK_ZIG_PACKAGE_DIR:-zig-pkg}" \
    >"$fixture_dir/tests.log" 2>&1 || { cat "$fixture_dir/tests.log"; exit 1; }
cat "$fixture_dir/tests.log"
printf 'Local SDK transaction checks passed.\n'
