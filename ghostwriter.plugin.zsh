# ghostwriter -- AI-generated tab titles for Ghostty
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
#   GHOSTWRITER_BACKEND        openai, anthropic, or openrouter
#                              (default: first backend with an API key set)
#   GHOSTWRITER_API_KEY        API key override; by default the backend's own
#                              env var is used (OPENAI_API_KEY,
#                              ANTHROPIC_API_KEY, OPENROUTER_API_KEY)
#   GHOSTWRITER_MODEL          model id (defaults: gpt-5-nano /
#                              claude-haiku-4-5 / anthropic/claude-haiku-4.5)
#   GHOSTWRITER_BASE_URL       API base URL override (proxies, compatibles)
#   GHOSTWRITER_REASONING      reasoning effort for gpt-5 models; "off"
#                              disables the parameter        (default: low)
#   GHOSTWRITER_CURL           path to curl binary           (default: curl)
#   GHOSTWRITER_CMD_THRESHOLD  commands before a re-name         (default: 6)
#   GHOSTWRITER_MIN_INTERVAL   min seconds between renames      (default: 60)
#   GHOSTWRITER_MAX_LEN        max title length                 (default: 32)
#   GHOSTWRITER_HISTORY        commands kept per directory as
#                              AI context                       (default: 10)
#   GHOSTWRITER_TIMEOUT        AI call timeout in seconds       (default: 45)
#   GHOSTWRITER_IGNORE         colon-separated path globs never sent to the
#                              AI; matching dirs keep a plain folder title
#   GHOSTWRITER_FORCE=1        run outside Ghostty (any OSC 2 terminal)
#   GHOSTWRITER_DEBUG=1        log to ~/.cache/ghostwriter/debug.log

# ---------------------------------------------------------------------------
# Guards: interactive zsh, inside Ghostty, not inside tmux, not loaded twice.
# ---------------------------------------------------------------------------
[[ -o interactive ]] || return 0
(( ${+_gw_loaded} )) && return 0
[[ -n "$TMUX" ]] && return 0
[[ -n "${GHOSTWRITER_FORCE:-}" || "$TERM" == *ghostty* || \
   "$TERM_PROGRAM" == (ghostty|Ghostty)* || -n "$GHOSTTY_RESOURCES_DIR" ]] || return 0

typeset -g _gw_loaded=1

# Resolve our own location to find the namer script.
typeset -g _gw_dir="${${(%):-%N}:A:h}"
typeset -g _gw_namer="$_gw_dir/bin/ghostwriter-namer"
if [[ ! -x "$_gw_namer" ]]; then
    print -u2 "ghostwriter: worker script not found/executable: $_gw_namer"
    return 0
fi

# Warn (once) if no usable backend/API key exists; plugin stays inert then.
# With no explicit backend, pick the first one whose API key is exported.
typeset -g _gw_backend="${GHOSTWRITER_BACKEND:-}"
typeset -g _gw_api_key="${GHOSTWRITER_API_KEY:-}"
if [[ -z "$_gw_backend" ]]; then
    if   [[ -n "${OPENAI_API_KEY:-}" ]];     then _gw_backend=openai
    elif [[ -n "${ANTHROPIC_API_KEY:-}" ]];  then _gw_backend=anthropic
    elif [[ -n "${OPENROUTER_API_KEY:-}" ]]; then _gw_backend=openrouter
    else
        print -u2 "ghostwriter: no API key found (export OPENAI_API_KEY, ANTHROPIC_API_KEY, or OPENROUTER_API_KEY); tab naming disabled"
        return 0
    fi
fi
case "$_gw_backend" in
    openai)     [[ -n "$_gw_api_key" ]] || _gw_api_key="${OPENAI_API_KEY:-}" ;;
    anthropic)  [[ -n "$_gw_api_key" ]] || _gw_api_key="${ANTHROPIC_API_KEY:-}" ;;
    openrouter) [[ -n "$_gw_api_key" ]] || _gw_api_key="${OPENROUTER_API_KEY:-}" ;;
    *)
        print -u2 "ghostwriter: unsupported backend '$_gw_backend' (expected openai, anthropic, or openrouter)"
        return 0
        ;;
esac
if [[ -z "$_gw_api_key" ]]; then
    print -u2 "ghostwriter: no API key for backend '$_gw_backend'; tab naming disabled"
    return 0
