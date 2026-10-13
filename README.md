# zenv

Python Environment Manager for HPC and Development Systems

`zenv` is a command-line tool written in Zig that manages Python virtual environments, primarily designed for High-Performance Computing (HPC) environments and development systems. It also manages environments for projects that are not Python projects: the modules, environment variables and settings a project needs, without a venv.

## Features

### Core Functionality

The tool provides several key features:

1. **Environment Management**: Create, activate, and manage Python virtual environments with configurations stored in `zenv.json`
2. **Registry**: Track environments globally so they can be activated from any directory
3. **System Targeting**: Configure environments for specific machines or clusters
4. **Dependency Management**: Install Python packages with awareness of what's already provided by system modules (dependencies that the loaded modules put on `PYTHONPATH` are not reinstalled; `zenv setup --force` installs them anyway)
5. **Add packages on the fly**: `zenv add` installs a package into an environment and records it in the project's manifest (`requirements.txt` / `pyproject.toml` / `zenv.json`)
6. **Module Integration**: Load HPC modules required for environment setup
7. **Environment variables**: Set variables per environment in `zenv.json`; `deactivate` restores them
8. **Environments without Python**: Use zenv for a project's modules, variables and settings alone (`"python": false`)

## Installation

### Homebrew (macOS / Linux)

```sh
brew install anoopkcn/zenv/zenv
```

Upgrade later with `brew upgrade zenv`.

### Use install script

```sh
curl -fsSL https://raw.githubusercontent.com/anoopkcn/zenv/HEAD/install.sh | bash
```

Run the same command to update an already installed `zenv`


### Alternative methods of installation

<details>
<summary>Manual download of stable release</summary>

**Change the `<tag>` according to the latest version**

```bash
# Replace <tag> with last stable release version:
curl -LO "https://github.com/anoopkcn/zenv/releases/download/<tag>/zenv-x86_64-linux-musl-small.tar.gz"

# Extract the 'zenv' executable and move it somewhere in your 'PATH'
tar -xvf zenv-x86_64-linux-musl-small.tar.gz
mv zenv ~/.local/bin/
```

</details>

<details>

<summary>Build from Source</summary>

```bash
# Clone the repository
git clone https://github.com/anoopkcn/zenv.git

# Build the project
cd zenv
zig build

# Optional: Move executable to ~/.local/bin (assumes ~/.local/bin is in PATH)
mv zig-out/bin/zenv ~/.local/bin/
# OR
# Optional: Add to your PATH
export PATH="$PATH:path/to/zig-out/bin"
```

</details>

