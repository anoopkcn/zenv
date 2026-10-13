# Some pyptojects impose a requires-python if zenv cant use this version notify user and exit

- STATUS: CLOSED
- PRIORITY: 100
- TAGS:

Maybe exit with an error message saying that project  requires a different version of Python and suggest the user to install the required version or use a virtual environment.

ask user to load the correct python version or install the required version. maybe give the commands to do so 


## Resolution (2026-10-13)

`zenv setup` now checks `[project].requires-python` before it creates the venv, and stops with advice when
the interpreter does not match. Uncommitted when written.

When it applies: the pyproject.toml is the env's `dependency_file`, or `--dev` installs `./pyproject.toml`
(which then takes precedence). A project whose dependency_file is requirements.txt is not checked without `--dev`.

- `src/utils/python.zig`: `satisfies(spec, version)`, a PEP 440 specifier matcher on release numbers
  (`>= <= > < == != ~=`, `.*` wildcards, comma sets; pre-releases count as the final release, as pip does).
  `===` and unreadable specifiers only warn and skip the check. `installedVersions()` was split out of
  `listInstalledVersions`.
- `src/utils/parse_deps.zig`: `pyprojectDescription` became `pyprojectField(content, key)`.
- `src/utils/envbuild.zig`: `Options.requires_python`; `checkRequiresPython` runs after `selectPython`, before
  `ensureVenv`, so a failed check leaves no venv behind. If an existing venv would be kept, its own Python is
  checked and the error says to `zenv rm` it. `Chosen.source` drives the advice:
  - module Python: change "modules" in zenv.json
  - otherwise: pin a matching zenv-installed Python (listed by version), or `zenv python install`, then pin;
    point `fallback_python` at one; with LMOD_CMD/MODULESHOME set, also load one through "modules".
    The pin advice is dropped when `fallback_python` is set, and only the pin advice is shown with `--python`.
- `src/commands.zig`: reads requires-python from the dependency file / `./pyproject.toml` for `--dev`.
- README (Python Management + help copy) and `zenv help` [b] footnote document it.

Tested: 2 new unit tests in python.zig (21 match cases, 8 invalid specifiers) plus an updated pyprojectField test;
149 unit tests pass. End to end with a scratch ZENV_DIR: system/fallback/pinned (--python) mismatches,
a matching fallback, a kept 3.12 venv after a bump to >=3.13, an invalid spec (warns, continues), --dev with a
requirements.txt dependency file, the MODULESHOME hint, and `zenv run` auto-setup after a requires-python
bump (fails, points to the log). Not tested: the module-Python branch on a real Lmod machine.
