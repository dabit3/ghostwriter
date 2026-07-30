#!/usr/bin/env zsh

emulate -L zsh
setopt err_exit no_unset pipe_fail

local repo_root="${0:A:h:h}"
local worker="$repo_root/bin/ghostwriter-namer"
local tmp
local fake_curl
local backend
local case_name
local effective_model
local model
local base_url
local key_override
local expected_url
local session
local url_file
local headers_file
local body_file
local response
local plugin_output
local title
local tricky_cmd='git commit -m "fix: \"quoted\" & <html>"'
local body_model
local body_content
local body_cap
local body_reasoning
local reasoning_env
local expected_reasoning
local headers
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ghostwriter-backends.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fake_curl="$tmp/fake-curl"

# Records the URL, headers (unwrapping the --config script fed on stdin), and
# request body (expanding --data-binary @file), then prints the canned API
# response.
print -r -- '#!/bin/sh
: > "$GW_TEST_HEADERS"
url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --config)
            [ "$2" = "-" ] && sed -n '"'"'s/^header = "\(.*\)"$/\1/p'"'"' \
                | sed '"'"'s/\\"/"/g; s/\\\\/\\/g'"'"' >> "$GW_TEST_HEADERS"
            shift 2 ;;
        -H)
            printf "%s\n" "$2" >> "$GW_TEST_HEADERS"
            shift 2 ;;
        --data-binary)
            case "$2" in
                @*) cat "${2#@}" > "$GW_TEST_BODY" ;;
                *)  printf "%s" "$2" > "$GW_TEST_BODY" ;;
            esac
            shift 2 ;;
        --max-time) shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
printf "%s\n" "$url" > "$GW_TEST_URL"
printf "%s" "$GW_TEST_RESPONSE"' > "$fake_curl"
chmod +x "$fake_curl"

# ---------------------------------------------------------------------------
# Plugin load: backend auto-detection from API key env vars
# ---------------------------------------------------------------------------
: > "$tmp/plugin-tty"
plugin_output=$(ROOT="$tmp" PLUGIN="$repo_root/ghostwriter.plugin.zsh" \
    XDG_CACHE_HOME="$tmp/plugin-cache" TERM_PROGRAM=ghostty zsh -dfi -c '
        unset OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY
        unset GHOSTWRITER_BACKEND GHOSTWRITER_API_KEY
        export ANTHROPIC_API_KEY=test-key
        TTY="$ROOT/plugin-tty"
        source "$PLUGIN"
        (( ${+functions[tabname]} )) && print -r -- "loaded:$_gw_backend"
    ')
[[ "$plugin_output" == loaded:anthropic ]] || {
    print -u2 -r -- "plugin did not auto-select the anthropic backend from ANTHROPIC_API_KEY"
    exit 1
}

# Titles are plain OSC 2, so the plugin must load in any ordinary terminal
# (no Ghostty required) -- and sit out only where titles can't render or the
# user opted out.
local guard_case guard_env expected
for guard_case guard_env in \
    plain    "TERM=xterm-256color" \
    dumb     "TERM=dumb" \
    console  "TERM=linux" \
    tmux     "TERM=xterm-256color TMUX=/tmp/tmux-1000/default,1,0" \
    disabled "TERM=xterm-256color GHOSTWRITER_DISABLE=1" \
    forced   "TERM=dumb GHOSTWRITER_FORCE=1"; do
    plugin_output=$(ROOT="$tmp" PLUGIN="$repo_root/ghostwriter.plugin.zsh" \
        XDG_CACHE_HOME="$tmp/plugin-cache" GUARD_ENV="$guard_env" zsh -dfi -c '
            unset TMUX TERM_PROGRAM GHOSTTY_RESOURCES_DIR INSIDE_EMACS
            unset GHOSTWRITER_BACKEND GHOSTWRITER_API_KEY
            export OPENAI_API_KEY=test-key ${=GUARD_ENV}
            TTY="$ROOT/plugin-tty"
            source "$PLUGIN" 2>/dev/null
            (( ${+functions[tabname]} )) && print -r -- loaded || print -r -- inert
        ')
    case "$guard_case" in
        plain|forced) expected=loaded ;;
        *)            expected=inert ;;
    esac
    [[ "$plugin_output" == "$expected" ]] || {
        print -u2 -r -- "terminal guard '$guard_case' was $plugin_output (expected $expected)"
        exit 1
    }
