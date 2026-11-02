#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Exercises tests/check-tox-lock.py: it must pass the lock in tox-lock/
# and fail each copy of it broken in one of the ways that let
# Dependabot break the lock, printing what to do about it.
#
# Usage: bash tests/check-tox-lock-test.sh    (needs Python 3.11+)

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT
guard="${root}/tests/check-tox-lock.py"

cases=0
failures=0

# fresh: a copy of the lock directory to break
fresh() {
  rm -rf -- "${work}/lock"
  cp -R -- "${root}/tox-lock" "${work}/lock"
}

# expect <pass|fail> <label>: run the guard on the copy
expect() {
  local ok=1
  cases=$((cases + 1))
  if python3 "${guard}" "${work}/lock" > "${work}/out" 2>&1; then
    [ "$1" = pass ] || ok=0
  else
    [ "$1" = fail ] || ok=0
    grep -qF 'raise' "${work}/out" || ok=0
  fi
  if [ "${ok}" = 1 ]; then
    printf '  ok    %s %s\n' "$1" "$2"
  else
    failures=$((failures + 1))
    printf '  FAIL  %s %s\n' "$1" "$2"
    sed 's/^/        | /' "${work}/out"
  fi
}

# edit <file> <old> <new>: replace the first <old> in a file of the copy
edit() {
  python3 -c 'import sys
path, old, new = sys.argv[1:]
with open(path) as f:
    s = f.read()
if old not in s:
    sys.exit(f"{path} lacks {old!r}")
with open(path, "w") as f:
    f.write(s.replace(old, new, 1))' "${work}/lock/$1" "$2" "$3"
}

fresh
expect pass 'the lock in tox-lock/'

fresh
edit uv.lock $'requires-python = ">=3.11"\n' \
  $'requires-python = ">=3.11"\nresolution-markers = [\n'\
$'    "python_full_version >= \'3.12\'",\n'\
$'    "python_full_version < \'3.12\'",\n]\n'
expect fail 'a lock forked by Python'

fresh
edit uv.lock $'[[package]]\nname = "tox"\n' \
  $'[[package]]\nname = "tox"\nversion = "4.30.3"\n'\
$'source = { registry = "https://pypi.org/simple" }\n\n'\
$'[[package]]\nname = "tox"\n'
expect fail 'a lock holding two tox entries'

fresh
edit pyproject.toml '"tox>=4.67"' '"tox>=99"'
expect fail 'a lock whose tox is below the floor'

fresh
edit pyproject.toml '"tox>=4.67"' '"tox"'
expect fail 'a project with no floor on tox'

fresh
edit pyproject.toml '">=3.11"' '">=3.8"'
expect fail 'a project whose requires-python differs from the lock'

echo "${cases} cases, ${failures} failed"
[ "${failures}" -eq 0 ]
