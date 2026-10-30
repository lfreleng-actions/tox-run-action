#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Exercises the tox-envs and parallel handling in action.yaml. The
# validation step must reject any value that could reach the tox
# command line as an option, and the run step must hand what it accepts
# to tox as separate arguments, whatever the value contains.
#
# As in tests/pre-build-script.sh, yq extracts each step's run block
# from action.yaml and bash runs it with the flags GitHub uses for
# 'shell: bash', under an emptied environment. The run step gets stub
# interpreters: the "Python" builds a virtual environment whose pip and
# tox only record their arguments, so no case installs or runs anything.
#
# Usage: tests/tox-inputs.sh    (needs mikefarah yq v4 and bash)

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(cd -- "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "${work}"' EXIT

cases=0
failures=0

if ! yq --version 2> /dev/null | grep -q 'mikefarah'; then
  echo '::error::tests/tox-inputs.sh needs mikefarah yq v4' >&2
  exit 2
fi

# extract <step name> <file>: write the step's run block to <file>,
# refusing a missing or duplicated step and one that interpolates an
# expression, which GitHub would expand before bash saw it.
extract() {
  if ! NAME="$1" yq -e \
    '[.runs.steps[] | select(.name == strenv(NAME))] | length == 1' \
    "${root}/action.yaml" > /dev/null 2>&1; then
    echo "::error::action.yaml has no single step named '$1'" >&2
    exit 2
  fi
  NAME="$1" yq '.runs.steps[] | select(.name == strenv(NAME)) | .run' \
    "${root}/action.yaml" > "$2"
  if grep -qF -- "\${{" "$2"; then
    echo "::error::'$1' interpolates an expression in its run block" >&2
    exit 2
  fi
}

validate="${work}/validate.sh"
run="${work}/run.sh"
extract 'Validate action/environment' "${validate}"
extract 'Run tox' "${run}"

ws="${work}/ws"
mkdir -p "${ws}"
: > "${ws}/tox.ini"

# Stubs. 'python' answers the run step's version probe; 'interpreter'
# stands in for the setup-python interpreter, and its virtual
# environment's python and tox log their arguments one per line.
stubs="${work}/stubs"
mkdir -p "${stubs}"
cat > "${stubs}/python" << 'EOF'
#!/bin/sh
echo 'Python 3.11.9'
EOF
cat > "${stubs}/interpreter" << 'EOF'
#!/bin/sh
[ "$1" = -I ] && [ "$2" = -m ] && [ "$3" = venv ] || exit 2
mkdir -p "$4/bin"
cp "${STUB_DIR}/venv-python" "$4/bin/python"
cp "${STUB_DIR}/tox" "$4/bin/tox"
EOF
cat > "${stubs}/venv-python" << 'EOF'
#!/bin/sh
for arg; do printf '%s\n' "$arg"; done > "${PIP_LOG}"
EOF
cat > "${stubs}/tox" << 'EOF'
#!/bin/sh
for arg; do printf '%s\n' "$arg"; done > "${TOX_LOG}"
EOF
chmod +x "${stubs}"/*

# step <script> <tox-envs> <parallel>: run a step as the runner would,
# leaving its output in ${work}/out and its error output in
# ${work}/output.
step() {
  : > "${work}/output"
  rm -rf "${work}/tmp"
  mkdir -p "${work}/tmp"
  (cd -- "${ws}" && env -i PATH="${stubs}:${PATH}" HOME="${HOME}" \
    GITHUB_WORKSPACE="${ws}" GITHUB_OUTPUT="${work}/output" \
    GITHUB_ACTION_PATH="${root}" RUNNER_TEMP="${work}/tmp" \
    STUB_DIR="${stubs}" PIP_LOG="${work}/pip" TOX_LOG="${work}/tox" \
    STEPS_SETUP_PYTHON_OUTPUTS_PYTHON_PATH="${stubs}/interpreter" \
    INPUT_PATH_PREFIX='.' INPUT_TOX_ENVS="$2" INPUT_PARALLEL="$3" \
    bash --noprofile --norc -eo pipefail "$1") > "${work}/out" 2>&1
}

report() {
  if [ "$1" = 1 ]; then
    printf '  ok    %s\n' "$2"
  else
    failures=$((failures + 1))
    printf '  FAIL  %s\n' "$2"
    sed 's/^/        | /' "${work}/out" "${work}/output"
  fi
}

# accept <tox-envs> <parallel>: validation passes and publishes no error
accept() {
  local ok=1
  cases=$((cases + 1))
  step "${validate}" "$1" "$2" || ok=0
  ! grep -q '^error=' "${work}/output" || ok=0
  report "${ok}" "accept tox-envs='$1' parallel='$2'"
}

# reject <error> <tox-envs> <parallel>: validation fails with error=<error>
reject() {
  local ok=1
  cases=$((cases + 1))
  ! step "${validate}" "$2" "$3" || ok=0
  grep -qxF -- "error=$1" "${work}/output" || ok=0
  report "${ok}" "reject tox-envs='$2' parallel='$3' as $1"
}

# args <tox-envs> <parallel> [<arg>...]: the run step calls tox with
# exactly <arg>..., one argument each
args() {
  local envs="$1" parallel="$2" ok=1
  shift 2
  cases=$((cases + 1))
  rm -f "${work}/tox"
  step "${run}" "${envs}" "${parallel}" || ok=0
  [ -f "${work}/tox" ] || ok=0
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "${work}/want"
  else
    : > "${work}/want"
  fi
  cmp -s "${work}/want" "${work}/tox" 2> /dev/null || ok=0
  report "${ok}" "tox-envs='${envs}' parallel='${parallel}' -> tox $*"
}

echo '== tox-envs'
accept '' ''
accept 'py311' ''
accept 'py311,lint,docs' ''
accept 'py3.12,docs-linkcheck,py311_x+y' ''
accept 'ALL' ''
reject invalid-tox-envs 'py311 --notest' ''
reject invalid-tox-envs '--notest' ''
reject invalid-tox-envs 'py311,-x' ''
reject invalid-tox-envs 'py311, lint' ''
reject invalid-tox-envs 'py311,,lint' ''
reject invalid-tox-envs 'py311,' ''
reject invalid-tox-envs 'py*' ''
reject invalid-tox-envs 'py311;lint' ''
reject invalid-tox-envs $'py311\nlint' ''

echo '== parallel'
accept '' 'auto'
accept '' 'all'
accept '' 'off'
accept '' '0'
accept '' '4'
reject invalid-parallel '' 'on'
reject invalid-parallel '' '-1'
reject invalid-parallel '' '1 --notest'
reject invalid-parallel '' '4x'
reject invalid-parallel '' $'auto\n'

echo '== tox command line'
args 'py311,lint' 'auto' --parallel auto --parallel-live -e py311,lint
args 'py311' '2' --parallel 2 --parallel-live -e py311
args 'py311' 'off' -e py311
args 'py311' '' -e py311
args '' 'auto' --parallel auto --parallel-live
args '' ''

echo '== tox install'
cases=$((cases + 1))
ok=1
step "${run}" '' '' || ok=0
# Isolated, so a pip.py in the project cannot replace pip
[ "$(head -n 1 "${work}/pip" 2> /dev/null)" = '-I' ] || ok=0
grep -sqxF -- '--require-hashes' "${work}/pip" || ok=0
grep -sqxF -- "${root}/requirements/tox.txt" "${work}/pip" || ok=0
report "${ok}" 'tox comes from the hashed lock, installed in isolation'

echo "${cases} cases, ${failures} failed"
[ "${failures}" -eq 0 ]
