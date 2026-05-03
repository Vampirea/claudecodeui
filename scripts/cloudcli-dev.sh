#!/usr/bin/env bash
# Allow users to run this file with `sh scripts/cloudcli-dev.sh ...`.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# Local development helper for CloudCLI UI.
#
# Usage:
#   ./scripts/cloudcli-dev.sh start [dev|prod]
#   ./scripts/cloudcli-dev.sh stop [dev|prod|all]
#   ./scripts/cloudcli-dev.sh restart [dev|prod]
#   ./scripts/cloudcli-dev.sh status
#   ./scripts/cloudcli-dev.sh logs [dev|prod|server|client]
#
# Dev mode starts backend and Vite separately so they can be stopped reliably.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$ROOT_DIR/.dev-runtime"
DEV_SERVER_PID_FILE="$RUNTIME_DIR/dev-server.pid"
DEV_CLIENT_PID_FILE="$RUNTIME_DIR/dev-client.pid"
PROD_PID_FILE="$RUNTIME_DIR/prod.pid"
DEV_SERVER_LOG_FILE="$RUNTIME_DIR/dev-server.log"
DEV_CLIENT_LOG_FILE="$RUNTIME_DIR/dev-client.log"
PROD_LOG_FILE="$RUNTIME_DIR/prod.log"

SERVER_PORT="${SERVER_PORT:-3001}"
VITE_PORT="${VITE_PORT:-5173}"
HOST="${HOST:-localhost}"
START_TIMEOUT="${START_TIMEOUT:-30}"

mkdir -p "$RUNTIME_DIR"

usage() {
  cat <<USAGE
CloudCLI UI local helper

Usage:
  $0 start [dev|prod]      Start app in background. Default: dev
  $0 stop [dev|prod|all]   Stop app. Default: all
  $0 restart [dev|prod]    Restart app. Default: dev
  $0 status                Show processes and URLs
  $0 logs [dev|prod|server|client]
                            Tail logs. Default: dev
  $0 help                  Show this help

Modes:
  dev   tsx server/index.js + vite
        Frontend: http://$HOST:$VITE_PORT
        Backend:  http://$HOST:$SERVER_PORT

  prod  npm run build && npm run server
        App:      http://$HOST:$SERVER_PORT

Environment overrides:
  SERVER_PORT=$SERVER_PORT VITE_PORT=$VITE_PORT HOST=$HOST
USAGE
}

pid_alive() {
  local pid="${1:-}"
  [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1
}

port_pids() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    { lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true; } | tr '\n' ' ' | sed 's/[[:space:]]*$//'
  fi
}

wait_for_ports() {
  local deadline=$((SECONDS + START_TIMEOUT))
  local server_pids vite_pids

  while (( SECONDS < deadline )); do
    server_pids="$(port_pids "$SERVER_PORT")"
    vite_pids="$(port_pids "$VITE_PORT")"
    if [[ -n "$server_pids" && -n "$vite_pids" ]]; then
      return 0
    fi
    sleep 1
  done

  return 1
}

wait_for_server_port() {
  local deadline=$((SECONDS + START_TIMEOUT))
  local server_pids

  while (( SECONDS < deadline )); do
    server_pids="$(port_pids "$SERVER_PORT")"
    if [[ -n "$server_pids" ]]; then
      return 0
    fi
    sleep 1
  done

  return 1
}

kill_pid() {
  local pid="${1:-}"
  [[ -z "$pid" ]] && return 0
  kill "$pid" >/dev/null 2>&1 || true
  for _ in {1..20}; do
    if ! pid_alive "$pid"; then
      return 0
    fi
    sleep 0.25
  done
  if pid_alive "$pid"; then
    echo "Process still alive; sending SIGKILL to pid=$pid"
    kill -9 "$pid" >/dev/null 2>&1 || true
  fi
}

read_pid() {
  local file="$1"
  [[ -f "$file" ]] && cat "$file" || true
}

start_process() {
  local name="$1"
  local pid_file="$2"
  local log_file="$3"
  local command="$4"

  local old_pid
  old_pid="$(read_pid "$pid_file")"
  if pid_alive "$old_pid"; then
    echo "Already running ($name), pid=$old_pid"
    return 0
  fi

  echo "Starting $name..."
  echo "Log: $log_file"
  : > "$log_file"

  nohup bash -lc "cd '$ROOT_DIR' && $command" >> "$log_file" 2>&1 &
  local pid=$!
  echo "$pid" > "$pid_file"
}

start_dev() {
  cd "$ROOT_DIR"
  start_process "dev server" "$DEV_SERVER_PID_FILE" "$DEV_SERVER_LOG_FILE" "./node_modules/.bin/tsx --tsconfig server/tsconfig.json server/index.js"
  # CI=true prevents Vite from exiting when started in a non-interactive background shell.
  start_process "dev client" "$DEV_CLIENT_PID_FILE" "$DEV_CLIENT_LOG_FILE" "CI=true ./node_modules/.bin/vite --host 0.0.0.0 --port $VITE_PORT"

  if ! wait_for_ports; then
    echo "Failed to start dev mode within ${START_TIMEOUT}s. Last log lines:" >&2
    echo "--- server log ---" >&2
    tail -n 100 "$DEV_SERVER_LOG_FILE" >&2 || true
    echo "--- client log ---" >&2
    tail -n 100 "$DEV_CLIENT_LOG_FILE" >&2 || true
    stop_dev >/dev/null 2>&1 || true
    exit 1
  fi

  echo "Started dev mode."
  status
}