fi
if ! command -v "${GHOSTWRITER_CURL:-curl}" >/dev/null 2>&1; then
    print -u2 "ghostwriter: curl not found; tab naming disabled"
    return 0
fi
# The worker builds and parses every request with perl (JSON::PP); without it
# each rename would fail silently in the background.
if ! command -v perl >/dev/null 2>&1; then
    print -u2 "ghostwriter: perl not found; tab naming disabled"
    return 0
fi

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
typeset -g _gw_cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/ghostwriter"
typeset -g _gw_session_dir="$_gw_cache_root/sessions/${TTY:t}-$$"
typeset -gA _gw_hist              # context -> newline-joined recent commands
typeset -ga _gw_hist_order        # contexts by last use, oldest first
typeset -ga _gw_ctx_cmds          # commands from _gw_ctx only (see _gw_collect)
typeset -gi _gw_total_cmds=0      # commands recorded tab-wide (fresh detection)
typeset -gi _gw_cmds_since=0      # commands since last rename trigger
typeset -gi _gw_last_time=0       # epoch of last rename trigger
typeset -gi _gw_gen=0             # rename generation (async ordering)
typeset -gi _gw_named=0           # has any rename been triggered yet?
typeset -g  _gw_named_ctx=""      # repo root (or cwd) at last rename
typeset -g  _gw_ctx=""            # current repo root (or cwd)

# Commands with no bearing on what a tab is for (see _gw_preexec).
typeset -ga _gw_noise=(
    ls ll la l clear pwd exit logout history jobs fg bg true false
    cd pushd popd z zi j .. ... ....
)

mkdir -p "$_gw_session_dir" 2>/dev/null
: >| "$_gw_session_dir/apply.lock" 2>/dev/null

zmodload zsh/datetime 2>/dev/null   # for $EPOCHSECONDS without forking
zmodload zsh/system 2>/dev/null

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Current context = git repo root if inside one, else cwd.
_gw_update_ctx() {
    local root
    root=$(command git rev-parse --show-toplevel 2>/dev/null) || root="$PWD"
    _gw_ctx="$root"
}

# Commands are remembered per context, so a rename triggered after moving to
# a new repo describes *that* repo instead of inheriting the command history
# of the one we just left -- and returning to an earlier repo still has its
# commands available, no matter how much happened elsewhere in between.
_gw_collect() {
    _gw_ctx_cmds=()
    [[ -n "${_gw_hist[$_gw_ctx]:-}" ]] && _gw_ctx_cmds=("${(@f)_gw_hist[$_gw_ctx]}")
}

