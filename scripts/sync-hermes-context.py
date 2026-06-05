#!/usr/bin/env python3
"""
Sync Hermes config.yaml context_length fields from the configured model.

Hermes sometimes detects a model's base context window even when the serving
provider exposes a larger context. This script keeps the override model-driven:
it reads config.yaml, resolves the active model's context from provider metadata
when possible, and writes the resolved value into the model and auxiliary
compression sections.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Sync Hermes model context_length")
    parser.add_argument(
        "--config",
        default="data/hermes/config.yaml",
        help="Hermes config.yaml path (default: data/hermes/config.yaml)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print planned changes without writing config.yaml",
    )
    parser.add_argument(
        "--models-json",
        default=os.environ.get("OPENROUTER_MODELS_JSON_FILE", ""),
        help="Optional OpenRouter /models JSON fixture for offline verification",
    )
    return parser.parse_args()


def read_scalar(lines: list[str], section: str, key: str) -> str:
    section_indent: int | None = None
    in_section = False
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if stripped == f"{section}:":
            section_indent = indent
            in_section = True
            continue
        if in_section:
            if indent <= (section_indent or 0):
                break
            prefix = f"{key}:"
            if stripped.startswith(prefix):
                return stripped[len(prefix) :].strip().strip("'\"")
    return ""


def load_openrouter_models(base_url: str, api_key: str, fixture: str) -> dict[str, Any]:
    if fixture:
        return json.loads(Path(fixture).read_text())

    endpoint = base_url.rstrip("/")
    if endpoint.endswith("/chat/completions"):
        endpoint = endpoint[: -len("/chat/completions")]
    if not endpoint.endswith("/models"):
        endpoint = f"{endpoint}/models"

    request = urllib.request.Request(endpoint)
    if api_key:
        request.add_header("Authorization", f"Bearer {api_key}")
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.loads(response.read().decode("utf-8"))


def resolve_context(lines: list[str], fixture: str) -> tuple[int, str]:
    model = read_scalar(lines, "model", "default")
    provider = read_scalar(lines, "model", "provider").lower()
    base_url = read_scalar(lines, "model", "base_url") or "https://openrouter.ai/api/v1"

    explicit = os.environ.get("HERMES_DEFAULT_MANAGED_CONTEXT_LENGTH", "").strip()
    if explicit:
        return int(explicit), f"HERMES_DEFAULT_MANAGED_CONTEXT_LENGTH for {model}"

    if provider != "openrouter":
        raise SystemExit(
            f"Cannot auto-resolve context for provider '{provider}'. "
            "Set HERMES_DEFAULT_MANAGED_CONTEXT_LENGTH."
        )

    payload = load_openrouter_models(base_url, os.environ.get("OPENROUTER_API_KEY", ""), fixture)
    for item in payload.get("data", []):
        if item.get("id") == model:
            context = item.get("context_length")
            if isinstance(context, int) and context > 0:
                return context, f"OpenRouter metadata for {model}"
            break

    raise SystemExit(f"Could not resolve context_length for model '{model}' from OpenRouter metadata.")


def set_scalar_in_section(lines: list[str], path: list[str], key: str, value: int) -> tuple[list[str], str]:
    output = list(lines)
    stack: list[tuple[int, str]] = []
    target_indent: int | None = None
    insert_at: int | None = None
    existing_at: int | None = None

    for index, line in enumerate(output):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        while stack and indent <= stack[-1][0]:
            stack.pop()
        if stripped.endswith(":"):
            stack.append((indent, stripped[:-1]))
            if [name for _, name in stack] == path:
                target_indent = indent
                insert_at = index + 1
            elif target_indent is not None and indent <= target_indent:
                break
            continue
        if target_indent is not None:
            if indent <= target_indent:
                break
            insert_at = index + 1
            if stripped.startswith(f"{key}:"):
                existing_at = index
                break

    if target_indent is None:
        raise SystemExit(f"Missing config section: {'.'.join(path)}")

    scalar_indent = target_indent + 2
    rendered = f"{' ' * scalar_indent}{key}: {value}\n"
    if existing_at is not None:
        before = output[existing_at].strip()
        output[existing_at] = rendered
        return output, f"updated {'.'.join(path)}.{key} ({before} -> {key}: {value})"

    if insert_at is None:
        raise SystemExit(f"Could not find insertion point for {'.'.join(path)}.{key}")
    output.insert(insert_at, rendered)
    return output, f"inserted {'.'.join(path)}.{key}: {value}"


def main() -> int:
    args = parse_args()
    config_path = Path(args.config)
    lines = config_path.read_text().splitlines(keepends=True)
    context, source = resolve_context(lines, args.models_json)

    updated, model_change = set_scalar_in_section(lines, ["model"], "context_length", context)
    updated, compression_change = set_scalar_in_section(
        updated,
        ["auxiliary", "compression"],
        "context_length",
        int(os.environ.get("HERMES_AUX_COMPRESSION_CONTEXT_LENGTH", context)),
    )

    print(f"resolved context_length={context} from {source}")
    print(model_change)
    print(compression_change)
    if args.dry_run:
        return 0

    config_path.write_text("".join(updated))
    return 0


if __name__ == "__main__":
    sys.exit(main())
