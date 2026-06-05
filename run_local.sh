#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "${SCRIPT_DIR}"

PIDS=()
TMP_BIN_DIR=""
LOG_DIR=$(mktemp -d /tmp/agenticflaw-run-local-XXXXXX)

cleanup() {
  local exit_code=$?
  if ((${#PIDS[@]})); then
    echo "Stopping running services..."
    for pid in "${PIDS[@]}"; do
      kill "${pid}" 2>/dev/null || true
    done
    wait "${PIDS[@]}" 2>/dev/null || true
  fi
  if [[ -n "${TMP_BIN_DIR}" && -d "${TMP_BIN_DIR}" ]]; then
    rm -rf "${TMP_BIN_DIR}"
  fi
  if [[ ${exit_code} -ne 0 ]]; then
    echo "Startup failed. Service logs are in: ${LOG_DIR}"
  fi
  exit "${exit_code}"
}
trap cleanup EXIT INT TERM

fail() {
  echo "Error: $1" >&2
  exit 1
}

resolve_uv_bin() {
  if command -v uv >/dev/null 2>&1; then
    echo "uv"
    return
  fi
  if [[ -x "${HOME}/.local/bin/uv" ]]; then
    echo "${HOME}/.local/bin/uv"
    return
  fi
  fail "uv is not installed. Install it first: python3 -m pip install --user uv"
}

ensure_gcloud_for_local_auth() {
  if command -v gcloud >/dev/null 2>&1; then
    return
  fi
  if [[ -x "${SCRIPT_DIR}/fake-gcloud" ]]; then
    TMP_BIN_DIR=$(mktemp -d /tmp/agenticflaw-gcloud-XXXXXX)
    ln -s "${SCRIPT_DIR}/fake-gcloud" "${TMP_BIN_DIR}/gcloud"
    export PATH="${TMP_BIN_DIR}:${PATH}"
    echo "gcloud not found; using bundled fake-gcloud for local token calls."
    return
  fi
  fail "gcloud is not installed and fake-gcloud fallback is unavailable."
}

validate_runtime_env() {
  local use_vertex="${GOOGLE_GENAI_USE_VERTEXAI:-false}"

  export GOOGLE_CLOUD_LOCATION="${GOOGLE_CLOUD_LOCATION:-global}"

  if [[ "${use_vertex}" == "True" || "${use_vertex}" == "true" ]]; then
    command -v gcloud >/dev/null 2>&1 || fail "GOOGLE_GENAI_USE_VERTEXAI=true requires gcloud."
    local configured_project
    configured_project=$(gcloud config get-value project 2>/dev/null || true)
    if [[ -z "${configured_project}" || "${configured_project}" == "(unset)" ]]; then
      fail "No active gcloud project found. Run: gcloud config set project <PROJECT_ID>"
    fi
    export GOOGLE_CLOUD_PROJECT="${GOOGLE_CLOUD_PROJECT:-${configured_project}}"
  else
    export GOOGLE_GENAI_USE_VERTEXAI="false"
    if [[ -n "${GEMINI_API_KEY:-}" && -z "${GOOGLE_API_KEY:-}" ]]; then
      export GOOGLE_API_KEY="${GEMINI_API_KEY}"
    fi
    if [[ -z "${GOOGLE_API_KEY:-}" ]]; then
      fail "Set GOOGLE_API_KEY (or GEMINI_API_KEY), or set GOOGLE_GENAI_USE_VERTEXAI=true with gcloud configured."
    fi
  fi
}

stop_existing_ports() {
  echo "Stopping existing processes on ports 8000-8004..."
  if command -v lsof >/dev/null 2>&1; then
    mapfile -t port_pids < <(lsof -ti:8000,8001,8002,8003,8004 2>/dev/null || true)
    if ((${#port_pids[@]})); then
      kill "${port_pids[@]}" 2>/dev/null || true
      sleep 1
    fi
  fi
}

start_service() {
  local name="$1"
  shift
  local log_file="${LOG_DIR}/${name// /_}.log"

  echo "Starting ${name}..."
  bash -c "$*" >"${log_file}" 2>&1 &
  local pid=$!
  PIDS+=("${pid}")

  sleep 1
  if ! kill -0 "${pid}" 2>/dev/null; then
    echo "----- ${name} log -----" >&2
    cat "${log_file}" >&2 || true
    fail "${name} exited during startup."
  fi
}

wait_for_http() {
  local label="$1"
  local url="$2"
  local retries="${3:-30}"

  for _ in $(seq 1 "${retries}"); do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      echo "${label} is ready: ${url}"
      return 0
    fi
    sleep 1
  done

  fail "${label} did not become ready at ${url}"
}

command -v bash >/dev/null 2>&1 || fail "bash is required."
command -v curl >/dev/null 2>&1 || fail "curl is required."

UV_BIN=$(resolve_uv_bin)
ensure_gcloud_for_local_auth
validate_runtime_env
stop_existing_ports

: "${RESEARCHER_AGENT_CARD_URL:=http://localhost:8001/a2a/agent/.well-known/agent.json}"
: "${JUDGE_AGENT_CARD_URL:=http://localhost:8002/a2a/agent/.well-known/agent.json}"
: "${CONTENT_BUILDER_AGENT_CARD_URL:=http://localhost:8003/a2a/agent/.well-known/agent.json}"
: "${AGENT_SERVER_URL:=http://localhost:8004}"
export RESEARCHER_AGENT_CARD_URL
export JUDGE_AGENT_CARD_URL
export CONTENT_BUILDER_AGENT_CARD_URL
export AGENT_SERVER_URL

start_service "Researcher Agent" "cd \"${SCRIPT_DIR}/agents/researcher\" && \"${UV_BIN}\" run adk_app.py --host 0.0.0.0 --port 8001 --a2a ."
start_service "Judge Agent" "cd \"${SCRIPT_DIR}/agents/judge\" && \"${UV_BIN}\" run adk_app.py --host 0.0.0.0 --port 8002 --a2a ."
start_service "Content Builder Agent" "cd \"${SCRIPT_DIR}/agents/content_builder\" && \"${UV_BIN}\" run adk_app.py --host 0.0.0.0 --port 8003 --a2a ."
start_service "Orchestrator Agent" "cd \"${SCRIPT_DIR}/agents/orchestrator\" && \"${UV_BIN}\" run adk_app.py --host 0.0.0.0 --port 8004 ."
start_service "App Server" "cd \"${SCRIPT_DIR}/app\" && \"${UV_BIN}\" run uvicorn main:app --host 0.0.0.0 --port 8000"

wait_for_http "Researcher agent card" "${RESEARCHER_AGENT_CARD_URL}"
wait_for_http "Judge agent card" "${JUDGE_AGENT_CARD_URL}"
wait_for_http "Content Builder agent card" "${CONTENT_BUILDER_AGENT_CARD_URL}"
wait_for_http "Orchestrator service" "http://localhost:8004/list-apps"
wait_for_http "App server" "http://localhost:8000"

echo "All services are running."
echo "Researcher:      http://localhost:8001"
echo "Judge:           http://localhost:8002"
echo "Content Builder: http://localhost:8003"
echo "Orchestrator:    http://localhost:8004"
echo "App Server:      http://localhost:8000"
echo "Logs directory:  ${LOG_DIR}"
echo ""
echo "Press Ctrl+C to stop all services."

while true; do
  wait -n
  fail "A service exited unexpectedly."
done
