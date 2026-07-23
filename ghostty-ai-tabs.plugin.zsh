# ghostty-ai-tabs -- AI-generated tab titles for Ghostty
#
# Watches your shell activity (cwd, git repo, recent commands) and asks an AI
# API (OpenAI, Anthropic, or OpenRouter) for a short descriptive tab title
# whenever your working context meaningfully changes. All AI calls happen
# asynchronously in the background; your prompt is never blocked.
#
# Usage: source this file from ~/.zshrc, then just use your terminal.
#   tabname            show current title & mode
#   tabname <name>     pin a manual title (AI stops renaming this tab)
#   tabname --auto     unpin and resume AI naming (renames immediately)
#   tabname --now      force an AI rename right now
#
# Config (set before sourcing, or export in ~/.zshrc):
#   GHOSTTY_AI_TABS_BACKEND        openai, anthropic, or openrouter
#                                  (default: first backend with an API key set)
#   GHOSTTY_AI_TABS_API_KEY        API key override; by default the backend's
#                                  own env var is used (OPENAI_API_KEY,
#                                  ANTHROPIC_API_KEY, OPENROUTER_API_KEY)
#   GHOSTTY_AI_TABS_MODEL          model id (defaults: gpt-5-nano /
#                                  claude-haiku-4-5 / anthropic/claude-haiku-4.5)
#   GHOSTTY_AI_TABS_BASE_URL       API base URL override (proxies, compatibles)
#   GHOSTTY_AI_TABS_CURL           path to curl binary           (default: curl)
#   GHOSTTY_AI_TABS_CMD_THRESHOLD  commands before a re-name     (default: 6)
#   GHOSTTY_AI_TABS_MIN_INTERVAL   min seconds between renames  (default: 60)
#   GHOSTTY_AI_TABS_MAX_LEN        max title length             (default: 32)
#   GHOSTTY_AI_TABS_DEBUG=1        log to ~/.cache/ghostty-ai-tabs/debug.log

# ---------------------------------------------------------------------------
# Guards: interactive zsh, inside Ghostty, not inside tmux, not loaded twice.
# ---------------------------------------------------------------------------
[[ -o interactive ]] || return 0
(( ${+_gat_loaded} )) && return 0
[[ -n "$TMUX" ]] && return 0
[[ "$TERM" == *ghostty* || "$TERM_PROGRAM" == (ghostty|Ghostty)* || -n "$GHOSTTY_RESOURCES_DIR" ]] || return 0

typeset -g _gat_loaded=1

# Resolve our own location to find the namer script.
typeset -g _gat_dir="${${(%):-%N}:A:h}"
typeset -g _gat_namer="$_gat_dir/bin/ghostty-ai-tabs-namer"
if [[ ! -x "$_gat_namer" ]]; then
    print -u2 "ghostty-ai-tabs: worker script not found/executable: $_gat_namer"
    return 0
fi

# Warn (once) if no usable backend/API key exists; plugin stays inert then.
# With no explicit backend, pick the first one whose API key is exported.
typeset -g _gat_backend="${GHOSTTY_AI_TABS_BACKEND:-}"
typeset -g _gat_api_key="${GHOSTTY_AI_TABS_API_KEY:-}"
if [[ -z "$_gat_backend" ]]; then
    if   [[ -n "${OPENAI_API_KEY:-}" ]];     then _gat_backend=openai
    elif [[ -n "${ANTHROPIC_API_KEY:-}" ]];  then _gat_backend=anthropic
    elif [[ -n "${OPENROUTER_API_KEY:-}" ]]; then _gat_backend=openrouter
    else
        print -u2 "ghostty-ai-tabs: no API key found (export OPENAI_API_KEY, ANTHROPIC_API_KEY, or OPENROUTER_API_KEY); tab naming disabled"
        return 0
    fi
fi
case "$_gat_backend" in
    openai)     [[ -n "$_gat_api_key" ]] || _gat_api_key="${OPENAI_API_KEY:-}" ;;
    anthropic)  [[ -n "$_gat_api_key" ]] || _gat_api_key="${ANTHROPIC_API_KEY:-}" ;;
    openrouter) [[ -n "$_gat_api_key" ]] || _gat_api_key="${OPENROUTER_API_KEY:-}" ;;
    *)
        print -u2 "ghostty-ai-tabs: unsupported backend '$_gat_backend' (expected openai, anthropic, or openrouter)"
        return 0
        ;;
esac
if [[ -z "$_gat_api_key" ]]; then
    print -u2 "ghostty-ai-tabs: no API key for backend '$_gat_backend'; tab naming disabled"
    return 0
