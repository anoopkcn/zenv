# add zenv clean to remove an env's bytecode caches

- STATUS: CLOSED
- PRIORITY: 100
- TAGS:

Since v0.33.1 zenv no longer stops Python from writing bytecode (task 20261112-194232). An env without a `PYTHONPYCACHEPREFIX` then collects `__pycache__` directories in its venv, and envs built with pip have them already, because pip compiles what it installs. There was no command to remove them.

## Findings (checked 2026-11-12)

On the Mac, counted before the change: `jobstate` had 130 `.pyc` files in its venv and `blablador` 709, although both were built while zenv still set `PYTHONDONTWRITEBYTECODE=1`. pip compiles packages at install time whatever the variable says (a pip-built test env had about 450 files, a uv-built one none), and Python run outside zenv writes `__pycache__` into the project.

## Resolution (2026-11-12)

`zenv clean <name|id|.> [--project] [--dry-run]` removes bytecode and nothing else. Scope, as decided with the user:

- By default it removes every `__pycache__` directory under the env directory, and the project's part of the env's bytecode directory. That directory is the `PYTHONPYCACHEPREFIX` of the env's last setup, read from `zenv-env.json`. Python mirrors absolute source paths under a prefix, so the part is the subtree at `<prefix>/<project_dir>`, and at `<prefix>/<env_dir>` when the env directory lies outside the project. Only `.pyc` files are removed there, then the directories that became empty.
- With `--project` it also removes the `__pycache__` directories under the project directory. It does not enter the env base directory, `.git`, `.hg`, `.svn`, or any directory that holds a `pyvenv.cfg`, so other envs and other venvs keep their bytecode.
- `--dry-run` only reports. Both modes print the number of files and directories per place.
- When the env sets no prefix and something was found, it prints the two `env` lines that keep bytecode in one directory, since the files otherwise come back.
- It exits 1 when something could not be removed.

What it leaves: installed packages, the venv, the setup log, the module cache, the uv cache and the registry. In a shared bytecode directory it also leaves the interpreter's own files (the standard library's bytecode) and other projects' files. Symlinks are never followed. A prefix of `/` is refused, because its mirror would be the source directory itself.

The changes by file:

- `src/clean.zig` (new) has `sweepPycache`, `mirrorOf`, `sweepMirror` and `pruneEmptyParents`, with unit tests.
- `src/commands.zig` has `handleClean`, `bytecodePrefix` and `hintBytecodeDir`, and the `clean` command name. `src/main.zig` dispatches it.
- `src/help.zig` has the topic, and `README.md` lists the command.

Checked on the Mac with a scratch `ZENV_DIR`: `zig build test` passes. An env without a prefix: the dry run removes nothing, the real run empties the venv of `.pyc` files and leaves the project's `__pycache__`, `--project` removes that and leaves the one in another venv, and the env still imports its packages afterwards. An env with a prefix in `.zenv/pycache`: the project's file goes, the emptied directories go, and the `.gitignore` and the interpreter's files stay. Wrong arguments and an unknown env are refused. A dry run against the real `jobstate`, `blablador` and `jscdocs` envs reports their files and changes nothing.

Not checked: a cluster filesystem, a container env (its files may belong to root with rootful Docker on Linux, which would be reported as not removed), and a bytecode directory shared by several projects.
