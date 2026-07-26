#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
python3 -m unittest discover -s "$ROOT_DIR/tests/agent" -p 'test_*.py'
