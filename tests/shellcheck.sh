#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Separate processes bound memory as the test suite grows. tests/run.sh skips
# test imports for ShellCheck only; every test file is checked directly here.
# Keep -x for real library dependencies and report all files even after errors.
status=0
for file in bin/* lib/*.sh install.sh config.example.sh tests/*.sh tests/fixtures/*; do
  shellcheck -x "$file" || status=$?
done
exit "$status"