# Directories the user never wants described to an AI. Patterns are zsh
# globs, colon-separated; a leading ~/ is expanded, and a match covers
# everything below the matched directory.
_gw_ignored() {
    local pat
    for pat in ${(s.:.)${GHOSTWRITER_IGNORE:-}}; do
        [[ -z "$pat" ]] && continue
        pat="${pat/#\~\//$HOME/}"
        # Tolerate the trailing and doubled slashes people naturally type.
        while [[ "$pat" == *//* ]]; do pat="${pat:gs|//|/|}"; done
        [[ "$pat" == ?*/ ]] && pat="${pat%/}"
        [[ "$_gw_ctx" == ${~pat} || "$_gw_ctx" == ${~pat}/* ]] && return 0
    done
    return 1
}

# Write an OSC 2 title directly to this tab's tty.
_gw_set_title() {
    [[ -w "$TTY" ]] || return 0
    printf '\033]2;%s\007' "$1" > "$TTY"
    print -r -- "$1" >| "$_gw_session_dir/title" 2>/dev/null
}

# Invalidate any in-flight rename: workers whose generation is below the
# barrier will discard their result instead of applying a stale title.
_gw_barrier() {
    (( _gw_gen++ ))
    if (( ${+builtins[zsystem]} )); then
        (
            local lock_fd
            zsystem flock -f lock_fd "$_gw_session_dir/apply.lock" 2>/dev/null
            print -r -- "$_gw_gen" >| "$_gw_session_dir/applied_gen" 2>/dev/null
        )
    else
        print -r -- "$_gw_gen" >| "$_gw_session_dir/applied_gen" 2>/dev/null
    fi
}

# Snapshot context for the worker and launch it in the background, disowned.
# $1 = "fresh" if this is a brand-new tab context (enables repo-name cache).
_gw_spawn_worker() {
    local fresh="$1"
    _gw_barrier
    local ctx_file="$_gw_session_dir/context.$_gw_gen"
    {
        print -r -- "cwd	$PWD"
        [[ -r "$_gw_session_dir/title" ]] && print -r -- "prev	$(<$_gw_session_dir/title)"
        local c
        for c in "${_gw_ctx_cmds[@]}"; do print -r -- "cmd	$c"; done
    } >| "$ctx_file" 2>/dev/null || return 0

    ( GHOSTWRITER_BACKEND="$_gw_backend" \
      GHOSTWRITER_API_KEY="$_gw_api_key" \
      GHOSTWRITER_MODEL="${GHOSTWRITER_MODEL:-}" \
      GHOSTWRITER_BASE_URL="${GHOSTWRITER_BASE_URL:-}" \
      GHOSTWRITER_REASONING="${GHOSTWRITER_REASONING:-}" \
      GHOSTWRITER_CURL="${GHOSTWRITER_CURL:-}" \
      GHOSTWRITER_MAX_LEN="${GHOSTWRITER_MAX_LEN:-}" \
      GHOSTWRITER_TIMEOUT="${GHOSTWRITER_TIMEOUT:-}" \
      GHOSTWRITER_DEBUG="${GHOSTWRITER_DEBUG:-}" \
      "$_gw_namer" --session-dir "$_gw_session_dir" --tty "$TTY" \
        --gen "$_gw_gen" ${fresh:+--fresh} </dev/null &>/dev/null & ) &!
}

# Decide whether to rename now. $1 = "force" to bypass all guards.
_gw_maybe_rename() {
    [[ -e "$_gw_session_dir/pin" ]] && return 0
    _gw_ignored && return 0
    local now=$EPOCHSECONDS fresh=""
    # "fresh" = this tab has barely been used anywhere yet. Only then is the
    # cross-tab repo-name cache consulted and refreshed; if it also applied
    # mid-session, a stale cached title would keep overwriting newer,
    # activity-based ones.
    (( _gw_total_cmds < 3 )) && fresh=1
    _gw_collect
    # A context nothing has run in has no signal to name it with -- an AI
    # title from just a path degrades into boilerplate ("X Project Root"),
    # so keep the folder/remembered title until a real command happens here.
    # Fresh tabs are the exception: naming a brand-new tab is the one case
    # where a repo name alone beats nothing.
    if [[ "$1" != force && -z "$fresh" ]] && (( ${#_gw_ctx_cmds} == 0 )); then
        return 0
    fi

    if [[ "$1" != force ]]; then
        local trigger=0
        if (( ! _gw_named )); then
            trigger=1                                   # first prompt in tab
        elif [[ "$_gw_ctx" != "$_gw_named_ctx" ]]; then
            (( now - _gw_last_time >= 10 )) && trigger=1   # repo/dir switch
        elif (( _gw_cmds_since >= ${GHOSTWRITER_CMD_THRESHOLD:-6} \
                && now - _gw_last_time >= ${GHOSTWRITER_MIN_INTERVAL:-60} )); then
            trigger=1                                   # enough new activity
        fi
        (( trigger )) || return 0
    fi

    _gw_named=1
    _gw_named_ctx="$_gw_ctx"
    _gw_cmds_since=0
    _gw_last_time=$now
    _gw_spawn_worker "$fresh"
}

# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------
_gw_preexec() {
    local cmd="${${1//$'\n'/; }//$'\t'/ }"
    [[ -z "$cmd" || "$cmd" == tabname* ]] && return 0
    # Noise says nothing about what the tab is for, so it neither reaches the
    # AI nor counts toward the rename threshold. Directory-navigation commands
    # additionally change the context mid-command -- a rename here would
    # snapshot the directory being left; chpwd/precmd handle those.
    (( ${_gw_noise[(Ie)${cmd%% *}]} )) && return 0
    local hist="${_gw_hist[$_gw_ctx]:-}"
    [[ "${hist##*$'\n'}" == "$cmd" ]] && return 0   # consecutive repeat
    if [[ -n "$hist" ]]; then hist+=$'\n'"$cmd"; else hist="$cmd"; fi
    local -i keep=${GHOSTWRITER_HISTORY:-10}
    (( keep < 1 )) && keep=1
    local -a lines=("${(@f)hist}")
    if (( ${#lines} > keep )); then
        lines=("${(@)lines[-keep,-1]}")
        hist="${(pj:\n:)lines}"
    fi
    _gw_hist[$_gw_ctx]="$hist"
    # Track per-context recency; forget the least recently used context so a
    # long session can't grow without bound.
    _gw_hist_order=("${(@)_gw_hist_order:#$_gw_ctx}" "$_gw_ctx")
    if (( ${#_gw_hist_order} > 8 )); then
        unset "_gw_hist[${(b)_gw_hist_order[1]}]"
        _gw_hist_order=("${(@)_gw_hist_order[2,-1]}")
    fi
    (( _gw_total_cmds += 1 ))
    (( _gw_cmds_since += 1 ))
    # Catch long-running commands (dev servers, builds): the rename fires while
    # they run, since precmd won't be reached until they exit.
    _gw_maybe_rename
}

_gw_precmd() {
    _gw_maybe_rename
}

# On every directory change, reconcile the title with the *current* context.
# Contexts named earlier this session are restored instantly from the
# worker-maintained map (no AI call); genuinely new contexts get a provisional
# basename title which the AI refines async. Both paths raise the generation
# barrier so any in-flight rename for the context we just left is discarded
# instead of stamping a stale title on this tab.
_gw_chpwd() {
    local previous_ctx="$_gw_ctx"
    _gw_update_ctx
    [[ -e "$_gw_session_dir/pin" ]] && return 0
    [[ "$_gw_ctx" == "$previous_ctx" ]] && return 0

    _gw_barrier
    local cur="" line remembered=""
    [[ -r "$_gw_session_dir/title" ]] && cur="$(<$_gw_session_dir/title)"
    if [[ -r "$_gw_session_dir/ctx-titles" ]]; then
        for line in ${(f)"$(<$_gw_session_dir/ctx-titles)"}; do
            [[ "${line%%	*}" == "$_gw_ctx" ]] && remembered="${line#*	}"
        done
    fi

    if [[ -n "$remembered" ]]; then
        # Seen this context before: restore its title, skip the AI entirely.
        [[ "$remembered" != "$cur" ]] && _gw_set_title "$remembered"
        _gw_named_ctx="$_gw_ctx"
    else
        [[ "${_gw_ctx:t}" != "$cur" ]] && _gw_set_title "${_gw_ctx:t}"
        [[ "$_gw_ctx" == "$_gw_named_ctx" ]] && _gw_named_ctx=""
    fi
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _gw_preexec
add-zsh-hook precmd  _gw_precmd
add-zsh-hook chpwd   _gw_chpwd

# ---------------------------------------------------------------------------
# tabname -- manual control
# ---------------------------------------------------------------------------
tabname() {
    case "$1" in
        -h|--help)
            print "usage: tabname            show current title & mode"
            print "       tabname <name>     pin a manual title"
            print "       tabname --auto     unpin, resume AI naming"
            print "       tabname --now      unpin and force an AI rename now"
            ;;
        "")
            local t="(unset)" mode="auto (AI)"
            [[ -r "$_gw_session_dir/title" ]] && t="$(<$_gw_session_dir/title)"
            _gw_ignored && mode="off (GHOSTWRITER_IGNORE)"
            [[ -e "$_gw_session_dir/pin" ]] && mode="pinned (manual)"
            print "title: $t"
            print "mode:  $mode"
            ;;
        -a|--auto)
            rm -f "$_gw_session_dir/pin"
            _gw_update_ctx
            _gw_maybe_rename force
            print "ghostwriter: auto naming resumed"
            ;;
        -n|--now)
            rm -f "$_gw_session_dir/pin"
            _gw_update_ctx
            _gw_maybe_rename force
            ;;
        *)
            local name="$*"
            print -r -- "$name" >| "$_gw_session_dir/pin"
            _gw_barrier
            _gw_set_title "$name"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Kickoff: provisional title immediately; first AI name arrives at first prompt.
# ---------------------------------------------------------------------------
_gw_update_ctx
_gw_named_ctx="$_gw_ctx"
_gw_set_title "${_gw_ctx:t}"
