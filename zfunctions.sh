# zenv shell functions
# Add these to your .bashrc, .zshrc, or other shell configuration file

# Setup a new environment
zsetup() {
    local env_name="$1"
    local force_deps=""

    if [[ "$#" -lt 1 ]]; then
        echo "Usage: zsetup <env_name> [--force-deps]"
        return 1
    fi

    if [[ "$2" == "--force-deps" ]]; then
        force_deps="--force-deps"
    fi

    echo "Setting up environment '$env_name'..."
    zenv setup "$env_name" $force_deps

    if [[ $? -eq 0 ]]; then
        echo "Environment '$env_name' set up successfully."
        echo "To activate it, use: zactivate $env_name"
    fi
}

# Activate an environment
zactivate() {
    local env_name="$1"

    if [[ "$#" -lt 1 ]]; then
        echo "Usage: zactivate <env_name|id>"
        return 1
    fi

    echo "Activating environment '$env_name'..."
    local activate_script=$(zenv activate "$env_name")

    if [[ $? -eq 0 && -n "$activate_script" ]]; then
        source "$activate_script"
        # Store the active environment name for potential use in command prompt
        export ZENV_ACTIVE_ENV="$env_name"
    else
        echo "Failed to activate environment '$env_name'"
        return 1
    fi
}

# Deactivate the current environment
zdeactivate() {
    if declare -f deactivate_all > /dev/null; then
        deactivate_all
        unset ZENV_ACTIVE_ENV
        echo "Environment deactivated."
    elif declare -f deactivate > /dev/null; then
        deactivate
        unset ZENV_ACTIVE_ENV
        echo "Environment partially deactivated (only venv)."
    else
        echo "No active environment to deactivate."
        return 1
    fi
}

# List environments
zlist() {
    if [[ "$1" == "--all" ]]; then
        zenv list --all
    else
        zenv list
    fi
}

# Register an environment
zreg() {
    local env_name="$1"

    if [[ "$#" -lt 1 ]]; then
        echo "Usage: zreg <env_name>"
        return 1
    fi

    zenv register "$env_name"
}

# Deregister an environment
zdereg() {
    local env_name="$1"

    if [[ "$#" -lt 1 ]]; then
        echo "Usage: zdereg <env_name>"
        return 1
    fi

    zenv unregister "$env_name"
}

# Change to environment's project directory
zcd() {
    local env_name="$1"

    if [[ "$#" -lt 1 ]]; then
        echo "Usage: zcd <env_name|id>"
        return 1
    fi

    local project_dir=$(zenv cd "$env_name")

    if [[ $? -eq 0 && -n "$project_dir" ]]; then
        echo "Changing to project directory for '$env_name'..."
        cd "$project_dir"
    else
        echo "Failed to find project directory for '$env_name'"
        return 1
    fi
}

# Utility function to set up a project directory prompt indicator
# Add this to your prompt if you want to show the active environment
zenv_prompt() {
    if [[ -n "$ZENV_ACTIVE_ENV" ]]; then
        echo "[zenv:$ZENV_ACTIVE_ENV]"
    fi
}

# Example prompt integration for bash:
# PS1='$(zenv_prompt) \u@\h:\w\$ '

# Example prompt integration for zsh:
# setopt PROMPT_SUBST
# PROMPT='$(zenv_prompt) %n@%m:%~%# '
