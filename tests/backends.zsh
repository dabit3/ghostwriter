#!/usr/bin/env zsh

emulate -L zsh
setopt err_exit no_unset pipe_fail

local repo_root="${0:A:h:h}"
local worker="$repo_root/bin/ghostty-ai-tabs-namer"
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
local headers
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ghostwriter-backends.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fake_curl="$tmp/fake-curl"

# Records the URL, headers (expanding -H @file), and request body (expanding
# --data-binary @file), then prints the canned API response.
print -r -- '#!/bin/sh
: > "$GHOSTWRITER_TEST_HEADERS"
url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -H)
            case "$2" in
                @*) cat "${2#@}" >> "$GHOSTWRITER_TEST_HEADERS" ;;
                *)  printf "%s\n" "$2" >> "$GHOSTWRITER_TEST_HEADERS" ;;
            esac
            shift 2 ;;
        --data-binary)
            case "$2" in
                @*) cat "${2#@}" > "$GHOSTWRITER_TEST_BODY" ;;
                *)  printf "%s" "$2" > "$GHOSTWRITER_TEST_BODY" ;;
            esac
            shift 2 ;;
        --max-time) shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
printf "%s\n" "$url" > "$GHOSTWRITER_TEST_URL"
printf "%s" "$GHOSTWRITER_TEST_RESPONSE"' > "$fake_curl"
chmod +x "$fake_curl"

# ---------------------------------------------------------------------------
# Plugin load: backend auto-detection from API key env vars
# ---------------------------------------------------------------------------
: > "$tmp/plugin-tty"
plugin_output=$(ROOT="$tmp" PLUGIN="$repo_root/ghostty-ai-tabs.plugin.zsh" \
    XDG_CACHE_HOME="$tmp/plugin-cache" TERM_PROGRAM=ghostty zsh -dfi -c '
        unset OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY
        unset GHOSTTY_AI_TABS_BACKEND GHOSTTY_AI_TABS_API_KEY
        export ANTHROPIC_API_KEY=test-key
        TTY="$ROOT/plugin-tty"
        source "$PLUGIN"
        (( ${+functions[tabname]} )) && print -r -- "loaded:$_gat_backend"
    ')
[[ "$plugin_output" == loaded:anthropic ]] || {
    print -u2 -r -- "plugin did not auto-select the anthropic backend from ANTHROPIC_API_KEY"
    exit 1
}

# A backend without its API key must leave the plugin inert.
plugin_output=$(ROOT="$tmp" PLUGIN="$repo_root/ghostty-ai-tabs.plugin.zsh" \
    XDG_CACHE_HOME="$tmp/plugin-cache" TERM_PROGRAM=ghostty zsh -dfi -c '
        unset OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY
        unset GHOSTTY_AI_TABS_API_KEY
        export GHOSTTY_AI_TABS_BACKEND=openai OPENROUTER_API_KEY=test-key
        TTY="$ROOT/plugin-tty"
        source "$PLUGIN" 2>/dev/null
        (( ${+functions[tabname]} )) && print -r -- loaded || print -r -- inert
    ')
[[ "$plugin_output" == inert ]] || {
    print -u2 -r -- "plugin loaded for backend openai without OPENAI_API_KEY"
    exit 1
}

# ---------------------------------------------------------------------------
# Worker: request shape per backend (url, auth headers, model, JSON body)
# ---------------------------------------------------------------------------
for case_name backend model base_url key_override effective_model expected_url title in \
    openai-default openai "" "" "" \
        gpt-5-nano https://api.openai.com/v1/chat/completions "Openai Title" \
    anthropic-default anthropic "" "" "" \
        claude-haiku-4-5 https://api.anthropic.com/v1/messages "Anthropic Title" \
    openrouter-explicit openrouter meta-llama/llama-3.3-70b-instruct "" "" \
        meta-llama/llama-3.3-70b-instruct https://openrouter.ai/api/v1/chat/completions "Openrouter Title" \
    openai-override openai gpt-4o-mini https://proxy.example/v1 override-key \
        gpt-4o-mini https://proxy.example/v1/chat/completions "Override Title"; do
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

    GHOSTWRITER_TEST_URL="$url_file" \
        GHOSTWRITER_TEST_HEADERS="$headers_file" \
        GHOSTWRITER_TEST_BODY="$body_file" \
        GHOSTWRITER_TEST_RESPONSE="$response" \
        XDG_CACHE_HOME="$tmp/$case_name/cache" \
        GHOSTTY_AI_TABS_BACKEND="$backend" \
        GHOSTTY_AI_TABS_MODEL="$model" \
        GHOSTTY_AI_TABS_BASE_URL="$base_url" \
        GHOSTTY_AI_TABS_API_KEY="$key_override" \
        GHOSTTY_AI_TABS_CURL="$fake_curl" \
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
done

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
    GHOSTTY_AI_TABS_BACKEND=openai \
    GHOSTTY_AI_TABS_MODEL="" \
    GHOSTTY_AI_TABS_BASE_URL="" \
    GHOSTTY_AI_TABS_API_KEY=test-key \
    GHOSTTY_AI_TABS_CURL="$fail_curl" \
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
    GHOSTTY_AI_TABS_BACKEND=openai \
    GHOSTTY_AI_TABS_MODEL="" \
    GHOSTTY_AI_TABS_BASE_URL="" \
    GHOSTTY_AI_TABS_API_KEY=test-key \
    GHOSTTY_AI_TABS_CURL="$error_curl" \
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