done

# A backend without its API key still names tabs locally, but must disable
# the AI fallback rather than call an API it has no key for.
plugin_output=$(ROOT="$tmp" PLUGIN="$repo_root/ghostwriter.plugin.zsh" \
    XDG_CACHE_HOME="$tmp/plugin-cache" TERM_PROGRAM=ghostty zsh -dfi -c '
        unset OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY
        unset GHOSTWRITER_API_KEY
        export GHOSTWRITER_BACKEND=openai OPENROUTER_API_KEY=test-key
        TTY="$ROOT/plugin-tty"
        source "$PLUGIN" 2>/dev/null
        (( ${+functions[tabname]} )) || { print -r -- inert; exit }
        print -r -- "loaded:ai=$_gw_ai"
    ')
[[ "$plugin_output" == "loaded:ai=0" ]] || {
    print -u2 -r -- "backend openai without OPENAI_API_KEY: expected loaded:ai=0, got $plugin_output"
    exit 1
}

# ---------------------------------------------------------------------------
# Worker: request shape per backend (url, auth headers, model, JSON body)
# ---------------------------------------------------------------------------
for case_name backend model base_url key_override reasoning_env \
    effective_model expected_url expected_reasoning title in \
    openai-default openai "" "" "" "" \
        gpt-5-nano https://api.openai.com/v1/chat/completions low "Openai title" \
    anthropic-default anthropic "" "" "" "" \
        claude-haiku-4-5 https://api.anthropic.com/v1/messages - "Anthropic title" \
    openrouter-explicit openrouter meta-llama/llama-3.3-70b-instruct "" "" "" \
        meta-llama/llama-3.3-70b-instruct https://openrouter.ai/api/v1/chat/completions - "Openrouter title" \
    openai-override openai gpt-4o-mini https://proxy.example/v1 override-key "" \
        gpt-4o-mini https://proxy.example/v1/chat/completions - "Override title" \
    openai-gpt51 openai gpt-5.1 "" "" "" \
        gpt-5.1 https://api.openai.com/v1/chat/completions - "Gpt51 title" \
    openai-effort-off openai "" "" "" off \
        gpt-5-nano https://api.openai.com/v1/chat/completions - "Effort off title"; do
    session="$tmp/$case_name/session"
    url_file="$tmp/$case_name/url"
    headers_file="$tmp/$case_name/headers"
    body_file="$tmp/$case_name/body"
    mkdir -p "$session" "$tmp/$case_name/cache" "$tmp/$case_name/work"
    : > "$session/tty"
    : > "$session/apply.lock"
    print -rl -- "cwd	$tmp/$case_name/work" "cmd	git status" "cmd	$tricky_cmd" \
        > "$session/context.1"

    if [[ "$backend" == anthropic ]]; then
        response='{"content":[{"type":"text","text":"'"$title"'"}],"role":"assistant"}'
    else
        response='{"choices":[{"message":{"role":"assistant","content":"'"$title"'"}}]}'
    fi

    GW_TEST_URL="$url_file" \
        GW_TEST_HEADERS="$headers_file" \
        GW_TEST_BODY="$body_file" \
        GW_TEST_RESPONSE="$response" \
        XDG_CACHE_HOME="$tmp/$case_name/cache" \
        GHOSTWRITER_BACKEND="$backend" \
        GHOSTWRITER_MODEL="$model" \
        GHOSTWRITER_BASE_URL="$base_url" \
        GHOSTWRITER_API_KEY="$key_override" \
        GHOSTWRITER_REASONING="$reasoning_env" \
        GHOSTWRITER_CURL="$fake_curl" \
        OPENAI_API_KEY=test-key-openai \
        ANTHROPIC_API_KEY=test-key-anthropic \
        OPENROUTER_API_KEY=test-key-openrouter \
        "$worker" --session-dir "$session" --tty "$session/tty" --gen 1

    [[ "$(<$session/title)" == "$title" ]] || {
        print -u2 -r -- "$case_name did not apply its title"
        exit 1
    }
    [[ "$(<$url_file)" == "$expected_url" ]] || {
        print -u2 -r -- "$case_name called unexpected url: $(<$url_file)"
        exit 1
    }

    headers="$(<$headers_file)"
    if [[ "$backend" == anthropic ]]; then
        [[ "$headers" == *"x-api-key: test-key-anthropic"* && \
           "$headers" == *"anthropic-version: 2023-06-01"* ]] || {
            print -u2 -r -- "$case_name sent unexpected anthropic headers: $headers"
            exit 1
        }
    else
        [[ "$headers" == *"Authorization: Bearer ${key_override:-test-key-$backend}"* ]] || {
            print -u2 -r -- "$case_name sent unexpected auth header: $headers"
            exit 1
        }
    fi
    [[ "$headers" == *"content-type: application/json"* ]] || {
        print -u2 -r -- "$case_name missing json content-type header"
        exit 1
    }

    # The body must be valid JSON carrying the model, a token cap, and the
    # prompt (including shell-hostile characters) round-tripped intact.
    body_model=$(perl -MJSON::PP -0777 -e \
        'my $d = decode_json(<STDIN>); print $d->{model};' < "$body_file")
    body_content=$(perl -MJSON::PP -0777 -e \
        'my $d = decode_json(<STDIN>); print $d->{messages}[0]{content};' < "$body_file")
    [[ "$backend" == anthropic ]] && body_cap=max_tokens || body_cap=max_completion_tokens
    [[ "$backend" == openrouter ]] && body_cap=max_tokens
    perl -MJSON::PP -0777 -e \
        'my $d = decode_json(<STDIN>); exit(defined $d->{$ARGV[0]} ? 0 : 1);' \
        "$body_cap" < "$body_file" || {
        print -u2 -r -- "$case_name body is missing $body_cap"
        exit 1
    }
    [[ "$body_model" == "$effective_model" ]] || {
        print -u2 -r -- "$case_name sent model '$body_model' (expected '$effective_model')"
        exit 1
    }
    [[ "$body_content" == *"Directory:"* && "$body_content" == *"$tricky_cmd"* ]] || {
        print -u2 -r -- "$case_name prompt did not survive JSON encoding"
        exit 1
    }

    # Naming a tab needs no deliberation: gpt-5 models must be pinned to
    # minimal effort, and every other model must be left alone.
    body_reasoning=$(perl -MJSON::PP -0777 -e \
        'my $d = decode_json(<STDIN>); print $d->{reasoning_effort} // "-";' < "$body_file")
    [[ "$body_reasoning" == "$expected_reasoning" ]] || {
        print -u2 -r -- "$case_name sent reasoning_effort '$body_reasoning' (expected '$expected_reasoning')"
        exit 1
    }

    # The API key must never be written anywhere: not to the session dir, not
    # to the cache. (The recorded headers file belongs to this harness, and
    # stands in for what only ever existed in curl's memory.)
    if grep -rq -- "${key_override:-test-key-$backend}" \
        "$session" "$tmp/$case_name/cache" 2>/dev/null; then
        print -u2 -r -- "$case_name wrote the API key to disk"
        exit 1
    fi
done

# Keys with characters that are special to curl's --config parser must arrive
# byte-for-byte.
local weird_key='sk-a"b\c-123'
session="$tmp/weird-key/session"
mkdir -p "$session" "$tmp/weird-key/cache" "$tmp/weird-key/work"
: > "$session/tty"
: > "$session/apply.lock"
print -rl -- "cwd	$tmp/weird-key/work" "cmd	git status" > "$session/context.1"

GW_TEST_URL="$tmp/weird-key/url" \
    GW_TEST_HEADERS="$tmp/weird-key/headers" \
    GW_TEST_BODY="$tmp/weird-key/body" \
    GW_TEST_RESPONSE='{"choices":[{"message":{"content":"Weird Key"}}]}' \
    XDG_CACHE_HOME="$tmp/weird-key/cache" \
    GHOSTWRITER_BACKEND=openai \
    GHOSTWRITER_MODEL="" \
    GHOSTWRITER_BASE_URL="" \
    GHOSTWRITER_API_KEY="$weird_key" \
    GHOSTWRITER_REASONING="" \
    GHOSTWRITER_CURL="$fake_curl" \
    "$worker" --session-dir "$session" --tty "$session/tty" --gen 1

[[ "$(<$tmp/weird-key/headers)" == *"Authorization: Bearer $weird_key"* ]] || {
    print -u2 -r -- "quoting mangled the api key: $(<$tmp/weird-key/headers)"
    exit 1
}

# ---------------------------------------------------------------------------
# Failure paths: HTTP errors and error payloads must never become titles
# ---------------------------------------------------------------------------
# curl --fail style failure: non-zero exit, error text on stderr, no body.
local fail_curl="$tmp/fail-curl"
print -r -- '#!/bin/sh
echo "curl: (22) The requested URL returned error: 401" >&2
exit 22' > "$fail_curl"
chmod +x "$fail_curl"

session="$tmp/backend-fail/session"
mkdir -p "$session" "$tmp/backend-fail/cache" "$tmp/backend-fail/work"
: > "$session/tty"
: > "$session/apply.lock"
print -rl -- "cwd	$tmp/backend-fail/work" "cmd	git status" > "$session/context.1"

XDG_CACHE_HOME="$tmp/backend-fail/cache" \
    GHOSTWRITER_BACKEND=openai \
    GHOSTWRITER_MODEL="" \
    GHOSTWRITER_BASE_URL="" \
    GHOSTWRITER_API_KEY=test-key \
    GHOSTWRITER_CURL="$fail_curl" \
    "$worker" --session-dir "$session" --tty "$session/tty" --gen 1 --fresh

title="$(<$session/title)"
[[ "$title" == work ]] || {
    print -u2 -r -- "backend-fail applied '$title' instead of the basename fallback"
    exit 1
}

# An error payload with rc 0 (e.g. a proxy answering 200) must not parse
# into a title, and its text must never reach the fresh-tab repo cache.
local error_curl="$tmp/error-curl"
print -r -- '#!/bin/sh
printf "%s" "{\"error\":{\"message\":\"Incorrect API key provided\"}}"' > "$error_curl"
chmod +x "$error_curl"

session="$tmp/backend-error/session"
mkdir -p "$session" "$tmp/backend-error/cache" "$tmp/backend-error/work"
: > "$session/tty"
: > "$session/apply.lock"
print -rl -- "cwd	$tmp/backend-error/work" "cmd	git status" > "$session/context.1"

XDG_CACHE_HOME="$tmp/backend-error/cache" \
    GHOSTWRITER_BACKEND=openai \
    GHOSTWRITER_MODEL="" \
    GHOSTWRITER_BASE_URL="" \
    GHOSTWRITER_API_KEY=test-key \
    GHOSTWRITER_CURL="$error_curl" \
    "$worker" --session-dir "$session" --tty "$session/tty" --gen 1 --fresh

title="$(<$session/title)"
[[ "$title" == work ]] || {
    print -u2 -r -- "backend-error applied '$title' instead of the basename fallback"
    exit 1
}
if grep -rq "Incorrect API key" "$tmp/backend-error/cache" 2>/dev/null; then
    print -u2 -r -- "backend-error leaked the error message into the repo cache"
    exit 1
fi
