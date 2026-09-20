#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_SWIFTLINT="$REPO_ROOT/.swiftlint.yml"
CONFIG_SWIFTFORMAT="$REPO_ROOT/.swiftformat"

SKIP_INSTALL=false
LINT_ONLY=false
SWIFTLINT_REPORTER="xcode"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-install) SKIP_INSTALL=true ;;
    --lint-only)    LINT_ONLY=true ;;
    --reporter)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for --reporter"
        exit 1
      fi
      SWIFTLINT_REPORTER="$2"
      shift
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
  shift
done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }

ensure_tool() {
  local tool=$1
  if command -v "$tool" >/dev/null 2>&1; then
    dim "$tool is installed ($(command -v "$tool"))"
    return 0
  fi
  if command -v brew >/dev/null 2>&1; then
    bold "Installing $tool via Homebrew..."
    brew install "$tool"
  else
    echo "Error: $tool is not installed and Homebrew is not available."
    exit 1
  fi
}

if [ "$SKIP_INSTALL" = false ]; then
  bold "=== Checking tools ==="
  ensure_tool swiftformat
  ensure_tool swiftlint
  echo ""
fi

cd "$REPO_ROOT"

if [ "$LINT_ONLY" = true ]; then
  bold "=== Running SwiftFormat (lint) ==="
  swiftformat --lint .

  bold "=== Running SwiftLint ==="
  if [ "$SWIFTLINT_REPORTER" = "quiet" ]; then
    swiftlint lint --strict --quiet --config "$CONFIG_SWIFTLINT"
  else
    swiftlint lint --config "$CONFIG_SWIFTLINT" --reporter "$SWIFTLINT_REPORTER"
  fi
  exit 0
fi

bold "=== Running SwiftFormat ==="
swiftformat .

bold "=== Running SwiftLint fix ==="
swiftlint lint --fix --quiet --config "$CONFIG_SWIFTLINT" 2>/dev/null || true

bold "=== Checking remaining SwiftLint issues ==="
swiftlint lint --config "$CONFIG_SWIFTLINT"
