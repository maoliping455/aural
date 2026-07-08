#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

user_path="/"'Users/[^[:space:]]+'
package_manager_path="/opt/"'homebrew'
key_marker="BE"'GIN .*'"K"'EY'
token_marker="(API|ACCESS|AUTH|BEARER|REFRESH|HF|HUGGINGFACE_HUB|MODELSCOPE|GITHUB)[_-]?"'TOKEN'
secret_marker="SEC"'RET'
password_marker="PASS"'WORD'

pattern_parts=(
  "$user_path"
  "$package_manager_path"
  "$key_marker"
  "$token_marker"
  "$secret_marker"
  "$password_marker"
)

pattern="$(IFS='|'; echo "${pattern_parts[*]}")"

if rg "$pattern" . --glob '!**/.git/**' --glob '!**/.build/**'; then
  echo "open-source audit failed: sensitive or local-only text found" >&2
  exit 1
fi

generated_files="$(
  find . \
    -path './.build' -prune -o \
    \( -name '__pycache__' -o -name '*.pyc' -o -name '.DS_Store' \) -print
)"
if [[ -n "$generated_files" ]]; then
  echo "$generated_files"
  echo "open-source audit failed: generated files found" >&2
  exit 1
fi

echo "open-source audit passed"
