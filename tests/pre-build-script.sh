#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Exercises the pre-build-script containment check in action.yaml
# against symlinks that lead out of the workspace, including into a
# sibling directory whose path starts with the workspace path.
#
# Why extract rather than duplicate: a copy of a step tests the copy.
# yq pulls the step's run block out of action.yaml, and bash runs it
# with the flags GitHub uses for 'shell: bash' (--noprofile --norc -eo
# pipefail), under an emptied environment so nothing leaks in from the
# caller's shell. A renamed or removed step fails the harness instead
# of being skipped.
#
# The step executes the script once validation passes, so every script
# here only records that it ran; a rejected script must leave no record.
#
# Usage: tests/pre-build-script.sh    (needs mikefarah yq v4 and bash)

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Resolved, as macOS places the temporary directory under a symlink
work="$(cd -- "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "${work}"' EXIT

step_name='Run pre-build-script'
script="${work}/step.sh"
ran="${work}/ran"
cases=0
failures=0
match=''
path="${PATH}"

if ! yq --version 2> /dev/null | grep -q 'mikefarah'; then
  echo '::error::tests/pre-build-script.sh needs mikefarah yq v4' >&2
  exit 2
fi

if ! NAME="${step_name}" yq -e \
  '[.runs.steps[] | select(.name == strenv(NAME))] | length == 1' \
  "${root}/action.yaml" > /dev/null 2>&1; then
  echo "::error::action.yaml has no single step named '${step_name}'" >&2
  exit 2
fi
NAME="${step_name}" yq \
  '.runs.steps[] | select(.name == strenv(NAME)) | .run' \
  "${root}/action.yaml" > "${script}"
# An expression left in the run block would be interpolated by GitHub
# before bash saw it, so this harness could not reproduce it.
marker="\${{"
if grep -qF -- "${marker}" "${script}"; then
  echo "::error::'${step_name}' interpolates an expression in its run" \
    "block; move it to env: so it can be tested" >&2
  exit 2
fi

# make_script <path> <id>: an executable script that records <id>.
make_script() {
  mkdir -p -- "$(dirname -- "$1")"
  printf '#!/bin/sh\necho %s >> "%s"\n' "$2" "${ran}" > "$1"
  chmod +x "$1"
}

# expect <pass|fail> <label> <workspace> <input> <id>: runs the step as
# the runner would, from the workspace. A pass must have executed the
# script recording <id>; a fail must have executed nothing and, when
# $match is set, printed it, so a case rejected for another reason does
# not count as rejected. $path is the PATH the step sees.
expect() {
  local want="$1" label="$2" ws="$3" input="$4" id="$5" got ok=1
  cases=$((cases + 1))
  : > "${ran}"
  if (cd -- "${ws}" && env -i PATH="${path}" HOME="${HOME}" \
    GITHUB_WORKSPACE="${ws}" INPUT_PRE_BUILD_SCRIPT="${input}" \
    bash --noprofile --norc -eo pipefail "${script}") \
    > "${work}/out" 2>&1; then
    got=pass
  else
    got=fail
  fi
  [ "${got}" = "${want}" ] || ok=0
  if [ "${want}" = pass ]; then
    grep -qxF -- "${id}" "${ran}" || ok=0
  else
    [ ! -s "${ran}" ] || ok=0
    [ -z "${match}" ] || grep -qF -- "${match}" "${work}/out" || ok=0
  fi
  if [ "${ok}" = 1 ]; then
    printf '  ok    %s\n' "${label}"
  else
    failures=$((failures + 1))
    printf '  FAIL  %s (wanted %s, got %s%s)\n' "${label}" "${want}" \
      "${got}" "${match:+, expecting \"${match}\"}"
    sed 's/^/        | /' "${work}/out" "${ran}"
  fi
  match=''
  path="${PATH}"
}

# The GitHub-hosted layout: <work>/<repo>/<repo>, with a sibling whose
# name extends the workspace's and an unrelated directory elsewhere.
ws="${work}/work/repo/repo"
make_script "${ws}/scripts/ok.sh" ok
make_script "${work}/work/repo/repo-evil/x.sh" sibling
make_script "${work}/outside/x.sh" outside
ln -s "${work}/work/repo/repo-evil/x.sh" "${ws}/sibling.sh"
ln -s "${work}/work/repo/repo-evil" "${ws}/linkdir"
ln -s "${work}/outside/x.sh" "${ws}/outside.sh"
ln -s scripts/ok.sh "${ws}/inside.sh"

echo '== pre-build-script containment'
expect pass 'script inside the workspace' "${ws}" 'scripts/ok.sh' ok
expect pass 'symlink to a script inside the workspace' \
  "${ws}" 'inside.sh' ok
match='Script must be within repository'
expect fail 'file symlink into a sibling directory' \
  "${ws}" 'sibling.sh' sibling
match='Script must be within repository'
expect fail 'directory symlink into a sibling directory' \
  "${ws}" 'linkdir/x.sh' sibling
match='Script must be within repository'
expect fail 'symlink to an unrelated directory' \
  "${ws}" 'outside.sh' outside

# Neither tool resolves a path through a missing directory, and the
# step must say so rather than stop at the failed assignment.
match='Failed to resolve canonical path for script'
expect fail 'script under a missing directory' \
  "${ws}" 'missing/x.sh' none

# Self-hosted runners may reach the workspace through a symlink; the
# script's resolved path must still count as inside it.
mkdir -p "${work}/real"
ln -s "${work}/real" "${work}/link"
make_script "${work}/real/repo/ok.sh" linked
expect pass 'workspace reached through a symlink' \
  "${work}/link/repo" 'ok.sh' linked

# Without a working readlink -f the step falls back to realpath, which
# must enforce the same boundary.
stubs="${work}/stubs"
mkdir -p "${stubs}"
printf '#!/bin/sh\nexit 1\n' > "${stubs}/readlink"
chmod +x "${stubs}/readlink"
path="${stubs}:${PATH}"
expect pass 'realpath fallback: script inside the workspace' \
  "${ws}" 'scripts/ok.sh' ok
path="${stubs}:${PATH}"
match='Script must be within repository'
expect fail 'realpath fallback: symlink into a sibling directory' \
  "${ws}" 'sibling.sh' sibling

# Without either tool nothing can be compared, so the step must stop,
# and say why, rather than run the script.
cp "${stubs}/readlink" "${stubs}/realpath"
path="${stubs}:${PATH}"
match='Failed to resolve canonical path for workspace'
expect fail 'neither readlink -f nor realpath resolves' \
  "${ws}" 'scripts/ok.sh' ok

echo "${cases} cases, ${failures} failed"
[ "${failures}" -eq 0 ]
