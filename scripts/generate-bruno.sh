#!/usr/bin/env bash
# HER-229 — regenerate the LuminaVaultCollection Bruno collection from
# Sources/AppAPI/openapi.yaml (HER-224). Run on demand; not part of
# `swift build`.
#
# Requires Node.js + Bruno CLI (`npm i -g @usebruno/cli`).
# Reference: https://docs.usebruno.com/converters/openapi-to-bruno
#
# Behaviour:
#   - Reads $REPO_ROOT/Sources/AppAPI/openapi.yaml.
#   - Writes into $LUMINAVAULT_COLLECTION_PATH (default
#     ~/Projects/ObsidianClaudeBrain/LuminaVaultCollection).
#   - `bru import openapi` overwrites generated request files; manual
#     additions and the environments/ folder are preserved (any path
#     not matching a generated operation name is left alone).
#
# Workflow:
#   1. Edit Sources/AppAPI/openapi.yaml.
#   2. make bruno-regen
#   3. cd $LUMINAVAULT_COLLECTION_PATH && git diff
#   4. Commit + push both repos.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SPEC="${REPO_ROOT}/Sources/AppAPI/openapi.yaml"
TARGET="${LUMINAVAULT_COLLECTION_PATH:-${HOME}/Projects/ObsidianClaudeBrain/LuminaVaultCollection}"

if [ ! -f "${SPEC}" ]; then
  echo "error: OpenAPI spec not found at ${SPEC}" >&2
  exit 1
fi

if [ ! -d "${TARGET}" ]; then
  echo "error: LuminaVaultCollection not found at ${TARGET}" >&2
  echo "hint: clone git@github.com:LuminaVault/LuminaVaultCollection.git there" >&2
  echo "      or set LUMINAVAULT_COLLECTION_PATH to its absolute path" >&2
  exit 1
fi

if ! command -v bru >/dev/null 2>&1; then
  echo "error: bru CLI not installed" >&2
  echo "hint: npm install -g @usebruno/cli" >&2
  exit 1
fi

DEST="${TARGET}/LuminaVaultServer"

echo "→ regenerating Bruno collection"
echo "    spec:   ${SPEC}"
echo "    target: ${DEST}"

# bru CLI v3 (3.0.x) refuses to import when the --output collection dir already
# exists and is non-empty ("Output directory is not empty"), which broke the
# old in-place `--output "${TARGET}"` workflow. Work around it: import into a
# fresh temp dir, then rsync the generated request folders back into the real
# collection. The hand-maintained environments/ folder is excluded so its
# baseUrl/token vars survive regeneration.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

bru import openapi \
  --source "${SPEC}" \
  --output "${TMP_DIR}" \
  --collection-name "LuminaVaultServer" \
  --group-by tags

GENERATED="${TMP_DIR}/LuminaVaultServer"
if [ ! -d "${GENERATED}" ]; then
  echo "error: bru produced no LuminaVaultServer collection under ${TMP_DIR}" >&2
  exit 1
fi

mkdir -p "${DEST}"
# --delete prunes operation folders dropped from the spec; --exclude keeps the
# manual environments/ folder untouched (bru would otherwise overwrite it).
rsync -a --delete --exclude 'environments' "${GENERATED}/" "${DEST}/"

echo
echo "✓ regenerated Bruno collection at ${DEST}"
echo "  preserved: ${DEST}/environments"
echo "  next: cd ${TARGET} && git diff && git commit + push"
