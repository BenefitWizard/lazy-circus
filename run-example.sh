#!/usr/bin/env sh
# Load environment variables from .env and run the Example.hs demo executable via stack.
# Usage: ./run-example.sh

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd)
cd "$SCRIPT_DIR"

if [ -f .env ]; then
    printf 'Loading environment from .env\n'
    set -a
    . .env
    set +a
else
    printf '.env file not found, running with existing environment variables\n'
fi

exec stack run example
