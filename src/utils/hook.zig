//! Shell hooks for `zenv hook <shell>`: activate a project's environment on
//! `cd` into it and deactivate it on the way out, like direnv but with no
//! background process. The hook finds the project root in the shell itself (a
//! few file tests, no fork) and calls `zenv activate --auto` only when the root
//! changes, so moving around inside a project costs nothing.

const std = @import("std");

/// Returns the hook code for `shell`, or null if there is none for it.
pub fn forShell(shell: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, shell, "zsh")) return zsh;
    return null;
}

// _zenv_hook_root is the project the hook last saw ("" for none) and
// _zenv_hook_env the ZENV_ENV_DIR it activated there. Neither is exported, so a
// nested shell starts fresh. The hook deactivates only an env it activated
// itself and that is still active: a manual `deactivate` or `zenv activate`
// inside a project is left alone until you enter another project.
const zsh =
    \\# zenv hook for zsh: activates a project's environment when you cd into
    \\# it and deactivates it when you leave. Load it from ~/.zshrc with:
    \\#   eval "$(zenv hook zsh)"
    \\_zenv_hook() {
    \\    # The project is the nearest directory at or above $PWD with a zenv.json.
    \\    local _zenv_dir=$PWD _zenv_root= _zenv_script=
    \\    while true; do
    \\        if [[ -f $_zenv_dir/zenv.json ]]; then
    \\            _zenv_root=$_zenv_dir
    \\            break
    \\        fi
    \\        [[ $_zenv_dir == / ]] && break
    \\        _zenv_dir=${_zenv_dir:h}
    \\    done
    \\    [[ $_zenv_root == "${_zenv_hook_root-}" ]] && return
    \\    if [[ -n ${_zenv_hook_env-} && ${ZENV_ENV_DIR-} == "$_zenv_hook_env" ]] && (( $+functions[deactivate] )); then
    \\        deactivate
    \\    fi
    \\    typeset -g _zenv_hook_root=$_zenv_root _zenv_hook_env=
    \\    [[ -n $_zenv_root ]] || return
    \\    _zenv_script=$(command zenv activate --auto "$_zenv_root") || return
    \\    [[ -n $_zenv_script ]] || return
    \\    source "$_zenv_script"
    \\    _zenv_hook_env=${ZENV_ENV_DIR-}
    \\}
    \\typeset -ga chpwd_functions
    \\if (( ! ${chpwd_functions[(Ie)_zenv_hook]} )); then
    \\    chpwd_functions+=(_zenv_hook)
    \\fi
    \\_zenv_hook
    \\
;

test "forShell knows zsh only" {
    try std.testing.expect(forShell("zsh") != null);
    try std.testing.expect(forShell("bash") == null);
    try std.testing.expect(std.mem.indexOf(u8, forShell("zsh").?, "zenv activate --auto") != null);
}
