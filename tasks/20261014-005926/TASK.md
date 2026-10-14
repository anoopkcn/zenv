# Fix the issues the benchmarks found

- STATUS: CLOSED
- PRIORITY: 100
- TAGS:

Fix the costs and bugs that the benchmarks in 20261014-001303 found.

## Resolution (2026-10-14)

Four changes. Uncommitted when written. The activation purge for envs without modules (~90 ms on jureca) was left
as it is: it was decided on 2026-10-13 to stop a loaded module's PYTHONPATH and RPATH-less Python leaking into the
venv.

1. `zenv run` execs the command instead of spawning it and waiting (`src/commands.zig`: `Launch`,
   `startCommand`; `src/utils/runtime.zig`: `replace`, deliberately not in `exec_backend` so a test cannot replace
   the test runner). This also fixes a bug: a SIGINT to the process group, as jupyter_client sends for "Interrupt
   kernel", killed the waiting zenv while Python kept running, so Jupyter saw the kernel die. Reproduced and
   verified fixed on macOS and jureca, on both the direct and the bash (`ZENV_RUN_SHELL=1`) path. `zenv add` still
   waits. Exit status is unchanged in practice: exit codes pass through, and a shell reports 128+n for a signal
   (SIGTERM gave 143). Command-not-found still exits 127. README `zenv run` paragraph updated.
2. `setup --uv` and `add --uv` use the uv on zenv's own PATH by its path (`envbuild.Options.uv`,
   `installerArgv` takes `uv: ?[]const u8`; `installPackage` resolves it). This fixes "uv: command not found" when uv
   comes from a module the env does not load, since setup and activate.sh purge modules. Verified on jureca with
   only `module load uv/0.8.17`: setup of an env without modules and of one with modules, and
   `ZENV_RUN_SHELL=1 zenv add --uv`, all failed before and work now.
3. `setup --uv` installs pip without `--upgrade` (`envbuild.run`). `--upgrade` made uv ask PyPI for the newest pip
   on every setup (~0.1 s). A new venv still gets the current pip (26.2.1 in the test). An existing venv keeps its
   pip. The pip path (no `--uv`) keeps `--ignore-installed --upgrade pip`.
4. `main` takes `std.process.Init.Minimal` and copies the environment into the arena (`src/main.zig`). On Linux
   without libc, `std.process.Init` copied it with SmpAllocator, which on the 256-CPU login node mapped a fresh
   64 KB slab for most of the small copies. mmap calls for `zenv --version`: 168 → 5; for `zenv run`: 185 → 20.
   No change on macOS (it uses malloc there): 1.8–2.0 ms before and after.

### Measurements (hyperfine means; old = c4f2c32, new = these changes, ReleaseFast)

jureca login node:

| | old ms | new ms |
|---|---:|---:|
| `true` (dynamically linked) | 2.1 | 2.1 |
| `zenv --version` | 3.5 | 1.4 |
| `zenv --version` (ReleaseSmall) | 3.9 | 1.7 |
| `zenv ls` | 4.1 | 2.0 |
| `zenv activate bench` | 4.1 | 2.2 |
| `zenv run bench true` | 6.6 | 3.9 |
| `zenv run bench python -c pass` (direct: 12.9) | 18.2 | 14.5 |
| `zenv run mods python -c pass` (module cache) | 25.1 | 21.4 |
| `zenv setup bench --uv`, nothing changed | 256 | 166 |
| `zenv setup bench --uv`, fresh | 428 | 358 |

macOS:

| | old ms | new ms |
|---|---:|---:|
| `zenv --version` / `ls` / `activate` | 2.0 / 2.1 / 2.0 | 1.8 / 1.9 / 2.0 |
| `zenv run bench true` | 3.1 | 3.1 |
| `zenv run bench python -c pass` (direct: 18.8) | 20.3 | 20.9 |
| `zenv setup bench --uv`, nothing changed | 133 | 21 |
| `zenv setup bench --uv`, fresh | 221 | 115 |

The exec change gives no speedup on macOS (posix_spawn is cheap there; loading the new program dominates). The
rest of setup's cost on jureca is mostly the module purge for envs without modules and the Python version probes.

Tested: 150 unit tests pass, `zig fmt --check` clean. The test that reproduces the interrupt (start the command in
a new session, SIGINT its process group) is `sigtest.py`. It is in
`jureca:/p/scratch/atmlaml/chandran1/zenv-bench/bin/`, along with the result exports (`res/jureca-fix-*.md`).
