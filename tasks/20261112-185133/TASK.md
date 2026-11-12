# Docker support and a host-driven container launch for both runtimes

- STATUS: CLOSED
- PRIORITY: 100
- TAGS:

A container env could only run in an Apptainer image, and zenv ran itself inside the image to build and to launch (`zenv __build`, `zenv __exec`). That works where the host's zenv and uv can run in the image, which is not the case for Docker on macOS: the host binaries are Mach-O and the image is Linux. The use case is an image from a publisher, such as a PyTorch image, with the user's own package and its extra dependencies on top, so that `import torch` gets the image's copy.

Decided with the user on 2026-11-12:

- zenv always stays on the host and only starts commands in the image through the runtime. This holds for Apptainer too, so there is one container mechanism and not two.
- `container.runtime` selects the runtime: `apptainer` (the default) or `docker`. Podman waits for a machine that has it.
- Each `zenv run` is one `docker run --rm`. There is no long-lived container.
- `zenv activate` and the `cd` hook keep refusing a container env. A `zenv shell` command or activation through shims is left for later.
- `zenv jupyter create` refuses a Docker env.

## Findings (checked 2026-11-12)

The checks ran with Docker 29.8.2 through OrbStack on an Apple Silicon Mac, and with Apptainer 1.4.5 on a JUPITER login node (aarch64).

- `pytorch/pytorch:latest` is published for amd64 only, so it runs under emulation on Apple Silicon. `nvcr.io/nvidia/pytorch:25.10-py3` and `python:3.13-slim` have arm64 builds. No Linux container on a Mac gets the GPU.
- OrbStack maps the ownership of files in bind mounts to the Mac user, although the container runs as root.
- An image's `ENTRYPOINT` receives the command of `docker run` as its arguments. `--entrypoint ""` makes the image run the command itself, as `apptainer exec` does.
- The command of `docker run` is PID 1, which ignores SIGINT and SIGTERM unless it handles them. `--init` fixes that: Ctrl-C on `zenv run <env> sleep 30` ends it with status 130 and removes the container.
- busybox (Alpine) has `env -0` and a `printf` that writes NUL, so the probe works there. Alpine has no bash.
- A bash that is started over ssh without `SHLVL` takes itself for a remote shell and reads `~/.bashrc`. The probed environment therefore keeps `SHLVL`.
- `zenv remove` never uninstalled from a container env: `venvHasPython` follows the `bin/python` link, which resolves only in the image. This was a bug in the existing Apptainer support and is fixed here.

- Apptainer binds `$HOME`, and a venv with `include-system-site-packages = true` also sees the user site, so packages in `~/.local/lib/python3.X/site-packages` on the host were importable in the image. On JUPITER, pip took `tqdm` from there and did not install it into the venv, and the uninstall probe of `zenv remove` named packages from there as requiring `packaging`. uv does not look there, so the uv path installed correctly, but the packages were still importable at run time. This was already so before this task. The user decided on 2026-11-12 to close it with `PYTHONNOUSERSITE=1` (see the Resolution).

## Resolution (2026-11-12)

How a container env works now:

