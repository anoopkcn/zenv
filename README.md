# zenv
Zenv - A virtual environment manager for supercomputers

`zenv` is a flexible python environment manager that simplifies the setup, activation, and management of project environments.

## Features

- **Environment Setup**: Creates a virtual environment with specific dependencies with a single `zenv.json` file.
- **Module Support**: Integrate with HPC module systems, specified in the same `zenv.json`
- **Machine-Specific Environments**: Configure environments for specific target machines
- **Operations from any directory**: All environments are registered at `~/.zenv/registry.json`, so operations like activation, listing and changing directories can be done from any directory location

## Installation

### Install a pre-built executable
Get the latest [release](https://github.com/anoopkcn/zenv/releases)

Example for Linux x86_64 machine:
```bash
curl -LO "https://github.com/anoopkcn/zenv/releases/download/tip/zenv-x86_64-linux-musl-small.tar.gz"
```
and extract the `zenv` executable using:
```bash
tar -xvf zenv-x86_64-linux-musl-small.tar.gz

```
Move the `zenv` executable somewhere in your PATH ( for example: `~/.local/bin/`)

**Supported OS: Linux(aarch64, x86_64), MacOs(aarch64, x86_64)**

*The linux versions are `musl` NOT `glibc`. Windows support is not planned*

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

Create a `zenv.json` configuration file in your project directory. You can then modify this json file according to your needs.

Example:
```json
{
  "my_env": {
    "target_machine": "computer1",
    "requirements_file": "requirements.txt", // or pyproject.toml
    "description": "Basic environment for Computer1",
    "modules":[ "Python", "CUDA" ]
    "dependencies": [ "numpy>=1.20.0", "tqdm" ]
  }
}
```
Provided `dependencies` will be installed in addition to the dependencies found in the `requirements_file` which can be (`requirements.txt` or a `pyproject.toml` file)

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
- test (ID: e66460f... Target: computer1 - My PyTorch environment for Computer1)
  [Project: /path/to/project]
- my_env (ID: 4a422bf... Target: computer2)
  [Project: /path/to/project]
Found 2 environment(s) for the current machine ('login07.computer1').
```

### Activating Environments

Activate an environment by name or ID

Example:
```bash
# Activate by name
source $(zenv activate my_env)

# Activate by full ID
source $(zenv activate 4a422bfd015982bc2569ebacb45bb590d7d5c561)

# Activate by partial ID (first 7+ characters)
source $(zenv activate 4a422bf)
```

### Registering and Unregistering Environments

Register an environment in the global registry:

*This is done automatically when you run `zenv setup <env_name>`*

```bash
zenv register my_env
```

Remove an environment from the registry:

```bash
zenv unregister my_env
```

## Configuration Reference

One can have multiple environment configurations in the same  `zenv.json` file and it supports the following structure:

```json
{
  "<env_name>": {
    "target_machine": "<machine_identifier>",
    "description": "<optional_description>",
    "modules": [
      "<module1>",
      "<module2>",
      // ...
    ],
    "requirements_file": "<optional_path_to_requirements_txt_or_pyproject_toml>",
    "dependencies": [
      "<package_name>[==version]",
      //...
    ],
    "python_executable": "<optional_path_to_python>",
    "custom_activate_vars": {
      "ENV_VAR_NAME": "value",
      //...
    },
    "setup_commands": [
      "echo 'Running custom setup commands'",
      //...
    ]
  },
  "<another_env_name>":{
    "target_machine": "<anothor_machine_identifier>",
    // ...
  }
}
```

## Registry

Zenv maintains a global registry at `~/.zenv/registry.json` that allows you to activate environments from any directory. The registry stores:

- Environment names
- Unique SHA-1 IDs
- Project directories
- Target machines
- Optional descriptions

## Issues
If you encounter any bugs open an Issues. To use the debug logging feature, users can set the `ZENV_DEBUG` environment variable:

Example:
```bash
ZENV_DEBUG=1 zenv setup env_name
```

## License

[MIT License](LICENSE)
