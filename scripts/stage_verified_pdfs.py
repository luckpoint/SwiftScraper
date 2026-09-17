#!/usr/bin/env python3
"""EXAMPLE: stage verified SwiftScraper PDFs into a cloud sync folder.

This is a reference example, not part of the SwiftScraper CLI. It shows one way
to post-process a PDF download run: re-verify every PDF the run reported as
successful, then move the good ones into a fresh folder that a sync client
(Google Drive, Dropbox, ...) uploads for you -- for example to feed a NotebookLM
notebook. Copy it and adapt it to your own workflow.

Prerequisites
-------------
1. Python 3.9+. No third-party packages are required.
2. A completed SwiftScraper PDF download run, which produces the result JSON:

       swift run swift-scraper -- https://example.com/legal/ \
           --download-pdfs downloads > result.json

   `--download-linked-pdfs <dir>` writes `<dir>/pdf-downloads.json` instead.
   Either file works, as do both the single-page and the batch result shapes.
3. A destination root that already exists and is watched by your sync client.
   It must live OUTSIDE the download output directory, or the script refuses
   to run.

Usage
-----
    python3 scripts/stage_verified_pdfs.py result.json ~/GoogleDrive/NotebookLM \
        --run-name okta-2026-09 [--dry-run]

Behavior
--------
- Only entries with `success: true` and an `outputPath` are staged.
- Each file is verified: exists, `.pdf` suffix, non-empty, `%PDF-` magic bytes.
- Every file is verified before the first move, so one bad file aborts the run
  with nothing moved.
- Files are MOVED, not copied; they no longer exist in the download directory.
- Staged paths keep their layout relative to the run's `outputDirectory`.
- `--run-name` must name a folder that does not exist yet.
- Two sources that resolve to the same destination path abort the run.
- A JSON summary goes to stdout. `--dry-run` prints it without touching files.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path
from typing import Any, Iterator


DEFAULT_RUN_NAME = "run"


def iter_successful_paths(value: Any) -> Iterator[Path]:
    if isinstance(value, dict):
        if value.get("success") is True and isinstance(value.get("outputPath"), str):
            yield Path(value["outputPath"])
        for child in value.values():
            yield from iter_successful_paths(child)
    elif isinstance(value, list):
        for child in value:
            yield from iter_successful_paths(child)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Move verified successful SwiftScraper PDFs into a unique staging folder."
    )
    parser.add_argument("result_json", type=Path, help="--download-pdfs JSON output or pdf-downloads.json")
    parser.add_argument("destination_root", type=Path, help="NotebookLM sync folder")
    parser.add_argument(
        "--run-name",
        default=DEFAULT_RUN_NAME,
        help="Name of the new collection folder under destination_root (default: run)",
    )
    parser.add_argument("--dry-run", action="store_true", help="Validate and print moves without changing files")
    return parser.parse_args()


def load_result(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"cannot read result JSON: {path}: {error}") from error


def output_directory(result: Any) -> Path | None:
    if isinstance(result, dict) and isinstance(result.get("outputDirectory"), str):
        return Path(result["outputDirectory"]).expanduser().resolve()
    return None


def unique_paths(paths: Iterator[Path]) -> list[Path]:
    seen: set[Path] = set()
    result: list[Path] = []
    for path in paths:
        resolved = path.expanduser().resolve()
        if resolved not in seen:
            seen.add(resolved)
            result.append(resolved)
    return result


def relative_destination(source: Path, output_root: Path | None, destination: Path) -> Path:
    if output_root is not None:
        try:
            return destination / source.relative_to(output_root)
        except ValueError:
            pass
    return destination / source.name


def ensure_safe_run_name(run_name: str) -> None:
    if not run_name or run_name in {".", ".."} or "/" in run_name or "\\" in run_name:
        raise RuntimeError("--run-name must be a single folder name")


def main() -> int:
    args = parse_args()
    result_json = args.result_json.expanduser().resolve()
    destination_root = args.destination_root.expanduser().resolve()
    destination = destination_root / args.run_name

    try:
        ensure_safe_run_name(args.run_name)
        result = load_result(result_json)
        paths = unique_paths(iter_successful_paths(result))
        if not paths:
            raise RuntimeError("result JSON contains no successful PDF downloads")

        output_root = output_directory(result)
        if output_root is not None:
            try:
                destination_root.relative_to(output_root)
            except ValueError:
                pass
            else:
                raise RuntimeError("destination root must be outside the download output directory")

        if destination.exists():
            raise RuntimeError(f"destination folder already exists: {destination}")

        moves: list[tuple[Path, Path]] = []
        planned: set[Path] = set()
        for source in paths:
            if not source.is_file():
                raise RuntimeError(f"PDF file is missing: {source}")
            if source.suffix.lower() != ".pdf":
                raise RuntimeError(f"not a .pdf file: {source}")
            if source.stat().st_size == 0:
                raise RuntimeError(f"PDF file is empty: {source}")
            with source.open("rb") as handle:
                if handle.read(5) != b"%PDF-":
                    raise RuntimeError(f"missing %PDF- header: {source}")

            target = relative_destination(source, output_root, destination)
            if target.exists():
                raise RuntimeError(f"destination file already exists: {target}")
            if target in planned:
                raise RuntimeError(f"two source files map to the same destination: {target}")
            planned.add(target)
            moves.append((source, target))

        if not args.dry_run:
            for _, target in moves:
                target.parent.mkdir(parents=True, exist_ok=True)
            for source, target in moves:
                shutil.move(str(source), str(target))

        payload = {
            "destination": str(destination),
            "dryRun": args.dry_run,
            "movedCount": len(moves),
            "files": [
                {"sourcePath": str(source), "destinationPath": str(target)}
                for source, target in moves
            ],
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0
    except RuntimeError as error:
        print(f"stage_verified_pdfs: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
