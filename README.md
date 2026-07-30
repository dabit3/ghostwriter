# ghostwriter

[![Built with Devin](https://img.shields.io/badge/Built%20with-Devin-blue)](https://devin.ai)

Context-aware tab titles for [Ghostty](https://ghostty.org). Instead of tabs
named after file paths or `zsh`, your tabs name themselves after the project
you're in:

```
before:  ~/opensource/experiments/ghostty-plugin   zsh   ~/blog
after:   Ghostty plugin   Api auth debugging   blog
```

Titles come from the folder (or git repo) name, split into words
(`naders-portfolio` becomes `Naders portfolio`) — no network, no latency. A
one-word name stays lowercase; longer ones capitalize only the first word.
Only when the name alone says nothing (`src`, `tmp`, `~`, the middle tab
above) is an AI fallback consulted to describe the work from recent
activity.

Ghostty has no plugin system, so this is implemented as a zsh plugin: it
watches your shell activity and sets the tab title through standard terminal
escape sequences (OSC 2). The rare fallback calls run asynchronously in the
background, so your prompt is never blocked.

## Requirements

- [Ghostty](https://ghostty.org) 1.x
- zsh (your login shell)
- Optional, for the AI fallback — an API key for one supported backend
  (without one, titles come purely from folder names):
  - [OpenAI](https://platform.openai.com/api-keys) (`OPENAI_API_KEY`)
  - [Anthropic](https://platform.claude.com/settings/keys) (`ANTHROPIC_API_KEY`)
  - [OpenRouter](https://openrouter.ai/keys) (`OPENROUTER_API_KEY`)
- `curl` and `perl` (preinstalled on macOS and most Linux distros)
- macOS or Linux

## Quick start

1. Clone this repo somewhere permanent:

   ```sh
   git clone https://github.com/dabit3/ghostwriter.git ~/ghostwriter
   ```

2. Optionally, export an API key in `~/.zshrc` to enable the AI fallback
   (skip if it's already there, or skip entirely for folder-name-only
   titles). The plugin picks the backend from whichever key it finds:

   ```sh
   export OPENAI_API_KEY=sk-...        # or ANTHROPIC_API_KEY / OPENROUTER_API_KEY
   ```

3. Add the plugin to the end of your `~/.zshrc` so it loads in every new
   shell from now on:

   ```sh
   echo 'source ~/ghostwriter/ghostwriter.plugin.zsh' >> ~/.zshrc
   ```

   (Or open `~/.zshrc` in an editor and paste the `source` line yourself.
   Running `source` directly in a terminal only lasts for that session.)

   Plugin managers work too — clone into `$ZSH_CUSTOM/plugins/ghostwriter`
   and add `ghostwriter` to `plugins=(...)` for Oh My Zsh, or
   `zinit light dabit3/ghostwriter` / `antidote bundle dabit3/ghostwriter`.

4. Tell Ghostty's shell integration to stop overwriting titles by adding
   `shell-integration-features = no-title` to your Ghostty config. On macOS:

   ```sh
   echo 'shell-integration-features = no-title' >> "$HOME/Library/Application Support/com.mitchellh.ghostty/config"
   ```

   On Linux:

   ```sh
   echo 'shell-integration-features = no-title' >> ~/.config/ghostty/config
   ```

   (The macOS path contains a space, so keep the quotes if you type it
   yourself.) This only disables Ghostty's built-in cwd-as-title behavior;
   cursor, sudo, and path integration stay on.

5. **Oh My Zsh users only:** OMZ has its own title auto-setter that will
   fight the plugin. Disable it in `~/.zshrc` (before `source
   $ZSH/oh-my-zsh.sh`):

   ```zsh
   DISABLE_AUTO_TITLE="true"
   ```

6. Reload the Ghostty config (`cmd+shift+,` on macOS) and **open a new tab**.
   Tabs opened before the config change keep the old behavior until closed.

## Try it out

Open a new tab, `cd` into one of your projects, and run a few commands:

```sh
cd ~/my-api && git status && npm test
```

The folder name appears as the title instantly, tidied up (`my-api` becomes
`My api`) — and that's the title. Only in a directory whose name says
nothing (`src`, `work`, `tmp`, ...) does the AI fallback rename the tab from
recent activity a few seconds later. Check what the plugin thinks it's doing
at any time:

```
$ tabname
title: My api
mode:  auto
```

## Usage

Mostly: just use your terminal, tabs name themselves. Manual control:

```
tabname            show current title & mode
tabname <name>     pin a manual title (automatic renaming stops)
tabname --auto     unpin and resume automatic naming (renames immediately)
tabname --now      unpin and force a rename right now (uses the AI fallback
                   when available)
```

### When renames happen

Most titles are computed locally and instantly: opening a tab or `cd`-ing
into a repo/directory names it after its folder, on the spot. The AI
fallback only fires for directories whose name carries no signal — `~`,
`src`, `tmp`, `work`, `code`, and the like — and even then only when:

- a tab opens there, or you `cd` in (the plain folder name appears
  immediately; the AI refines it a few seconds later)
- enough new commands have run there (default 6, at most once per minute)

Navigation and filler (`cd`, `ls`, `clear`, `pwd`, ...) and immediately
repeated commands are ignored: they neither count toward that threshold nor
get sent to the AI. Commands are remembered per directory, so moving to a
new directory starts its description from scratch instead of describing it
with the last one's commands — and returning to an earlier directory picks
its history back up.

A no-signal directory you haven't run anything in keeps its plain folder
name (or its cached name): with no activity there is nothing meaningful for
the AI to say, and guessed titles are worse than honest ones.

### Keeping it fast and cheap

- Directories with meaningful names never touch the network at all — for
  most tabs the title is pure local string-mangling.
- New tabs in a repo the AI has already named reuse a cached title (7-day
  TTL), so opening five tabs in one project costs at most one AI call.
- Returning to a directory you already named this session restores its title
  instantly from a per-tab map, no AI call.
- A generation barrier discards in-flight renames for directories you've
  since left, so fast navigation never stamps a stale title on a tab.
- Tabs sitting in a no-signal directory with no activity (including
  `$HOME`) skip the AI entirely.
- Pinned and ignored tabs are never touched.
- On the gpt-5 family, reasoning effort is capped at `low`: a three-word tab
  title needs little deliberation, and the model's default (`medium`) spends
  reasoning tokens and seconds of latency to reach the same answer.

## Configuration

Set in `~/.zshrc` before sourcing the plugin. Everything except
`GHOSTWRITER_FORCE`, `GHOSTWRITER_MAX_LEN`, and `GHOSTWRITER_IGNORE` only
affects the AI fallback.

| Variable | Default | Description |
|---|---|---|
| `GHOSTWRITER_BACKEND` | auto | `openai`, `anthropic`, or `openrouter` (default: first backend with an API key set, in that order) |
| `GHOSTWRITER_API_KEY` | unset | API key override; by default the backend's own env var is used |
| `GHOSTWRITER_MODEL` | per backend | Model id (see below) |
| `GHOSTWRITER_BASE_URL` | per backend | API base URL override (proxies, OpenAI-compatible servers) |
| `GHOSTWRITER_REASONING` | `low` | Reasoning effort for gpt-5 models; `off` omits the parameter |
| `GHOSTWRITER_IGNORE` | unset | Colon-separated path globs to never send to the AI |
| `GHOSTWRITER_FORCE` | unset | `1` runs outside Ghostty, in any OSC 2 terminal |
| `GHOSTWRITER_CURL` | `curl` | Path to the curl binary |
| `GHOSTWRITER_CMD_THRESHOLD` | `6` | Commands before a re-name |
| `GHOSTWRITER_MIN_INTERVAL` | `60` | Min seconds between renames |
| `GHOSTWRITER_MAX_LEN` | `32` | Max title length |
| `GHOSTWRITER_HISTORY` | `10` | Commands kept per directory as AI context |
| `GHOSTWRITER_TIMEOUT` | `45` | AI call timeout (seconds) |
| `GHOSTWRITER_DEBUG` | unset | `1` logs to `~/.cache/ghostwriter/debug.log` |

### Backends and models

For the AI fallback, the plugin calls the backend's HTTP API directly with
`curl`; nothing else needs to be installed. Each backend reads its standard
API key env var and defaults to a small, cheap model suited to naming tabs:

| Backend | API key env var | Default model | API |
|---|---|---|---|
| `openai` | `OPENAI_API_KEY` | `gpt-5-nano` | `https://api.openai.com/v1/chat/completions` |
| `anthropic` | `ANTHROPIC_API_KEY` | `claude-haiku-4-5` | `https://api.anthropic.com/v1/messages` |
| `openrouter` | `OPENROUTER_API_KEY` | `anthropic/claude-haiku-4.5` | `https://openrouter.ai/api/v1/chat/completions` |

If exactly one key is exported, no further setup is needed. With several
keys, or to pick a specific model, set the backend explicitly before the
plugin's `source` line:

```zsh
export GHOSTWRITER_BACKEND=openrouter
export GHOSTWRITER_MODEL=meta-llama/llama-3.3-70b-instruct
source ~/ghostwriter/ghostwriter.plugin.zsh
```

`GHOSTWRITER_BASE_URL` points the `openai` backend at any
OpenAI-compatible server (e.g. a local proxy or gateway):

```zsh
export GHOSTWRITER_BACKEND=openai
export GHOSTWRITER_BASE_URL=http://localhost:4000/v1
export GHOSTWRITER_API_KEY=whatever-your-proxy-expects
```

The backend is read once when the plugin loads, so existing tabs keep
whatever backend they started with; open a new tab after changing it. Run
`tabname --now` to force a rename and confirm titles are coming from the
right place (with `GHOSTWRITER_DEBUG=1`, each call is logged to
`~/.cache/ghostwriter/debug.log`).

## Troubleshooting

**Tabs aren't renaming at all**

- Are you in a *new* tab? Tabs opened before the Ghostty config change keep
  the old title behavior.
- Does `tabname` print anything? If "command not found", the plugin didn't
  load; check the `source` line in `~/.zshrc` and that you're in Ghostty
  (the plugin deactivates outside Ghostty and inside tmux).
- Folder-name titles work with no API key; if the AI fallback specifically
  isn't firing, the plugin prints a one-line warning when a prerequisite is
  missing (API key, `curl`, `perl`), so open a new tab and look for that
  message.
- Does `tabname` report `mode: off (GHOSTWRITER_IGNORE)`? This directory is
  on your exclusion list.
- Does the API key work on its own? For OpenAI:

  ```sh
  curl -sS https://api.openai.com/v1/chat/completions \
    -H "Authorization: Bearer $OPENAI_API_KEY" -H "content-type: application/json" \
    -d '{"model":"gpt-5-nano","messages":[{"role":"user","content":"say hi"}]}'
  ```

  With `GHOSTWRITER_DEBUG=1`, failed API calls (bad key, quota, network)
  land in `~/.cache/ghostwriter/debug.log`.

**Titles keep getting overwritten with the directory path**

- Ghostty's `no-title` setting isn't active in this tab: reload config and
  open a fresh tab.
- Oh My Zsh: confirm `DISABLE_AUTO_TITLE="true"` is set.

**Titles are weird or wrong**

- Turn on debug logging (`export GHOSTWRITER_DEBUG=1` in `~/.zshrc`,
  new tab) and watch `~/.cache/ghostwriter/debug.log`; every decision,
  AI call, and applied title is logged.
- Force a redo with `tabname --now`, or take over with `tabname My Name`.

**A rename lags a long-running command**

That's by design: the rename fires when you *launch* a long command (dev
server, build), so the tab is named while it runs.

## Privacy & cost

Directories with meaningful names are titled entirely on your machine;
nothing is sent anywhere. When the AI fallback fires (no-signal directory
names only), recent command lines (plus cwd, repo name, and the branch when
it isn't the default one) are sent directly to the selected backend's API
with your API key. Common secret patterns in those command lines (`API_KEY=...`,
`Authorization: Bearer ...`, long tokens) are redacted before leaving the
machine. Directory paths and branch names are sent as-is, since they carry
most of the signal — treat the whole context as something you'd paste into
that provider's chat.

To keep certain projects off the wire entirely, list them in
`GHOSTWRITER_IGNORE`; matching directories (and everything under them) keep a
plain folder title and never trigger a request:

```zsh
export GHOSTWRITER_IGNORE="~/work/acme:~/private/*"
```

Your API key is piped into `curl --config`, so it is never passed as a
command-line argument, never written to disk, and never written to the
debug log.

Cost: with no API key exported there is none — the fallback is simply off.
With one, the defaults are the cheapest current models (`gpt-5-nano`,
`claude-haiku-4-5`) at low reasoning effort. The prompt is only a few
hundred tokens, and since most directories never trigger the fallback,
calls are rare. Usage and billing follow the API key's account.

## Limitations

- Inside tmux the plugin disables itself (tmux owns titles there).
- TUI apps that set their own titles (e.g. Claude Code) will win while they
  run; the next rename trigger takes the title back.
- zsh only for now.
- Built for Ghostty, but nothing in it is Ghostty-specific beyond the
  terminal check; `GHOSTWRITER_FORCE=1` runs it in any terminal that honors
  OSC 2 titles.

## Uninstall

1. Remove the `source ...ghostwriter.plugin.zsh` line from `~/.zshrc`.
2. Remove `shell-integration-features = no-title` from your Ghostty config
   (and re-enable OMZ auto-title if you disabled it).
3. `rm -rf ~/.cache/ghostwriter` to clear state, then delete the repo.

## Files

- `ghostwriter.plugin.zsh`: zsh hooks, local naming, rename triggers,
  `tabname` command
- `bin/ghostwriter-namer`: detached worker for the AI fallback (cache,
  redaction, API call, OSC 2 title write)
- `tests/`: regression suite (`zsh tests/<name>.zsh`, no network required)
- State/cache: `~/.cache/ghostwriter/` (sessions auto-cleaned after 7 days)

## Development

```sh
zsh -n ghostwriter.plugin.zsh bin/ghostwriter-namer tests/*.zsh   # syntax
for t in tests/*.zsh; do zsh "$t" || break; done                  # tests
```

The suite stubs `curl`, so it never makes a real API call.

## License

MIT — see [LICENSE](LICENSE).