Check [release](https://github.com/anoopkcn/zenv/releases) for specific versions.
Supported OS: Linux(`aarch64`, `x86_64`), MacOS(`aarch64`, `x86_64`). _Windows support is not planned_

## Usage

### Initialize and setup an environment

```bash
zenv init [name] [description]
# This creates a `zenv.json` configuration file in your project directory
# You can then modify this json file according to your needs and run:
zenv setup <name>
# This will also register the environment to global ZENV_DIR/registry.json
```

`name` defaults to the project directory's name (characters an environment name cannot contain become `-`), and `description` to `[project].description` from `pyproject.toml` when there is one. If `zenv.json` already exists, `zenv init` adds the new environment to it (the file is rewritten with 2-space indentation) and refuses only when that name is already defined. `zenv setup <name> --init` does the same and then sets the environment up; if `zenv.json` already defines `<name>`, it just sets it up.

For a project that is not a Python project, add `--no-python` (`zenv init <name> --no-python`, or `zenv setup <name> --init --no-python`) to get an environment without Python; see [Environments without Python](#environments-without-python).

**A minimal example of a `zenv.json` file**:

```json
{
  "base_dir": "zenv",
  "test": {
    "target_machines": ["*"],
    "description": "Basic environment JURECA and any machine",
    "modules": ["Stages/2025", "StdEnv", "Python"],
    "dependency_file": "requirements.txt"
  }
}
```

Check the [Configuration Reference](#configuration-reference) for full list of key-values. The optional `dependency_file` can be a `requirements.txt` OR `pyproject.toml` file. If you run `zenv init` then it will be automatically populated according to what is found in the project.

### Listing environments

List all environments registered for the current machine:

```bash
zenv ls # for listing envs configured for current computer
# OR
zenv ls --all # for listing all available envs in the registry
# OR
zenv ls test # for the details of one env (name, alias, id, or . for the current project)
```

Example output:

```
- test
  id      : c3c494547b40f070b4c080f95c707622d84fe749
  target  : jureca, juwels, *
  project : /path/to/project
  venv    : /path/to/project/zenv/test
  python  : /p/software/default/stages/2025/software/Python/3.12.3-GCCcore-13.3.0/bin/python3.12
  desc    : Test python environment

Found 1 environment(s) for the current machine ('jurecadc')
```

The `python` line shows the interpreter the venv was built from (omitted until the environment is set up), and an `aliases` line appears when the environment has any. `list` still works wherever `ls` does (`zenv list`, `zenv alias list`, `zenv jupyter list`, `zenv python list`).

### Activating environments

Activate an environment by name or ID

Example:

```bash
# Activate by name
source $(zenv activate test)

# Activate by full ID
source $(zenv activate c3c494547b40f070b4c080f95c707622d84fe749)

# Activate by partial ID (first 7+ characters)
source $(zenv activate c3c4945)

# Activate the project you are in, from any subdirectory of it
source $(zenv activate --auto .)
```

`zenv activate .` needs the `zenv.json` in the current directory itself. `--auto .` searches upward from the current directory for the nearest `zenv.json` instead, and prints nothing if that project has no registered environment (it is what the [cd hook](#activating-on-cd-zsh-bash) runs). Unlike a plain `activate`, it never rebuilds an out-of-date environment: it prints a notice and activates it as built.

From csh/tcsh or fish, ask for that shell's script instead (activate hooks are sh code and are skipped there):

```csh
source `zenv activate test --shell=csh`
```

```fish
source (zenv activate test --shell=fish)
```

Either script defines `deactivate`, which restores what activation set: `PATH`, the venv variables, the module-cache variables and the variables from `env` go back to their previous values (or are unset if they had none). Activating another environment runs the current one's `deactivate` first, so switching leaves nothing behind. Changes made by `activate.commands` / `activate.script` are arbitrary shell code and are not undone; put plain variables in [`env`](#environment-variables) instead. Environments set up with an older zenv get this behaviour after `zenv setup <name>`.

Jupyter kernels created by zenv (`zenv jupyter create <env>` or `zenv setup <env> --jupyter`) start through `zenv run`, so they get the environment's modules even when the Jupyter server runs with a different module set. The environment needs `ipykernel` (`zenv add <env> ipykernel`). The kernel is named `zenv-<env>` and shown as `Python (<env>)`; `zenv jupyter create <env> --name <kernel> --display-name <text>` picks others.

### Activating on cd (zsh, bash)

To activate a project's environment whenever you `cd` into the project, and deactivate it when you leave, add this to `~/.zshrc`:

```zsh
eval "$(zenv hook zsh)"
```

or, for bash (3.2 or newer), to the end of `~/.bashrc`:

```bash
eval "$(zenv hook bash)"
```

bash has no hook for directory changes, so there the hook runs from `PROMPT_COMMAND` before each prompt and returns at once while the directory is unchanged. It adds itself to whatever `PROMPT_COMMAND` holds and keeps `$?` for prompts that show it, so load it after anything that assigns `PROMPT_COMMAND` outright.

Like direnv, this is a shell hook with no background process. On each directory change it looks for the nearest `zenv.json` at or above the current directory. Moving around inside the same project does nothing; only entering a different project calls `zenv activate --auto`, which prints the activation script of the environment registered for that project.

- Only environments you have built with `zenv setup` (or registered) activate. A `zenv.json` in a cloned repository does nothing until you set it up, and a project with several environments for this machine prints a hint and activates none.
- The hook never rebuilds. If `zenv.json` or a dependency file changed since the last setup, it prints `zenv: '<name>' is out of date with zenv.json; run 'zenv setup <name>'` and activates the environment as built. This keeps `cd` fast and means newly pulled `activate` hooks run only after you set the environment up again.
- The nearest `zenv.json` wins: a nested project without a registered environment shadows the project around it, so entering it deactivates the outer environment.
- The hook deactivates only an environment it activated itself. If you run `deactivate` or activate another environment by hand inside a project, it leaves that alone until you enter another project.

The hook runs `zenv activate --auto`, which you can also use by hand: `source $(zenv activate --auto .)` activates the environment of the project you are in, from any subdirectory.

### Direct run without activation

One could run commands and tools without explicit activation of Environments using `zenv run` command

```bash
zenv run <name|id> <command>
```

For example to run a script using python from the environment:

```bash
zenv run test python my_test_file.py
```

Or to run a server:

```bash
zenv run test jupyter notebook
# OR
zenv run test mkdocs serve
```

Or make the environment available to your editor without activation:

```bash
# for vim or neovim
zenv run test vim

# for vs code
# zenv run test code -n .
```

`zenv run` exits with the command's exit status (128 + the signal number if a signal ended it), so it works in scripts and CI. It starts the command directly with the environment's variables applied, without a shell; environments with `activate` hooks, or with modules but no module cache usable on this machine (for example `"module_cache": false`), are run by sourcing `activate.sh` in bash instead. `ZENV_RUN_SHELL=1` forces that bash path, which helps tell whether the direct launch is the cause of a difference.

### Adding packages to an environment

`zenv add` installs a package into an existing environment **and** records it in the
project's manifest, so the dependency persists and is reinstalled on the next setup/rebuild.
The package is installed first; the manifest is only updated if the install succeeds.

```bash
zenv add <name|id|.> <package> [--dev] [--zenv] [--uv]
```

The `<package>` may include a version specifier (e.g. `flask>=2.0`). Re-adding a package
that is already recorded replaces its spec, so you can use `zenv add` to update a pin.
Names match the way pip compares them: `Flask_Login` replaces an existing `flask-login`.

```bash
# install requests and record it in the manifest
zenv add test requests

# install with a version constraint
zenv add test "numpy>=1.26,<2.0"

# add a development dependency
zenv add test pytest --dev
```

**Where the package is recorded** depends on the environment's `dependency_file` and the flags:

| Environment uses        | normal dependency               | `--dev` (development dependency)          |
| ----------------------- | ------------------------------- | ----------------------------------------- |
| `requirements.txt`      | appended to `requirements.txt`  | `dev_dependencies` in `zenv.json`         |
| `pyproject.toml`        | `[project].dependencies`        | `[dependency-groups].dev` (PEP 735)       |
| no `dependency_file`    | `dependencies` in `zenv.json`   | `dev_dependencies` in `zenv.json`         |

Flags:

- `--dev` — record the package as a development dependency (see the table above).
- `--zenv` — record the package **only** in `zenv.json` (under `dependencies`, or
  `dev_dependencies` with `--dev`), leaving `requirements.txt` / `pyproject.toml` untouched.
  The package is still installed into the environment.
- `--uv` — use `uv pip install` instead of `python -m pip install`.

> Note: `--dev` is interpreted per-command — it means *editable install of the current
> project* for `zenv setup`, but *development dependency* for `zenv add`.

In `pyproject.toml` only the affected entry changes: the rest of the file, including comments, stays as it was. If the package installs but cannot be recorded, `zenv add` says so, and you add it to the manifest by hand. Recording the package does not make the next `zenv run` rebuild the environment (see [Automatic rebuilds](#automatic-rebuilds)).

The environment must already be built (`zenv setup <name>`); `zenv add` does not create it. An environment with `"python": false` has nothing to install into, so `zenv add` refuses it and says how to turn Python on.

### Automatic rebuilds

`zenv run`, `zenv activate`, `zenv cd` and `zenv jupyter create` first check that the environment matches its configuration: its own entry in `zenv.json` (plus `base_dir`), and the `dependency_file`, `modules_file` and `setup.script` that entry names. If any of them changed since the last `zenv setup`, zenv runs the setup again, with the same build flags (`--uv`, `--dev`, `--python`, `--force`, `--no-cache`), before the command continues. Editing another environment in the same `zenv.json` does not rebuild this one.

A rebuild prints a short notice on **stderr** (`zenv: rebuilding environment '<name>' (...; auto-setup)...` and a completion line). It is on stderr deliberately: `zenv activate` and `zenv cd` put their shell-eval payload on stdout (`source $(zenv activate <name>)`), and stderr does not corrupt that capture while still being visible in your terminal. A routine command with no changes stays silent. If the rebuild fails, its errors are printed and the command stops, except `zenv cd`, which still prints the project directory so you can go fix `zenv.json`.

- `zenv add` and `zenv rename` change these files themselves and keep the environment's build record current, so they do not cause a rebuild.
- If the project's `zenv.json` was removed, the environment is used as last built. If `zenv.json` does not validate (for example while you are editing it), zenv prints one line saying so and uses the environment as last built; `zenv validate` shows what is wrong.
- `zenv activate --auto` (the [cd hook](#activating-on-cd-zsh-bash)) never rebuilds; it prints a notice instead.
- Set `ZENV_NO_AUTO_SETUP=1` to turn automatic rebuilds off.

### Registering and Deregistering Environments

A metadata information about the environments are stored at `ZENV_DIR/registry.json`. by default `ZENV_DIR` is `$HOME/.zenv`.
But one can set `ZENV_DIR` environment variable as any directory with write permission.

Register an environment in the global registry:

**This is done automatically when you run `zenv setup <name>`**

```bash
zenv register <name>
```

Remove an environment from the registry:

```bash
zenv deregister <name>     # Remove by name or ID
```

## Python Management

The default priority of the Python is as follows:

1. Module-provided Python (if HPC modules are loaded)
2. Explicitly configured 'fallback_python' from zenv.json (if not null)
3. zenv-managed pinned Python
4. System python3
5. System python

Environments with `"python": false` skip this entirely: no interpreter is looked up.

If the project's `pyproject.toml` declares `requires-python` and zenv reads it (it is the
`dependency_file`, or `--dev` installs the project), setup checks the selected Python against it
before creating the venv. When it does not match, setup stops and says how to make a matching
Python the one zenv selects: a Python module, `fallback_python`, or a zenv-installed Python you pin.
An existing venv built with a non-matching Python is reported too; remove it with `zenv rm <name>`
and set it up again.

If you would like to use zenv-managed default Python for the environment, run:

```bash
# Install a python version if not done already
zenv python install <version>

# Pin a specific python version
zenv python pin <version>

# use the pinned version
zenv setup <name> --python
```

## Configuration Reference

One can have multiple environment configurations in the same `zenv.json` file and it supports the following structure:

```json
{
  "base_dir": "<base directory where all envs listed in the config will be stored>",
  "<name>": {
    "target_machines": ["<machine identifier accepts wild card *>"],
    "fallback_python": "<path to python executable OR null>",
    "description": "<optional description OR null>",
    "modules": ["<module1>", "<module2>"],
    "modules_file": "<path to modules file OR null>",
    "module_cache": true,
    "python": true,
    "dependency_file": "<optional path to requirements_txt OR pyproject_toml OR null>",
    "dependencies": ["<package name with or without version>"],
    "dev_dependencies": ["<development dependency, typically added via 'zenv add --dev'>"],
    "env": {
      "<NAME>": "<value>",
      "<PATH_LIKE_NAME>": { "prepend": "<value>" }
    },
    "setup": {
      "commands": ["<list of shell commands which is run during setup>"],
      "script": "<path to a shell script which is run during setup>"
    },
    "activate": {
      "commands": ["<list of shell commands which is run during activation>"],
      "script": "<path to a shell script which will be run during activation>"
    }
  },
  "<another_name>": {
    "target_machines": ["<another machine identifier>"]
  }
}
```

One can run `zenv validate` to validate the config file. If there are errors in the JSON it will try to inform the context of the error.

In the configuration `target_machines` is required key(If you want, you can disable the validation check using `--no-host`), all other entries are optional. Top-level `base_dir` can be an absolute path or relative one(relative to the `zenv.json` file), if not provided it will create a directory called `.zenv` at the project root. One can use wildcards to target specific systems, to match any machine use `*` or `any` (`"target_machines": ["*"]`). The lookup location of the `dependency_file` is the same directory as `zenv.json`.

`python` (default `true`) says whether the environment has a Python venv; set it to `false` for a project that only needs modules, environment variables and settings (see [Environments without Python](#environments-without-python)). `env` sets environment variables (see [Environment variables](#environment-variables)).

The `dependencies` and `dev_dependencies` arrays list packages that `zenv setup` installs into the environment in addition to anything from `dependency_file`. Both are usually populated for you by `zenv add` (see [Adding packages to an environment](#adding-packages-to-an-environment)) rather than edited by hand, but you can also add entries directly.

The machine identity that `target_machines` is matched against is taken from `$SYSTEMNAME` when it is set (falling back to `$HOSTNAME`/`$HOST`, then the `hostname` command). On HPC systems every node of a cluster exports the same `$SYSTEMNAME` while per-node `hostname`s differ (e.g. `jrlogin01` vs `jrc0042`), so keying off `$SYSTEMNAME` lets a single entry like `"target_machines": ["jureca"]` match on login and compute nodes alike. This is the same cluster identity used for the module cache (below). Off HPC, where `$SYSTEMNAME` is unset, matching uses the hostname as before.

**Host-aware selection (shared filesystems).** When several machines share a filesystem (e.g. HPC login/compute nodes), you can register one environment per machine — distinct names like `env_machine1`, `env_machine2`, each with its own `target_machines` — and give them all the **same alias** (e.g. `zenv alias create dev env_machine1`, then `... dev env_machine2`). Resolving that alias, or the `.` current-directory shortcut, then auto-selects the environment whose `target_machines` matches the machine you are on, so the *same* command (`zenv run dev`, `zenv activate .`, `zenv cd .`) works on every node. If the current host matches none of the candidates — or more than one (e.g. two share a `*`/`any` target) — resolution reports an ambiguity listing each candidate and its target machines; use the exact environment name or id to disambiguate. A unique alias (one holder) still resolves regardless of host.

### Environment variables

The `env` object sets environment variables for the environment, in the order written:

```json
"env": {
  "PROJECT_DATA": "${ZENV_PROJECT_DIR}/data",
  "OMP_NUM_THREADS": "8",
  "PATH": { "prepend": "${ZENV_PROJECT_DIR}/scripts" },
  "LD_LIBRARY_PATH": { "append": "/opt/foo/lib" }
}
```

A string value sets the variable; `{"prepend": ...}` or `{"append": ...}` adds an entry to the front or back of a `:`-separated variable instead of replacing it. In values, `${ZENV_ENV_DIR}` (the environment directory) and `${ZENV_PROJECT_DIR}` (the directory holding `zenv.json`) are replaced by zenv; everything else, `$HOME` included, is taken literally, so the value is the same in every shell.

Unlike `export` lines in `activate.commands`, these are recorded as data in `zenv-env.json`, which means:

- `deactivate`, and switching to another environment, restores each variable's previous value (or unsets it if it was not set);
- they work in bash, zsh, csh/tcsh and fish (`activate.commands` run only in bash and zsh);
- `zenv run` applies them directly, without starting a shell to source `activate.sh`;
- `zenv setup` applies them too, so package installs and `setup` hooks see them.

Variables zenv's activation manages (`VIRTUAL_ENV`, `VIRTUAL_ENV_PROMPT`, `ZENV_ENV_DIR`, `PYTHONHOME`, `PS1`, and names starting with `_ZENV_` or `_OLD_VIRTUAL_`) cannot be set, and `PATH` can only be prepended or appended to. Use `activate.commands` / `activate.script` for anything that needs shell logic.

For custom scripts, you can use `setup.script` and `activate.script` to specify paths to shell scripts that will be copied to the environment's directory and executed during setup or activation. These scripts allow for more complex customization than inline commands. The scripts are copied to the environment directory, making the environment portable and independent of the original script location.

The key-val `"modules_file": "path/to/file.txt"` can be specified in an environment to load module names from an external file. The file has one module name per line; blank lines and lines starting with `#` are skipped, and a repeated name is loaded once. When specified, any modules listed in the "modules" array are ignored.

### Module caching

On HPC systems, `module load` (Lmod) can be slow, and the generated `activate.sh` runs it on every activation. With `"module_cache": true` (the default), `zenv setup` captures the environment that `module load` produces and writes it to the environment directory (`.zenv_module_cache.json`). Subsequent activations and `zenv run` replay that captured environment instead of invoking Lmod, which is significantly faster.

The cache is used only when it is trustworthy; otherwise activation transparently falls back to a real `module --force purge` + `module load`:

- It is keyed to the **cluster** via `$SYSTEMNAME` (falling back to `hostname`), so it is reused across all nodes of a system but never replayed on a different one.
- Path-style variables (`PATH`, `LD_LIBRARY_PATH`, …) are replayed as the entries the modules put before or after the previous value (prepends and appends), so your live login environment is preserved.
- If any module fails to load, `zenv setup` fails and names the module, instead of building an environment without it.
- Replaying the cache does not need a `module` command, so it also works in shells where Lmod is not initialised (e.g. a non-login `tcsh`). Only the `module load` fallback needs one; if `module` is missing but `$LMOD_CMD` is set, the activation script defines it the way Lmod does.
- `deactivate` undoes everything the cache replay set, so deactivating and re-activating does not stack path entries.

If your login shell is not bash (e.g. zsh), `module` is not visible to the bash that `zenv setup` uses to load modules. zenv then defines it from `$LMOD_CMD`, the way Lmod's own bash init does.

**Reuse on rebuild.** zenv re-runs `zenv setup` automatically when it detects that `zenv.json` or a referenced dependency/modules file changed (see [Automatic rebuilds](#automatic-rebuilds)). To avoid paying the Lmod cost on every such rebuild, the cache also records a signature of the module set (`modules_sig`), and automatic rebuilds pass `--reuse-module-cache`. When such a rebuild leaves the module set unchanged — e.g. you only edited `requirements.txt` — setup skips `module --force purge` + `module load` and instead replays the existing cache to establish the build environment, provided the cache is still trustworthy for this cluster (same `$SYSTEMNAME`, not untrusted). When the module set itself changes (you edit `modules`/`modules_file`), setup re-runs Lmod and re-captures the cache. A `zenv setup` you run yourself always re-captures; pass `--reuse-module-cache` to skip that when you know the modules have not changed.

The cache is **not** auto-invalidated when the system's modules change underneath you, and automatic rebuilds keep replaying it. If a `module load` is updated by site maintenance, re-run `zenv setup` to refresh the cache. Set `"module_cache": false` to always run `module load` at activation. Environments without `modules` are unaffected.

### Environments without Python

For a project that is not a Python project, set `"python": false` to use a zenv environment only for its modules, environment variables and settings. `zenv setup` then loads the modules (and captures the module cache), creates the environment directory with an empty `bin/` that activation puts on `PATH`, runs the `setup` hooks and writes the activation scripts. It does not look for a Python interpreter, create a venv or install anything, so `uv` is not needed either.

`zenv init <name> --no-python` (or `zenv setup <name> --init --no-python`) writes such an environment for you: `"python": false`, an empty `env`, and none of the Python-only keys, even when the project has a `requirements.txt` or `pyproject.toml`. On `zenv setup` without `--init`, `--no-python` is refused: for an existing environment, change `"python"` in `zenv.json`, which is what the automatic rebuild reads.

```json
{
  "base_dir": ".zenv",
  "tools": {
    "target_machines": ["*"],
    "python": false,
    "modules": ["GCC", "CMake"],
    "setup": { "commands": ["cp scripts/build.sh \"$ZENV_ENV_DIR/bin/\""] },
    "env": { "PROJECT_DATA": "/p/scratch/mydata" }
  }
}
```

Activation and `zenv run` set `ZENV_ENV_DIR`, put `<env>/bin` on `PATH` and apply `env`, but do not export `VIRTUAL_ENV` (tools like uv and pip would otherwise target a directory that has no Python in it). The `setup` hooks also see `ZENV_ENV_DIR` and `env`. `zenv activate`, `zenv run`, `zenv cd`, `zenv rename` and the other commands that do not install packages work the same as for a Python environment.

A Python-free environment cannot have `dependencies`, `dev_dependencies` or a `dependency_file` (`zenv validate` reports them), and `zenv add`, `zenv setup --dev`, `--jupyter` and `zenv jupyter create` refuse it with a message saying what to change.

**Adding Python later.** Set `"python": true` (or remove the key) and run `zenv setup <name>`, or simply `zenv add <name> <pkg> --uv`: the environment is rebuilt with a venv in the same directory, keeping the modules, the hooks and any files you put in `bin/`.

**Removing Python.** Going the other way is not done in place, because a venv's `bin/` mixes installed entry points with your own files. Setup stops and asks you to run `zenv rm <name>` and then `zenv setup <name>`; the environment is rebuilt from `zenv.json`.

## Help

```bash
zenv help
```

Output:

```
Usage: zenv <command> [name|id] [options]

Manages project environments based on zenv.json configuration: a Python venv
and its packages, HPC modules, environment variables and settings.

Commands:
  init [name] [desc]         Creates 'zenv.json' with environment 'name', or adds it to an
                             existing one. 'name' defaults to the directory's name.
                             --no-python: an environment without Python, for modules,
                             environment variables and settings only.
                             Use to start defining your environments[z].

  setup <name>               Creates and configures the environment '<name>' as per
                             'zenv.json' in '<base_dir>/<name>': modules, the Python venv and
                             its packages (none with "python": false), hooks and activation.
                             This is the primary command to build an environment.

  activate <name|id|.>       Outputs the activation script path for an environment.
                             To use: source $(zenv activate <name|id|.>)
                             csh/tcsh: source `zenv activate <name|id|.> --shell=csh`
                             fish:     source (zenv activate <name|id|.> --shell=fish)
                             'deactivate' then restores what activation set; activating
                             another environment deactivates this one first.
                             --auto [dir]: the project you are in, from any subdirectory:
                             source $(zenv activate --auto .)
                             Uses the nearest zenv.json at or above dir (default: .);
                             prints nothing if it has no registered env. Never rebuilds.

  hook <shell>               Outputs a shell hook that activates a project's environment
                             when you cd into it and deactivates it when you leave.
                             zsh:  add to ~/.zshrc: eval "$(zenv hook zsh)"
                             bash: add to the end of ~/.bashrc: eval "$(zenv hook bash)"

  run <name|id|.> <command>  Executes a <command> within the specified isolated environment.
                             Does NOT require manual activation of the environment.
                             Exits with the command's exit status.

  add <name|id|.> <package>  Installs <package> into the environment and records it in the
                             project's manifest (requirements.txt / pyproject.toml / zenv.json).
                             <package> may include a version (e.g. 'flask>=2.0'); adding a
                             package again updates its recorded version.
                             Options: --dev (dev dependency), --zenv (record only in
                             zenv.json), --uv (use uv instead of pip).
                             Refused for environments with "python": false.

  cd <name|id|.>             Outputs the project directory path for an environment.
                             To use: cd $(zenv cd <name|id|.>)

  ls                         Lists registered environments accessible on this machine.

  ls --all                   Lists all registered environments.

  ls <name|id|.>             Shows only the details of the specified environment.

  register <name>            Adds the environment '<name>' (from current 'zenv.json') to the
                             global registry[a], making it accessible from any location.

  deregister <name|id|.>     Removes an environment from the global registry.
                             The virtual environment files are NOT deleted.

  rename <old|id> <new>      Renames an environment from 'old' to 'new': its registry entry,
                             its directory and generated scripts, its entry in zenv.json and
                             its Jupyter kernel. Nothing changes if 'new' is already a name,
                             alias or id, or its directory exists.

  rm <name|id|.>             De-registers the environment AND permanently deletes its
                             virtual environment directory from the filesystem.

  validate [config]          Validates the configuration file. If no argument is provided it
                             will validate the 'zenv.json' file in the current directory.
                             Reports errors with line numbers and field names if found.

  log <name|id|.>            Displays the setup log file for the specified environment.

  alias <subcommand>         Manages environment aliases for easier access:
    create <alias> <env>     Creates an alias for an environment.
    remove <alias>           Removes the alias (from every environment sharing it).
    ls                       Lists all defined aliases.
    show <alias>             Shows what environment an alias points to.

  jupyter <subcommand>       Manages Jupyter kernels for environments:
    create <env_name>        Creates a Jupyter kernel for the environment. The kernel starts
                             through 'zenv run', so it gets the env's modules; the env
                             needs ipykernel ('zenv add <env> ipykernel').
                             --name <kernel> and --display-name <text> replace the
                             defaults 'zenv-<env_name>' and 'Python (<env_name>)'.
    remove <env_name>        Removes the Jupyter kernel for the specified environment.
    ls                       Lists all zenv-managed Jupyter kernels.
    check                    Checks if Jupyter is installed and available.

  python <subcommand>        (Experimental feature) Manages Python installations:
    install <version>        Downloads and installs a specific Python version for zenv.
    pin <version>            Sets <version> as the pinned Python for zenv to prioritize.
    ls                       Shows Python versions installed and managed by zenv.

  version, -v, --version     Prints the installed zenv version.

  help, --help               Shows this help message.

Options for 'zenv setup <name>':
  --init                     Creates and populates 'zenv.json' file before 'zenv setup'.
                             Convenient for creating and setting up in one step.
  --no-python                With --init (or 'zenv init'): write the env as "python": false.

  --dev                      Installs the current directory's project in editable mode.
                             Equivalent to 'pip install --editable .' command.

  --uv                       Uses 'uv' instead of 'pip' for package operations.
                             Ensure 'uv' is installed and accessible.

  --no-host                  Bypasses hostname validation during setup.
                             Equivalent to "target_machines": ["*"] in zenv.json.
                             Use if an environment should be set up regardless of the machine.

  --python                   Use the zenv-pinned Python for creating environment.
                             Ignores the default Python priority[b] list.

  --force                    Installs every dependency, including those the loaded modules
                             already provide, and re-captures the module cache.

  --reuse-module-cache       Replays the existing module cache instead of re-running
                             'module load' when the module list is unchanged.
                             Automatic rebuilds use it; plain 'zenv setup' re-captures.

  --no-cache                 Disables the package cache when installing dependencies.
                             Ensures fresh package downloads for each installation.

  --jupyter                  Creates a Jupyter kernel for the environment after setup.
                             Equivalent to running 'zenv jupyter create <name>' after setup.

Options for 'zenv add <name> <package>':
  --dev                      Records the package as a development dependency.
                             pyproject.toml -> [dependency-groups].dev; otherwise zenv.json.
                             (Note: --dev means editable install for 'setup', dev dependency
                             for 'add' — its meaning is per-command.)

  --zenv                     Records the package only in zenv.json, leaving requirements.txt
                             and pyproject.toml untouched. The package is still installed.

  --uv                       Uses 'uv pip install' instead of 'python -m pip install'.

[z] Configuration (zenv.json):
  The 'zenv.json' file is a JSON formatted file that defines your environments.
  Each top-level key is an environment name. "base_dir": "path/to/venvs" is a special
  top-level key specifying the storage location for virtual environments.
  Paths can be absolute (e.g., /path/to/venvs) or relative to the 'zenv.json' location.
  In an environment, "python": false builds it without a Python venv, and "env" sets
  environment variables ("NAME": "value", or {"prepend": ...} / {"append": ...}).

[a] Registry (ZENV_DIR/registry.json):
  A global JSON file (path in ZENV_DIR environment variable, typically $HOME/.zenv)
  that tracks registered environments. This allows 'zenv' commands to manage
  these environments from any directory. Environments are added via 'zenv setup'
  or 'zenv register'.

[b] Python Priority List (for 'zenv setup' without '--python' flag):
  zenv attempts to find a Python interpreter in the following order:
  1. HPC module-provided Python (if HPC environment modules are loaded).
  2. Path explicitly specified by the 'fallback_python' key in zenv.json.
  3. zenv-pinned Python (set via 'zenv python pin <version>').
  4. System Python.
  Use 'zenv setup <name> --python' to use only the pinned version.
  When pyproject.toml sets requires-python (as the dependency_file, or with
  --dev), setup stops if the selected Python does not satisfy it.

[.] Dot Notation:
  Use '.' as the environment identifier to automatically select an environment
  from the current directory. This works when you're in a directory containing
  a zenv.json file and have registered environments for that directory.
  From a subdirectory of the project, use 'zenv activate --auto .' instead.

Automatic rebuilds:
  'run', 'activate', 'cd' and 'jupyter create' first rebuild an environment whose
  entry in zenv.json, or a file that entry names (dependency_file, modules_file,
  setup.script), changed since its last setup. A notice goes to stderr.

Environment variables:
  ZENV_DIR                   Where zenv keeps its registry and Python installs
                             (default: $HOME/.zenv).
  ZENV_NO_AUTO_SETUP=1       Turns automatic rebuilds off.
  ZENV_RUN_SHELL=1           'zenv run' sources activate.sh in bash instead of starting
                             the command directly.
  ZENV_DEBUG=1               Prints debug output.
```

## Issues

If you encounter any bugs open an Issue. To use the debug logging feature, set the `ZENV_DEBUG` environment variable:

Example:

```bash
ZENV_DEBUG=1 zenv setup <name>
```

## License

[MIT License](LICENSE)
