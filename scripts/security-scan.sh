#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"

missing=()
command -v gitleaks >/dev/null 2>&1 || missing+=(gitleaks)
command -v osv-scanner >/dev/null 2>&1 || missing+=(osv-scanner)

if ((${#missing[@]} > 0)); then
  printf 'Missing required command(s): %s\n' "${missing[*]}" >&2
  printf 'Install them with: brew install gitleaks osv-scanner\n' >&2
  exit 127
fi

echo "==> Gitleaks: scanning repository history"
gitleaks git \
  --redact \
  --no-banner \
  --log-opts="--all" \
  "${repo_root}"

echo "==> OSV-Scanner: scanning dependency manifests"
osv-scanner scan source \
  --recursive \
  "${repo_root}"
