#!/usr/bin/env bash
# Run only against a fresh replica created here, never an existing listening service.
set -euo pipefail

repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
server=${1:?Usage: bash tests/tigerbeetle_isolated_test.sh /absolute/server verified-sha256}
server_sha256=${2:?Supply the checksum of a server built from the documented intended commit}
[[ "$server" = /* && -x "$server" ]]
[[ "$server_sha256" =~ ^[0-9a-f]{64}$ ]]
[[ $(shasum -a 256 "$server" | awk '{print $1}') = "$server_sha256" ]]
version=$("$server" version)
[[ "$version" = 'TigerBeetle version 65535.0.0+97c7a8e' ]]
package="$repository/zig-pkg/tigerbeetle_c_artifacts-65535.0.0+g97c7a8ef3.pr3695-fTLGi0aNGQC3xlGJoqTt6DVm9fZPGoBrSKcdqoZZgjNd"
rg -q '97c7a8ef385270ebe0e1b75959d3d21d134629df' "$package/PROVENANCE.md"
rg -q 'e9bb4085cb18500e37df9714b3eea1cc3f7b6d4e' "$package/PROVENANCE.md"
(cd "$package" && shasum -a 256 -c SHA256SUMS)
printf '%s\nserver_sha256=%s\n' "$version" "$server_sha256"
uname -sm
zig version

fixture=$(mktemp -d "${TMPDIR:-/tmp}/tigerbeetle-fixture.XXXXXXXX")
server_pid=
test_pid=
cleanup() {
    # Even when the runner is signaled, finish the client process before deleting its replica.
    trap '' INT TERM
    if [[ -n "$test_pid" ]]; then
        wait "$test_pid" 2>/dev/null || true
    fi
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$server" format --cluster=0 --replica=0 --replica-count=1 "$fixture/0_0.tigerbeetle"
port=33171
"$server" start --addresses="127.0.0.1:$port" --cache-grid=64MiB \
    "$fixture/0_0.tigerbeetle" >"$fixture/server.log" 2>&1 &
server_pid=$!
ready=false
for ((attempt=0; attempt<100; attempt++)); do
    if ! kill -0 "$server_pid" 2>/dev/null; then
        cat "$fixture/server.log"
        exit 1
    fi
    # Attribute the listener to our child, not merely to the port.
    if lsof -nP -a -p "$server_pid" -iTCP:"$port" -sTCP:LISTEN >/dev/null; then
        ready=true
        break
    fi
    sleep 0.1
done
if [[ "$ready" != true ]]; then
    cat "$fixture/server.log"
    exit 1
fi
cd "$repository"
TIGERBEETLE_TEST_OWNED=fresh-local-cluster TIGERBEETLE_ADDRESSES="127.0.0.1:$port" \
    zig build test-tigerbeetle &
test_pid=$!
wait "$test_pid"
