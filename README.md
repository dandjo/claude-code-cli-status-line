# Claude Code status line

A multi-line status line for [Claude Code](https://code.claude.com) that keeps
the things you actually look up while working on screen: which model you are
talking to, where you are, how full the context window is, how much of your
subscription limits is left before each window resets, and what extra usage
credits you have spent this month.

![The status line rendered in a terminal](assets/preview.svg)

One Bash script, no dependencies beyond Python 3 (and `curl` for the credits
and per-model lines), nothing to configure.

## What it shows

| Line      | Contents                                                             |
| :-------- | :------------------------------------------------------------------- |
| 1         | Model with its effort level, working directory, current git branch    |
| 2         | Context-window usage, tokens in context, session cost, elapsed time   |
| `5h`      | The rolling five-hour subscription window                             |
| `7d`      | The weekly subscription window                                        |
| per model | A model-scoped weekly window, labelled with the model name            |
| `Credits` | Usage credits spent this month, against the monthly limit if set      |

The working directory is shortened to `~` like a shell prompt, and the branch
disappears outside a git repository. The effort level is only shown for models
that support it.

The `5h` and `7d` lines need a Claude.ai subscription. On an API-key account
those windows do not exist and the lines stay away.

## Reading the limit lines

Bars run green, turn yellow at 70%, and red at 90%. Behind the bar, `⏰ Resets`
gives the local wall-clock time the window resets, with the time left in
brackets:

| The reset falls on | Shown as                         |
| :----------------- | :------------------------------- |
| today              | `16:11 (in 2h 14m)`              |
| a later day        | `Sa 19.09. 14:11 (in 3d 2h 14m)` |
| already past       | `now`                            |

The countdown drops the leading units that are zero, so it reads `in 14m`,
`in 2h 14m`, or `in 3d 2h 14m`. Weekday and date follow the terminal's
`LC_TIME`, so they appear in your own locale.

Colour carries the same meaning everywhere: cyan for a value you read (the
model, the token count, the reset time), amber for anything that costs you
(session cost, effort level, the countdown, credits spent).

## The credits line

Usage credits are the extra usage you can buy on top of a Claude.ai plan. The
line shows them while they are turned on, or once anything was spent this
month:

| Monthly limit | Shown as                                              |
| :------------ | :---------------------------------------------------- |
| set           | a bar like the limit lines, then `💳 €120.98 of €200.00` |
| none          | a grey `no limit` bar, then `💳 €120.98 this month`     |

`· off` follows while the credits are turned off, and `· as of 14:30` once the
figure is more than ten minutes old.

The status-line payload does not carry these figures for a Claude.ai sign-in,
so the script asks the same endpoint Claude Code's `/usage` dialog reads
(`api.anthropic.com/api/oauth/usage`). That is the one network request the
script makes:

- It runs in the background at most every two minutes, and a render never
  waits for it; the line shows the last answer, cached in
  `~/.cache/claude-statusline/usage-credits.json`.
- It uses Claude Code's OAuth access token from
  `~/.claude/.credentials.json`. The token goes to `curl` on stdin, so it
  never shows up in the process list, and it is never written to the cache.
- An expired token is left alone. Refreshing it would rotate the refresh
  token behind Claude Code's back, so the line waits until Claude Code has
  renewed it on its next request.
- On macOS Claude Code keeps the credentials in the Keychain rather than in
  that file, so the line stays away there.

## The per-model lines

A plan can limit a model on a weekly window of its own, such as Fable. Each
window gets a line labelled with the model name, in the form of the limit lines
above. It shows as soon as the server reports the window, at 0% too, so its
reset stays in view even if you do not use that model.

Claude Code does not hand these windows to the status line yet: it keeps
`rate_limits.model_scoped` for the SDK's `get_usage` request. So the script reads
them from the same answer as the credits, the rows of `limits[]` of kind
`weekly_scoped` with a model name, and all of the above applies: no extra
request, up to two minutes old, no line on macOS. `· as of 14:30` follows once
the answer is more than ten minutes old. If the payload carries the field one
day, it takes over without a change to the script.

The endpoint is undocumented, so its fields may change. The lines then
disappear; the rest of the status line stays.

## Requirements

- Bash, and Python 3.8 or newer to parse the status-line JSON, standard library only (`apt install python3`; on macOS it comes with the Command Line Tools, `xcode-select --install`)
- `curl` for the credits and per-model lines; without it they stay away
- A terminal with truecolor support for the exact amber; without it the script falls back to ANSI yellow
- GNU or BSD `date` — both are handled, so Linux and macOS work the same

## Install

1. Download the script:

   ```bash
   mkdir -p ~/.claude
   curl -fsSL https://raw.githubusercontent.com/dandjo/claude-code-cli-status-line/main/statusline-command.sh \
     -o ~/.claude/statusline-command.sh
   ```

2. Add the `statusLine` key to `~/.claude/settings.json`, leaving every other
   setting alone:

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "bash ~/.claude/statusline-command.sh"
     }
   }
   ```

3. Start a Claude Code session. The status line appears at the bottom.

To update later, run the same `curl` again. The setting stays as it is, only
the script changes.

## Let Claude install it

Paste this into a Claude Code session instead of running the steps by hand:

```text
Install this Claude Code status line for me:
https://github.com/dandjo/claude-code-cli-status-line

