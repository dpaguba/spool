#!/bin/bash
# Fails when the en and uk Localizable.strings files do not have the same key set.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

keys() {
    plutil -convert json -o - "Resources/$1.lproj/Localizable.strings" \
        | /usr/bin/python3 -I -c 'import json,sys; print("\n".join(sorted(json.load(sys.stdin))))'
}

en="$(keys en)"
uk="$(keys uk)"
if [ "$en" != "$uk" ]; then
    echo "Localizable.strings key sets differ (< en, > uk):" >&2
    diff <(echo "$en") <(echo "$uk") >&2 || true
    exit 1
fi
echo "Localizable.strings: $(echo "$en" | wc -l | tr -d ' ') keys in en and uk, identical"
