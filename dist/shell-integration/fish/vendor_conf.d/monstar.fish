# Monstar fish shell integration. Loaded automatically because Monstar
# prepends the integration directory to XDG_DATA_DIRS (see ShellIntegration.zig)
# and fish sources <XDG_DATA_DIRS>/fish/vendor_conf.d/*.fish on startup.

# Drop our directory from XDG_DATA_DIRS so child processes do not inherit it.
if set -q MONSTAR_SHELL_INTEGRATION_XDG_DIR
    set --local dirs (string split : -- "$XDG_DATA_DIRS")
    set --local idx (contains --index -- "$MONSTAR_SHELL_INTEGRATION_XDG_DIR" $dirs)
    if test -n "$idx"
        set --erase dirs[$idx]
        if test (count $dirs) -gt 0
            set --global --export XDG_DATA_DIRS (string join : -- $dirs)
        else
            set --erase XDG_DATA_DIRS
        end
    end
    set --erase MONSTAR_SHELL_INTEGRATION_XDG_DIR
end

status --is-interactive; or return 0

function __monstar_title_pwd --on-event fish_prompt
    printf '\e]7;file://%s%s\a\e]2;%s\a' $hostname $PWD (prompt_pwd --dir-length=0)
end

function __monstar_title_cmd --on-event fish_preexec
    printf '\e]2;%s\a' $argv
end
