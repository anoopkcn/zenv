# zenv
zenv: Python Environment Manager for HPC and Development Systems

`zenv`  is a command-line tool written in Zig that manages Python virtual environments, primarily designed for High-Performance Computing (HPC) environments and development systems.

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

### Alternative methods of installation

<details>
<summary>Manual download of stable release</summary>

```bash
# Replace <tag> with last stable release version:
curl -LO "https://github.com/anoopkcn/zenv/releases/download/<tag>/zenv-x86_64-linux-musl.tar.gz"

# Extract the 'zenv' executable and move it somewhere in your 'PATH'
tar -xvf zenv-x86_64-linux-musl.tar.gz
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

# Optional: Add to your PATH
export PATH="$PATH:path/to/zig-out/bin"
```

</details>

Check [release](https://github.com/anoopkcn/zenv/releases) for specific versions.
Supported OS: Linux(`aarch64`, `x86_64`), MacOS(`aarch64`, `x86_64`).
Linux versions are `musl` NOT `glibc`. _Windows support is not planned_

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
  "env_name": {
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
Available zenv environments:
- test (fd15568424877584b01313de7b6a5a57be73b746)
  [target  : jureca, juwels, *]
  [project : /p/project1/hai_matbind/chandran1/zenv/test]
  [venv    : /p/project1/hai_matbind/chandran1/zenv/test/zenv/test]
  [desc    : Test python environment]

Found 1 environment(s) for the current machine ('jrlogin12.jureca').
```

### Activating environments

Activate an environment by name or ID

Example:

```bash
# Activate by name
source $(zenv activate env_name)

# Activate by full ID
source $(zenv activate fd15568424877584b01313de7b6a5a57be73b746)

# Activate by partial ID (first 7+ characters)
source $(zenv activate fd15568)
```

### Registering and Deregistering Environments

A metadata information about the environments are stored at `ZENV_DIR/registry.json`. by default `ZENV_DIR` is `$HOME/.zenv`.
But one can set `ZENV_DIR` environment variable as any directory with write permission.

Register an environment in the global registry:

**This is done automatically when you run `zenv setup env_name`**

```bash
zenv register env_name
```

Remove an environment from the registry:

```bash
zenv deregister env_name     # Remove by name or ID
```

## Python Management
The default priority of the Python is as follows:

1. Module-provided Python (if HPC modules are loaded)
2. Explicitly configured fallback_python from zenv.json (if specified)
3. zenv-managed default Python (if set with `zenv python use <version>`)
4. System python3
5. System python

If you would like to use zenv-managed default Python for the environment the use:
```bash
zenv setup <env_name> --python
```
Note that this command assumes you have already installed a python version using `zenv python install <version>` and run the command `zenv python use <version>` to pin a python version(`ZENV_DIR/default-python`)


## Configuration Reference

One can have multiple environment configurations in the same `zenv.json` file and it supports the following structure:

```json
{
  "base_dir": "<opional_base_dir>",
  "<env_name>": {
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
  "<another_env_name>": {
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

  setup <env_name>          Set up the specified environment based on zenv.json file.
                            Creates a virtual environment in <base_dir>/<env_name>/.

  activate <env_name|id>    Output the path to the activation script.
                            You can use the environment name or its ID (full or partial).
                            To activate the environment, use: source $(zenv activate <env_name|id>)

  cd <env_name|id>          Output the project directory path.
                            You can use the environment name or its ID (full or partial).
                            To change to the project directory, use: cd $(zenv cd <env_name|id>)

  list                      List environments registered for the current machine.

  list --all                List all registered environments.

  register <env_name>       Register an environment in the global registry.
                            Registers the current directory as the project directory.

  deregister <env_name|id>  Remove an environment from the global registry.
                            It does not remove the environment itself.

  python <subcommand>       Python management commands:
    install <version>       Install a specified Python version (e.g., 3.10.8)
    use <version>           Set the specified version as the pinned python version.
    list                    List all installed Python versions

  version, -v, --version    Print the zenv version.

  help, --help              Show this help message.

Options:
  --force-deps              When used with setup command, it tries to install all dependencies
                            even if they are already provided by loaded modules.

  --no-host                 Bypass hostname validation and allow setup/register of an environment
                            regardless of the target_machine specified in the configuration.
                            Useful for portable environments or development machines.

  --rebuild                 Force rebuild the virtual environment, even if it already exists.
                            Useful when modules change or Python version needs to be updated.

  --python                  Use only the default Python set with 'zenv python use <version>'.
                            This ignores any module-provided Python and other configuration.
                            Will error if no default Python is configured.

Configuration (zenv.json):
  The 'zenv.json' file defines your environments. It can optionally include top-level key-value:
  "base_dir": "path/to/venvs",  Specifies the base directory for creating virtual environments.
  Can be relative to zenv.json location or an absolute path(starts with a /).
  Defaults to "base_dir": "zenv" if omitted.

Registry (ZENV_DIR/registry.json):
  The global registry allows you to manage environments from any directory.
  Setting up an environment will register that environment OR register it with 'zenv register <env_name>'.
  Once registred one can activate it from anywhere with 'source $(zenv activate <env_name|id>)'.
  Also the project directory can be 'cd' into from anywhere using 'source $(zenv cd <env_name|id>)'
```

## Issues

If you encounter any bugs open an Issues. To use the debug logging feature, users can set the `ZENV_DEBUG` environment variable:

Example:

```bash
ZENV_DEBUG=1 zenv setup env_name
```

## License

[MIT License](LICENSE)
