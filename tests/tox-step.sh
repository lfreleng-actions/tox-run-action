#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Exercises the handling of the path_prefix, tox-envs and parallel
# inputs in action.yaml. The validation step must keep path_prefix
# inside the workspace, through any symlink, and reject any tox-envs or
# parallel value that could reach the tox command line as an option;
# the run step must hand what it accepts to tox as separate arguments,
# whatever the value contains. The Python check must refuse to run tox
# on an interpreter older than the lock's floor.
#
# As in tests/pre-build-script.sh, yq extracts each step's run block
# from action.yaml and bash runs it with the flags GitHub uses for
# 'shell: bash', under an emptied environment. The run step gets stubs:
# a "uv" that records its arguments and environment, and builds a
# virtual environment whose Python stands in for tox and records its
# own, so no case installs or runs anything. The Install Python step
# runs against a "uv" that records the environment it gets.
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
check="${work}/check.sh"
extract 'Validate action/environment' "${validate}"
extract 'Check Python version' "${check}"
extract 'Detect dependency management tool' "${detect}"
extract 'Run tox' "${run}"
install="${work}/install.sh"
extract 'Install Python' "${install}"
refuse="${work}/refuse.sh"
extract 'Refuse an inherited UV_NO_MODIFY_PATH' "${refuse}"

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
# it sees, one per line, and puts the stub Python in the environment it
# was given. Started as 'python -I -m tox', that stub logs tox's
# arguments, and the UV_* and macOS launcher variables it sees; started
# any other way, it logs how instead.
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
cp "${STUB_DIR}/tox" "${UV_PROJECT_ENVIRONMENT}/bin/python"
EOF
cat > "${stubs}/tox" << 'EOF'
#!/bin/sh
if [ "$1" != '-I' ] || [ "$2" != '-m' ] || [ "$3" != 'tox' ]; then
  echo "not started as python -I -m tox: $*" > "${TOX_LOG}"
  exit 0
fi
shift 3
for arg; do printf '%s\n' "$arg"; done > "${TOX_LOG}"
pwd -P > "${TOX_CWD}"
env | grep -E '^(UV_|PYTHONEXECUTABLE=|__PYVENV_LAUNCHER__=)' | sort \
  > "${TOX_ENV}"
