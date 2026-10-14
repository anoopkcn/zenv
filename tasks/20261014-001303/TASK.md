# benchmark the commands on macos and HPC system

- STATUS: CLOSED
- PRIORITY: 100
- TAGS:

Measure how fast zenv's commands are on macOS and on the HPC system jureca.

## Resolution (2026-10-14)

Measured with hyperfine at v0.27.8 (c4f2c32), using ReleaseFast builds of that commit: macOS arm64 natively, and
`x86_64-linux-musl` (static, like the release builds) on a jureca login node (256 CPUs, Rocky 9, project on GPFS
scratch). Both runs used a scratch `ZENV_DIR` and project, so real environments were untouched. The login node is
shared: expect about ±0.8 ms of noise in the jureca numbers. Results and binaries are in
`jureca:/p/scratch/atmlaml/chandran1/zenv-bench` (`res/` has the hyperfine markdown/JSON exports).

Summary: zenv's own work costs about 0.7–0.9 ms per command over an empty process on macOS, and about 1–1.5 ms on
jureca. The time users notice comes from the programs zenv launches (uv/PyPI, Lmod, Python). The module cache makes
`zenv run` about 40× faster than going through Lmod.

### Everyday commands (mean, ms)

| Command | macOS | jureca |
|---|---:|---:|
| `true` (empty process) | 1.2 | 2.8 |
| `zenv --version` | 1.9 | 3.7 |
| `zenv ls` | 1.9 | 4.1 |
| `zenv cd` / `zenv activate` | 2.1 | 4.1–4.3 |
| `zenv activate --auto .` / `zenv hook zsh` | 2.0 / 1.9 | 4.0 / 3.6 |
| `zenv run env true` | 3.3 | 7.1 |
| `python -c pass`, run directly | 17.9 | 13.2 |
| `zenv run env python -c pass` | 20.0 | 18.3 |

- On macOS ReleaseFast and ReleaseSmall measure the same (`activate --auto` / `hook` above are from the Small run;
  the Fast run had outliers). On jureca Small is about 0.3–0.5 ms slower.
- A registry of 502 environments (230 KB) adds 0.6 ms to `zenv run` (3.1 → 3.7 ms on macOS).
- `uv run --no-project --python <venv python> python -c pass` on macOS: 24.4 ms (`zenv run`: 21.4 ms in the same run).

### HPC environments with modules (jureca, Python 3.13.5 from modules, `python -c pass`)

| | ms |
|---|---:|
| venv python directly (module's LD_LIBRARY_PATH already set) | 19.9 |
| `zenv run`, with module cache (default) | 25.0 |
| `zenv run` forced through bash (`ZENV_RUN_SHELL=1`), with cache | 48.4 |
| `zenv run`, with `"module_cache": false` (goes through Lmod) | 1,021 |
| By hand in a login shell: `module load` + activate + python | 1,609 |

Activation in bash on jureca (`bash --noprofile --norc -c ...`; Lmod's exported `module` function is present):

| | ms |
|---|---:|
| `bash -c :` | 20.0 |
| `source $(zenv activate mods)`, env with modules and cache | 29.0 |
| `source $(zenv activate bench)`, env without modules | 117.1 |
| `module --force purge` alone | 111.7 |

In a login shell (`bash -lc`, which alone takes 495 ms): activation with cache 525 ms, with `module_cache: false`
1,489 ms, `module load` + venv activate by hand 1,586 ms.

### `zenv setup --uv` (mean, ms)

| | macOS | jureca |
|---|---:|---:|
| Nothing changed | 134 | 261 |
| Fresh, no packages | 226 | 437 |
| Same steps by hand: `uv venv` + `uv pip install pip` | 24 | 124 |
| `python -m venv`, for comparison | 1,456 | 2,618 |
| Fresh, with requests + rich | 303 | 623 |
| Same by hand with uv | 34 | 148 |
| Env with 3 modules: fresh / unchanged / `--reuse-module-cache` | – | 1,470 / 1,250 / 158 |

The first jureca run of the module-setup row measured only fresh builds, because a single hyperfine `--prepare`
applies to every command. The unchanged and `--reuse-module-cache` numbers are from a rerun.

### Where the time goes

1. Every `setup --uv` runs `uv pip install --link-mode=copy --upgrade pip` (`src/utils/envbuild.zig`).
   `--upgrade` makes uv ask PyPI for the latest pip: 127 ms on macOS and 108 ms on jureca, against 7 ms and
   20 ms without it. It accounts for nearly all of an unchanged setup on macOS.
2. On HPC, activating an env without modules runs `module --force purge` (~90 ms of the 117 ms). The `cd` hook
   pays it on every entry into such a project. Setup also purges for envs without modules; that probably
   explains part of setup's extra cost on jureca (not timed separately).
3. Linux startup: the musl build does not link libc, so `std.process.Init` gives `std.heap.smp_allocator` as the
   gpa. Copying the ~150 environment variables into `Environ.Map` alternates size classes, and on a 256-CPU node
   SmpAllocator maps a fresh 64 KB slab for most of them: 164 mmaps for `zenv --version` (42 when pinned to 4 CPUs
   with taskset). Cost: 0.7 ms on `--version`, 1.6 ms on `zenv run`. Pinned to 4 CPUs, `zenv --version` timed the
   same as `true`. Building with `link_libc = true` saved only 0.3–0.6 ms (musl malloc still made 147 mmaps).
   Not tried on Linux: `std.process.Init.Minimal` with the environ map built in the arena. It gave no gain on macOS,
   which uses malloc and never had this problem.
4. `zenv run` spawns the command and waits for it instead of exec'ing it (`runtime.realExec`). That probably
   costs under 1 ms (estimate, not measured).

Bug seen on jureca: `zenv setup --uv` fails with "uv: command not found" when uv comes from a module (JSC has
`uv/0.8.17`). Setup finds uv first ("Using uv 0.8.17"), then purges all modules (even for an env that lists none)
and calls bare `uv` on the purged PATH. Using the absolute path it found would fix it.
