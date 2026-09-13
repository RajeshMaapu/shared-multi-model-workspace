#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p docs/evidence/phase1
swift test 2>&1 | sed -e "s#$PWD#<repo>#g" -e "s#$HOME#<home>#g" \
    | tee docs/evidence/phase1/test-output.txt
