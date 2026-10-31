# Bug and optimization analysis 2026-10-31

- STATUS: OPEN
- PRIORITY: 100
- TAGS:

The analysis split zenv into four slices, each reviewed separately: the uncommitted refactor
(task 20261030-232733), the build pipeline, the registry and CLI, and activation and launch.
Every finding was reproduced with the binary in an isolated ZENV_DIR/HOME (CONFIRMED) or traced
through the code (PLAUSIBLE). The repro projects are in the session scratchpad and are not kept.

Settled decisions were excluded: cache replay without purge, rm keeping kernels, the name in the
stamp hash, subprocess rebuilds, the activate.sh purge, Python built from source, the startup
floor, and the deferred items.

## Findings (checked 2026-10-31)

### Data loss or a silently wrong environment

- H1 `zenv rm` can delete the project dir or ZENV_DIR (CONFIRMED; reproduced again by the main
  session). `{"base_dir":"..","C":{...}}` builds env C into the project dir itself, and `zenv rm C`
  deletes the whole project. The same happens with base_dir = the parent of ZENV_DIR and the env
  named after it. setup only refuses base_dir == ZENV_DIR (paths.baseDirIsZenvDir), register has
  no guard, and rm `deleteTree`s unchecked (commands.zig handleRm). Fix: in setup/register,
  refuse env dirs that equal or contain the project dir or overlap ZENV_DIR; in rm, delete only a
  dir with a zenv marker that is not the project dir and does not contain it.
- H2 On an Lmod host, `fallback_python` and the pinned Python are ignored (CONFIRMED with a fake
  LMOD_CMD; the main session checked the code). `loadModules` returns true whenever a module system
  exists, even with no modules, and `workingPython` then takes the first python3 on PATH as
  "module-provided", which `selectPython` ranks first (envbuild.zig ~111-129, 855, 1075). Fix: treat
  a Python as module-provided only if the module delta prepended its directory to PATH.
- H3 Changing the interpreter keeps the old venv (CONFIRMED). After a fallback_python or Python
  module change, the rebuild says "Using existing valid virtual environment" and keeps the old
  bin/python; the system_site branch then rewrites pyvenv.cfg for the new one (ensureVenv ~1122).
  Fix: compare pyvenv.cfg version/executable with the chosen interpreter and recreate the venv.
- H4 A pyproject.toml with an empty inline table (`environment = {}`, as in pandas) means zero
  deps, and setup still succeeds with exit 0 (CONFIRMED). zig-toml `parseInlineTable` rejects
  `{}`; deps.zig logs the error and goes on; requires-python is skipped too. Fix: a parse failure
  of the dependency_file is fatal; patch zig-toml to accept `{}`.
- H5 Registration is upserted by name only (Registry.zig ~276). Setting up `dev` in clone B moves
  clone A's registration to B, and `zenv rm dev` typed in A deletes B's venv (CONFIRMED). Fix:
  refuse or warn when the project_dir differs.
- H6 requirements.txt: `\` continuations (pip-compile --generate-hashes) break the install;
  `-r`, `-c`, `--index-url`, `--extra-index-url` and `-e` are dropped with only a warning
  (CONFIRMED; deps.zig ~270-323). Fix: join continuations; pass option lines through.
- H7 Dedup by bare name drops real requirements: marker-split pins (`numpy<2; python_version<'3.9'`
  plus `numpy>=2; ...`) keep only the first, and two `git+ssh://git@...` URLs collapse to one
  (CONFIRMED; deps.zig validateDependencies). The manifest editors and recordAdded hit the same
  collision. Fix: dedup on name and marker; don't dedup URL-only lines.
- H8 `zenv run` aborts when any activate command fails: launch.zig `run_runner` uses `set -e`, so
  the command never runs, nothing is printed, rc=1. Sourcing activate.sh interactively carries on
  (CONFIRMED). Fix: `. "$1" || :` without `set -e`, after checking that $1 is readable.
- H9 `rename` leaves an expanded `${ZENV_ENV_DIR}` in the middle of an env value pointing at the
  old dir (`/opt/x:${ZENV_ENV_DIR}/lib`, `--prefix=${ZENV_ENV_DIR}`). Nothing rebuilds it, because
  rename restamps (CONFIRMED; envspec.relocate/movePath). Fix: regenerate userOps for the new path.
- H10 `rename old new` onto a `new` that zenv.json already defines prints an error but exits 0.
  The env then runs as `new` with `old`'s config and no rebuild (CONFIRMED; commands.zig rename
  pre-checks). Fix: check zenv.json for `new` before anything moves.
- H11 `zenv add X --group G` (or `--dev` into an existing pyproject dev group) restamps the env
  with `--group G` as up to date, though G's other packages were never installed (CONFIRMED; the
  bug predates the refactor: HEAD's addReplayGroup + restamp). Fix: if replayGroup newly added the
  group, skip the rehash so the next gated command installs it.

### Wrong behavior, with a workaround or a narrower trigger

