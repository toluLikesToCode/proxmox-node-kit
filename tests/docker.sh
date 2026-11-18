#!/bin/bash
# Builds the test image and runs the suite inside it.
set -euo pipefail
cd "$(dirname "$0")/.."
docker build -q -t node-kit-tests tests >/dev/null
docker run --rm --cap-add NET_ADMIN -v "$PWD:/repo" node-kit-tests
