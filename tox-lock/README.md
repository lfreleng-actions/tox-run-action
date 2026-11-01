<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

# Tox lock

The action installs tox from `uv.lock` in this directory. The project
here exists to hold that lock and nothing else: it builds no package,
and it lists `tox` as its one dependency.

The lock covers every Python from 3.8 up, and picks the newest tox each
version supports, so Python 3.8, 3.9 and 3.10 each get an older tox
than 3.11 and later. It records a sha256 hash for every file, and the
action installs it with `uv sync --frozen`, which never resolves again.

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
