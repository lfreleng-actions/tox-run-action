# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""Check that the tox lock holds one set of versions.

tox-lock/uv.lock must target only Pythons that every package in it
supports: no resolution-markers, so no per-Python sections, a single
tox, and that tox at or above the tox>= bound in pyproject.toml. A lock
that forks per Python holds older copies of its packages, which
Dependabot bumps to releases that drop their Python.

Usage: python3 tests/check-tox-lock.py [<lock directory>]
(defaults to tox-lock/ beside this script; needs Python 3.11+)
"""

import re
import sys
import tomllib
from pathlib import Path
from typing import cast

ADVICE = """\
The tox lock must hold one set of versions, for every Python from the
floor in tox-lock/pyproject.toml up. If tox has dropped support for
that floor, do not accept a lock with per-Python sections: raise
requires-python in tox-lock/pyproject.toml and the floor in the
'Check Python version' step of action.yaml together, then regenerate
the lock, as tox-lock/README.md describes."""


def release(version: str) -> tuple[int, ...]:
    """Return the numeric release segment of a version string."""
    match = re.match(r"\d+(?:\.\d+)*", version)
    if not match:
        raise ValueError(f"unparsable version {version!r}")
    return tuple(int(part) for part in match.group().split("."))


def load(path: Path) -> dict[str, object]:
    """Parse a TOML file."""
    with path.open("rb") as handle:
        return cast("dict[str, object]", tomllib.load(handle))


def table(value: object) -> dict[str, object]:
    """Return value as a TOML table, or an empty one."""
    if not isinstance(value, dict):
        return {}
    return cast("dict[str, object]", value)


def tables(value: object) -> list[dict[str, object]]:
    """Return the TOML tables in value, if it is a list."""
    if not isinstance(value, list):
        return []
    return [table(item) for item in cast("list[object]", value)]


def strings(value: object) -> list[str]:
    """Return the strings in value, if it is a list."""
    if not isinstance(value, list):
        return []
    return [item for item in cast("list[object]", value) if isinstance(item, str)]


def problems(directory: Path) -> list[str]:
    """Return what is wrong with the lock in directory, if anything."""
    project = table(load(directory / "pyproject.toml").get("project"))
    lock = load(directory / "uv.lock")

    found: list[str] = []
    wanted = project.get("requires-python")
    if lock.get("requires-python") != wanted:
        found.append(
            f"uv.lock requires-python {lock.get('requires-python')!r} "
            + f"differs from pyproject.toml's {wanted!r}"
        )
    if "resolution-markers" in lock:
        found.append("uv.lock forks by Python: it has resolution-markers")
    packages = tables(lock.get("package"))
    for package in packages:
        if "resolution-markers" in package:
            found.append(
                f"{package.get('name')} {package.get('version')} has "
                + "resolution-markers"
            )

    floors = [
        match.group(1)
        for spec in strings(project.get("dependencies"))
        if (match := re.fullmatch(r"tox\s*>=\s*([0-9][0-9.]*)", spec))
    ]
    if len(floors) != 1:
        found.append("pyproject.toml must depend on tox as 'tox>=<version>'")
    toxes = [str(p.get("version")) for p in packages if p.get("name") == "tox"]
    if len(toxes) != 1:
        found.append(f"uv.lock holds {len(toxes)} tox entries, not one")
    elif len(floors) == 1 and release(toxes[0]) < release(floors[0]):
        found.append(f"uv.lock holds tox {toxes[0]}, below {floors[0]}")
    return found


def main() -> int:
    """Report problems with the tox lock; exit non-zero on any."""
    default = Path(__file__).resolve().parent.parent / "tox-lock"
    directory = Path(sys.argv[1]) if len(sys.argv) > 1 else default
    found = problems(directory)
    if not found:
        print(f"✅ {directory / 'uv.lock'} holds one set of versions")
        return 0
    for problem in found:
        print(f"::error::{problem}")
    print(ADVICE)
    return 1


if __name__ == "__main__":
    sys.exit(main())
