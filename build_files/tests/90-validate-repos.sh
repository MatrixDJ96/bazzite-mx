#!/usr/bin/env bash
# The repository gate passes on the finished tree and its self-test fails closed.
set -euo pipefail

validator=$(dirname "$(realpath "$0")")/../90-validate-repos.sh

if bash "$validator" > /dev/null; then
    echo "OK: no enabled third-party repository in the image"
else
    echo "FAIL: 90-validate-repos.sh rejects the finished tree"
fi

if bash "$validator" --self-test > /dev/null; then
    echo "OK: validator self-test refuses the known-bad layouts"
else
    echo "FAIL: validator self-test"
fi
