# Monstar bash shell integration.
#
# Loaded automatically through $ENV when Monstar starts bash in POSIX mode
# (see ShellIntegration.zig), or sourced manually from a user's bashrc:
#
#     if [ -n "${MONSTAR_RESOURCES_DIR}" ]; then
#         builtin source "${MONSTAR_RESOURCES_DIR}/shell-integration/bash/monstar.bash"
#     fi
#
# It restores the normal startup sequence, then installs hooks that report the
# working directory (OSC 7) and window title (OSC 2) as events: the directory
# while sitting at a prompt, the command line while one runs.

# Only interactive shells get a prompt or title.
if [[ "$-" != *i* ]]; then builtin return 0; fi

# Automatic injection: bash was started in POSIX mode so it would source this
# file instead of its normal startup files. Recreate that startup sequence.
if [[ -n "$MONSTAR_BASH_INJECT" ]]; then
    __monstar_flags="$MONSTAR_BASH_INJECT"
    builtin unset ENV MONSTAR_BASH_INJECT

    if [[ -n "$MONSTAR_BASH_ENV" ]]; then
        builtin export ENV="$MONSTAR_BASH_ENV"
        builtin unset MONSTAR_BASH_ENV
    fi

    builtin set +o posix
    builtin shopt -u inherit_errexit 2>/dev/null

    if [[ -n "$MONSTAR_BASH_UNEXPORT_HISTFILE" ]]; then
        builtin export -n HISTFILE
        builtin unset MONSTAR_BASH_UNEXPORT_HISTFILE
    fi

    if builtin shopt -q login_shell; then
        if [[ "$__monstar_flags" != *"--noprofile"* ]]; then
            [ -r /etc/profile ] && builtin source /etc/profile
            for __monstar_rc in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
                [ -r "$__monstar_rc" ] && { builtin source "$__monstar_rc"; break; }
            done
        fi
    else
        if [[ "$__monstar_flags" != *"--norc"* ]]; then
            for __monstar_rc in /etc/bash.bashrc /etc/bash/bashrc /etc/bashrc; do
                [ -r "$__monstar_rc" ] && { builtin source "$__monstar_rc"; break; }
            done
            if [[ -z "$MONSTAR_BASH_RCFILE" ]]; then MONSTAR_BASH_RCFILE="$HOME/.bashrc"; fi
            [ -r "$MONSTAR_BASH_RCFILE" ] && builtin source "$MONSTAR_BASH_RCFILE"
        fi
    fi

    builtin unset __monstar_rc __monstar_flags MONSTAR_BASH_RCFILE
fi

# Report cwd (OSC 7) and the abbreviated path as the title (OSC 2).
__monstar_title_pwd() {
    local __monstar_title=${PWD/#$HOME/\~}
    printf '\e]7;file://%s%s\a\e]2;%s\a' "$HOSTNAME" "$PWD" "$__monstar_title"
}

# Report the command line about to run as the title. bash has no preexec hook,
# so this is invoked from PS0 and recovers the command from history.
__monstar_title_cmd() {
    local __monstar_cmd
    __monstar_cmd=$(LC_ALL=C HISTTIMEFORMAT='' builtin history 1)
    __monstar_cmd="${__monstar_cmd#*[[:digit:]][* ] }"
    [[ -n "$__monstar_cmd" ]] && printf '\e]2;%s\a' "${__monstar_cmd//[[:cntrl:]]/}"
}

__monstar_hook() {
    __monstar_title_pwd
    [[ "$PS0" == *"__monstar_title_cmd"* ]] || PS0+='$(__monstar_title_cmd)'
}

# Append the hook to PROMPT_COMMAND, preserving its existing type.
case "$(builtin declare -p PROMPT_COMMAND 2>/dev/null)" in
    "declare -a "*)
        [[ " ${PROMPT_COMMAND[*]} " == *" __monstar_hook "* ]] || PROMPT_COMMAND+=(__monstar_hook)
        ;;
    "declare -- "*)
        [[ "$PROMPT_COMMAND" == *"__monstar_hook"* ]] || PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }__monstar_hook"
        ;;
    *)
        PROMPT_COMMAND="__monstar_hook"
        ;;
esac
