#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Checks that tox-lock/uv.lock holds one set of versions. tox runs on
# one host Python, so the lock needs one version of each package. A
# lock that forks by Python version, through resolution-markers or a
# second copy of a package, gives Dependabot an older copy to bump past
# the Python it serves, and has let the resolver fall back to an
# ancient tox. The check also holds tox at or above the floor that
# tox-lock/pyproject.toml declares as its one dependency, "tox>=X.Y".
#
# uv writes uv.lock in a fixed layout: one 'name = "..."' line per
# [[package]], with its 'version = "..."' on the line after.
#
# Usage: bash tests/check-tox-lock.sh

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
lock="${root}/tox-lock/uv.lock"
project="${root}/tox-lock/pyproject.toml"
failures=0

fail() {
  echo "::error file=tox-lock/uv.lock::$1"
  failures=$((failures + 1))
}

# version_ge <a> <b>: a is the same release as b or a later one
version_ge() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$2" ]
}

floor="$(sed -n 's/^dependencies = \["tox>=\([0-9][0-9.]*\)"\]$/\1/p' \
  "${project}")"
if [ -z "${floor}" ]; then
  echo "::error file=tox-lock/pyproject.toml::declare the one" \
    "dependency as 'dependencies = [\"tox>=<version>\"]'"
  failures=$((failures + 1))
fi

markers="$(grep -c '^resolution-markers' "${lock}" || true)"
if [ "${markers}" -gt 0 ]; then
  fail "uv.lock forks by Python version: ${markers} resolution-markers"
fi

while read -r count name; do
  if [ "${count}" -gt 1 ]; then
    fail "uv.lock holds ${count} versions of ${name}"
  fi
done < <(sed -n 's/^name = "\(.*\)"$/\1/p' "${lock}" | sort | uniq -c)

toxes="$(sed -n '/^name = "tox"$/{n;s/^version = "\(.*\)"$/\1/p;}' "${lock}")"
if [ -z "${toxes}" ]; then
  fail 'uv.lock holds no tox'
fi
if [ -n "${floor}" ]; then
  while read -r tox; do
    if [ -n "${tox}" ] && ! version_ge "${tox}" "${floor}"; then
      fail "uv.lock pins tox ${tox}, below the floor of ${floor}"
    fi
  done <<< "${toxes}"
fi

if [ "${failures}" -gt 0 ]; then
  echo "tox-lock/uv.lock must hold one version of each package;" \
    "tox-lock/README.md describes how to refresh it"
  exit 1
fi
echo "✅ tox-lock/uv.lock holds one set, with tox ${toxes} >= ${floor}"
