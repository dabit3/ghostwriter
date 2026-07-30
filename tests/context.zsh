#!/usr/bin/env zsh
#
# Plugin-side context handling: which commands are remembered, which ones the
# AI is allowed to see, when a rename is even worth spawning, and which
# directories are excluded entirely.

emulate -L zsh
setopt err_exit no_unset pipe_fail

local repo_root="${0:A:h:h}"
local tmp
local output
local expected
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ghostwriter-context.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

mkdir "$tmp/repoA" "$tmp/repoB" "$tmp/src" "$tmp/temp"
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
        _gw_preexec "../repoB"        # auto_cd navigation: ignored
        _gw_preexec "~"               # auto_cd to home: ignored
        _gw_preexec "git push"
        _gw_ctx="$ROOT/repoB"
        _gw_preexec "cargo build"

        print -r -- "counted=$_gw_cmds_since"
        _gw_collect
        print -r -- "inB=${(j:|:)_gw_ctx_cmds}"
        _gw_ctx="$ROOT/repoA"
        _gw_collect
        print -r -- "inA=${(j:|:)_gw_ctx_cmds}"

        # Working elsewhere must not evict a context s history: coming back
        # to repoA later, its commands are still there for the AI.
        _gw_ctx="$ROOT/repoB"
        local i
        for i in {1..15}; do _gw_preexec "cargo cmd$i"; done
        _gw_ctx="$ROOT/repoA"
        _gw_collect
        print -r -- "backInA=${(j:|:)_gw_ctx_cmds}"

        # A command containing a literal tab must survive recording.
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

        # An ignored subdirectory of a larger repo: ctx is the repo root and
        # matches nothing, but $PWD is inside the ignored tree.
        builtin cd "$ROOT/repoB"
        GHOSTWRITER_IGNORE="$ROOT/repoB"
        _gw_ctx="$ROOT"
        _gw_ignored && print -r -- "pwdsub=yes" || print -r -- "pwdsub=no"
    ')

expected=$'counted=3\ninB=cargo build\ninA=npm test|git push\nbackInA=npm test|git push\ntabs=grep -P "a b" file\ntilde=yes\nslashes=yes\nsubtree=yes\nprefix=no\nother=no\npwdsub=yes'

if [[ "$output" != "$expected" ]]; then
    print -u2 -r -- "context regression"
    print -u2 -r -- "expected:"
    print -u2 -r -- "$expected"
    print -u2 -r -- "actual:"
    print -u2 -r -- "$output"
    exit 1
fi

# ---------------------------------------------------------------------------
# Spawn discipline. _gw_gen only moves when a barrier is raised (cd, pin) or
# a worker is spawned, so it exposes exactly when the AI would be consulted:
#   - a context with a meaningful folder name is titled locally, never AI,
#   - a no-signal name (src, tmp, ...) falls through to the AI fallback,
#   - but only once a real command has run there,
#   - and with the AI unavailable, even those are titled locally.
# ---------------------------------------------------------------------------
output=$(ROOT="$tmp" PLUGIN="$repo_root/ghostwriter.plugin.zsh" \
    XDG_CACHE_HOME="$tmp/cache2" TERM_PROGRAM=ghostty \
    GHOSTWRITER_BACKEND=openai GHOSTWRITER_API_KEY=test-key \
    GHOSTWRITER_CURL=true zsh -dfi -c '
        TTY="$ROOT/tty"
        builtin cd "$ROOT/repoA"
        source "$PLUGIN"
        _gw_precmd                       # meaningful name: local, no spawn
        print -r -- "freshtab=$_gw_gen:$(<$_gw_session_dir/title)"
        local i
        for i in {1..10}; do _gw_preexec "make step$i"; done
        _gw_last_time=0                  # neutralize the interval guard
        _gw_precmd                       # threshold reached: still no AI
        print -r -- "threshold=$_gw_gen"

        local before=$_gw_gen
        builtin cd "$ROOT/src"           # chpwd raises the barrier (+1) ...
        _gw_precmd; _gw_precmd; _gw_precmd
        print -r -- "quietSrc=$(( _gw_gen - before ))"   # ... but no spawns

        _gw_last_time=0                  # neutralize the 10s switch guard
        before=$_gw_gen
        _gw_preexec "python train.py"    # no-signal dir with activity: spawns
        print -r -- "aiSrc=$(( _gw_gen - before ))"

        _gw_ai=0                         # no backend available
        builtin cd "$ROOT/temp"
        _gw_last_time=0
        before=$_gw_gen
        _gw_preexec "cargo build"        # AI off: named locally instead
        print -r -- "noai=$(( _gw_gen - before )):$(<$_gw_session_dir/title)"
    ')

expected=$'freshtab=0:repoa\nthreshold=0\nquietSrc=1\naiSrc=1\nnoai=0:temp'
if [[ "$output" != "$expected" ]]; then
    print -u2 -r -- "spawn-discipline regression"
    print -u2 -r -- "expected:"
    print -u2 -r -- "$expected"
    print -u2 -r -- "actual:"
    print -u2 -r -- "$output"
    exit 1
fi

# ---------------------------------------------------------------------------
# An ignored directory must never reach the worker: no context snapshot, and
# therefore no API call, even when a rename is explicitly forced.
# ---------------------------------------------------------------------------
output=$(ROOT="$tmp" PLUGIN="$repo_root/ghostwriter.plugin.zsh" \
    XDG_CACHE_HOME="$tmp/cache3" TERM_PROGRAM=ghostty \
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
