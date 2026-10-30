# Apptainer support: run an env inside a container image

- STATUS: CLOSED
- PRIORITY: 100
- TAGS:

An env with `container` in zenv.json runs inside an Apptainer image: setup builds its venv on the
image's Python, installs only what the image lacks, and `zenv run` starts commands in the image.
Decided with the user (2026-10-30): Apptainer only for now; `zenv activate` refuses with a hint to
`zenv run <env> bash`; `zenv add` records the package, rebuilds in the image, and restores the
manifest if that fails. Container networking (NCCL etc.) is the image's business, not zenv's.

## Findings (checked 2026-10-30, Apptainer 1.4.5 on JURECA and JUPITER)

- Host variables reach the container except PATH (the image's) and LD_LIBRARY_PATH; PYTHONPATH
  leaks in unchanged. APPTAINERENV_<NAME> and --env set variables, PATH included.
- $HOME, /tmp and the cwd are bound by default; /p (and /e on JUPITER) by site config. Nested and
  single-file binds work; a bind whose source is missing is fatal.
- APPTAINER_CONTAINER is set inside (to the image path).
- zenv's static musl build and the host's uv run inside a glibc image.
- The vLLM image sets UV_CACHE_DIR=/opt/uv/cache (read-only), UV_OVERRIDE, UV_COMPILE_BYTECODE,
  UV_LINK_MODE, UV_INDEX_STRATEGY, UV_PYTHON_INSTALL_DIR: an image's own build settings.
- A host BASH_ENV (Lmod init) and exported BASH_FUNC_module%% make every bash in the image try to
  run the host's Lmod, which fails there.
- JURECA: ~/.apptainer is a symlink to /p/scratch/atmlaml/chandran1/.apptainer, which does not
  exist, so `apptainer pull` fails without APPTAINER_CACHEDIR (not changed).

## Resolution (2026-10-30)

- config/validation: `container` {image, options, bind}; refused with modules, modules_file,
  fallback_python.
- src/container.zig: image resolution, `apptainer exec` argv with zenv's own binds (existing paths
  only), host-only variables (PYTHONPATH, PYTHONHOME, VIRTUAL_ENV*, BASH_ENV, BASH_FUNC_*), image
  fingerprint (size + mtime).
- envbuild: `run` hands a container env to `runInContainer`, which writes a BuildRequest and starts
  `zenv __build` in the image (`runInside`). Inside: no modules, the image's Python
  (`imagePython`), a venv with include-system-site-packages, the image's packages as the provided
  set (`imagePackages`) for the stub/constraint resolution, and the host's UV_* settings and cache
  in place of the image's (`useHostUvSettings`). The last ERROR line from inside is repeated on the
  host so auto-setup shows the reason.
- commands: `zenv run` -> `apptainer exec ... zenv __exec <venv> <cmd>` (`execInContainer`,
  `handleExecInside`); activate refuses (error.ContainerEnv), the cd hook skips; `zenv add` ->
  `addByRebuild` (backs up manifest and stamp, restores them on failure).
- activation: activate.sh refuses outside a container (zenv inside still uses it for activate
  hooks); csh/fish scripts only print the refusal.
- autosetup: the image's fingerprint is part of the tracked hash (container envs only, so other
  envs keep their digest).
- README: Features, configuration reference, "Container images (Apptainer)" section, help text.

Checked:
- unit tests (container.zig, validation, venv, envbuild, autosetup); `zig build test`.
- JURECA, python:3.13-slim image: setup, run (env ops, PATH prepend, no host PYTHONPATH, exit
  codes, from another cwd), activate refusal, `add six`, `add 'pip<1'` failing with the reason and
  the manifest restored, rebuild after touching the image, `--python` refused, `"python": false`,
  activate hooks via activate.sh inside.
- JUPITER, vllm-0.32.0-aarch64-cu13.sif, dependency `peft`: 10 image packages reused (torch
  2.13.0+cu130, transformers 5.19.0, ...), only peft installed, venv 895 inodes; runtime imports
  torch from the image and peft from the venv.
- Not checked: GPU jobs with --nv, multi-node runs, docker:// URIs as image, Jupyter kernels.
