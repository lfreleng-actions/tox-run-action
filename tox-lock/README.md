<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

# Tox lock

The action installs tox from `uv.lock` in this directory. The project
here exists to hold that lock and nothing else: it builds no package,
and it lists `tox` as its one dependency, with a lower bound.

tox runs on a pinned host Python, 3.13, that the action sets up for it
alone, while test environments run on the caller's Python. Since tox
itself runs on that host, the lock targets Python 3.11 and later, the
versions current tox supports, and holds one version of each package
with no `resolution-markers`. A lock that also covered older Pythons
would hold an older copy of tox and its dependencies for each, and
Dependabot would bump such a copy past the Python it serves. The lower
bound on tox makes an update that cannot resolve fail, rather than fall
back to an ancient tox. The lock records a sha256 hash for every file,
and the action installs it with `uv sync --frozen`, which never
resolves again.

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
