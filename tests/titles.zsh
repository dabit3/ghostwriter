#!/usr/bin/env zsh
#
# Worker-side handling of what leaves the machine (redaction) and of what the
# model sends back (sanitizing, truncation, no-signal tabs).

emulate -L zsh
setopt err_exit no_unset pipe_fail

local repo_root="${0:A:h:h}"
local worker="$repo_root/bin/ghostwriter-namer"
local tmp
local fake_curl
local sent_prompt
local session
local secret_token='tok-abc-secret-value'
local long_token='AKIA0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ012'
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ghostwriter-titles.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fake_curl="$tmp/fake-curl"

print -r -- '#!/bin/sh
while [ "$#" -gt 0 ]; do
    case "$1" in
        --data-binary) case "$2" in @*) cat "${2#@}" > "$GW_TEST_BODY" ;; esac; shift 2 ;;
        *) shift ;;
    esac
done
printf "%s" "$GW_TEST_RESPONSE"' > "$fake_curl"
chmod +x "$fake_curl"

# Runs the worker over a set of recorded commands and echoes back whatever
# title it decided on. $1 = case name, $2 = canned API response, rest = cmds.
_run() {
    local name="$1" response="$2"
    shift 2
    session="$tmp/$name/session"
    mkdir -p "$session" "$tmp/$name/cache" "$tmp/$name/work"
    : > "$session/tty"
    : > "$session/apply.lock"
    {
        print -r -- "cwd	$tmp/$name/work"
        local c
        for c in "$@"; do print -r -- "cmd	$c"; done
    } > "$session/context.1"

    GW_TEST_BODY="$tmp/$name/body" GW_TEST_RESPONSE="$response" \
        XDG_CACHE_HOME="$tmp/$name/cache" \
        GHOSTWRITER_BACKEND=openai GHOSTWRITER_API_KEY=test-key \
        GHOSTWRITER_MODEL="" GHOSTWRITER_BASE_URL="" GHOSTWRITER_REASONING="" \
        GHOSTWRITER_MAX_LEN="${GHOSTWRITER_MAX_LEN:-32}" \
        GHOSTWRITER_CURL="$fake_curl" \
        "$worker" --session-dir "$session" --tty "$session/tty" --gen 1
    [[ -r "$session/title" ]] && print -r -- "$(<$session/title)" || print -r -- "(none)"
}

# ---------------------------------------------------------------------------
# Secrets must be scrubbed out of the prompt
# ---------------------------------------------------------------------------
_run redaction '{"choices":[{"message":{"content":"Redaction Case"}}]}' \
    "export API_KEY=sk-supersecret123" \
    "curl -H \"Authorization: Bearer $secret_token\" https://api.example.com" \
    "psql \"password: hunter2\"" \
    "aws configure set x $long_token" >/dev/null

sent_prompt=$(perl -MJSON::PP -0777 -e \
    'my $d = decode_json(<STDIN>); print $d->{messages}[0]{content};' < "$tmp/redaction/body")

local leaked=""
if [[ "$sent_prompt" == *"sk-supersecret123"* ]]; then leaked+=" api-key"; fi
if [[ "$sent_prompt" == *"$secret_token"*    ]]; then leaked+=" bearer-token"; fi
if [[ "$sent_prompt" == *"hunter2"*          ]]; then leaked+=" password"; fi
if [[ "$sent_prompt" == *"$long_token"*      ]]; then leaked+=" long-token"; fi
[[ -z "$leaked" ]] || {
    print -u2 -r -- "secrets reached the prompt:$leaked"
    print -u2 -r -- "$sent_prompt"
    exit 1
}
[[ "$sent_prompt" == *"[REDACTED]"* ]] || {
    print -u2 -r -- "redaction produced no markers; commands may have been dropped entirely"
    exit 1
}
# Redaction must not swallow the surrounding command, or the AI loses context.
[[ "$sent_prompt" == *"aws configure set"* && "$sent_prompt" == *"curl -H"* ]] || {
    print -u2 -r -- "redaction destroyed too much of the command line"
    print -u2 -r -- "$sent_prompt"
    exit 1
}

