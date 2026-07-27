# Project guidance

## Verification

- Run regressions: `for t in tests/*.zsh; do zsh "$t" || break; done`
  (`navigation` = titles/generation barrier, `backends` = request shape per
  provider, `context` = command bookkeeping and ignore list, `titles` =
  redaction and sanitizing). The suite stubs `curl`; no network needed.
- Check zsh syntax: `zsh -n ghostwriter.plugin.zsh bin/ghostwriter-namer tests/*.zsh`

## Conventions

- Everything user-facing is named `ghostwriter` / `GHOSTWRITER_*`; internal
  shell functions and variables use the `_gw_` prefix.
- The plugin must never block the prompt: anything that can be slow belongs
  in `bin/ghostwriter-namer`, which is spawned detached.
- The API key may be passed through the environment and piped into
  `curl --config`, but must never be written to disk or passed as an argument.
