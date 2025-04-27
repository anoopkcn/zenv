# zenv
Zenv - Environment Manager for supercomputing clusters

Zenv is a flexible environment manager that simplifies the setup, activation, and management of project environments.

## Features

- **Environment Setup**: Create Python virtual environments with specific dependencies
- **Module Support**: Integrate with HPC module systems
- **Machine-Specific Environments**: Configure environments for specific target machines

## Installation

```bash
# Clone the repository
git clone https://github.com/anoopkcn/zenv.git

# Build the project
cd zenv
zig build

# Optional: Add to your PATH
export PATH="$PATH:$(pwd)/zig-out/bin"
```

## Usage

### Creating an Environment

Create a `zenv.json` configuration file in your project directory:

```json
{
  "my_env": {
    "target_machine": "computer1",
    "description": "Basic environment for Computer1",
    "dependencies": [
      "numpy",
      "scipy",
      "matplotlib"
    ]
  },
  "my_env2": {
    "target_machine": "computer2",
    "description": "Basic environment for Jureca",
    "dependencies": [
      "numpy",
      "scipy",
      "matplotlib"
    ]
  }
}
```

Then set up the environment:

```bash
zenv setup my_env
```

### Listing Environments

List all environments registered for the current machine:

```bash
zenv list
```

Example output:
```
Available zenv environments:
- test (ID: e66460f... Target: computer1 - My PyTorch environment for Computer1)
  [Project: /path/to/project]
  Full ID: e66460fc6eb7e1d133ca000d5e28abc66b16a3d0 (you can use the first 7+ characters)
- my_env (ID: 4a422bf... Target: computer2 - Basic environment for Computer2)
  [Project: /path/to/project]
  Full ID: 4a422bfd015982bc2569ebacb45bb590d7xyz561 (you can use the first 7+ characters)
Found 2 environment(s) for the current machine ('jrlogin07.jureca').
```

### Activating Environments

Activate an environment by name or ID:

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

```bash
zenv register my_env
```

Remove an environment from the registry:

```bash
zenv unregister my_env
```

## Configuration Reference

The `zenv.json` file supports the following structure:

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