# ---------------------------------------------------------------------------
# Model output is never trusted verbatim
# ---------------------------------------------------------------------------
local got
got=$(_run messy '{"choices":[{"message":{"content":"\n  \"My  Quoted  Title\"  \nsecond line"}}]}' "vim main.go")
[[ "$got" == "My Quoted Title" ]] || {
    print -u2 -r -- "sanitizer produced '$got' (expected 'My Quoted Title')"
    exit 1
}

got=$(GHOSTWRITER_MAX_LEN=12 _run toolong \
    '{"choices":[{"message":{"content":"Extremely Long Project Title"}}]}' "vim main.go")
[[ "$got" == "Extremely" ]] || {
    print -u2 -r -- "truncation produced '$got' (expected 'Extremely')"
    exit 1
}

# ---------------------------------------------------------------------------
# A brand-new tab at $HOME has nothing to describe: no call, no invention
# ---------------------------------------------------------------------------
local home="$tmp/fakehome"
session="$tmp/nosignal/session"
mkdir -p "$session" "$tmp/nosignal/cache" "$home"
: > "$session/tty"
: > "$session/apply.lock"
print -r -- "cwd	$home" > "$session/context.1"

HOME="$home" GW_TEST_BODY="$tmp/nosignal/body" GW_TEST_RESPONSE='{}' \
    XDG_CACHE_HOME="$tmp/nosignal/cache" \
    GHOSTWRITER_BACKEND=openai GHOSTWRITER_API_KEY=test-key \
    GHOSTWRITER_MODEL="" GHOSTWRITER_BASE_URL="" GHOSTWRITER_REASONING="" \
    GHOSTWRITER_CURL="$fake_curl" \
    "$worker" --session-dir "$session" --tty "$session/tty" --gen 1

[[ "$(<$session/title)" == "fakehome" ]] || {
    print -u2 -r -- "empty home tab was titled '$(<$session/title)' instead of 'fakehome'"
    exit 1
}
if [[ -e "$tmp/nosignal/body" ]]; then
    print -u2 -r -- "empty home tab still made an API call"
    exit 1
fi

# The same must hold for any non-repo directory nothing has run in (e.g. a
# parent folder being passed through): basename, no API call, no invented
# "X Project Root" style names.
session="$tmp/transit/session"
mkdir -p "$session" "$tmp/transit/cache" "$tmp/transit/open-source_dir"
: > "$session/tty"
: > "$session/apply.lock"
print -r -- "cwd	$tmp/transit/open-source_dir" > "$session/context.1"

GW_TEST_BODY="$tmp/transit/body" GW_TEST_RESPONSE='{}' \
    XDG_CACHE_HOME="$tmp/transit/cache" \
    GHOSTWRITER_BACKEND=openai GHOSTWRITER_API_KEY=test-key \
    GHOSTWRITER_MODEL="" GHOSTWRITER_BASE_URL="" GHOSTWRITER_REASONING="" \
    GHOSTWRITER_CURL="$fake_curl" \
    "$worker" --session-dir "$session" --tty "$session/tty" --gen 1 --fresh

# Separators in the folder name become word breaks, so the fallback reads
# like a name rather than a path fragment. Only the first word is capitalized.
[[ "$(<$session/title)" == "Open source dir" ]] || {
    print -u2 -r -- "command-less transit dir was titled '$(<$session/title)' instead of 'Open source dir'"
    exit 1
}
if [[ -e "$tmp/transit/body" ]]; then
    print -u2 -r -- "command-less transit dir still made an API call"
    exit 1
fi

