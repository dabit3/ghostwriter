#!/usr/bin/env zsh
#
# Plugin-side context handling: which commands are remembered, which ones the
# AI is allowed to see, and which directories are excluded entirely.

emulate -L zsh
setopt err_exit no_unset pipe_fail

local repo_root="${0:A:h:h}"
local tmp
local output
local expected
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ghostwriter-context.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

mkdir "$tmp/repoA" "$tmp/repoB"
: > "$tmp/tty"

# The tab is pinned up front so no worker is ever spawned: this exercises the
# bookkeeping in preexec/_gw_collect on its own, with no async timing.
output=$(ROOT="$tmp" PLUGIN="$repo_root/ghostwriter.plugin.zsh" \
    XDG_CACHE_HOME="$tmp/cache" TERM_PROGRAM=ghostty \
    GHOSTWRITER_BACKEND=openai GHOSTWRITER_API_KEY=test-key \
    GHOSTWRITER_CURL=true zsh -dfi -c '
        TTY="$ROOT/tty"
        builtin cd "$ROOT/repoA"
        source "$PLUGIN"
        tabname "Pinned"

        _gw_ctx="$ROOT/repoA"
        _gw_preexec "npm test"
        _gw_preexec "npm test"        # consecutive repeat: ignored
        _gw_preexec "ls -la"          # noise: ignored
        _gw_preexec "cd ../repoB"     # navigation: ignored
        _gw_preexec "git push"
        _gw_ctx="$ROOT/repoB"
        _gw_preexec "cargo build"

        print -r -- "remembered=${#_gw_recent}"
        print -r -- "counted=$_gw_cmds_since"
        _gw_collect
        print -r -- "inB=${(j:|:)_gw_ctx_cmds}"
        _gw_ctx="$ROOT/repoA"
        _gw_collect
        print -r -- "inA=${(j:|:)_gw_ctx_cmds}"

        # A command containing a literal tab must not corrupt the
        # context<TAB>command encoding used by the rolling window.
        local tab="$(printf "\t")"
        _gw_preexec "grep -P \"a${tab}b\" file"
        _gw_collect
        print -r -- "tabs=${_gw_ctx_cmds[-1]}"

        GHOSTWRITER_IGNORE="~/private/*:/opt/secret//:/srv/clients/"
        _gw_ctx="$HOME/private/clientwork";  _gw_ignored && print -r -- "tilde=yes"   || print -r -- "tilde=no"
        _gw_ctx="/opt/secret";               _gw_ignored && print -r -- "slashes=yes" || print -r -- "slashes=no"
        _gw_ctx="/srv/clients/acme/api";     _gw_ignored && print -r -- "subtree=yes" || print -r -- "subtree=no"
        _gw_ctx="/srv/clients-public";       _gw_ignored && print -r -- "prefix=yes"  || print -r -- "prefix=no"
        _gw_ctx="$ROOT/repoA";               _gw_ignored && print -r -- "other=yes"   || print -r -- "other=no"
    ')

expected=$'remembered=3\ncounted=3\ninB=cargo build\ninA=npm test|git push\ntabs=grep -P "a b" file\ntilde=yes\nslashes=yes\nsubtree=yes\nprefix=no\nother=no'

if [[ "$output" != "$expected" ]]; then
    print -u2 -r -- "context regression"
    print -u2 -r -- "expected:"
    print -u2 -r -- "$expected"
    print -u2 -r -- "actual:"
    print -u2 -r -- "$output"
    exit 1
fi

# An ignored directory must never reach the worker: no context snapshot, and
# therefore no API call, even when a rename is explicitly forced.
output=$(ROOT="$tmp" PLUGIN="$repo_root/ghostwriter.plugin.zsh" \
    XDG_CACHE_HOME="$tmp/cache2" TERM_PROGRAM=ghostty \
    GHOSTWRITER_BACKEND=openai GHOSTWRITER_API_KEY=test-key \
    GHOSTWRITER_IGNORE="$tmp/repoB" GHOSTWRITER_CURL=true zsh -dfi -c '
        TTY="$ROOT/tty"
        builtin cd "$ROOT/repoB"
        source "$PLUGIN"
        _gw_preexec "npm test"
        tabname --now
        local -a snapshots=("$_gw_session_dir"/context.*(N))
        print -r -- "snapshots=${#snapshots}"
        tabname | sed -n 2p
    ')
[[ "$output" == "snapshots=0"*"GHOSTWRITER_IGNORE"* ]] || {
    print -u2 -r -- "ignored directory still produced worker input: $output"
    exit 1
}