EOF
chmod +x "${stubs}"/*
# The interpreter setup-python reports, which every case puts back
python="${stubs}/interpreter"

# step <script> <tox-envs> <parallel>: run a step as the runner would,
# leaving its output in ${work}/out and its error output in
# ${work}/output. The caller's environment carries UV_* variables that
# would redirect uv's index and environment if they reached it, and the
# variables macOS reads to pick an interpreter even under -I.
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
    STEPS_SETUP_PYTHON_OUTPUTS_PYTHON_PATH="${python}" \
    PYTHON="${python}" PY_ARGS="${work}/py-args" \
    PYTHONEXECUTABLE="${stubs}/interpreter" \
    __PYVENV_LAUNCHER__="${stubs}/interpreter" \
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
  python="${stubs}/interpreter"
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

# python_reports <version> [<eol>]: setup-python's interpreter prints
# <version>, as Python does for the version query the check step makes,
# ending the line with <eol>, a printf escape: '\n' by default, or
# '\r\n' as Python on Windows does. It logs its arguments, and any
# macOS launcher variable it sees, to ${work}/py-args.
python_reports() {
  python="${work}/python"
  cat > "${python}" << 'EOF'
#!/bin/sh
for arg; do printf '%s\n' "$arg"; done > "$PY_ARGS"
env | grep -E '^(PYTHONEXECUTABLE|__PYVENV_LAUNCHER__)=' >> "$PY_ARGS"
EOF
  printf 'printf "%%s%s" "%s"\n' "${2:-\\n}" "$1" >> "${python}"
  chmod +x "${python}"
}

# python_ok <label>: the check step passes and publishes no error
python_ok() {
  local ok=1
  cases=$((cases + 1))
  step "${check}" '' '' || ok=0
  ! grep -q '^error=' "${work}/output" || ok=0
  report "${ok}" "accept ${1}"
}

# python_bad <label>: the check step fails with error=unsupported-python
python_bad() {
  local ok=1
  cases=$((cases + 1))
  ! step "${check}" '' '' || ok=0
  grep -qxF 'error=unsupported-python' "${work}/output" || ok=0
  report "${ok}" "reject ${1} as unsupported-python"
}

echo '== Python version'
python_reports '3.10'
python_bad 'Python 3.10, below the floor'
python_reports '2.7'
python_bad 'Python 2.7'
python_reports '3.11'
python_ok 'Python 3.11, the floor'
python_reports '3.14'
python_ok 'Python 3.14'
python_reports '4.0'
python_ok 'Python 4.0'
python_reports '3.12' '\r\n'
python_ok 'Python 3.12 printed with CRLF, as on Windows'
python_reports '3.10' '\r\n'
python_bad 'Python 3.10 printed with CRLF, as on Windows'
python_reports 'Python 3.12'
python_bad 'an unparsable version'
python_reports ''
python_bad 'an empty version'
# stubs/interpreter exits non-zero without printing anything
python_bad 'an interpreter that fails'
python=''
python_ok 'no interpreter from setup-python, leaving Install Python one'
# The query runs isolated: -I first, and no launcher variable
python_reports '3.12'
cases=$((cases + 1))
ok=1
step "${check}" '' '' || ok=0
[ "$(head -n 1 "${work}/py-args" 2> /dev/null)" = '-I' ] || ok=0
! grep -q '=' "${work}/py-args" 2> /dev/null || ok=0
report "${ok}" 'the version query runs python -I, launcher variables unset'
# The check and the lock must agree on the floor: the lock's
# requires-python passes and the minor version below it fails
floor="$(sed -n 's/^requires-python = ">=\([0-9.]*\)"$/\1/p' \
  "${root}/tox-lock/pyproject.toml")"
if [[ "${floor}" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
  python_reports "${floor}"
  python_ok "Python ${floor}, the lock's requires-python"
  python_reports "${BASH_REMATCH[1]}.$((BASH_REMATCH[2] - 1))"
  python_bad "Python ${BASH_REMATCH[1]}.$((BASH_REMATCH[2] - 1))"
else
  cases=$((cases + 1))
  : > "${work}/out"
  : > "${work}/output"
  report 0 "tox-lock/pyproject.toml sets requires-python as '>=X.Y'"
fi

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
python=''
rm -f "${work}/uv"
! step "${run}" '' '' || ok=0
[ ! -f "${work}/uv" ] || ok=0
report "${ok}" "with no Python to run tox, the run step stops before uv"

cases=$((cases + 1))
ok=1
step "${run}" '' '' || ok=0
# tox and the commands it runs keep the caller's UV_* variables, which
# a tox environment may pass through to its own uv, but not the macOS
# launcher variables
printf '%s\n' "UV_INDEX_URL=https://index.invalid/simple" \
  "UV_PROJECT_ENVIRONMENT=${work}/caller-venv" > "${work}/want"
cmp -s "${work}/want" "${work}/tox-env" 2> /dev/null || ok=0
report "${ok}" "tox sees the caller's UV_* variables, not the launcher ones"

echo '== setup-uv and interpreter contract'
# setup_uv <query>: the yq <query> applied to the setup-uv step
setup_uv() {
  QUERY="$1" yq -r \
    '.runs.steps[] | select(.id == "setup-uv") | eval(strenv(QUERY))' \
    "${root}/action.yaml" 2> /dev/null
}

cases=$((cases + 1))
ok=1
# setup-uv's own "uv python find" must fail before any lookup, from the
# action's directory, and put only the action's own directory on PATH,
# on every OS. Nothing else may be set: a python-version input or
# UV_SYSTEM_PYTHON, UV_MANAGED_PYTHON or UV_NO_MODIFY_PATH would reopen
# a lookup or leak to later steps.
[ "$(setup_uv '.with | keys | sort | join(" ")')" = \
  'enable-cache tool-bin-dir tool-dir version working-directory' ] || ok=0
want='UV_NO_CONFIG UV_NO_PROJECT UV_PYTHON_ARCH UV_PYTHON_INSTALL_DIR'
[ "$(setup_uv '.env | keys | sort | join(" ")')" = \
  "${want} UV_PYTHON_PREFERENCE" ] || ok=0
while read -r key want; do
  [ "$(setup_uv ".${key}")" = "${want}" ] || ok=0
done << 'EOF'
with.working-directory ${{ github.action_path }}
with.enable-cache false
with.tool-bin-dir ${{ runner.temp }}/tox-run-action/bin
with.tool-dir ${{ runner.os == 'Windows' && env.UV_TOOL_DIR || '' }}
env.UV_NO_CONFIG 1
env.UV_NO_PROJECT 1
env.UV_PYTHON_PREFERENCE lookup-disabled
env.UV_PYTHON_ARCH
env.UV_PYTHON_INSTALL_DIR ${{ runner.temp }}/tox-run-action/python
EOF
report "${ok}" "setup-uv runs no lookup and adds only its own dir to PATH"

cases=$((cases + 1))
ok=1
# An inherited UV_NO_MODIFY_PATH, empty or not, would make setup-uv
# start the caller's uv: a step before it must refuse the variable. On
# Windows setup-uv and uv match its name in any letter case, so the
# step must too; a name that merely contains it is not refused.
names="$(yq -r '.runs.steps[] | .id' "${root}/action.yaml")"
before="$(sed -n '/^setup-uv$/q;p' <<< "${names}")"
grep -qx 'no-modify-path' <<< "${before}" || ok=0
for name in '' UV_NO_MODIFY_PATH_X X_UV_NO_MODIFY_PATH; do
  env -i PATH="${PATH}" ${name:+"${name}=1"} \
    bash --noprofile --norc -eo pipefail "${refuse}" > /dev/null 2>&1 ||
    ok=0
done
for name in UV_NO_MODIFY_PATH uv_no_modify_path Uv_No_Modify_Path; do
  for value in '' 1; do
    ! env -i PATH="${PATH}" "${name}=${value}" \
      bash --noprofile --norc -eo pipefail "${refuse}" > /dev/null 2>&1 ||
      ok=0
  done
done
report "${ok}" "an inherited UV_NO_MODIFY_PATH, in any case, stops the action"

# Every run block, with continuation lines joined and comments dropped
yq -r '.runs.steps[] | select(has("run")) | .run' "${root}/action.yaml" |
  sed -e ':a' -e '/\\$/N' -e 's/\\\n//' -e 'ta' |
  grep -v '^[[:space:]]*#' > "${work}/runs"

cases=$((cases + 1))
ok=1
# uv runs only through setup-uv's uv-path, never from PATH, and each
# call names its Python by absolute path or runs with an empty
# environment
for var in UV STEPS_SETUP_UV_OUTPUTS_UV_PATH; do
  VAR="${var}" yq -r '.runs.steps[] | .env[strenv(VAR)] | select(. != null)' \
    "${root}/action.yaml" > "${work}/uv-vars"
  [ -s "${work}/uv-vars" ] || ok=0
  ! grep -vxF "\${{ steps.setup-uv.outputs.uv-path }}" \
    "${work}/uv-vars" > /dev/null || ok=0
done
! grep -E '(^[[:space:]]*|\$\(|[;&|][[:space:]]*)uvx?([[:space:]]|$)' \
  "${work}/runs" > /dev/null || ok=0
grep -E '"[$](UV|[{]STEPS_SETUP_UV_OUTPUTS_UV_PATH[}])"' "${work}/runs" \
  > "${work}/uv-calls" || ok=0
[ "$(wc -l < "${work}/uv-calls")" -ge 3 ] || ok=0
! grep -vE -- '--python "\$|/usr/bin/env -i ' "${work}/uv-calls" \
  > /dev/null || ok=0
report "${ok}" "every uv call names its Python or runs under env -i"

cases=$((cases + 1))
ok=1
# Python starts by absolute path from a variable, isolated, and the
# step clears the variables macOS reads even under -I first
grep -E '(^[[:space:]]*|\$\()"\$[{]?[A-Za-z_]+[}]?(/python)?" ' \
  "${work}/runs" | grep -E 'python" ' > "${work}/py-calls" || ok=0
[ "$(wc -l < "${work}/py-calls")" -ge 2 ] || ok=0
! grep -vE 'python" -I ' "${work}/py-calls" > /dev/null || ok=0
[ "$(grep -c '^[[:space:]]*unset PYTHONEXECUTABLE __PYVENV_LAUNCHER__$' \
  "${work}/runs")" -ge 2 ] || ok=0
! grep -E '(^[[:space:]]*|\$\(|[;&|][[:space:]]*)python3?([[:space:]]|$)' \
  "${work}/runs" > /dev/null || ok=0
report "${ok}" "every Python start is by absolute path, with -I"

echo '== Install Python'
# A uv that logs its arguments and the environment it gets, and reports
# the Python held in its 'found' file. env -i leaves it no variable to
# find its logs by, so it keeps them beside itself.
installer="${work}/installer"
mkdir -p "${installer}"
cat > "${installer}/uv" << 'EOF'
#!/bin/sh
dir="${0%/*}"
printf '%s\n' "$*" >> "${dir}/args"
/usr/bin/env >> "${dir}/env"
if [ "$1 $2" = 'python find' ]; then /bin/cat "${dir}/found"; fi
EOF
chmod +x "${installer}/uv"

# install <install dir> <found>: run the step with uv reporting <found>
# as the Python it installed under <install dir>, in an environment
# holding every interpreter selector a caller could set
install() {
  : > "${work}/output"
  rm -f "${installer}/args" "${installer}/env"
  printf '%s\n' "$2" > "${installer}/found"
  (cd -- "${root}" && env -i PATH="${stubs}:${PATH}" HOME="${HOME}" \
    GITHUB_OUTPUT="${work}/output" UV="${installer}/uv" \
    INSTALL_DIR="$1" CACHE_DIR="${work}/cache" PYTHON_VERSION='3.13' \
    HTTPS_PROXY='http://proxy.invalid:3128' \
    UV_PYTHON="${stubs}/interpreter" UV_SYSTEM_PYTHON=1 \
    UV_PYTHON_INSTALL_DIR="${work}/caller-python" \
    UV_PYTHON_INSTALL_MIRROR='https://127.0.0.1:9' \
    UV_INTERNAL__PARENT_INTERPRETER="${stubs}/interpreter" \
    VIRTUAL_ENV="${work}/caller-venv" CONDA_PREFIX="${work}/conda" \
    PYTHONPATH="${work}" PYTHONEXECUTABLE="${stubs}/interpreter" \
    bash --noprofile --norc -eo pipefail "${install}") \
    > "${work}/out" 2>&1
}

cases=$((cases + 1))
ok=1
dir="${work}/python"
install "${dir}" "${dir}/cpython-3.13/bin/python3.13" || ok=0
grep -qxF "path=${dir}/cpython-3.13/bin/python3.13" "${work}/output" ||
  ok=0
grep -qxF 'python install --quiet --no-bin 3.13' "${installer}/args" ||
  ok=0
grep -qxF 'python find --managed-python 3.13' "${installer}/args" || ok=0
# uv sees the allow-list, and what sh adds, and nothing else
sed 's/=.*//' "${installer}/env" | sort -u > "${work}/names"
printf '%s\n' HTTPS_PROXY OLDPWD PWD SHLVL UV_CACHE_DIR UV_NO_CONFIG \
  UV_NO_PROJECT UV_PYTHON_INSTALL_DIR _ | sort > "${work}/allowed"
[ -z "$(comm -23 "${work}/names" "${work}/allowed")" ] || ok=0
grep -qxF "UV_PYTHON_INSTALL_DIR=${dir}" "${installer}/env" || ok=0
grep -qxF 'HTTPS_PROXY=http://proxy.invalid:3128' "${installer}/env" ||
  ok=0
report "${ok}" "uv installs Python with only the allow-list to steer it"

cases=$((cases + 1))
ok=1
! install "${dir}" "${work}/caller-venv/bin/python" || ok=0
! grep -q '^path=' "${work}/output" || ok=0
report "${ok}" "a Python outside the install directory stops the step"

cases=$((cases + 1))
ok=1
# On Windows runner.temp has backslashes and the step appends slashes
install 'D:\a\_temp/tox-run-action/python' \
  'D:\a\_temp\tox-run-action\python\cpython-3.13\python.exe' || ok=0
grep -qxF 'path=D:\a\_temp\tox-run-action\python\cpython-3.13\python.exe' \
  "${work}/output" || ok=0
report "${ok}" "a Windows path inside the install directory passes"

echo "${cases} cases, ${failures} failed"
[ "${failures}" -eq 0 ]