start_prod() {
  cd "$ROOT_DIR"
  local old_pid
  old_pid="$(read_pid "$PROD_PID_FILE")"
  if pid_alive "$old_pid"; then
    echo "Already running (prod), pid=$old_pid"
    status
    return 0
  fi

  echo "Starting prod mode..."
  echo "Log: $PROD_LOG_FILE"
  : > "$PROD_LOG_FILE"
  nohup bash -lc "cd '$ROOT_DIR' && npm run build && npm run server" >> "$PROD_LOG_FILE" 2>&1 &
  local pid=$!
  echo "$pid" > "$PROD_PID_FILE"

  if wait_for_server_port; then
    echo "Started prod mode, pid=$pid"
    status
  else
    echo "Failed to start prod mode within ${START_TIMEOUT}s. Last log lines:" >&2
    tail -n 100 "$PROD_LOG_FILE" >&2 || true
    rm -f "$PROD_PID_FILE"
    exit 1
  fi
}

start_mode() {
  case "${1:-dev}" in
    dev) start_dev ;;
    prod) start_prod ;;
    *) echo "Unknown mode: $1" >&2; exit 2 ;;
  esac
}

stop_pid_file() {
  local name="$1"
  local pid_file="$2"
  local pid
  pid="$(read_pid "$pid_file")"
  if pid_alive "$pid"; then
    echo "Stopping $name, pid=$pid..."
    kill_pid "$pid"
  else
    echo "Not running ($name)"
  fi
  rm -f "$pid_file"
}

stop_ports() {
  for port in "$@"; do
    local pids
    pids="$(port_pids "$port")"
    [[ -z "$pids" ]] && continue
    echo "Stopping process(es) listening on port $port: $pids"
    for pid in $pids; do
      kill_pid "$pid"
    done
  done
}

stop_dev() {
  stop_pid_file "dev client" "$DEV_CLIENT_PID_FILE"
  stop_pid_file "dev server" "$DEV_SERVER_PID_FILE"
  stop_ports "$VITE_PORT" "$SERVER_PORT"
}

stop_prod() {
  stop_pid_file "prod" "$PROD_PID_FILE"
  stop_ports "$SERVER_PORT"
}

stop_mode() {
  case "${1:-all}" in
    dev) stop_dev ;;
    prod) stop_prod ;;
    all) stop_dev; stop_prod ;;
    *) echo "Unknown mode: $1" >&2; exit 2 ;;
  esac
}

status_line() {
  local name="$1"
  local pid_file="$2"
  local log_file="$3"
  local pid
  pid="$(read_pid "$pid_file")"
  if pid_alive "$pid"; then
    echo "$name: running pid=$pid log=$log_file"
  else
    echo "$name: stopped"
  fi
}

status() {
  echo "Project: $ROOT_DIR"
  status_line "dev server" "$DEV_SERVER_PID_FILE" "$DEV_SERVER_LOG_FILE"
  status_line "dev client" "$DEV_CLIENT_PID_FILE" "$DEV_CLIENT_LOG_FILE"
  status_line "prod" "$PROD_PID_FILE" "$PROD_LOG_FILE"

  local server_pids vite_pids
  server_pids="$(port_pids "$SERVER_PORT")"
  vite_pids="$(port_pids "$VITE_PORT")"
  echo "Ports:"
  echo "  $SERVER_PORT: ${server_pids:-free}"
  echo "  $VITE_PORT: ${vite_pids:-free}"

  echo "URLs:"
  echo "  Dev frontend: http://$HOST:$VITE_PORT"
  echo "  Backend/prod: http://$HOST:$SERVER_PORT"
}

logs() {
  local mode="${1:-dev}"
  case "$mode" in
    dev)
      touch "$DEV_SERVER_LOG_FILE" "$DEV_CLIENT_LOG_FILE"
      tail -n 80 -f "$DEV_SERVER_LOG_FILE" "$DEV_CLIENT_LOG_FILE"
      ;;
    server|dev-server)
      touch "$DEV_SERVER_LOG_FILE"
      tail -n 120 -f "$DEV_SERVER_LOG_FILE"
      ;;
    client|dev-client)
      touch "$DEV_CLIENT_LOG_FILE"
      tail -n 120 -f "$DEV_CLIENT_LOG_FILE"
      ;;
    prod)
      touch "$PROD_LOG_FILE"
      tail -n 120 -f "$PROD_LOG_FILE"
      ;;
    *) echo "Unknown log target: $mode" >&2; exit 2 ;;
  esac
}

case "${1:-help}" in
  start) start_mode "${2:-dev}" ;;
  stop) stop_mode "${2:-all}" ;;
  restart) stop_mode "${2:-dev}"; start_mode "${2:-dev}" ;;
  status) status ;;
  logs) logs "${2:-dev}" ;;
  help|-h|--help) usage ;;
  *) echo "Unknown command: ${1:-}" >&2; usage; exit 2 ;;
esac