- M1 Regression from the refactor: `pythonDisabled` requires the whole zenv.json to be valid.
  An invalid sibling env makes `setup X --init --no-python` say X "has Python", and makes
  `jupyter create` fail with "Python executable not found" (CONFIRMED). Fix: return ?bool and
  report the file problem on null.
- M2 A nested shell started from an activated one (exec zsh, tmux) inherits the env but not
  deactivate or the save vars. Re-activating stacks PYTHONPATH and PATH, and leaving the project
  leaves the env half on (CONFIRMED, zsh hook). Fix: export the _ZENV_OLD_* / _ZENV_ACTIVE state.
- M3 The cd hook (activate --auto) activates a project's only env even when its target_machines
  exclude this host (CONFIRMED). On a shared HPC home, a jureca env activates on juwels. Fix:
  activateAuto prints nothing unless the targets match.
- M4 rename only renames the `zenv-<old>` kernel. A kernel created with `--name` keeps
  `run <old>`, and a custom display name is reset (CONFIRMED). Fix: rewrite every kernel.json
  whose argv is `run <old>`.
- M5 manifest pyproject edits:
  - `{include-group = "x"}` inside an inline array is treated as a package, so the include is
    lost;
  - a multi-line array ending in an inline table without a trailing comma gets invalid TOML;
  - the group key is matched exactly, so `--group test_utils` next to `test-utils` adds a
    duplicate group (PEP 735 forbids it);
  - `dynamic = ["dependencies"]` gets a static `dependencies` written;
  - replacing a hashed requirements.txt line orphans its `--hash` continuation.

  All CONFIRMED except the backend-rejection part of the dynamic case.
- M6 `fallback_python` pointing at a missing interpreter silently falls through to system python3
  (CONFIRMED). Fix: warn or fail.
- M7 Atomic writes replace a symlinked zenv.json with a regular file and reset its mode to 644
  (CONFIRMED; runtime.writeFileAtomic). Fix: realpath first and keep the mode.
- M8 Usage hints and the README use an unquoted `source $(zenv activate X)`, which breaks when
  the venv path has a space (CONFIRMED in bash and zsh). Fix: quote it everywhere.
