# zenv

Python Environment Manager for HPC and Development Systems

`zenv` is a command-line tool written in Zig that manages Python virtual environments, primarily designed for High-Performance Computing (HPC) environments and development systems.

## Features

### Core Functionality

The tool provides several key features:

1. **Environment Management**: Create, activate, and manage Python virtual environments with configurations stored in `zenv.json`
2. **Registry**: Track environments globally so they can be activated from any directory
3. **System Targeting**: Configure environments for specific machines or clusters
4. **Dependency Management**: Install Python packages with awareness of what's already provided by system modules
5. **Module Integration**: Load HPC modules required for environment setup

## Installation

```sh
curl -fsSL https://raw.githubusercontent.com/anoopkcn/zenv/HEAD/install.sh | sh
```

Run the same command to update already insalled `zenv` version

### Alternative methods of installation

<details>
<summary>Manual download of stable release</summary>

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

**A minimal example of a `zenv.json` file**:

```json
{
  "base_dir": "zenv"
  "test": {
    "target_machines": ["jrlogin*.jureca", "*"],
    "description": "Basic environment JURECA and any machine",
    "modules": ["Stages/2025", "StdEnv", "Python"],
    "dependency_file": "requirements.txt"
  }
}
```

Check the [Configuration Reference](#configuration-reference) for full list of key-values. The optional `dependency_file` can be `requirements.txt` OR  `pyproject.toml` file. If you run `zenv init` then it will be automatically populated according to what is found in the project.

### Listing environments

List all environments registered for the current machine:

```bash
zenv list # for listing envs configured for current computer
# OR
zenv list --all # for listing all available envs in the registry
```

Example output:

```
- test
  id      : c3c494547b40f070b4c080f95c707622d84fe749
  target  : jureca, juwels, *
  project : /path/to/project/
  venv    : /path/to/project/zenv/test
  desc    : Test python environment

Found 1 environment(s) for the current machine ('jrlogin01.jureca').
```

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
```

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

OR make environment avilable for your editor without activaton:

```bash
# for vim or neovim
zenv run test vim

# for vs code
# zenv run test code -n .
```

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

If you would like to use zenv-managed default Python for the environment, run:

```bash
# Install a python version if not done already
zenv python install <version>

# Pin a specic python version
zenv python use <version>

# use the pinned version
zenv setup <name> --python
```

## Configuration Reference

One can have multiple environment configurations in the same `zenv.json` file and it supports the following structure:

```json
{
  "base_dir": "<base dirrectory where all envs listed in the config will be stored>",
  "<name>": {
    "target_machines": ["<machine identifier accepts wild card *>"],
    "fallback_python": "<path to python executable OR null>",
    "description": "<optional description OR null>",
    "modules": ["<module1>", "<module2>"],
    "modules_file": "<path to modules file OR null>"
    "dependency_file": "<optional path to requirements_txt OR pyproject_toml OR null>",
    "dependencies": ["<package name with or without version>"],
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
    "target_machines": ["<anothor machine identifier>"]
  }
}
```

One can run `zenv validate` to validate the config file. It there are errors in the JSON it will try to inform the context of the error.

In the configuration `target_machines` is required key(If you want, you can disable the validation check using `--no-host`), all other entries are optional. Top-level `base_dir` can be an absolute path or relative one(relative to the `zenv.json` file), if not provided it will create a directory called `zenv` at the project root. One can use wildcards to target specific systems, to mantch any machine use `*` or `any` (`"target_machines": ["*"]`). The lookup location of the `dependency_file` is the same directory as `zenv.json`.

For custom scripts, you can use `activate_hook` and `setup_hook` to specify paths to shell scripts that will be copied to the environment's directory and executed during activation or setup. These scripts allow for more complex customization than inline commands. The scripts are copied to the environment directory, making the environment portable and independent of the original script location.

The key-val `"modules_file": "path/to/file.txt"` can be specified in an environment to load module names from an external file. The file can contain module names separated by spaces, tabs, commas, or newlines. When specified, any modules listed in the "modules" array are ignored.

## Help

```bash
zenv help
```

Output:

```
Usage: zenv <command> [environment_name|id] [options]

Manages Python virtual environments based on zenv.json configuration.

Commands:
  init [name] [desc]       Initializes a new 'zenv.json' in the current directory.
                           Creates a 'test' environment if 'name' is not provided.
                           Use to start defining your environments.

  setup <name>             Creates and configures the virtual environment for '<name>'.
                           Builds the environment in '<base_dir>/<name>' as per 'zenv.json'.
                           This is the primary command to build an environment.

  activate <name|id>       Outputs the activation script path for an environment.
                           To use: source $(zenv activate <name|id>)

  run <name|id> <command>  Executes a <command> within the specified isolated environment.
                           Does NOT require manual activation of the environment.

  cd <name|id>             Outputs the project directory path for an environment.
                           To use: cd $(zenv cd <name|id>)

  list                     Lists registered environments accessible on this machine.

  list --all               Lists all registered environments.

  register <name>          Adds the environment '<name>' (from current 'zenv.json')
                           to the global registry, making it accessible from any location.

  deregister <name|id>     Removes an environment from the global registry.
                           The virtual environment files are NOT deleted.

  rm <name|id>             De-registers the environment AND permanently deletes its
                           virtual environment directory from the filesystem.

  python <subcommand>      Manages Python installations used by zenv:
    install <version>      Downloads and installs a specific Python version for zenv.
    use <version>          Sets <version> as the pinned Python for zenv to prioritize.
    list                   Shows Python versions installed and managed by zenv.

  validate                 Validates the configuration file in the current directory.
                           Reports errors with line numbers and field names if found.

  log <name|id>            Displays the setup log file for the specified environment.
                           Useful for troubleshooting setup issues.

  version, -v, --version   Prints the installed zenv version.

  help, --help             Shows this help message.

Options for 'zenv setup <name>':
  --no-host                Bypasses hostname validation during setup.
                           (Equivalent to "target_machines": ["*"] in zenv.json).
                           Use if an environment should be set up regardless of the machine.

  --init                   Automatically runs 'zenv init <name>' before 'zenv setup'.
                           Convenient for creating and setting up in one step.

  --uv                     Uses 'uv' instead of 'pip' for package operations.
                           Ensure 'uv' is installed and accessible.

  --rebuild                Attempts to rebuild existing virtual environment.
                           Recreates the environment if it's corrupted or doesn't exist.

  --python                 Forces setup to use only the zenv-pinned Python version.
                           Ignores the default Python priority list (see below).

  --dev                    Installs the current directory's project in editable mode.
                           (Equivalent to 'pip install --editable .').
                           Requires a 'setup.py' or 'pyproject.toml'.

  --force                  Forces reinstallation of all dependencies.
                           Useful if dependencies from loaded modules cause conflicts.

  --no-cache               Disables the package cache when installing dependencies.
                           Ensures fresh package downloads for each installation.

Configuration (zenv.json):
  The 'zenv.json' file is a JSON formatted file that defines your environments.
  Each top-level key is an environment name. "base_dir": "path/to/venvs" is a special
  top-level key specifying the storage location for virtual environments.
  Paths can be absolute (e.g., /path/to/venvs) or relative to the 'zenv.json' location.

Registry (ZENV_DIR/registry.json):
  A global JSON file (path in ZENV_DIR environment variable, typically ~/.zenv)
  that tracks registered environments. This allows 'zenv' commands to manage
  these environments from any directory. Environments are added via 'zenv setup'
  or 'zenv register'.

Python Priority List (for 'zenv setup' without '--python' flag):
  zenv attempts to find a Python interpreter in the following order:
  1. HPC module-provided Python (if HPC environment modules are loaded).
  2. 'fallback_python' path explicitly configured in 'zenv.json'.
  3. zenv-pinned Python (set via 'zenv python use <version>').
  4. System 'python3'.
  5. System 'python'.
  Use 'zenv setup <name> --python' to use only the pinned version (item 3).
```

## Issues

If you encounter any bugs open an Issue. To use the debug logging feature, users can set the `ZENV_DEBUG` environment variable:

Example:

```bash
ZENV_DEBUG=1 zenv setup <name>
```

## License

[MIT License](LICENSE)
