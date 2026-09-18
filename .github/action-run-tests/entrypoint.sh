#!/bin/sh

set -eu

echo "🎌 Running LRR Test Suite 🎌"

mkdir -p log database
chown -R koyomi:koyomi log database
s6-setuidgid koyomi valkey-server tools/build/docker/redis.conf &
valkey_pid=$!

cleanup() {
    status=$?
    trap - EXIT
    kill "$valkey_pid" 2>/dev/null || true
    wait "$valkey_pid" 2>/dev/null || true
    exit "$status"
}
trap cleanup EXIT

attempt=0
until valkey-cli ping >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 50 ]; then
        echo "Valkey did not become ready" >&2
        exit 1
    fi
    sleep 0.1
done

# Run the perl tests on the repo
prove -I /home/koyomi/perl5/lib/perl5 -r -l -v tests/
