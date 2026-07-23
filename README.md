# ghostwriter

AI-generated tab titles for [Ghostty](https://ghostty.org). Instead of tabs
named after file paths or `zsh`, your tabs name themselves after what you're
actually doing in them:

```
before:  ~/opensource/experiments/ghostty-plugin   zsh   ~/blog
after:   Ghostty Plugin Dev   Api Auth Debugging   Blog Deploy Setup
```

Ghostty has no plugin system, so this is implemented as a zsh plugin: it
watches your shell activity and sets the tab title through standard terminal
escape sequences (OSC 2). All AI calls run asynchronously in the background,
so your prompt is never blocked.

## Requirements

- [Ghostty](https://ghostty.org) 1.x
- zsh (your login shell)
- An API key for one supported backend:
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

2. Export your API key in `~/.zshrc` (skip if it's already there). The
   plugin picks the backend from whichever key it finds:

   ```sh
   export OPENAI_API_KEY=sk-...        # or ANTHROPIC_API_KEY / OPENROUTER_API_KEY
   ```

3. Add the plugin to the end of your `~/.zshrc` so it loads in every new
   shell from now on:

   ```sh
   echo 'source ~/ghostwriter/ghostty-ai-tabs.plugin.zsh' >> ~/.zshrc
   ```

   (Or open `~/.zshrc` in an editor and paste the `source` line yourself.
   Running `source` directly in a terminal only lasts for that session.)

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

You'll see the directory name appear as the title instantly, then the AI
title (e.g. `My Api Testing`) replace it a few seconds later. Check what the
plugin thinks it's doing at any time:

```
$ tabname
title: My Api Testing
mode:  auto (AI)
```

## Usage

Mostly: just use your terminal, tabs name themselves. Manual control:

```
tabname            show current title & mode
tabname <name>     pin a manual title (AI stops renaming this tab)
tabname --auto     unpin and resume AI naming (renames immediately)
tabname --now      force an AI rename right now
```

### When renames happen

- a tab opens somewhere with signal (a repo or a non-`$HOME` directory)
- you `cd` into a different repo/directory context (an instant provisional
  title appears immediately; the AI refines it a few seconds later)
- enough new commands have run (default 6, at most once per minute)

### Keeping it fast and cheap

- New tabs in a repo you've already named reuse a cached title (7-day TTL),
  so opening five tabs in one project costs one AI call.
- Returning to a directory you already named this session restores its title
  instantly from a per-tab map, no AI call.
- A generation barrier discards in-flight renames for directories you've
  since left, so fast navigation never stamps a stale title on a tab.
- Empty tabs at `$HOME` skip the AI entirely.
- Pinned tabs are never touched.

## Configuration

Set in `~/.zshrc` before sourcing the plugin.

| Variable | Default | Description |
|---|---|---|
| `GHOSTTY_AI_TABS_BACKEND` | auto | `openai`, `anthropic`, or `openrouter` (default: first backend with an API key set, in that order) |
| `GHOSTTY_AI_TABS_API_KEY` | unset | API key override; by default the backend's own env var is used |
| `GHOSTTY_AI_TABS_MODEL` | per backend | Model id (see below) |
| `GHOSTTY_AI_TABS_BASE_URL` | per backend | API base URL override (proxies, OpenAI-compatible servers) |
| `GHOSTTY_AI_TABS_CURL` | `curl` | Path to the curl binary |
| `GHOSTTY_AI_TABS_CMD_THRESHOLD` | `6` | Commands before a re-name |
| `GHOSTTY_AI_TABS_MIN_INTERVAL` | `60` | Min seconds between renames |
| `GHOSTTY_AI_TABS_MAX_LEN` | `32` | Max title length |
| `GHOSTTY_AI_TABS_HISTORY` | `10` | Commands kept as AI context |
| `GHOSTTY_AI_TABS_TIMEOUT` | `45` | AI call timeout (seconds) |
| `GHOSTTY_AI_TABS_DEBUG` | unset | `1` logs to `~/.cache/ghostty-ai-tabs/debug.log` |

### Backends and models

The plugin calls the backend's HTTP API directly with `curl`; nothing else
needs to be installed. Each backend reads its standard API key env var and
defaults to a small, cheap model suited to naming tabs:

| Backend | API key env var | Default model | API |
|---|---|---|---|
| `openai` | `OPENAI_API_KEY` | `gpt-5-nano` | `https://api.openai.com/v1/chat/completions` |
| `anthropic` | `ANTHROPIC_API_KEY` | `claude-haiku-4-5` | `https://api.anthropic.com/v1/messages` |
| `openrouter` | `OPENROUTER_API_KEY` | `anthropic/claude-haiku-4.5` | `https://openrouter.ai/api/v1/chat/completions` |

If exactly one key is exported, no further setup is needed. With several
keys, or to pick a specific model, set the backend explicitly before the
plugin's `source` line:

```zsh
export GHOSTTY_AI_TABS_BACKEND=openrouter
export GHOSTTY_AI_TABS_MODEL=meta-llama/llama-3.3-70b-instruct
source ~/ghostwriter/ghostty-ai-tabs.plugin.zsh
```

`GHOSTTY_AI_TABS_BASE_URL` points the `openai` backend at any
OpenAI-compatible server (e.g. a local proxy or gateway):

```zsh
export GHOSTTY_AI_TABS_BACKEND=openai
export GHOSTTY_AI_TABS_BASE_URL=http://localhost:4000/v1
export GHOSTTY_AI_TABS_API_KEY=whatever-your-proxy-expects
```

The backend is read once when the plugin loads, so existing tabs keep
whatever backend they started with; open a new tab after changing it. Run
`tabname --now` to force a rename and confirm titles are coming from the
right place (with `GHOSTTY_AI_TABS_DEBUG=1`, each call is logged to
`~/.cache/ghostty-ai-tabs/debug.log`).

## Troubleshooting

**Tabs aren't renaming at all**

- Are you in a *new* tab? Tabs opened before the Ghostty config change keep
  the old title behavior.
- Does `tabname` print anything? If "command not found", the plugin didn't
  load; check the `source` line in `~/.zshrc` and that you're in Ghostty
  (the plugin deactivates outside Ghostty and inside tmux). The plugin also
  prints a one-line warning and stays inert when it can't find an API key,
  so open a new tab and look for that message.
- Does the API key work on its own? For OpenAI:

  ```sh
  curl -sS https://api.openai.com/v1/chat/completions \
    -H "Authorization: Bearer $OPENAI_API_KEY" -H "content-type: application/json" \
    -d '{"model":"gpt-5-nano","messages":[{"role":"user","content":"say hi"}]}'
  ```

  With `GHOSTTY_AI_TABS_DEBUG=1`, failed API calls (bad key, quota, network)
  land in `~/.cache/ghostty-ai-tabs/debug.log`.

**Titles keep getting overwritten with the directory path**

- Ghostty's `no-title` setting isn't active in this tab: reload config and
  open a fresh tab.
- Oh My Zsh: confirm `DISABLE_AUTO_TITLE="true"` is set.

**Titles are weird or wrong**

- Turn on debug logging (`export GHOSTTY_AI_TABS_DEBUG=1` in `~/.zshrc`,
  new tab) and watch `~/.cache/ghostty-ai-tabs/debug.log`; every decision,
  AI call, and applied title is logged.
- Force a redo with `tabname --now`, or take over with `tabname My Name`.

**A rename lags a long-running command**

That's by design: the rename fires when you *launch* a long command (dev
server, build), so the tab is named while it runs.

## Privacy & cost

Recent command lines (plus cwd, repo name, branch) are sent directly to the
selected backend's API with your API key. Common secret patterns
(`API_KEY=...`, `Authorization: Bearer ...`, long tokens) are redacted before
leaving the machine, but treat the context as things you would paste into
that provider's chat. Your API key is passed to `curl` through a
permission-restricted header file, never on the command line, and is never
written to the debug log.

Cost: the defaults are the cheapest current models (`gpt-5-nano`,
`claude-haiku-4-5`). The prompt is only a few hundred tokens, and the
trigger design keeps calls rare: typically a handful per hour of active
use. Usage and billing follow the API key's account.

## Limitations

- Inside tmux the plugin disables itself (tmux owns titles there).
- TUI apps that set their own titles (e.g. Claude Code) will win while they
  run; the next rename trigger takes the title back.
- zsh only for now.

## Uninstall

1. Remove the `source ...ghostty-ai-tabs.plugin.zsh` line from `~/.zshrc`.
2. Remove `shell-integration-features = no-title` from your Ghostty config
   (and re-enable OMZ auto-title if you disabled it).
3. `rm -rf ~/.cache/ghostty-ai-tabs` to clear state, then delete the repo.

## Files

- `ghostty-ai-tabs.plugin.zsh`: zsh hooks, rename triggers, `tabname` command
- `bin/ghostty-ai-tabs-namer`: detached worker for cache, redaction, AI call,
  OSC 2 title write
- State/cache: `~/.cache/ghostty-ai-tabs/` (sessions auto-cleaned after 7 days)
