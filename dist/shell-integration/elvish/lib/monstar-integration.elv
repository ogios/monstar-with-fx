# Monstar shell integration for elvish. Elvish cannot be integrated
# automatically, so load it from rc.elv:
#
#     use monstar-integration
{
    use platform
    use str

    if (and (has-env MONSTAR_SHELL_INTEGRATION_XDG_DIR) (has-env XDG_DATA_DIRS)) {
        set-env XDG_DATA_DIRS (str:replace $E:MONSTAR_SHELL_INTEGRATION_XDG_DIR":" "" $E:XDG_DATA_DIRS)
        unset-env MONSTAR_SHELL_INTEGRATION_XDG_DIR
    }

    fn report-pwd {
        var title = $pwd
        if (not-eq $E:HOME "") {
            set title = (str:replace $E:HOME "~" $pwd)
        }
        printf "\e]7;file://%s%s\a\e]2;%s\a" (platform:hostname) $pwd $title
    }

    fn report-cmd {|_|
        if (not-eq $edit:current-command "") {
            printf "\e]2;%s\a" $edit:current-command
        }
    }

    set edit:before-readline = (conj $edit:before-readline $report-pwd~)
    set edit:after-readline = (conj $edit:after-readline $report-cmd~)
    set after-chdir = (conj $after-chdir {|_| report-pwd })
    report-pwd
}
