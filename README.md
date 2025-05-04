# zenv

zenv: Python Environment Manager for HPC and Development Systems

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
zenv init
# This creates a `zenv.json` configuration file TEMPLATE in your project directory
# You can then modify this json file according to your needs and run:
zenv setup <name_of_your_environment>
```

Example of a `zenv.json` file:

```json
{
  "test": {
    "target_machines": ["jrlogin*.jureca", "*.juwels", "jrc*"],
    "fallback_python": null,
    "dependency_file": "requirements.txt",
    "description": "Basic environment for jureca and juwels",
    "modules": ["Stages/2025", "StdEnv", "Python", "CUDA"],
    "dependencies": ["numpy>=1.20.0", "pandas"]
  }
}
```

Provided `dependencies` will be installed in addition to the dependencies found in the optional `dependency_file` which can be (`requirements.txt` or a `pyproject.toml` file)

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
    project : /p/project1/hai_matbind/chandran1/zenv/test
    venv    : /p/project1/hai_matbind/chandran1/zenv/test/zenv/test
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
  "base_dir": "<opional_base_dir>",
  "<name>": {
    "target_machines": ["<machine_identifier>"],
    "fallback_python": "<path_to_python_or_null>",
    "description": "<optional_description_or_null>",
    "modules": ["<module1>", "<module2>"],
    "dependency_file": "<optional_path_to_requirements_txt_or_pyproject_toml_or_null>",
    "dependencies": ["<package_name_version>"],
    "setup_commands": ["<custom commands to run during setup process>"],
    "custom_activate_vars": {
      "ENV_VAR_NAME": "value"
    },
    "activate_commands": ["<custom commands to run during activation process>"]
  },
  "<another_name>": {
    "target_machines": ["<anothor_machine_identifier>"]
  }
}
```

In the configuration `target_machines` is required key(If you want, you can disable the validation check using `--no-host`), all other entries are optional. Top-level `base_dir` can be an absolute path or relative one(relative to the `zenv.json` file), if not provided it will create a directory called `zenv` at the project root. One can use wildcards to target specific systems, to mantch any machine use `*` or `any` (`"target_machines": ["*"]`). The lookup location of the `dependency_file` is the same directory as `zenv.json`.

## Help

```bash
zenv help
```

Output:

```
Usage: zenv <command> [environment_name|id] [options]

Manages environments based on zenv.json configuration.

Commands:
  init                      Create a new zenv.json template file in the current directory.

  setup <name>              Set up the specified environment based on zenv.json file.
                            Creates a virtual environment in <base_dir>/<name>/.
                            <base_dir> and <name> can be defined in the zenv.json file.

  activate <name|id>        Output the path to the activation script.
                            You can use the environment name or its ID (full or partial).
                            To activate the environment, use:
                            source $(zenv activate <name|id>)

  cd <name|id>              Output the project directory path.
                            You can use the environment name or its ID (full or partial).
                            To change to the project directory, use:
                            cd $(zenv cd <name|id>)

  list                      List environments registered for the current machine.

  list --all                List all registered environments.

  register <name>           Register an environment in the global registry.
                            Registers the current directory as the project directory.

  deregister <name|id>      Remove an environment from the global registry.
                            It does not remove the environment itself.

  python <subcommand>       Python management commands:
                            install <version>  :  Install a specified Python version.
                            use <version>      :  pinn a python version.
                            list               :  List all installed Python versions.

  version, -v, --version    Print the zenv version.

  help, --help              Show this help message.

Options for setup:
  --force-deps              It tries to install all dependencies even if they are already
                            provided by loaded modules.

  --no-host                 Bypass hostname validation, this is equivalant to setting
                            "target_machines": ["*"] in the zenv.json

  --rebuild                 Re-build the virtual environment, even if it already exists.

  --python                  Use only the pinned Python set with 'use' subcommand.
                            This ignores the default python priority list.
                            Will error if no pinned Python is configured.

Configuration (zenv.json):
  The 'zenv.json' file defines your environments. Environment names occupy top level
  "base_dir": "path/to/venvs", is exceptional top level key-value which specifies the
  base directory for for storing environments. The value can be a relative path,
  relative to zenv.json OR an absolute path(if path starts with a /).

Registry (ZENV_DIR/registry.json):
  The global registry allows you to manage environments from any directory.
  Setting up an environment will register that environment OR
  register it with 'zenv register <name>'. Once registred one can activate
  using 'source $(zenv activate <name|id>)' from any directory.

Python Priority list
  1. Module-provided Python (if HPC modules are loaded)
  2. Explicitly configured 'fallback_python' from zenv.json (if not null)
  3. zenv-managed pinned Python
  4. System python3
  5. System python
  This prority list can be ignored with 'zenv setup <name> --python' which will use,
  pinned python to manage the environement
```

## Issues

If you encounter any bugs open an Issue. To use the debug logging feature, users can set the `ZENV_DEBUG` environment variable:

Example:

```bash
ZENV_DEBUG=1 zenv setup name
```

## License

[MIT License](LICENSE)
