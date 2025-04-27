# zenv
Zenv - A python environment manager for supercomputers

Zenv is a flexible python environment manager that simplifies the setup, activation, and management of project environments that has a module system.

## Features

- **Environment Setup**: Create Python virtual environments with specific dependencies with a single `zenv.json` file.
- **Module Support**: Integrate with HPC module systems
- **Machine-Specific Environments**: Configure environments for specific target machines
- **Operations from any directory**: All environments are registered at `~/.zenv/registry.json` so operations like activation, lisitng and changing directories can be done from any directory location

## Installation

### Install a pre-built executable
Get the latest [release](https://github.com/anoopkcn/zenv/releases)
```bash
wget https://github.com/anoopkcn/zenv/releases/download/tip/zenv-x86_64-linux-musl.tar.xz
```

*Windows not supported*

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

Create a `zenv.json` configuration file in your project directory

Example:
```json
{
  "my_env": {
    "target_machine": "computer1",
    "description": "Basic environment for Computer1",
    "modules":[
      "Python"
      "CUDA"
    ]
    "dependencies": [
      "numpy",
      "scipy",
      "matplotlib"
    ]
  },
  "my_env2": {
    "target_machine": "computer2",
    ...
  }
}
```

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
Found 2 environment(s) for the current machine ('jrlogin07.jureca').
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

Tou can have multiple environment configurations in the same  `zenv.json` file and it supports the following structure:

```json
{
  "<env_name>": {
    "target_machine": "<machine_identifier>",
    "description": "<optional_description>",
    "modules": [
      "<module1>",
      "<module2>",
    ],
    "requirements_file": "<optional_path_to_requirements_txt_or_pyproject_toml>",
    "dependencies": [
      "<package_name>[==version]"
    ],
    "python_executable": "<optional_path_to_python>",
    "custom_activate_vars": {
      "ENV_VAR_NAME": "value"
    },
    "setup_commands": [
      "echo 'Running custom setup commands'"
    ]
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

## License

[MIT License](LICENSE)
