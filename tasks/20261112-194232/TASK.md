# Write bytecode by default and let zenv init set the cache directory

- STATUS: CLOSED
- PRIORITY: 100
- TAGS:

zenv set `PYTHONDONTWRITEBYTECODE=1` in every Python env, to save inodes on the clusters. The price is that Python recompiles every module at each start. The user wants zenv to follow Python's default, which is to write bytecode, and wants the choice visible and editable in `zenv.json`.

Decided with the user on 2026-11-12:

- zenv no longer sets `PYTHONDONTWRITEBYTECODE` at activation or in `zenv run`.
- `zenv init` and `zenv setup --init` write two `env` entries into a new Python env: `"PYTHONDONTWRITEBYTECODE": ""` and `"PYTHONPYCACHEPREFIX": "<base_dir>/pycache"`.
- When `ZENV_PYCACHE_DIR` is set, its value is written as the prefix instead.

## Resolution (2026-11-12)

- `src/envspec.zig`: `venvOps` no longer has the `PYTHONDONTWRITEBYTECODE` op.
- `src/commands.zig`: `initConfigJson` writes the `env` block for a Python env, and `pycachePrefix` picks the value. A relative `base_dir` gives `${ZENV_PROJECT_DIR}/<base_dir>/pycache`, an absolute one `<base_dir>/pycache`, and `ZENV_PYCACHE_DIR` wins over both and is made absolute. When the env is added to an existing `zenv.json`, that file's `base_dir` is used. A Python-free env gets no such entries.
- `src/envbuild.zig`: `keepBytecodeOutOfGit` creates the prefix directory at setup and writes a `.gitignore` into it when the directory lies inside the project, so `.zenv/pycache` does not show up in `git status`. It never writes into the project directory itself or over an existing `.gitignore`. Setup still installs with `PYTHONDONTWRITEBYTECODE=1` and gives the hooks the env's own value back, as before.
- `README.md` and `src/help.zig` describe the entries and `ZENV_PYCACHE_DIR`.

`ZENV_PYCACHE_DIR` is read by `init` only. It does not change an env that exists already, and an explicit entry in `zenv.json` is the only source at run time. This is my reading of "if the user has already set ZENV_PYCACHE_DIR then use that for PYTHONPYCACHEPREFIX"; reading the variable at activation as well was not asked for and is not done.

What changes for existing envs: their `zenv.json` has neither entry, so after their next setup with this zenv they write `__pycache__` directories next to the sources, in the venv too, which costs one inode per imported module. Adding the two lines, or `"PYTHONDONTWRITEBYTECODE": "1"`, restores control.

Checked on the Mac: `zig build test` passes, with tests for `pycachePrefix`, the template's `env` block and `venvOps`. `zenv setup p --init --uv` writes the entries, `sys.pycache_prefix` is `<project>/.zenv/pycache` in `zenv run`, the `.pyc` files land there with a `.gitignore`, and `git status` shows only the project's own files. `ZENV_PYCACHE_DIR` is written into a second env added to the same file. `init --no-python` writes no `PYTHON` entry. Six standard-library imports through `zenv run` took 0.03 s with a warm cache and 0.13 s without one.

Notes:

- With a prefix, Python also caches the standard library there, because it ignores the `__pycache__` files shipped with the interpreter. The directory therefore holds more files than the env's own packages.
- Apple's system Python has a built-in prefix (`~/Library/Caches/com.apple.python`), so an env on it without the entries writes there and not next to the sources.
- Not checked: the effect on a cluster filesystem, where the gain should be larger, and container envs with a prefix outside the project. A Docker env does not see such a directory unless it is listed in `bind`.
- An env named `pycache` would share its directory with the default prefix. Nothing guards against that.
