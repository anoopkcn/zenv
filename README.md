# zenv

`zenv` is a flexible python environment manager that simplifies the setup, activation, and management of project environments **for supercomputers**

## Features

- **Environment Setup**: Creates a virtual environment with specific dependencies with a single `zenv.json` file.
- **Module Support**: Integrate with HPC module systems, specified in the same `zenv.json`
- **Machine-Specific Environments**: Configure environments for specific target machines
- **Operations from any directory**: Environments can be located anywhere(project directory or a global location) but all are registered at `~/.zenv/registry.json`, so operations like activation, listing and changing directories can be done from any directory location
- **Validation**: Input validation, module priority mode(by default)

## Installation

Install the latest stable [release](https://github.com/anoopkcn/zenv/releases) (pre-built executable)

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/anoopkcn/zenv/HEAD/install.sh)"
```

Supported OS: Linux(`aarch64`, `x86_64`), MacOS(`aarch64`, `x86_64`)

_note: linux versions are `musl` NOT `glibc`. Windows support is not planned_

<details>
<summary> OR manual download of stable release: </summary>

```bash
# Replace <tag> with last stable release version:
# Example tag = v0.5.4
curl -LO "https://github.com/anoopkcn/zenv/releases/download/<tag>/zenv-x86_64-linux-musl-small.tar.gz"
```

Extract the `zenv` executable and move it somewhere in your `PATH`

```bash
tar -xvf zenv-x86_64-linux-musl-small.tar.gz
mv zenv ~/.local/bin/
```

</details>

<details>

<summary>OR Build from Source</summary>

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
    "target_machines": ["login*.computer1", "cnode*"],
    "python_executable": "python3",
    "requirements_file": "requirements.txt",
    "description": "Basic environment for Computer1",
    "modules":[ "Stages/2025", "StdEnv", "Python", "CUDA" ]
    "dependencies": [ "numpy>=1.20.0", "tqdm" ]
  }
}
```

Provided `dependencies` will be installed in addition to the dependencies found in the optional `requirements_file` which can be (`requirements.txt` or a `pyproject.toml` file)

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
- env_name (404dee1315fb7a2447e864ec029d6d06562afa68)
  [target  : *.machine1, cnode*]
  [project : /path/to/project]
  [venv    : /path/to/project/zenv/env_name]
  [desc    : My test environment for machine1]

Found 1 total registered environment(s).
```

### Activating environments

Activate an environment by name or ID

Example:

```bash
# Activate by name
source $(zenv activate env_name)

# Activate by full ID
source $(zenv activate 404dee1315fb7a2447e864ec029d6d06562afa68)

# Activate by partial ID (first 7+ characters)
source $(zenv activate 404dee1)
```

### Registering and Deregistering Environments

Register an environment in the global registry:

**This is done automatically when you run `zenv setup env_name`**

```bash
zenv register env_name
```

Remove an environment from the registry:

```bash
zenv deregister env_name     # Remove by name or ID
```

## Configuration Reference

One can have multiple environment configurations in the same `zenv.json` file and it supports the following structure:

```json
{
  "base_dir": "<opional_base_dir>",
  "<env_name>": {
    "target_machines": ["<machine_identifier>"],
    "python_executable": "<path_to_python>",
    "description": "<optional_description>",
    "modules": ["<module1>", "<module2>"],
    "requirements_file": "<optional_path_to_requirements_txt_or_pyproject_toml>",
    "dependencies": ["<package_name_version>"],
    "custom_activate_vars": {
      "ENV_VAR_NAME": "value"
    },
    "setup_commands": ["echo 'Running custom setup commands'"]
  },
  "<another_env_name>": {
    "target_machines": ["<anothor_machine_identifier>"],
    "python_executable": "<path_to_python>"
  }
}
```

In the configuration `target_machines` and `python_executable` are required key-values, all other entries are optional. Top-level `base_dir` can be an absolute path or relative one(relative to the `zenv.json` file), if not provided it will create a directory called `zenv` at the project directory. One can use wildcards to target specific systems, to mantch all systems use `*` or `any` (`"target_machines": ["*"]`). The lookup location of the `requirements_file` is the same directory as `zenv.json`.

## Help

```bash
zenv help
```

Output:

```
Usage: zenv <command> [environment_name|id] [options]

Manages environments based on zenv.json configuration.

Configuration (zenv.json):
  The zenv.json file defines your environments. It can optionally include top-level key-value:
  "base_dir": "path/to/venvs",  Specifies the base directory for creating virtual environments.
  Can be relative to zenv.json location or an absolute path. Defaults to "zenv" if omitted.

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

  version, -v, --version    Print the zenv version.

  help, --help              Show this help message.

Options:
  --force-deps              When used with setup command, it tries to install all dependencies
                            even if they are already provided by loaded modules.

  --no-host                 Bypass hostname validation and allow setup/register of an environment
                            regardless of the target_machine specified in the configuration.
                            Useful for portable environments or development machines.

Registry:
  The global registry (~/.zenv/registry.json) allows you to manage environments from any directory.
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
