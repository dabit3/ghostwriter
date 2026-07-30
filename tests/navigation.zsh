#!/usr/bin/env zsh

emulate -L zsh
setopt err_exit no_unset pipe_fail

local repo_root="${0:A:h:h}"
local tmp
local output
local expected
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ghostwriter-navigation.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

mkdir "$tmp/alpha" "$tmp/beta" "$tmp/two-word-dir"
: > "$tmp/tty"

output=$(ROOT="$tmp" PLUGIN="$repo_root/ghostwriter.plugin.zsh" \
    XDG_CACHE_HOME="$tmp/cache" TERM_PROGRAM=ghostty \
    GHOSTWRITER_BACKEND=openai GHOSTWRITER_API_KEY=test-key \
    GHOSTWRITER_CURL=true zsh -dfi -c '
        TTY="$ROOT/tty"
        builtin cd "$ROOT/alpha"
        source "$PLUGIN"
        print -r -- "initial=$(<$_gw_session_dir/title):$_gw_gen"
        builtin cd "$ROOT/beta"
        print -r -- "forward=$(<$_gw_session_dir/title):$_gw_gen"
        builtin cd "$ROOT/alpha"
        print -r -- "return=$(<$_gw_session_dir/title):$_gw_gen"
        builtin cd "$ROOT/two-word-dir"
        print -r -- "split=$(<$_gw_session_dir/title):$_gw_gen"
        # A cd the interactive shell is not really making: zsh completion runs
        # one in a subshell to expand "../<TAB>". The tab must not follow it.
        ( builtin cd "$ROOT/alpha" )
        print -r -- "subshell=$(<$_gw_session_dir/title):$(<$_gw_session_dir/applied_gen)"
        typeset -gA compstate=()
        builtin cd "$ROOT/alpha"
        print -r -- "completing=$(<$_gw_session_dir/title):$(<$_gw_session_dir/applied_gen)"
        unset compstate
        builtin cd "$ROOT/two-word-dir"
        print -r -- "restored=$(<$_gw_session_dir/title):$_gw_gen"
        tabname "Pinned Work"
        [[ -e "$_gw_session_dir/pin" ]] && pin_state=yes || pin_state=no
        print -r -- "pinned=$(<$_gw_session_dir/title):$_gw_gen:$pin_state"
    ')
expected=$'initial=alpha:0\nforward=beta:1\nreturn=alpha:2\nsplit=Two word dir:3'
expected+=$'\nsubshell=Two word dir:3\ncompleting=Two word dir:3\nrestored=Two word dir:3'
expected+=$'\npinned=Pinned Work:4:yes'

if [[ "$output" != "$expected" ]]; then
    print -u2 -r -- "navigation regression"
    print -u2 -r -- "expected:"
    print -u2 -r -- "$expected"
    print -u2 -r -- "actual:"
    print -u2 -r -- "$output"
    exit 1
fi

local session="$tmp/race/session"
local fake_curl="$tmp/race/fake-curl"
local marker="$tmp/race/curl-finished"
local worker_pid
local barrier_pid
local reader_pid
local -a pending
mkdir -p "$session" "$tmp/race/cache"
mkfifo "$session/tty"
: > "$session/apply.lock"
print -r -- 1 > "$session/applied_gen"
print -rl -- "cwd	$tmp/alpha" "cmd	git status" > "$session/context.1"
print -r -- '#!/bin/sh
printf "%s" "{\"choices\":[{\"message\":{\"content\":\"Alpha Work\"}}]}"
: > "$GW_TEST_MARKER"' > "$fake_curl"
chmod +x "$fake_curl"

GW_TEST_MARKER="$marker" XDG_CACHE_HOME="$tmp/race/cache" \
    GHOSTWRITER_BACKEND=openai GHOSTWRITER_API_KEY=test-key \
    GHOSTWRITER_CURL="$fake_curl" \
    "$repo_root/bin/ghostwriter-namer" \
    --session-dir "$session" --tty "$session/tty" --gen 1 &
worker_pid=$!

repeat 500; do
    [[ -e "$marker" ]] && break
    sleep 0.01
done
[[ -e "$marker" ]] || { print -u2 "worker did not reach title application"; exit 1 }
repeat 500; do
    pending=("$session"/out.*(N))
    (( ${#pending} == 0 )) && break
    sleep 0.01
done
(( ${#pending} == 0 )) || { print -u2 "worker output was not consumed"; exit 1 }
sleep 0.05

zsh -fc '
    zmodload zsh/system
    local session="$1" lock_fd
    zsystem flock -f lock_fd "$session/apply.lock"
    print -r -- 2 >| "$session/applied_gen"
    zsystem flock -u $lock_fd
    print -r -- beta >| "$session/title"
' _ "$session" &
barrier_pid=$!
sleep 0.05
command cat "$session/tty" >/dev/null &
reader_pid=$!
wait $worker_pid
wait $barrier_pid
wait $reader_pid

if [[ ! -r "$session/title" || "$(<$session/title)" != beta ]]; then
    print -u2 -r -- "stale worker overwrote a newer folder title"
    exit 1
fi
