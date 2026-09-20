#!/bin/sh
set -eu

APP="${1:?usage: scripts/test-cua-host-lifecycle.sh /absolute/path/Perry.app}"
EXECUTABLE="${APP}/Contents/MacOS/Perry"
[ "${APP#/}" != "${APP}" ]
[ -x "${EXECUTABLE}" ]

RUN_DIRECTORY=$(mktemp -d /tmp/perry-cua-lifecycle.XXXXXX)
HOST_PID=""
WORKER_PID=""

cleanup() {
  if [ -n "${HOST_PID}" ] && kill -0 "${HOST_PID}" 2>/dev/null; then
    kill -KILL "${HOST_PID}" 2>/dev/null || true
  fi
  if [ -n "${WORKER_PID}" ] && kill -0 "${WORKER_PID}" 2>/dev/null; then
    kill -TERM "${WORKER_PID}" 2>/dev/null || true
  fi
  rm -r "${RUN_DIRECTORY}"
}
trap cleanup EXIT INT TERM

PERRY_PERFORMANCE_EVENT_LOG="${RUN_DIRECTORY}/events.jsonl" "${EXECUTABLE}" >"${RUN_DIRECTORY}/stdout" 2>"${RUN_DIRECTORY}/stderr" &
HOST_PID=$!

attempt=0
while [ "${attempt}" -lt 100 ]; do
  WORKER_PID=$(/usr/bin/pgrep -P "${HOST_PID}" -f 'cua-driver mcp --direct --embedded' | head -1 || true)
  if [ -n "${WORKER_PID}" ]; then
    break
  fi
  if ! kill -0 "${HOST_PID}" 2>/dev/null; then
    echo "Perry exited before starting its Cua worker" >&2
    exit 1
  fi
  sleep 0.05
  attempt=$((attempt + 1))
done

if [ -z "${WORKER_PID}" ]; then
  echo "Perry did not start its direct Cua worker" >&2
  exit 1
fi

kill -KILL "${HOST_PID}"
wait "${HOST_PID}" 2>/dev/null || true
HOST_PID=""

attempt=0
while kill -0 "${WORKER_PID}" 2>/dev/null && [ "${attempt}" -lt 50 ]; do
  sleep 0.05
  attempt=$((attempt + 1))
done

if kill -0 "${WORKER_PID}" 2>/dev/null; then
  echo "Cua worker survived Perry's forced termination" >&2
  exit 1
fi

WORKER_PID=""
echo "Cua worker exited with its host"
