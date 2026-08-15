#!/bin/bash
# Builds, signs and runs the live check against the real address book.
#
# The signing is the point. `swift build` leaves a linker-signed binary, which is signed
# by nobody: it has no designated requirement, so TCC never registers it as a subject,
# never prompts, and never logs. Contacts access would sit at "not determined" forever
# and every call would fail with no dialog to explain why. Re-signing ad-hoc gives it a
# cdhash TCC can key on — at the price of a fresh prompt after every rebuild, which is
# the right trade for a tool the owner runs by hand.
#
# What it touches: only contacts and Lists it creates itself, all named `ZZTest …`, all
# deleted before it exits. See the hard rule in CLAUDE.md.
set -euo pipefail

NAME="contacts-live-check"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Building $NAME"
swift build --product "$NAME"

BINARY="$(swift build --product "$NAME" --show-bin-path)/$NAME"
[ -f "$BINARY" ] || { echo "!! no binary at $BINARY" >&2; exit 1; }

# Without this the consent dialog has nothing to show and macOS denies silently.
otool -P "$BINARY" | grep -q NSContactsUsageDescription \
  || { echo "!! NSContactsUsageDescription did not survive linking" >&2; exit 1; }

echo "==> Signing"
codesign --force --sign - "$BINARY" 2>&1 | sed 's/^/    /'
codesign -dv "$BINARY" 2>&1 | grep flags | sed 's/^/    /'

echo "==> Running"
echo
exec "$BINARY"
