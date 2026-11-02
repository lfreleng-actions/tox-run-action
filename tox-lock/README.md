<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

# Tox lock

The action installs tox from `uv.lock` in this directory. The project
here exists to hold that lock and nothing else: it builds no package,
and it lists `tox` as its one dependency.

The lock covers Python 3.11 and newer, the oldest Python current tox
supports, and nothing below it. Every package it holds then supports
every Python it targets, so it records one version of each, with no
`resolution-markers` and no per-Python sections. A lock that reached
back to older Pythons would hold an older copy of tox and its
dependencies for each of them, and Dependabot bumps such a copy to a
release that no longer supports its Python, breaking the lock. The
`tox>=` lower bound in `pyproject.toml` makes such an update fail to
resolve instead of falling back to an ancient tox.

The lock records a sha256 hash for every file, and the action installs
it with `uv sync --frozen`, which never resolves again. Before that,
the action stops with `unsupported-python` when the interpreter that
would run tox is older than the floor.

## Maintenance

Dependabot's `uv` ecosystem keeps the lock current, with a seven-day
cooldown on new releases.

To refresh it by hand, run this from the repository root, with
`<date>` set to seven days ago in RFC 3339 form, such as
`2026-10-25T00:00:00Z`, to match that cooldown:

```bash
uv lock --upgrade --no-config --project tox-lock --exclude-newer <date>
```

uv records the cutoff in `uv.lock` as `exclude-newer` under
`[options]`. Delete those lines before committing, then confirm
`uv lock --check --no-config --project tox-lock` passes: a fixed cutoff
left in the lock would stop Dependabot moving past that date.

Delete `uv.lock` before a refresh that changes `requires-python`: an
upgrade in place can keep stale `resolution-markers` from the old range.

## Raising the floor

When tox drops support for the current floor (Python 3.11 reaches end
of life in October 2027), raise the floor rather than accept a lock
with per-Python sections. Change these together:

- `requires-python` and the `tox>=` bound in `pyproject.toml`;
- `min_major` and `min_minor` in the `Check Python version` step of
  `action.yaml`;
- the Python matrix of `test-tox-lock` in
  `.github/workflows/testing.yaml`, its `unsupported-python` case and
  the `unsupported-python` case of `test-error-handling`, and the
  fixed versions in `tests/tox-step.sh`;
- the floor stated in the repository's `README.md`.

Then regenerate the lock as above.

## Guard

`tests/check-tox-lock.py` runs on every pull request, Dependabot's
included, and fails when `uv.lock` has any `resolution-markers`, holds
more than one tox, or holds a tox below the `tox>=` bound. A failure
there means an update needs a newer Python than the floor: raise the
floor as above rather than accept a lock with per-Python sections.
