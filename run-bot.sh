#!/usr/bin/env sh
# Load environment variables from .env, start docker services, wait for Postgres, and run the bot.
# Usage: ./run-bot.sh

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

printf 'Starting docker services...\n'
docker compose up -d

printf 'Waiting for Postgres to be ready...\n'
until docker exec lazy_postgres pg_isready -U postgres >/dev/null 2>&1; do
    sleep 0.5
done
printf 'Postgres is ready.\n'

exec stack run bot
