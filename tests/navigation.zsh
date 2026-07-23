#!/usr/bin/env zsh

emulate -L zsh
setopt err_exit no_unset pipe_fail

local repo_root="${0:A:h:h}"
local tmp
local output
local expected
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ghostwriter-navigation.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

mkdir "$tmp/alpha" "$tmp/beta"
: > "$tmp/tty"

output=$(ROOT="$tmp" PLUGIN="$repo_root/ghostty-ai-tabs.plugin.zsh" \
    XDG_CACHE_HOME="$tmp/cache" TERM_PROGRAM=ghostty \
    GHOSTTY_AI_TABS_BACKEND=openai GHOSTTY_AI_TABS_API_KEY=test-key \
    GHOSTTY_AI_TABS_CURL=true zsh -dfi -c '
        TTY="$ROOT/tty"
        builtin cd "$ROOT/alpha"
        source "$PLUGIN"
        print -r -- "initial=$(<$_gat_session_dir/title):$_gat_gen"
        builtin cd "$ROOT/beta"
        print -r -- "forward=$(<$_gat_session_dir/title):$_gat_gen"
        builtin cd "$ROOT/alpha"
        print -r -- "return=$(<$_gat_session_dir/title):$_gat_gen"
        tabname "Pinned Work"
        [[ -e "$_gat_session_dir/pin" ]] && pin_state=yes || pin_state=no
        print -r -- "pinned=$(<$_gat_session_dir/title):$_gat_gen:$pin_state"
    ')
expected=$'initial=alpha:0\nforward=beta:1\nreturn=alpha:2\npinned=Pinned Work:3:yes'

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
: > "$GHOSTWRITER_TEST_MARKER"' > "$fake_curl"
chmod +x "$fake_curl"

GHOSTWRITER_TEST_MARKER="$marker" XDG_CACHE_HOME="$tmp/race/cache" \
    GHOSTTY_AI_TABS_BACKEND=openai GHOSTTY_AI_TABS_API_KEY=test-key \
    GHOSTTY_AI_TABS_CURL="$fake_curl" \
    "$repo_root/bin/ghostty-ai-tabs-namer" \
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
