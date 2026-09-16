# Sourced by zsh because Monstar set ZDOTDIR to this directory. Restores the
# user's ZDOTDIR, sources their .zshenv, then loads our integration for
# interactive shells.

if [[ -n "${MONSTAR_ZDOTDIR+x}" ]]; then
    builtin export ZDOTDIR="$MONSTAR_ZDOTDIR"
    builtin unset MONSTAR_ZDOTDIR
else
    builtin unset ZDOTDIR
fi

{
    builtin typeset _monstar_file=${ZDOTDIR-$HOME}/.zshenv
    [[ -r "$_monstar_file" ]] && builtin source -- "$_monstar_file"
} always {
    if [[ -o interactive ]]; then
        builtin typeset _monstar_file=${${(%):-%x}:A:h}/monstar-integration
        if [[ -r "$_monstar_file" ]]; then
            builtin autoload -Uz -- "$_monstar_file"
            "${_monstar_file:t}"
            builtin unfunction -- "${_monstar_file:t}"
        fi
    fi
    builtin unset _monstar_file
}
