# add zenv remove to undo zenv add

- STATUS: CLOSED
- PRIORITY: 100
- TAGS:

`zenv add <env> <package>` had no inverse. Removing a package meant deleting its line from the manifest by hand, and the package stayed installed in the venv until the env was rebuilt.

## Resolution (2026-11-12)

`zenv remove <name|id|.> <package> [--dev | --group <name>] [--zenv] [--uv|--pip]` removes the package from the manifest and then uninstalls it from the venv.

The flags pick the manifest exactly as they do for `add` (`sources.recordTarget`), so `remove` looks only in the place `add` would have recorded into with the same flags. When the package is not there, nothing is removed, the command exits 1, and the error names every other place of the env that records it together with the flags that reach it. The one exception mirrors `add`: a runtime package that `pyproject.toml` does not list is looked for in zenv.json `dependencies`, because `add` falls back to zenv.json when there is no `[project]` table. A version, extras or marker given with the name is ignored.

The manifest is edited first, so a failed uninstall leaves a package too many and never one that is recorded but missing. The package is then uninstalled unless one of these holds:

- Another manifest of the env still records it: zenv.json `dependencies` or `dev_dependencies`, the `dependency_file`, the `dev` group, or a dependency group the build record replays.
- An installed package requires it. A short Python script run in the env (`uninstall_probe` in `src/commands.zig`) checks this with `importlib.metadata` and answers by exit status.
- The venv does not hold it, because a module or the container image provides it.

Packages that were installed only because the removed package required them stay installed, as with `pip uninstall`. A rebuild creates the venv afresh, which drops them.

An env that was up to date stays up to date (`autosetup.Change`), so the next `zenv run` does not rebuild. An env that is registered but not built only has its manifest edited.

The changes by file:

- `src/manifest.zig` has `removeFromRequirementsTxt`, `removeFromZenvJson` and `removeFromPyproject`, each with a `check` mode that writes nothing. A requirements entry goes with its `\` continuation lines. `editPyproject` now shares `splitLines`, `locate` and `closingBracket` with the removal code.
- `src/jsonc.zig` has `removeItem`, the edit that takes one array element out with its comma.
- `src/sources.zig` has `unrecord`, `recordedIn` and `Record.describe`.
- `src/envbuild.zig` has `recordRemoved`, which drops the package from the venv's `requirements.txt` record.
- `src/autosetup.zig` has `replayedGroups`.
- `src/commands.zig` has `handleRemove` and `uninstallPackage`. `addGroup` now names the running command in its messages.
- `src/help.zig`, `src/main.zig`, `src/errors.zig`, `README.md` and `CONTEXT.md` list the command.

`zig build test` passes, with new unit tests for the three manifest editors, `unrecord`, `recordedIn` and `recordRemoved`. The command was run by hand against a scratch `ZENV_DIR` with both the uv and the pip uninstall, for a zenv.json manifest, a requirements file and a pyproject.toml with groups: a plain removal, a package recorded elsewhere (the hint), a package recorded twice, a package another one requires, a stale env, and an unbuilt env.

These cases were not run:

- A container env. There the uninstall always uses `python -m pip` inside the image, because the host's uv is not bound into `zenv run`. It depends on the image providing pip.
- An env with HPC modules, where the probe should report a module-provided package as not in the venv.

Known limits:

- A package listed only in a file that the requirements file includes with `-r` is reported as not recorded.
- A dependency group the build does not replay is not checked before uninstalling.
- Emptied arrays stay in the manifest (`dependencies = []`), and a replayed group stays replayed when it becomes empty.
