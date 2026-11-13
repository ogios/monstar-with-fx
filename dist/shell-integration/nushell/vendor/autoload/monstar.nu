# Monstar shell integration for nushell.
#
# Nushell sets the window title natively, so this only drops the temporary
# XDG_DATA_DIRS entry Monstar prepended to make this module discoverable.
if 'MONSTAR_SHELL_INTEGRATION_XDG_DIR' in $env {
    if 'XDG_DATA_DIRS' in $env {
        $env.XDG_DATA_DIRS = ($env.XDG_DATA_DIRS | str replace $"($env.MONSTAR_SHELL_INTEGRATION_XDG_DIR):" "")
    }
    hide-env MONSTAR_SHELL_INTEGRATION_XDG_DIR
}