fi
if ! command -v "${GHOSTTY_AI_TABS_CURL:-curl}" >/dev/null 2>&1; then
    print -u2 "ghostty-ai-tabs: curl not found; tab naming disabled"
    return 0
fi

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
typeset -g _gat_cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/ghostty-ai-tabs"
typeset -g _gat_session_dir="$_gat_cache_root/sessions/${TTY:t}-$$"
typeset -ga _gat_recent            # rolling window of recent commands
typeset -gi _gat_cmds_since=0      # commands since last rename trigger
typeset -gi _gat_last_time=0       # epoch of last rename trigger
typeset -gi _gat_gen=0             # rename generation (async ordering)
typeset -gi _gat_named=0           # has any rename been triggered yet?
typeset -g  _gat_named_ctx=""      # repo root (or cwd) at last rename
typeset -g  _gat_ctx=""            # current repo root (or cwd)

mkdir -p "$_gat_session_dir" 2>/dev/null
: >| "$_gat_session_dir/apply.lock" 2>/dev/null

zmodload zsh/datetime 2>/dev/null   # for $EPOCHSECONDS without forking
zmodload zsh/system 2>/dev/null

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Current context = git repo root if inside one, else cwd.
_gat_update_ctx() {
    local root
    root=$(command git rev-parse --show-toplevel 2>/dev/null) || root="$PWD"
    _gat_ctx="$root"
}

# Write an OSC 2 title directly to this tab's tty.
_gat_set_title() {
    [[ -w "$TTY" ]] || return 0
    printf '\033]2;%s\007' "$1" > "$TTY"
    print -r -- "$1" >| "$_gat_session_dir/title" 2>/dev/null
}

# Invalidate any in-flight rename: workers whose generation is below the
# barrier will discard their result instead of applying a stale title.
_gat_barrier() {
    (( _gat_gen++ ))
    if (( ${+builtins[zsystem]} )); then
        (
            local lock_fd
            zsystem flock -f lock_fd "$_gat_session_dir/apply.lock" 2>/dev/null
            print -r -- "$_gat_gen" >| "$_gat_session_dir/applied_gen" 2>/dev/null
        )
    else
        print -r -- "$_gat_gen" >| "$_gat_session_dir/applied_gen" 2>/dev/null
    fi
}

# Snapshot context for the worker and launch it in the background, disowned.
# $1 = "fresh" if this is a brand-new tab context (enables repo-name cache).
_gat_spawn_worker() {
    local fresh="$1"
    _gat_barrier
    local ctx_file="$_gat_session_dir/context.$_gat_gen"
    {
        print -r -- "cwd	$PWD"
        [[ -r "$_gat_session_dir/title" ]] && print -r -- "prev	$(<$_gat_session_dir/title)"
        local c
        for c in "${_gat_recent[@]}"; do print -r -- "cmd	$c"; done
    } >| "$ctx_file" 2>/dev/null || return 0

    ( GHOSTTY_AI_TABS_BACKEND="$_gat_backend" \
      GHOSTTY_AI_TABS_API_KEY="$_gat_api_key" \
      GHOSTTY_AI_TABS_MODEL="${GHOSTTY_AI_TABS_MODEL:-}" \
      GHOSTTY_AI_TABS_BASE_URL="${GHOSTTY_AI_TABS_BASE_URL:-}" \
      GHOSTTY_AI_TABS_CURL="${GHOSTTY_AI_TABS_CURL:-}" \
      GHOSTTY_AI_TABS_MAX_LEN="${GHOSTTY_AI_TABS_MAX_LEN:-}" \
      GHOSTTY_AI_TABS_TIMEOUT="${GHOSTTY_AI_TABS_TIMEOUT:-}" \
      GHOSTTY_AI_TABS_DEBUG="${GHOSTTY_AI_TABS_DEBUG:-}" \
      "$_gat_namer" --session-dir "$_gat_session_dir" --tty "$TTY" \
        --gen "$_gat_gen" ${fresh:+--fresh} </dev/null &>/dev/null & ) &!
}

