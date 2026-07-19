#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

PREFIX="${PREFIX:-${HOME}/.local}"
BIN_DIR="${BIN_DIR:-${PREFIX}/bin}"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
BINARY_NAME="swift-scraper"
BUILD_BINARY="${PROJECT_DIR}/.build/${BUILD_CONFIGURATION}/${BINARY_NAME}"
INSTALL_BINARY="${BIN_DIR}/${BINARY_NAME}"

if ! command -v swift >/dev/null 2>&1; then
  echo "error: Swift が見つかりません。Swift 6.0 以降をインストールしてください。" >&2
  exit 1
fi

echo "Building ${BINARY_NAME} (${BUILD_CONFIGURATION})..."
(
  cd -- "${PROJECT_DIR}"
  swift build -c "${BUILD_CONFIGURATION}"
)

if [[ ! -x "${BUILD_BINARY}" ]]; then
  echo "error: ビルド成果物が見つかりません: ${BUILD_BINARY}" >&2
  exit 1
fi

install -d "${BIN_DIR}"
install -m 755 "${BUILD_BINARY}" "${INSTALL_BINARY}"

echo "Installed: ${INSTALL_BINARY}"
"${INSTALL_BINARY}" --help >/dev/null
echo "Verified: ${INSTALL_BINARY} --help"
