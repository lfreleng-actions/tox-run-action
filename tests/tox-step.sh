#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Exercises the handling of the path_prefix, tox-envs and parallel
# inputs in action.yaml. The validation step must keep path_prefix
# inside the workspace, through any symlink, and reject any tox-envs or
# parallel value that could reach the tox command line as an option;
# the run step must hand what it accepts to tox as separate arguments,
# whatever the value contains.
#
# As in tests/pre-build-script.sh, yq extracts each step's run block
# from action.yaml and bash runs it with the flags GitHub uses for
# 'shell: bash', under an emptied environment. The run step gets stubs:
# a "uv" that records its arguments and environment, and builds a
# virtual environment holding a tox that records its own, so no case
# installs or runs anything.
#
# Usage: bash tests/tox-step.sh    (needs mikefarah yq v4 and bash)

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(cd -- "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "${work}"' EXIT

cases=0
failures=0

if ! yq --version 2> /dev/null | grep -q 'mikefarah'; then
  echo '::error::tests/tox-step.sh needs mikefarah yq v4' >&2
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
detect="${work}/detect.sh"
run="${work}/run.sh"
extract 'Validate action/environment' "${validate}"
extract 'Detect dependency management tool' "${detect}"
extract 'Run tox' "${run}"

ws="${work}/ws"
mkdir -p "${ws}"
: > "${ws}/tox.ini"
# The workspace and path_prefix each case runs with, and directories put
# ahead of PATH; every case puts them back afterwards
workspace="${ws}"
prefix='.'
toolpath=''

# Stubs. 'interpreter' stands in for the setup-python interpreter, which
# only uv may run. 'uv' logs its arguments, and then the UV_* variables
# it sees, one per line, and puts the stub tox, which logs its own
# arguments and the UV_* variables it sees, in the environment it was
# given.
stubs="${work}/stubs"
mkdir -p "${stubs}"
cat > "${stubs}/interpreter" << 'EOF'
#!/bin/sh
exit 2
EOF
cat > "${stubs}/uv" << 'EOF'
#!/bin/sh
for arg; do printf '%s\n' "$arg"; done > "${STUB_UV_LOG}"
env | grep '^UV_' | sort > "${STUB_UV_ENV}"
mkdir -p "${UV_PROJECT_ENVIRONMENT}/bin"
cp "${STUB_DIR}/tox" "${UV_PROJECT_ENVIRONMENT}/bin/tox"
EOF
cat > "${stubs}/tox" << 'EOF'
#!/bin/sh
for arg; do printf '%s\n' "$arg"; done > "${TOX_LOG}"
pwd -P > "${TOX_CWD}"
env | grep '^UV_' | sort > "${TOX_ENV}"
EOF
chmod +x "${stubs}"/*

# step <script> <tox-envs> <parallel>: run a step as the runner would,
# leaving its output in ${work}/out and its error output in
# ${work}/output. The caller's environment carries UV_* variables that
# would redirect uv's index and environment if they reached it.
step() {
  : > "${work}/output"
  rm -rf "${work}/tmp"
  mkdir -p "${work}/tmp"
  (cd -- "${workspace}" && env -i PATH="${toolpath}${stubs}:${PATH}" \
    HOME="${HOME}" \
    GITHUB_WORKSPACE="${workspace}" GITHUB_OUTPUT="${work}/output" \
    GITHUB_ACTION_PATH="${root}" RUNNER_TEMP="${work}/tmp" \
    STUB_DIR="${stubs}" STUB_UV_LOG="${work}/uv" \
    STUB_UV_ENV="${work}/uv-env" \
    TOX_LOG="${work}/tox" TOX_ENV="${work}/tox-env" \
    TOX_CWD="${work}/cwd" GITHUB_STEP_SUMMARY="${work}/summary" \
    STEPS_SETUP_PYTHON_OUTPUTS_PYTHON_PATH="${stubs}/interpreter" \
    STEPS_SETUP_UV_OUTPUTS_UV_PATH="${stubs}/uv" \
    UV_INDEX_URL='https://index.invalid/simple' \
    UV_PROJECT_ENVIRONMENT="${work}/caller-venv" \
    INPUT_PATH_PREFIX="${prefix}" INPUT_TOX_ENVS="$2" \
    INPUT_PARALLEL="$3" \
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
  workspace="${ws}"
  prefix='.'
  toolpath=''
}

# accept <tox-envs> <parallel>: validation passes and publishes no error
accept() {
  local ok=1
  cases=$((cases + 1))
  step "${validate}" "$1" "$2" || ok=0
  ! grep -q '^error=' "${work}/output" || ok=0
  report "${ok}" \
    "accept path_prefix='${prefix}' tox-envs='$1' parallel='$2'"
}

# reject <error> <tox-envs> <parallel>: validation fails with error=<error>
reject() {
  local ok=1
  cases=$((cases + 1))
  ! step "${validate}" "$2" "$3" || ok=0
  grep -qxF -- "error=$1" "${work}/output" || ok=0
  report "${ok}" \
    "reject path_prefix='${prefix}' tox-envs='$2' parallel='$3' as $1"
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

# same_dir <dir>: once validation accepts path_prefix, the detection
# step inspects <dir>, which holds no lock file, and the run step
# starts tox in it
same_dir() {
  local ok=1
  cases=$((cases + 1))
  step "${validate}" '' '' || ok=0
  step "${detect}" '' '' || ok=0
  grep -qxF 'build-backend=none' "${work}/output" || ok=0
  rm -f "${work}/cwd"
  step "${run}" '' '' || ok=0
  [ "$(cat "${work}/cwd" 2> /dev/null)" = "$1" ] || ok=0
  report "${ok}" "path_prefix='${prefix}': detection and tox use $1"
}

echo '== path_prefix'
# A tree beside the workspace, whose name extends the workspace's, and
# a tox.ini in every directory a prefix can reach, so only containment
# can reject one
: > "${work}/tox.ini"
mkdir -p "${ws}/sub" "${work}/ws-evil"
: > "${ws}/sub/tox.ini"
: > "${work}/ws-evil/tox.ini"
ln -s sub "${ws}/inside"
ln -s "${work}/ws-evil" "${ws}/sibling"
ln -s "${work}" "${ws}/up"
accept '' ''
prefix='sub'
accept '' ''
prefix='inside'
accept '' ''
prefix='sub/..'
accept '' ''
prefix='..'
reject path-prefix-outside-workspace '' ''
prefix='sub/../..'
reject path-prefix-outside-workspace '' ''
prefix='../ws-evil'
reject path-prefix-outside-workspace '' ''
prefix='sibling'
reject path-prefix-outside-workspace '' ''
prefix='up'
reject path-prefix-outside-workspace '' ''
# Self-hosted runners may reach the workspace through a symlink
ln -s "${ws}" "${work}/ws-link"
workspace="${work}/ws-link"
prefix='sub'
accept '' ''
# Without readlink -f or realpath nothing can be compared, so the step
# must stop rather than let the prefix through
broken="${work}/broken"
mkdir -p "${broken}"
printf '#!/bin/sh\nexit 1\n' > "${broken}/readlink"
cp "${broken}/readlink" "${broken}/realpath"
chmod +x "${broken}"/*
toolpath="${broken}:"
reject workspace-unresolved '' ''
# Validation resolves '..' after following symlinks, so the steps after
# it must too: a logical cd through deep -> sub/deep would climb from
# the link's own directory and leave the workspace for its parent,
# where a uv.lock gives it away
mkdir -p "${ws}/sub/deep"
ln -s sub/deep "${ws}/deep"
: > "${work}/uv.lock"
prefix='deep/../..'
same_dir "${ws}"

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
# The caller's UV_* variables, set in step(), never reach uv: only the
# environment the step creates under RUNNER_TEMP does
uv_env="$(cat "${work}/uv-env" 2> /dev/null)" || true
[[ "${uv_env}" == "UV_PROJECT_ENVIRONMENT=${work}/tmp/tox-venv."* ]] || ok=0
[ "$(wc -l 2> /dev/null < "${work}/uv-env")" = 1 ] || ok=0
[ "$(head -n 1 "${work}/uv" 2> /dev/null)" = 'sync' ] || ok=0
for flag in --frozen --no-config --no-install-project; do
  grep -sqxF -- "${flag}" "${work}/uv" || ok=0
done
grep -sqxF -- "${root}/tox-lock" "${work}/uv" || ok=0
grep -sqxF -- "${stubs}/interpreter" "${work}/uv" || ok=0
[ -f "${root}/tox-lock/uv.lock" ] || ok=0
report "${ok}" "tox comes from the action's frozen uv lock, unconfigured"

cases=$((cases + 1))
ok=1
step "${run}" '' '' || ok=0
# tox and the commands it runs keep the caller's UV_* variables, which
# a tox environment may pass through to its own uv
printf '%s\n' "UV_INDEX_URL=https://index.invalid/simple" \
  "UV_PROJECT_ENVIRONMENT=${work}/caller-venv" > "${work}/want"
cmp -s "${work}/want" "${work}/tox-env" 2> /dev/null || ok=0
report "${ok}" "tox sees the caller's UV_* variables"

cases=$((cases + 1))
ok=1
# On Windows setup-uv replaces UV_TOOL_DIR and UV_TOOL_BIN_DIR unless
# its inputs carry them, so the step must pass on the caller's values
for pair in 'tool-dir UV_TOOL_DIR' 'tool-bin-dir UV_TOOL_BIN_DIR'; do
  read -r input var <<< "${pair}"
  value="$(INPUT="${input}" yq \
    '.runs.steps[] | select(.id == "setup-uv") | .with[strenv(INPUT)]' \
    "${root}/action.yaml" 2> /dev/null)" || ok=0
  [ "${value}" = "\${{ env.${var} }}" ] || ok=0
done
report "${ok}" "setup-uv keeps the caller's uv tool directories"

echo "${cases} cases, ${failures} failed"
[ "${failures}" -eq 0 ]