- `src/container.zig` holds the runtime abstraction. `hostArgv` builds `apptainer exec [--pwd] --bind ...` or `docker run --rm --init --entrypoint "" [-i] [-t] [-w] -v ... [-e]`, with the env's `options` and `bind` after zenv's own. A bare Docker bind `src` becomes `src:src`. `fingerprint` is the file's size and mtime for Apptainer and the image ID from `docker image inspect` for Docker. `inside()` is gone.
- Setup (`src/envbuild.zig`) runs on the host. `openBox` starts the image once with `probe_script`, which writes the image's `python3` and its environment into a file in the env directory. Every later step goes through `place`, which wraps it as `<runtime> ... image env -i NAME=value... <argv>`, so the child's environment is exact with both runtimes. The image's Python describes itself (`venv.query_script`) and lists its packages (`packages_script`); the venv's files and links are written from the host (`venv.createFrom`). `BuildRequest`, `runInContainer`, `runInside` and `ErrorWatch` are removed.
- The installer is the host's uv, bound into the image with its cache, when the host runs Linux, and the image's pip otherwise (`imageUv`). In an image pip builds with isolation, so `--dev` works in an image without the build backend, and it gets the image's packages pinned as constraints with all requirements, so a direct or transitive requirement on another version fails the install as it does with uv.
- A container env sets `PYTHONNOUSERSITE=1` (`envspec.container_ops`), in setup and in activation, before the env's own `env` entries, so an entry in zenv.json can override it. An env built before this change gets it at its next setup, and one that relied on a `~/.local` package then needs that package in its requirements. On JUPITER the pip env installs tqdm into the venv after this, `import transformers` (present only in `~/.local`) fails in the image, and `zenv remove` uninstalls `packaging`.
- Setup hooks run in bash when the image has it and in sh otherwise (`container.pick_shell`).
- `zenv run` (`src/launch.zig`) starts `/bin/sh -c <pick_shell> <runner> activate.sh <command>` in the image. The runner sets `ZENV_CONTAINER=1`, sources `activate.sh` and execs the command. For Docker it also binds the working directory and passes `-i`, and `-t` with `TERM` when zenv has a terminal. `activate.sh` of a container env now checks `ZENV_CONTAINER` instead of `APPTAINER_CONTAINER`.
- `src/config.zig` and `src/validation.zig` have `container.runtime`. `src/autosetup.zig` folds the Docker image ID into the tracked hash; an Apptainer env keeps its digest. `src/commands.zig` drops `__build` and `__exec`, refuses Jupyter kernels for Docker envs, prints `Usage: zenv run <env> <command>` for a container env, and lets `remove` uninstall in a container env. `README.md`, `src/help.zig` and `CONTEXT.md` describe both runtimes.

Checked:

- `zig build test` passes, with new unit tests for `hostArgv`, `fromConfig`, `parseProbe`, `parsePackages`, `place`, the pip argv in an image, and `container.runtime` validation.
- Docker on the Mac, with `python:3.13-slim`, `python:3.13-alpine`, `alpine:3.20` and a local image that ships numpy and requests behind an `ENTRYPOINT`: setup with the image pulled by `docker run`; a kept venv on a second setup; `pyproject.toml` with `--dev` and a hatchling build; the image's numpy used and only tqdm installed; setup and activate hooks; `env` ops and `PATH`; `zenv run` from a subdirectory and from outside the project, with arguments that need quoting, pipes in and out, exit statuses, an unknown command (127), a terminal and Ctrl-C; activation refused; `add`, `remove`, a failing `add` with the manifest restored; a direct and a transitive version conflict; a rebuild after the image was replaced; `"python": false`; the Jupyter refusal. An up-to-date `zenv run <env> true` takes about 0.2 s in total.
- Apptainer on JUPITER, with a `python:3.13-slim` SIF and one built from it that ships numpy and requests: the same list with the host's uv bound in (`--uv`) and with `--pip`, a host `PYTHONPATH` kept out, a rebuild after `touch` on the image, `--python` refused. An env built by the installed v0.31.2 runs with the new binary without a rebuild, still runs with v0.31.2 afterwards, and keeps its venv on a new setup. `zenv run` takes about 0.2 s.
- A plain env without a container still builds and runs on the Mac with uv and with pip.

Not checked or not done:

- Docker on a Linux host. With rootful Docker the files in the env directory and the uv cache would be owned by root, because zenv passes no `--user`. The README says to add `"options": ["--user", "<uid>:<gid>"]`.
- GPU runs (`--nv`, `--gpus all`), compute nodes, multi-node runs, and `docker://` URIs as an Apptainer image.
- An env with HPC modules was not rebuilt on a cluster with this binary. Its code path changed only in the signatures of `runStep` and `capture`.
- uv for Docker on macOS. Setup could install uv into the venv with pip and use that copy.
- Podman, `zenv shell`, and activation through shims.
