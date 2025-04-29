# zenv

zenv - A virtual environment manager for supercomputers

`zenv` is a flexible python environment manager that simplifies the setup, activation, and management of project environments.

## Features

- **Environment Setup**: Creates a virtual environment with specific dependencies with a single `zenv.json` file.
- **Module Support**: Integrate with HPC module systems, specified in the same `zenv.json`
- **Machine-Specific Environments**: Configure environments for specific target machines
- **Operations from any directory**: All environments are registered at `~/.zenv/registry.json`, so operations like activation, listing and changing directories can be done from any directory location
- **Validation**: Input validation, module priority mode(by default)

## Installation

### Install a pre-built executable

Get the latest [release](https://github.com/anoopkcn/zenv/releases)

For example to get latest **pre-release** build for Linux x86_64 machine:

```bash
curl -LO "https://github.com/anoopkcn/zenv/releases/download/tip/zenv-x86_64-linux-musl-small.tar.gz"
```

OR

Get the latest stable release:

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

**Supported OS: Linux(aarch64, x86_64), MacOs(aarch64, x86_64)**

_The linux versions are `musl` NOT `glibc`. Windows support is not planned_

### Build from source

```bash
# Clone the repository
git clone https://github.com/anoopkcn/zenv.git

# Build the project
cd zenv
zig build

# Optional: Add to your PATH
export PATH="$PATH:path/to/zig-out/bin"
```

## Usage

### Creating an Environment

```bash
zenv init
```

This creates a `zenv.json` configuration file in your project directory. You can then **modify this json file** according to your needs.

Example:

```json
{
  "my_env": {
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

Then set up the environment:

```bash
zenv setup <env_name>
```

### Listing Environments

List all environments registered for the current machine:

```bash
zenv list
# OR
zenv list --all
```

Example output:

```
Available zenv environments:
- test (ID: e66460f... Target: login*.computer1, cnode* - My PyTorch environment for Computer1)
  [Project: /path/to/project]
Found 1 environment(s) for the current machine ('login07.computer1').
```

### Activating Environments

Activate an environment by name or ID

Example:

```bash
# Activate by name
source $(zenv activate my_env)

# Activate by full ID
source $(zenv activate e66460fd015982bc2569ebacb45bb590d7d5c561)

# Activate by partial ID (first 7+ characters)
source $(zenv activate e66460f)
```

### Registering and Deregistering Environments

Register an environment in the global registry:

_This is done automatically when you run `zenv setup <env_name>`_

```bash
zenv register my_env
```

Remove an environment from the registry:

```bash
zenv deregister my_env        # Remove by name
zenv deregister abc1234      # Remove by ID prefix
```

## Configuration Reference

One can have multiple environment configurations in the same `zenv.json` file and it supports the following structure:

NOTE: THE CONFIG TEMPLATE IS ONLY A REFERENCE, COMMENTS (`//`) WILL THROW AN ERROR IF YOU TRY TO USE IT WITHOUT MODIFICATION

```json
{
  "base_dir": "<opional_base_dir>",
  "<env_name>": {
    "target_machines": ["<machine_identifier>"], // REQUIRED FIELD
    "python_executable": "<path_to_python>", // REQUIRED FIELD
    "description": "<optional_description>",
    "modules": [
      "<module1>",
      "<module2>"
      // ...
    ],
    "requirements_file": "<optional_path_to_requirements_txt_or_pyproject_toml>",
    "dependencies": [
      "<package_name>[==version]"
      //...
    ],
    "custom_activate_vars": {
      "ENV_VAR_NAME": "value"
      //...
    },
    "setup_commands": [
      "echo 'Running custom setup commands'"
      //...
    ]
  },
  "<another_env_name>": {
    "target_machines": ["<anothor_machine_identifier>"], // REQUIRED FIELD
    "python_executable": "<path_to_python>" // REQUIRED FIELD
    // ...
  }
}
```

In the configuration `target_machines` and `python_executable` are required key-values, all other entries are optional. Top-level `base_dir` can be an absolute path or relative one(relative to the `zenv.json` file), if not provided it will create a directory called `zenv` at the project directory. One can use wildcards to target specific systems, to mantch all systems use `*` or `any` (`"target_machines": ["*"]`). The lookup location of the `requirements_file` is the same directory as `zenv.json`.


## Help

```bash
zenv --help
```

Output:

```
Usage: zenv <command> [environment_name|id] [options]

Manages environments based on zenv.json configuration.

Configuration (zenv.json):
  The zenv.json file defines your environments. It can optionally include top-level key-value:
  "base_dir": "path/to/venvs",  Specifies the base directory for creating virtual environments.
  Can be relative to zenv.json location or an absolute path.
  Defaults to "zenv" if omitted.

Commands:
  init                      Create a new zenv.json template file in the current directory.

  setup <env_name>          Set up the specified environment for the current machine.
                            Creates a Python virtual environment in <base_dir>/<env_name>/.
                            Checks if current machine matches env_name's target_machine.

  activate <env_name|id>    Output the path to the activation script.
                            You can use the environment name or its ID (full or partial).
                            To activate the environment, use:
                            source $(zenv activate <env_name|id>)

  cd <env_name|id>          Output the project directory path.
                            You can use the environment name or its ID (full or partial).
                            To change to the project directory, use:
                            cd $(zenv cd <env_name|id>)

  list                      List environments registered for the current machine.

  list --all                List all registered environments.

  register <env_name>       Register an environment in the global registry.
                            Registers the current directory as the project directory.

  deregister <env_name|id>  Remove an environment from the global registry.

  version, -v, --version    Print the zenv version.

  help, --help              Show this help message.

Options:
  --force-deps              When used with setup command, it tries to install all specified dependencies
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
