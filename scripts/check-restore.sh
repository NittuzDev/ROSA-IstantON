#!/usr/bin/env bash
# Fail unless the release resumed from an InstantOn checkpoint.
# Usage: scripts/check-restore.sh [namespace] [helm-release]
set -euo pipefail

NS="${1:-instanton-demo}"
RELEASE="${2:-instanton-demo}"
EXPECTED_SCC="${EXPECTED_SCC:-scc-cap-cr}"

if ! command -v oc >/dev/null 2>&1; then
  echo "oc is required" >&2
  exit 1
fi

PODS="$(oc get pods -n "${NS}" -l "app=${RELEASE}" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}')"
if [[ -z "${PODS// /}" ]]; then
  echo "FAIL: no pods in namespace ${NS} for Helm release ${RELEASE}" >&2
  exit 1
fi

fail=0
for POD in ${PODS}; do
  echo "=== ${POD} ==="
  PHASE="$(oc get pod -n "${NS}" "${POD}" -o jsonpath='{.status.phase}')"
  READY="$(oc get pod -n "${NS}" "${POD}" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}')"
  SCC="$(oc get pod -n "${NS}" "${POD}" -o jsonpath='{.metadata.annotations.openshift\.io/scc}')"
  echo "phase=${PHASE} ready=${READY:-unknown} scc=${SCC:-<none>}"

  if [[ "${SCC}" != "${EXPECTED_SCC}" ]]; then
    echo "FAIL: pod was admitted by '${SCC:-<none>}', expected ${EXPECTED_SCC}"
    fail=1
  fi

  LOGS="$(oc logs -n "${NS}" "${POD}" 2>/dev/null || true)"
  if [[ -z "${LOGS}" ]]; then
    LOGS="$(oc logs -n "${NS}" "${POD}" --previous 2>/dev/null || true)"
    echo "(current logs are empty; showing the previous container)"
  fi

  printf '%s\n' "${LOGS}" | grep -E 'CWWKC0452I|CWWKF0011I|CWWKE0961I|Operation not permitted|clone3|ptrace|vmsplice' || true

  if printf '%s\n' "${LOGS}" | grep -q 'CWWKE0961I'; then
    echo "FAIL: CRIU restore failed (CWWKE0961I)"
    fail=1
  elif printf '%s\n' "${LOGS}" | grep -q 'CWWKC0452I'; then
    echo "PASS: process resumed from a checkpoint"
    printf '%s\n' "${LOGS}" | grep 'CWWKC0452I' || true
    printf '%s\n' "${LOGS}" | grep 'CWWKF0011I' || true
  else
    echo "FAIL: log has no CWWKC0452I resume message"
    fail=1
  fi
  echo
done

ROUTE="$(oc get route -n "${NS}" -l "app=${RELEASE}" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)"
if [[ -n "${ROUTE}" ]]; then
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is not installed; skipped https://${ROUTE}/status"
  else
    echo "=== GET https://${ROUTE}/status ==="
    if ! curl -fsS "https://${ROUTE}/status"; then
      echo
      echo "FAIL: /status did not return HTTP 200"
      fail=1
    else
      echo
    fi
  fi
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "InstantOn test failed."
  exit 1
fi

echo "InstantOn test passed."
