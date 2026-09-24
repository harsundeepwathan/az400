#!/usr/bin/env bash
# Starts/stops a disposable local PostgreSQL cluster for development and tests.
# Uses the PostgreSQL binaries already on this machine (15+). If you have Docker,
# `docker compose up -d db` is an equivalent alternative.
set -euo pipefail

PORT="${LOCAL_PG_PORT:-54329}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="${LOCAL_PG_DATA:-$ROOT/.data/postgres}"
LOG_FILE="$ROOT/.data/postgres.log"

find_bin() {
  if command -v "$1" >/dev/null 2>&1; then command -v "$1"; return; fi
  for dir in /usr/lib/postgresql/*/bin /opt/homebrew/opt/postgresql@*/bin /usr/local/opt/postgresql@*/bin; do
    if [ -x "$dir/$1" ]; then echo "$dir/$1"; return; fi
  done
  echo "Could not find '$1'. Install PostgreSQL 15+ or use 'docker compose up -d db'." >&2
  exit 1
}

INITDB="$(find_bin initdb)"
PG_CTL="$(find_bin pg_ctl)"

# PostgreSQL refuses to run as root; fall back to the 'postgres' system user.
run() {
  if [ "$(id -u)" = "0" ]; then
    su postgres -s /bin/bash -c "$*"
  else
    bash -c "$*"
  fi
}

case "${1:-start}" in
  start)
    mkdir -p "$(dirname "$DATA_DIR")"
    if [ "$(id -u)" = "0" ]; then chown -R postgres "$(dirname "$DATA_DIR")"; fi
    if [ ! -f "$DATA_DIR/PG_VERSION" ]; then
      run "'$INITDB' -D '$DATA_DIR' -U postgres --auth=trust --encoding=UTF8 >/dev/null"
    fi
    if run "'$PG_CTL' -D '$DATA_DIR' status" >/dev/null 2>&1; then
      echo "Local PostgreSQL already running on port $PORT"
    else
      run "'$PG_CTL' -D '$DATA_DIR' -l '$LOG_FILE' -o '-p $PORT -k /tmp -c listen_addresses=127.0.0.1' -w start" >/dev/null
      echo "Local PostgreSQL started on port $PORT"
    fi
    run "psql -h 127.0.0.1 -p $PORT -U postgres -tAc \"select 1 from pg_database where datname='jobpilot'\"" | grep -q 1 \
      || run "psql -h 127.0.0.1 -p $PORT -U postgres -c 'create database jobpilot' >/dev/null"
    ;;
  stop)
    run "'$PG_CTL' -D '$DATA_DIR' -m fast stop" || true
    ;;
  *)
    echo "usage: $0 start|stop" >&2; exit 1 ;;
esac