# ---------------------------------------------------------------------------
# Branch context: a default branch is assumed, a feature branch is signal
# ---------------------------------------------------------------------------
# Runs the worker inside a git repo checked out on $2 and echoes the prompt
# that was sent. $1 = case name.
_prompt_on_branch() {
    local name="$1" branch="$2" proj="$tmp/$1/proj"
    session="$tmp/$name/session"
    mkdir -p "$session" "$tmp/$name/cache" "$proj"
    git -C "$proj" init -q
    git -C "$proj" -c user.email=t@example.com -c user.name=t \
        commit -q --allow-empty -m init
    if [[ -n "$branch" ]]; then git -C "$proj" checkout -q -b "$branch"; fi
    : > "$session/tty"
    : > "$session/apply.lock"
    print -rl -- "cwd	$proj" "cmd	npm test" > "$session/context.1"

    GW_TEST_BODY="$tmp/$name/body" \
        GW_TEST_RESPONSE='{"choices":[{"message":{"content":"Proj"}}]}' \
        XDG_CACHE_HOME="$tmp/$name/cache" \
        GHOSTWRITER_BACKEND=openai GHOSTWRITER_API_KEY=test-key \
        GHOSTWRITER_MODEL="" GHOSTWRITER_BASE_URL="" GHOSTWRITER_REASONING="" \
        GHOSTWRITER_CURL="$fake_curl" \
        "$worker" --session-dir "$session" --tty "$session/tty" --gen 1
    perl -MJSON::PP -0777 -e \
        'my $d = decode_json(<STDIN>); print $d->{messages}[0]{content};' \
        < "$tmp/$name/body"
}

sent_prompt=$(_prompt_on_branch defaultbranch "")
[[ "$sent_prompt" != *"branch:"* ]] || {
    print -u2 -r -- "the default branch was sent as context:"
    print -u2 -r -- "$sent_prompt"
    exit 1
}

sent_prompt=$(_prompt_on_branch featurebranch "feature/login")
[[ "$sent_prompt" == *"branch: feature/login"* ]] || {
    print -u2 -r -- "a feature branch was dropped from the context:"
    print -u2 -r -- "$sent_prompt"
    exit 1
}

# ---------------------------------------------------------------------------
# The cross-tab name cache is for repos only
# ---------------------------------------------------------------------------
# A fresh rename inside a git repo populates the cache...
session="$tmp/repocache/session"
mkdir -p "$session" "$tmp/repocache/cache" "$tmp/repocache/proj"
git -C "$tmp/repocache/proj" init -q
: > "$session/tty"
: > "$session/apply.lock"
print -rl -- "cwd	$tmp/repocache/proj" "cmd	npm test" > "$session/context.1"

GW_TEST_BODY="$tmp/repocache/body" \
    GW_TEST_RESPONSE='{"choices":[{"message":{"content":"Proj Testing"}}]}' \
    XDG_CACHE_HOME="$tmp/repocache/cache" \
    GHOSTWRITER_BACKEND=openai GHOSTWRITER_API_KEY=test-key \
    GHOSTWRITER_MODEL="" GHOSTWRITER_BASE_URL="" GHOSTWRITER_REASONING="" \
    GHOSTWRITER_CURL="$fake_curl" \
    "$worker" --session-dir "$session" --tty "$session/tty" --gen 1 --fresh

grep -rq "Proj Testing" "$tmp/repocache/cache/ghostwriter/repo-cache" 2>/dev/null || {
    print -u2 -r -- "fresh repo rename did not populate the repo cache"
    exit 1
}

# ...but a fresh rename in a plain directory must not: transient directories
# polluting the cache is how stale names ended up slapped onto later tabs.
session="$tmp/dircache/session"
mkdir -p "$session" "$tmp/dircache/cache" "$tmp/dircache/plaindir"
: > "$session/tty"
: > "$session/apply.lock"
print -rl -- "cwd	$tmp/dircache/plaindir" "cmd	vim notes.md" > "$session/context.1"

GW_TEST_BODY="$tmp/dircache/body" \
    GW_TEST_RESPONSE='{"choices":[{"message":{"content":"Plain Notes"}}]}' \
    XDG_CACHE_HOME="$tmp/dircache/cache" \
    GHOSTWRITER_BACKEND=openai GHOSTWRITER_API_KEY=test-key \
    GHOSTWRITER_MODEL="" GHOSTWRITER_BASE_URL="" GHOSTWRITER_REASONING="" \
    GHOSTWRITER_CURL="$fake_curl" \
    "$worker" --session-dir "$session" --tty "$session/tty" --gen 1 --fresh

[[ "$(<$session/title)" == "Plain Notes" ]] || {
    print -u2 -r -- "plain dir with commands was not AI-titled: '$(<$session/title)'"
    exit 1
}
if grep -rq "Plain Notes" "$tmp/dircache/cache/ghostwriter/repo-cache" 2>/dev/null; then
    print -u2 -r -- "non-repo title leaked into the repo cache"
    exit 1
fi
exit 0
