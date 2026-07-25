#!/usr/bin/env bash
#
# Rehearse what the desktop shell does, without the desktop shell.
#
# The risky part of packaging is not the Rust: it is the handshake
# between a launcher and a BEAM that picks its own port. This script
# performs exactly that handshake against a real release, so the sequence
# can be proven before any of it is written twice.
#
#   start the release  ->  wait for the address file  ->  open the url
#                      ->  terminate  ->  check nothing was left behind
#
# Usage: desktop/verify-launch.sh [path/to/release/root]

set -uo pipefail

RELEASE="${1:-_build/prod/rel/mnemo}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-40}"

if [ ! -x "$RELEASE/bin/mnemo" ]; then
  echo "no release at $RELEASE — run: MIX_ENV=prod mix assets.deploy && MIX_ENV=prod mix release" >&2
  exit 1
fi

# Everything the run touches goes here, so a rehearsal never writes to
# the data directory of an installed copy.
WORK="$(mktemp -d)"
ADDRESS="$WORK/xdg/mnemo/endpoint.json"
trap 'rm -rf "$WORK"' EXIT

pass() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=1; }
FAILED=0

echo "release: $RELEASE"
echo

# `start` runs in the foreground, which is what a launcher wants from a
# child process. RELEASE_DISTRIBUTION=none keeps epmd out of the bundle;
# the cost is that `bin/mnemo stop` and `rpc` stop working, so shutdown
# below is a signal rather than a command.
PHX_SERVER=true \
RELEASE_DISTRIBUTION=none \
MNEMO_FAKE_DRIVE="${MNEMO_FAKE_DRIVE:-1}" \
DATABASE_PATH="$WORK/mnemo.db" \
XDG_DATA_HOME="$WORK/xdg" \
  "$RELEASE/bin/mnemo" start >"$WORK/out.log" 2>&1 &
CHILD=$!

# The BEAM takes seconds to boot and migrate, so the launcher polls for
# the address instead of assuming a delay.
waited=0
while [ ! -f "$ADDRESS" ]; do
  if ! kill -0 "$CHILD" 2>/dev/null; then
    fail "the release exited during boot"
    sed 's/^/        /' "$WORK/out.log" | tail -20
    exit 1
  fi
  if [ "$waited" -ge "$BOOT_TIMEOUT" ]; then
    fail "no address published within ${BOOT_TIMEOUT}s"
    sed 's/^/        /' "$WORK/out.log" | tail -20
    exit 1
  fi
  sleep 1
  waited=$((waited + 1))
done
pass "address published after ${waited}s"

URL="$(sed -n 's/.*"url":"\([^"]*\)".*/\1/p' "$ADDRESS")"
PORT="$(sed -n 's/.*"port":\([0-9]*\).*/\1/p' "$ADDRESS")"

if [ -n "$URL" ]; then pass "url: $URL"; else fail "no url in $ADDRESS"; fi

# Port 0 means the OS chose it, so a fixed number here would be a bug.
if [ "$PORT" != "4000" ] && [ "$PORT" -gt 1024 ]; then
  pass "port was assigned by the OS, not hard-coded"
else
  fail "unexpected port $PORT"
fi

for path in / /enroll /settings; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "$URL$path")"
  if [ "$code" = "200" ]; then pass "$path -> $code"; else fail "$path -> $code"; fi
done

# The database is created by the migrations that run at boot; a release
# has no Mix to run them any other way.
if [ -f "$WORK/mnemo.db" ]; then
  pass "database created and migrated at boot"
else
  fail "no database at $WORK/mnemo.db"
fi

# A window closing sends a signal, not an rpc. If the BEAM does not shut
# down gracefully here, the address file outlives the process and the
# next launch reads a port that belongs to something else.
kill -TERM "$CHILD" 2>/dev/null
waited=0
while kill -0 "$CHILD" 2>/dev/null && [ "$waited" -lt 15 ]; do
  sleep 1
  waited=$((waited + 1))
done

if kill -0 "$CHILD" 2>/dev/null; then
  fail "still running 15s after SIGTERM"
  kill -KILL "$CHILD" 2>/dev/null
else
  pass "shut down on SIGTERM after ${waited}s"
fi

if [ -f "$ADDRESS" ]; then
  fail "address file outlived the process: $ADDRESS"
else
  pass "address file removed on shutdown"
fi

echo
if [ "$FAILED" = "0" ]; then
  echo "the launch cycle works end to end"
else
  echo "something in the launch cycle is broken" >&2
fi
exit "$FAILED"