- M9 csh:
  - a `!` or `$` in the venv path breaks activate.csh, because the deactivate alias body is
    history-expanded;
  - a multi-line value in a touched var aborts activate.csh ("Unmatched '"'").

  Both CONFIRMED in tcsh. Fix: keep the path in a variable for the alias; use `$X:q`.
- M10 pip mode drops the extras of a requirement that a module provides (`dask[distributed]`
  with a module dask) (PLAUSIBLE). The uv mode is correct.
- M11 The direct `zenv run` launch cannot run a shebang-less executable script (ENOEXEC →
  InvalidExe, error printed twice). A non-executable file or a dir gives rc=1, not 126
  (CONFIRMED). Fix: retry through /bin/sh; map AccessDenied/IsDir to 126.

### Minor

- L1 Refactor: `autosetup.buildOf` returns `groups.items` but `currentHash` frees it as owned.
  This is a no-op under the arena and panics under a checking allocator (CONFIRMED in a scratch
  test). Fix: toOwnedSlice.
- L2 Refactor: `zenv add` on an env missing from zenv.json prints two errors (CONFIRMED).
- L3 rename exits 0 when updating zenv.json fails (CONFIRMED).
- L4 Validation accepts env names starting with `-`, which no command can address (CONFIRMED).
- L5 `target_machines` elements are not checked: `""` becomes "any" in the registry, and an
  element containing `,` splits differently (CONFIRMED).
- L6 Help says `--no-host` equals `target_machines ["*"]`, but the registry keeps the real
  targets, so `zenv ls` hides the env (CONFIRMED).
- L7 The first registry creation is not under the lock, so an entry can be lost on a concurrent
  first run (PLAUSIBLE; not hit in 1,200 attempts).
- L8 A zenv.json starting with a UTF-8 BOM fails at 1:1, while modules_file accepts a BOM
  (CONFIRMED).
- L9 sh deactivate does not restore an empty or unset PATH (CONFIRMED; csh and fish do).
- L10 `zenv run env -- cmd` treats `--` as the command (CONFIRMED).
- L11 The README says pip installs use `--no-build-isolation`; requirement installs don't pass
  it (PLAUSIBLE: the docs or the code is wrong).
- L12 A failed `make install` can leave a Python version that counts as installed (PLAUSIBLE).
- L13 Stub wheels for module packages with a `-` in the version don't resolve (PLAUSIBLE).
- L14 The container kernel check follows the bin/python symlink into the image path, which
  doesn't exist on the host (PLAUSIBLE).
- Upgrade note, not a bug: envs built with `--group`/`--dev` from a non-dependency_file
  pyproject rebuild once after the refactor (the intended hash change).

## Optimizations (measured; none significant)

- No-op `setup --uv` takes ~0.05 s; each uv step ~8 ms warm. `zenv run` direct 4.0 ms,
  `activate` 2.7 ms, `activate --auto` 2.8 ms (hyperfine).
- With module packages: the stub-wheel step starts Python (~20-30 ms) and could be done in Zig.
  `zenv add` re-resolves the whole recorded set every time, which is fine warm and hits the
  index cold.
- `launch.start` parses zenv-env.json twice (containerOf, then environ).
- `checkRequiresPython` runs `python --version` on a kept venv; pyvenv.cfg already has the
  version.
- Change.begin re-validates and re-hashes what add just loaded, and reads a stamp copy that
  add/rename never use: sub-ms next to an install.

## Open questions

- Q1 H5: should a name be allowed in two projects at once (clones/worktrees), or refused with
  a message naming the other project? **Decided 2026-10-31: allowed.** The registry key becomes
  (name, project_dir).
- Q2 L11: should requirement installs use `--no-build-isolation` (module build deps visible), or
  should the README change? **Decided 2026-10-31: add the flag.**
- Q3 H4: how should zig-toml's rejection of `{}` be fixed? zig-toml is not vendored. It is
  fetched from github.com/sam701/zig-toml at a pinned commit (build.zig.zon), and zig-pkg/ is
  only the ignored fetch cache, so a patch made there would be lost. The options:
  - upstream: a PR to sam701/zig-toml, then bump the commit;
  - point build.zig.zon at a fork;
  - copy the library into the repo.

  Making a dependency_file parse failure fatal is needed in every case.

## Resolution, partial (2026-10-31)

Fixed and verified (uncommitted). 192 unit tests pass, `zig fmt` is clean, and the x86_64-linux-musl
cross-build succeeds. The scratch e2e transcript is identical to the one before the fixes, so the
fixes changed nothing else on its 72 steps.

- **Refactor regressions:**
  - L1: `buildOf` now uses toOwnedSlice.
  - L2: add on an env missing from zenv.json returns the silent EnvironmentNotConfigured.
  - M1: `pythonDisabled` returns ?bool. setupInit falls through to the loud load; jupyter create
    reads the venv when zenv.json is unusable.
- **H1:** `paths.envDirOverlap` replaces baseDirIsZenvDir. setup and register refuse an env dir that
  is or contains the project dir, or is or contains ZENV_DIR, sits directly in it, or lies in
  `$ZENV_DIR/python`. rm also refuses a dir without a setup marker (zenv-env.json, .zenv.stamp,
  zenv_setup.log) and points to `zenv deregister`. Reproduced: base_dir ".." is refused, and the
  project is untouched.
- **H2:** loadModules returns the PATH entries the modules added (from the delta or the cache ops).
  workingPython counts a Python as the modules' only if its dir is among them. Checked with a fake
  LMOD_CMD: fallback 3.12 is selected.
  - Limit: when a load removes an entry of the base PATH, moduleDelta prepends the whole PATH, as
    before.
- **H3:** `keepsVenv` compares the realpath of the chosen interpreter with pyvenv.cfg
  `executable`. On a mismatch, ensureVenv clears the Python parts and recreates them;
  checkRequiresPython uses the same rule.
  - First attempt compared `home` dirs. That rebuilt Homebrew venvs on every setup, and the e2e
    diff caught it.
  - Checked: 3.12 → 3.13 switch gets a new venv with packages; a Homebrew venv is kept on
    re-setup.
- **H4 (zenv side):** an unparsable pyproject dependency_file is error.InvalidPyproject.
  zig-toml's `{}` rejection is still open (Q3).
- **H5 (Q1 decided):** registry entries are keyed by (name, project_dir).
  - A duplicate name resolves to the cwd's project (nearest zenv.json); anywhere else it is
    ambiguous, and the message lists each project and id.
  - Aliases attach by id. nameTaken is per project. Kernels of a duplicated name run
    `zenv run <id>` (`Registry.launchIdentifier`).
  - Checked with two clones: each resolves to its own env, and rm in A keeps B.
  - Limit: renaming a duplicated-name kernel is not handled.
- **H6:** requirements files: `\` continuations are joined; option lines are kept, with
  `-r/-c/-e/-f` paths anchored at the file's dir. Checked: `-r base.txt` installs.
- **H7:** packageBaseName returns "" for options, URLs and paths. Duplicates need the same name and
  the same marker; unnamed lines dedup only when identical.
- **H8:** the run_runner has no `set -e`: `source "$1" || :` after a readability check. Checked: a
  failing activate command no longer stops the run, and its exit code passes through.
- **H9:** movePath replaces every whole-path occurrence of the old venv dir. Checked:
  `/opt/x:${ZENV_ENV_DIR}/lib` and `--prefix=${ZENV_ENV_DIR}` move on rename.
- **H10:** rename refuses a new name that the project's zenv.json already defines.
  **L3:** a failed zenv.json update exits 1.
- **H11:** `Change.replayGroup` leaves the env stale when the group is new to the build.
- **L11 (Q2 decided):** pip installs pass `--no-build-isolation` everywhere: installerArgv, and
  add's pip path.

Still open: H4's zig-toml fix (Q3), and all M and L items not listed above (M2-M11, L4-L10,
L12-L14).
