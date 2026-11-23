#!/usr/bin/env bash
# Build the InstantOn image, or the baseline image used for the comparison.
# Usage: scripts/build-instanton.sh <image-reference> [instanton|baseline]
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: scripts/build-instanton.sh <image-reference> [instanton|baseline]" >&2
  exit 1
fi

IMAGE="$1"
MODE="${2:-instanton}"
FILE="Containerfile"
if [[ "${MODE}" == "baseline" ]]; then
  FILE="Containerfile.baseline"
elif [[ "${MODE}" != "instanton" ]]; then
  echo "Second argument must be instanton or baseline" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

exec sudo podman build \
  --cap-add=CHECKPOINT_RESTORE \
  --cap-add=SYS_PTRACE \
  --cap-add=SETPCAP \
  --security-opt seccomp=unconfined \
  -t "${IMAGE}" \
  -f "${FILE}" \
  .
