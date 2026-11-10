# Part 5: Omarchy bar indicator

Goal: a small Omarchy shell plugin (`omarchy/io.github.sspaeti.agent-ide/`) with a coloured dot on the bar that
shows whether any AI coding agent needs the user. Green = all good, yellow = running, orange = a finished or
failed result waits, violet = input needed (with count).

## Conventions found

- Plugin layout (user plugins in `~/.config/omarchy/plugins/<id>/`, hot-reloaded on save): `manifest.json`
  (`schemaVersion 1`, `kinds: ["bar-widget"]`, `entryPoints.barWidget`, `barWidget {displayName, category, defaultSection}`),
  `BarWidget.qml` (extends `qs.Ui BarWidget`, loads `Panel.qml` via a `Loader`, injects `bar`/`settings`/`anchorItem`/`hostWidget`,
  exposes `open/close/opened/closeForPopoutSwitch`, `IpcHandler`), `Panel.qml` (`Panel` + `KeyboardPanel` + `PanelKeyCatcher`).
  Model: `io.github.sspaeti.neomd/{manifest.json,BarWidget.qml,Panel.qml,Model.js,fetch.sh}`.
- `Model.js` is `.pragma library` and ends with `if (typeof module !== "undefined") module.exports = {...}`, tested with plain node
  (`io.github.sspaeti.battery/test/model.test.js`).
- Async data: `Process { command; stdout: StdioCollector { waitForEnd; onStreamFinished } }` driven by `Timer`; scripts are
  located with `Qt.resolvedUrl("x.sh")`. Shell scripts add `~/.local/bin` to PATH (shell children lack the login PATH).
- Built-in "agents overview": `~/.local/share/omarchy/shell/plugins/agents/` (`Panel.qml` = bar button + popup, glyph `󱚣`,
  button `active` turns the urgent colour). Bar buttons: `Ui/WidgetButton.qml` (text label, `tooltipText`, `pressed(button)`).
- Theme palette: `~/.local/state/omarchy/current/theme/colors.toml` has `green`, `yellow`, `orange`, `magenta` keys. The shell
  singleton `Color` only exposes foreground/background/accent/urgent/muted, so the widget reads `colors.toml` itself.

## Data flow

1. `collect.sh` (every 2 s): for each `$XDG_RUNTIME_DIR/agent-ide/status-<pid>.json` print `pid TAB alive TAB json-on-one-line`.
   Liveness = `/proc/<pid>` exists. No directory = no output.
2. `outside.sh` (every 5 s): `timeout 4 claude agents --json`; no output on failure.
3. `Model.js` `aggregate(files, outside, nowSec)` -> `{level, name, waiting, review, busy, rows, groups}`.
4. `BarWidget.qml` owns the processes and the aggregate; `Panel.qml` reads it through `hostWidget`; click on a row runs `jump.sh`.

## Aggregation decision

The Neovim counters (`waiting/review/busy`) also contain live sessions the Neovim does not own (status.lua `level()` adds
the `claude agents` map), so summing counters of N Neovims plus the outside list counts a tmux session N+1 times. The counts are
therefore derived from the de-duplicated session rows (file `sessions[]` by id, then outside by `sessionId`). Same level rule.

## Files

`manifest.json`, `BarWidget.qml`, `Panel.qml`, `Model.js`, `collect.sh`, `outside.sh`, `jump.sh`, `README.md`,
`test/model.test.js`, `test/collect.test.js`; `Makefile` target `test-omarchy`.

## Tests (node:test)

Levels for every combination, 90 s staleness (level>1 only), dead pid, de-dup file/outside and across files, malformed JSON,
empty input, row ordering, theme parsing, collect.sh against a temp dir.