1. Download statusline-command.sh from the repo's main branch to
   ~/.claude/statusline-command.sh. Use the repo copy as-is — do not write
   your own status line and do not merge anything from an existing file.
2. Ensure ~/.claude/settings.json contains:
     "statusLine": { "type": "command", "command": "bash ~/.claude/statusline-command.sh" }
   Add the key if it is missing; leave every other setting untouched.
3. The script needs python3. If it is not installed, tell me the install
   command for my system instead of installing it yourself.
4. Feed a sample status-line payload into the script and show me the rendered
   output, including the 5h and 7d lines, so I can see it works.
```

## Customizing

Everything worth changing sits at the top of the script:

- `BAR_WIDTH` is the bar length in characters, 20 by default
- `CYAN`, `GREEN`, `YELLOW`, `RED` are plain ANSI codes
- `MONEY` is the amber used for cost, effort, the countdown, and credits spent, matching the colour Claude Code's own dark theme uses for its mode indicator
- `NO_LIMIT` is the grey of the `no limit` bar on the credits line
- `CREDITS_TTL` is how often the credits and per-model windows are fetched, 120 seconds by default, and `CREDITS_STALE` when their lines start to say `as of`, 600 seconds
- the two thresholds that colour a bar live in `render_bar`, at 70 and 90

The layout of each line is a single `printf` near the bottom of the file, so
reordering or dropping a field is a one-line change.

## Testing a change

The script reads one JSON object on stdin and writes the status line to
stdout, so you can exercise it without starting a session:

```bash
echo '{"model":{"display_name":"Opus 5"},"cost":{"total_cost_usd":1.23,"total_duration_ms":930000},"context_window":{"used_percentage":42,"total_input_tokens":67512},"workspace":{"current_dir":"'"$PWD"'"},"rate_limits":{"five_hour":{"used_percentage":31,"resets_at":'"$(($(date +%s)+7200))"'}}}' \
  | bash statusline-command.sh
```

Vary `used_percentage` to see the colour thresholds, and move `resets_at`
further out to see the countdown switch to days.

The credits line reads only its cache. To see it without a network request,
point the script at a scratch cache and config directory and write the cache
yourself (amounts are in cents):

```bash
dir=$(mktemp -d); mkdir -p "$dir/cache/claude-statusline"
date +%s > "$dir/cache/claude-statusline/.attempt"
echo '{"fetched_at":'"$(date +%s)"',"is_enabled":true,"used_credits":12098,"monthly_limit":20000,"decimal_places":2,"currency":"EUR"}' \
  > "$dir/cache/claude-statusline/usage-credits.json"
echo '{"model":{"display_name":"Opus 5"}}' \
  | XDG_CACHE_HOME="$dir/cache" CLAUDE_CONFIG_DIR="$dir" bash statusline-command.sh
```

Drop `monthly_limit` to see the `no limit` bar. Add
`"model_scoped":[{"display_name":"Fable","used_percentage":95,"resets_at":"2030-01-01T18:00:00+00:00"}]`
to the cache to see a per-model line.

## When something looks wrong

| Symptom                                | Cause                                                                                    |
| :------------------------------------- | :---------------------------------------------------------------------------------------- |
| No status line at all                  | `statusLine` missing from `~/.claude/settings.json`, or the path in `command` does not exist |
| `Status line needs python3` instead of the line | Python 3 is not installed; install it with the command shown                     |
| No `5h` / `7d` lines                   | Expected on API-key accounts — those windows only exist for Claude.ai subscriptions         |
| No per-model line                      | The plan has no model-scoped window, `curl` is missing, you are on macOS (Keychain), or the first fetch has not landed yet |
| No `Credits` line                      | Credits are off and nothing was spent, `curl` is missing, or you are on macOS (Keychain)    |
| `Credits` or per-model line says `as of …` | The last fetch failed or the token expired; it catches up after Claude Code's next request  |
| Cost and effort level are plain yellow | The terminal does not report truecolor, so the script falls back to ANSI yellow              |
| Boxes instead of icons                 | The terminal font has no emoji coverage; replace the icons in the `printf` calls            |

The full payload schema is documented at
<https://code.claude.com/docs/en/statusline>.

## License

[0BSD](LICENSE). Use it, change it, ship it. No attribution required, so the
copy in your `~/.claude` carries no obligations at all.
