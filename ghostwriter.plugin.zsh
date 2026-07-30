# ghostwriter -- context-aware tab titles for Ghostty
#
# Names each tab after the project it is in: the folder (or git repo) name,
# split into words. Only when that name carries no signal (src, tmp, ~) is an
# AI API (OpenAI, Anthropic, or OpenRouter) consulted as a fallback to name
# the tab from recent activity. All AI calls happen asynchronously in the
# background; your prompt is never blocked.
#
# Usage: source this file from ~/.zshrc, then just use your terminal.
#   tabname            show current title & mode
#   tabname <name>     pin a manual title (automatic renaming stops)
#   tabname --auto     unpin and resume automatic naming
#   tabname --now      force a rename right now (uses the AI if available)
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

# Missing configuration is worth saying once, not in every new tab.
_gw_warn_once() {
    local marker="${XDG_CACHE_HOME:-$HOME/.cache}/ghostwriter/warned"
    [[ -e "$marker" && "$(<$marker)" == "$1" ]] && return 0
    print -u2 -r -- "$1 (this warning is shown once)"
    mkdir -p "${marker:h}" 2>/dev/null
    print -r -- "$1" >| "$marker" 2>/dev/null
}

# Resolve our own location to find the namer script.
typeset -g _gw_dir="${${(%):-%N}:A:h}"
typeset -g _gw_namer="$_gw_dir/bin/ghostwriter-namer"

# The AI is a fallback, consulted only for directories whose name carries no
# signal. Missing prerequisites (API key, curl, perl, the worker script)
# disable that fallback; folder-name titles keep working regardless.
typeset -gi _gw_ai=1
typeset -g _gw_backend="${GHOSTWRITER_BACKEND:-}"
typeset -g _gw_api_key="${GHOSTWRITER_API_KEY:-}"
if [[ ! -x "$_gw_namer" ]]; then
    print -u2 "ghostwriter: worker script not found/executable: $_gw_namer; AI fallback disabled"
    _gw_ai=0
fi
# With no explicit backend, pick the first one whose API key is exported.
if (( _gw_ai )) && [[ -z "$_gw_backend" ]]; then
    if   [[ -n "${OPENAI_API_KEY:-}" ]];     then _gw_backend=openai
    elif [[ -n "${ANTHROPIC_API_KEY:-}" ]];  then _gw_backend=anthropic
    elif [[ -n "${OPENROUTER_API_KEY:-}" ]]; then _gw_backend=openrouter
    else
        _gw_warn_once "ghostwriter: no API key found (export OPENAI_API_KEY, ANTHROPIC_API_KEY, or OPENROUTER_API_KEY); AI fallback disabled"
        _gw_ai=0
    fi
fi
if (( _gw_ai )); then
    case "$_gw_backend" in
        openai)     [[ -n "$_gw_api_key" ]] || _gw_api_key="${OPENAI_API_KEY:-}" ;;
        anthropic)  [[ -n "$_gw_api_key" ]] || _gw_api_key="${ANTHROPIC_API_KEY:-}" ;;
        openrouter) [[ -n "$_gw_api_key" ]] || _gw_api_key="${OPENROUTER_API_KEY:-}" ;;
        *)
            print -u2 "ghostwriter: unsupported backend '$_gw_backend' (expected openai, anthropic, or openrouter); AI fallback disabled"
            _gw_ai=0
            ;;
    esac
fi
if (( _gw_ai )) && [[ -z "$_gw_api_key" ]]; then
    _gw_warn_once "ghostwriter: no API key for backend '$_gw_backend'; AI fallback disabled"
    _gw_ai=0
fi
if (( _gw_ai )) && ! command -v "${GHOSTWRITER_CURL:-curl}" >/dev/null 2>&1; then
    print -u2 "ghostwriter: curl not found; AI fallback disabled"
    _gw_ai=0
fi
# The worker builds and parses every request with perl (JSON::PP); without it
# each rename would fail silently in the background.
if (( _gw_ai )) && ! command -v perl >/dev/null 2>&1; then
    print -u2 "ghostwriter: perl not found; AI fallback disabled"
    _gw_ai=0
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
typeset -g  _gw_pretty=""         # scratch: _gw_pretty_name's answer

# Commands with no bearing on what a tab is for (see _gw_preexec).
typeset -ga _gw_noise=(
    ls ll la l clear pwd exit logout history jobs fg bg true false
    cd pushd popd z zi j .. ... ....
)

