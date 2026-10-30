<!--
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# 🧪 Tox Run Action

A GitHub Action to run tox on specific environments with Python version
management and optional pre-build scripts.

## tox-run

This action provides a streamlined way to run tox testing environments in
GitHub workflows, with support for different Python versions, parallel
execution, and custom build scripts.

## Prerequisites

This action requires:

- **tox.ini**: Must exist in the project directory

The action installs tox itself, from a hashed lock file, so the runner
needs no tox or `pipx` of its own.

## Usage Example

<!-- markdownlint-disable MD046 -->

```yaml
steps:
  - name: "Run tox tests with explicit Python version"
    id: tox-run
    uses: lfreleng-actions/tox-run-action@main
    with:
      path_prefix: './my-project'
      python-version: '3.11'
      tox-envs: 'py311,lint,docs'
      parallel: 'auto'
      pre-build-script: './scripts/setup.sh'

  - name: "Run tox tests with version from file"
    id: tox-run-from-file
    uses: lfreleng-actions/tox-run-action@main
    with:
      path_prefix: './my-project'
      python-version-file: '.python-version'
      tox-envs: 'py311,lint,docs'
      parallel: 'auto'

  - name: "Use build-backend output in next step"
    id: show-backend
    run: |
      echo "Detected build backend: ${{ steps.tox-run.outputs.build-backend }}"
      if [[ "${{ steps.tox-run.outputs.build-backend }}" == "poetry" ]]; then
        echo "Using Poetry-specific commands..."
      fi
```

<!-- markdownlint-enable MD046 -->

## Inputs

<!-- markdownlint-disable MD013 -->

| Name                | Required | Default | Description                                                     |
| ------------------- | -------- | ------- | --------------------------------------------------------------- |
| path_prefix         | False    | '.'     | Directory containing tox.ini, inside the workspace              |
| python-version      | False    | -       | Version of Python to use                                        |
| python-version-file | False    | -       | File containing the Python version to use (e.g. pyproject.toml) |
| tox-envs            | False    | -       | Comma-separated tox envs to run on this py-version; no spaces   |
| parallel            | False    | 'auto'  | Parallel processes: auto, all, a number, or off/empty           |
| pre-build-script    | False    | -       | Path to optional pre-build script to run before tox             |

<!-- markdownlint-enable MD013 -->

## Outputs

<!-- markdownlint-disable MD013 -->

| Name          | Description                                          |
| ------------- | ---------------------------------------------------- |
| build-backend | Detected Python dependency management tool           |
| error         | Reason input validation stopped the action, or empty |

Note: detected build backend values are uv, pdm, poetry, pipenv, pip-tools, pip, or none

The action fails at the first input check that does not pass, and sets
`error` to identify that check. Read it from a step with
`continue-on-error: true` to tell one failure from another:

<!-- markdownlint-disable MD013 -->

| Check                                         | error                         |
| --------------------------------------------- | ----------------------------- |
| `path_prefix` directory missing               | missing-path-prefix           |
| Workspace path does not resolve               | workspace-unresolved          |
| `path_prefix` path does not resolve           | path-prefix-unresolved        |
| `path_prefix` resolves outside workspace      | path-prefix-outside-workspace |
| `tox.ini` missing from `path_prefix`          | missing-tox-ini               |
| `tox.ini` not readable                        | unreadable-tox-ini            |
| `tox-envs` not comma-separated env names      | invalid-tox-envs              |
| `parallel` not auto, all, off or a number     | invalid-parallel              |
| `pre-build-script` path contains `..`         | script-path-traversal         |
| `pre-build-script` name lacks `.sh` suffix    | script-not-sh                 |
| `pre-build-script` path does not resolve      | script-unresolved             |
| `pre-build-script` resolves outside workspace | script-outside-workspace      |
| `pre-build-script` file missing               | script-not-found              |
| `pre-build-script` not executable             | script-not-executable         |

<!-- markdownlint-enable MD013 -->

## Implementation Details

The action performs the following steps:

1. **Directory Validation**: Verifies that `path_prefix` exists and contains a
   `tox.ini` file before proceeding
2. **Python Setup**: Configures the specified Python version using
   `actions/setup-python`
3. **Pre-build Script**: Executes an optional pre-build script if provided
4. **Dependency Detection**: Automatically detects the dependency management
   tool (uv, PDM, Poetry, Pipenv, pip-tools, or pip) and outputs it as
   `build-backend`
5. **Tox Execution**: Installs tox from `requirements/tox.txt` into a
   virtual environment on the configured Python, then runs it with the
   specified environments and parallel settings

The action automatically handles:

- **Smart dependency detection** from these formats (reported via
  `build-backend` output):
  - `uv.lock` (uv) - highest priority
  - `pdm.lock` (PDM)
  - `poetry.lock` (Poetry)
  - `Pipfile.lock` (Pipenv)
  - `requirements.txt` with `requirements.in` (pip-tools)
  - `requirements.txt` (plain pip)
  - `pyproject.toml` (fallback)
- Parallel execution configuration
- Environment-specific tox runs

**Note:** Tox manages its own dependencies and builds packages in isolated
environments. The action does not install dependencies directly.

## Notes

- The action installs tox from `requirements/tox.txt`, a lock with a
  hash for every package, into a virtual environment of its own. The
  lock picks the newest tox that supports the configured Python, so
  Python 3.8 to 3.10 get an older tox than 3.11 and later. Dependabot
  keeps it current; to refresh it by hand, run the command in its header
- Tox handles package building internally when `tox.ini` sets
  `isolated_build = True`
- When `tox-envs` is not specified, tox will run its default environments
- The `pre-build-script` path is relative to the repository root, and must
  resolve, after following any symlinks, to a file inside the workspace
- `tox-envs` takes environment names separated by commas, such as
  `py311,lint`, with no spaces. The action refuses anything else, so a
  value cannot pass tox an option such as `--notest`
- `parallel` takes `auto`, `all` or a process count; `off` or an
  empty value runs the environments in turn
- The action validates that `path_prefix` exists, resolves, after
  following any symlinks, to the workspace or a directory inside it, and
  contains `tox.ini` before proceeding
- The action changes to the `path_prefix` before executing tox commands
- **Input precedence**: When both `python-version` and
  `python-version-file` exist, `python-version` takes precedence and
  `python-version-file` gets ignored
- **Dependency detection**: The action detects which dependency management
  tool your project uses (for informational purposes). Detection
  priority order:
  1. **uv** (uv.lock) - Modern, fast Python package manager
  2. **PDM** (pdm.lock) - PEP 582 compliant dependency manager
  3. **Poetry** (poetry.lock) - Popular Python packaging tool
  4. **Pipenv** (Pipfile.lock) - Python dependency management
  5. **pip-tools** (requirements.txt + requirements.in) - Pin management
  6. **pip** (requirements.txt) - Standard Python package installer
  7. **pyproject.toml** (editable install) - Fallback for PEP 621 projects

  Note: tox manages dependencies in isolated environments. The detection
  result is available via the `build-backend` output.
- If neither `python-version` nor `python-version-file` specifies a version,
  `actions/setup-python` automatically uses the version from a
  `.python-version` file if present, or falls back to the system default.
- You can explicitly specify a file to determine the Python version using
  `python-version-file`. Supported formats include `.python-version`,
  `pyproject.toml`, `.tool-versions`, and `Pipfile`.
- The `build-backend` output shows which dependency management tool the
  action detected in your project