# Decide whether to rename now. $1 = "force" to bypass all guards.
_gat_maybe_rename() {
    [[ -e "$_gat_session_dir/pin" ]] && return 0
    local now=$EPOCHSECONDS fresh=""
    (( ${#_gat_recent} < 3 )) && fresh=1

    if [[ "$1" != force ]]; then
        local trigger=0
        if (( ! _gat_named )); then
            trigger=1                                   # first prompt in tab
        elif [[ "$_gat_ctx" != "$_gat_named_ctx" ]]; then
            (( now - _gat_last_time >= 10 )) && trigger=1   # repo/dir switch
        elif (( _gat_cmds_since >= ${GHOSTTY_AI_TABS_CMD_THRESHOLD:-6} \
                && now - _gat_last_time >= ${GHOSTTY_AI_TABS_MIN_INTERVAL:-60} )); then
            trigger=1                                   # enough new activity
        fi
        (( trigger )) || return 0
    fi

    _gat_named=1
    _gat_named_ctx="$_gat_ctx"
    _gat_cmds_since=0
    _gat_last_time=$now
    _gat_spawn_worker "$fresh"
}

# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------
_gat_preexec() {
    local cmd="${1//$'\n'/; }"
    [[ -z "$cmd" || "$cmd" == tabname* ]] && return 0
    _gat_recent+=("$cmd")
    local -i keep=${GHOSTTY_AI_TABS_HISTORY:-10}
    (( ${#_gat_recent} > keep )) && _gat_recent=("${(@)_gat_recent[-keep,-1]}")
    (( _gat_cmds_since += 1 ))
    # Directory-navigation commands change the context mid-command; a rename
    # here would snapshot the directory being left. chpwd/precmd handle those.
    case "${cmd%% *}" in
        cd|pushd|popd|z|zi|j|..|...|....) return 0 ;;
    esac
    # Catch long-running commands (dev servers, builds): the rename fires while
    # they run, since precmd won't be reached until they exit.
    _gat_maybe_rename
}

_gat_precmd() {
    _gat_maybe_rename
}

# On every directory change, reconcile the title with the *current* context.
# Contexts named earlier this session are restored instantly from the
# worker-maintained map (no AI call); genuinely new contexts get a provisional
# basename title which the AI refines async. Both paths raise the generation
# barrier so any in-flight rename for the context we just left is discarded
# instead of stamping a stale title on this tab.
_gat_chpwd() {
    local previous_ctx="$_gat_ctx"
    _gat_update_ctx
    [[ -e "$_gat_session_dir/pin" ]] && return 0
    [[ "$_gat_ctx" == "$previous_ctx" ]] && return 0

    _gat_barrier
    local cur="" line remembered=""
    [[ -r "$_gat_session_dir/title" ]] && cur="$(<$_gat_session_dir/title)"
    if [[ -r "$_gat_session_dir/ctx-titles" ]]; then
        for line in ${(f)"$(<$_gat_session_dir/ctx-titles)"}; do
            [[ "${line%%	*}" == "$_gat_ctx" ]] && remembered="${line#*	}"
        done
    fi

    if [[ -n "$remembered" ]]; then
        # Seen this context before: restore its title, skip the AI entirely.
        [[ "$remembered" != "$cur" ]] && _gat_set_title "$remembered"
        _gat_named_ctx="$_gat_ctx"
    else
        [[ "${_gat_ctx:t}" != "$cur" ]] && _gat_set_title "${_gat_ctx:t}"
        [[ "$_gat_ctx" == "$_gat_named_ctx" ]] && _gat_named_ctx=""
    fi
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _gat_preexec
add-zsh-hook precmd  _gat_precmd
add-zsh-hook chpwd   _gat_chpwd

# ---------------------------------------------------------------------------
# tabname -- manual control
# ---------------------------------------------------------------------------
tabname() {
    case "$1" in
        -h|--help)
            print "usage: tabname            show current title & mode"
            print "       tabname <name>     pin a manual title"
            print "       tabname --auto     unpin, resume AI naming"
            print "       tabname --now      force an AI rename now"
            ;;
        "")
            local t="(unset)" mode="auto (AI)"
            [[ -r "$_gat_session_dir/title" ]] && t="$(<$_gat_session_dir/title)"
            [[ -e "$_gat_session_dir/pin" ]] && mode="pinned (manual)"
            print "title: $t"
            print "mode:  $mode"
            ;;
        -a|--auto)
            rm -f "$_gat_session_dir/pin"
            _gat_update_ctx
            _gat_maybe_rename force
            print "ghostty-ai-tabs: auto naming resumed"
            ;;
        -n|--now)
            rm -f "$_gat_session_dir/pin"
            _gat_update_ctx
            _gat_maybe_rename force
            ;;
        *)
            local name="$*"
            print -r -- "$name" >| "$_gat_session_dir/pin"
            _gat_barrier
            _gat_set_title "$name"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Kickoff: provisional title immediately; first AI name arrives at first prompt.
# ---------------------------------------------------------------------------
_gat_update_ctx
_gat_named_ctx="$_gat_ctx"
_gat_set_title "${_gat_ctx:t}"