mkdir -p "$_gw_session_dir" 2>/dev/null
# Context snapshots hold command lines before the worker's redaction pass;
# keep the whole cache private on shared machines.
chmod 700 "$_gw_cache_root" 2>/dev/null
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
        # Match the current directory as well as the context (repo root):
        # an ignored subdirectory of a larger repo must stay ignored.
        [[ "$_gw_ctx" == ${~pat} || "$_gw_ctx" == ${~pat}/* || \
           "$PWD" == ${~pat} || "$PWD" == ${~pat}/* ]] && return 0
    done
    return 1
}

# A context whose folder name says nothing about the work: only these fall
# through to the AI; everywhere else the folder name itself is the title.
typeset -ga _gw_no_signal_names=(
    src source code dev developer projects project work workspace workspaces
    repos repo git github gitlab opensource tmp temp test tests testing
    scratch sandbox playground demo demos example examples sample samples
    notes docs documents desktop downloads misc stuff new untitled app apps
    build dist out bin lib home user users files data local share
)
_gw_no_signal() {
    [[ "$_gw_ctx" == "$HOME" || "$_gw_ctx" == "/" ]] && return 0
    local name="${(L)${_gw_ctx:t}//[-_. ]/}"
    (( ${#name} <= 2 )) && return 0
    (( ${_gw_no_signal_names[(Ie)$name]} )) && return 0
    return 1
}

# Turn a directory name into a readable title: separators become spaces and
# the result is lowercased. A single word is a name and stays lowercase
# ("ghostwriter"); two or more read as a phrase, so the first word is
# capitalized ("naders-portfolio" -> "Naders portfolio").
# Answers in $_gw_pretty rather than a subshell: this runs on every cd.
_gw_pretty_name() {
    local -a words=( ${(L)${(s: :)${1//[-_.]/ }}} )
    _gw_pretty="${(j: :)words}"
    (( ${#words} > 1 )) && _gw_pretty="${(U)_gw_pretty[1]}${_gw_pretty[2,-1]}"
    [[ -n "$_gw_pretty" ]] || _gw_pretty="$1"
}

# Write an OSC 2 title directly to this tab's tty. Control characters are
# stripped: a directory name may contain any byte, and a stray \a or \e would
# end the OSC early and feed the rest to the terminal as escape sequences.
_gw_set_title() {
    [[ -w "$TTY" ]] || return 0
    local title="${1//[[:cntrl:]]/}"
    printf '\033]2;%s\007' "$title" > "$TTY"
    print -r -- "$title" >| "$_gw_session_dir/title" 2>/dev/null
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
    # The folder name is the title; the AI is consulted only as a fallback,
    # for contexts whose name carries no signal (and for explicit --now
    # renames). Every path here runs behind a chpwd barrier, so no stale
    # in-flight title can overwrite the one painted below.
    if (( _gw_ai )) && { [[ "$1" == force ]] || _gw_no_signal }; then
        _gw_spawn_worker "$fresh"
    else
        local cur=""
        [[ -r "$_gw_session_dir/title" ]] && cur="$(<$_gw_session_dir/title)"
        _gw_pretty_name "${_gw_ctx:t}"
        [[ "$_gw_pretty" != "$cur" ]] && _gw_set_title "$_gw_pretty"
    fi
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
    # Under auto_cd a bare directory path is itself a command; it is
    # navigation all the same, so it must not reach the AI or the threshold.
    if [[ "$cmd" != *' '* ]]; then
        local dest="$cmd"
        [[ "$dest" == '~' ]] && dest="$HOME"
        [[ "$dest" == '~/'* ]] && dest="$HOME/${dest#\~/}"
        [[ -d "$dest" ]] && return 0
    fi
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
    # Not every chpwd is the user navigating. Completion for cd (and for a
    # bare path under auto_cd) expands "../na<TAB>" by running a plain cd in a
    # command-substitution subshell, and shell functions do the same all the
    # time. Those moves are undone before the next prompt, but a title painted
    # from one is not: the tab would sit on the directory being completed and
    # that name would go on to reach the AI as the previous title.
    (( ZSH_SUBSHELL )) && return 0
    (( ${+compstate} )) && return 0
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
        _gw_pretty_name "${_gw_ctx:t}"
        [[ "$_gw_pretty" != "$cur" ]] && _gw_set_title "$_gw_pretty"
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
            print "       tabname --auto     unpin, resume automatic naming"
            print "       tabname --now      unpin and force a rename now"
            ;;
        "")
            local t="(unset)" mode="auto"
            (( _gw_ai )) && _gw_no_signal && mode="auto (AI fallback)"
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
_gw_pretty_name "${_gw_ctx:t}"
_gw_set_title "$_gw_pretty"
