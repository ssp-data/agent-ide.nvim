#!/usr/bin/env bash
# Screenshot of `make demo` for the README: a foot window running zsh, coloured by an Omarchy theme,
# floated and sized on Hyprland, captured with grim. Needs foot, grim, hyprctl and python3.
# Usage: scripts/demo-screenshot.sh [output.png]   (AGENT_IDE_DEMO_THEME picks the theme, default pics-costa-rica-sunset)
set -euo pipefail
cd "$(dirname "$0")/.."
src="$PWD"
out="${1:-$src/docs/images/main.png}"
theme="${AGENT_IDE_DEMO_THEME:-pics-costa-rica-sunset}"
colors="$HOME/.config/omarchy/themes/$theme/colors.toml"
[ -f "$colors" ] || { echo "no Omarchy theme at $colors" >&2; exit 1; }

# Your foot.ini (font, padding, keys) with the Omarchy theme include dropped, and the theme's palette
# appended as [colors]: the screenshot looks like your terminal, in the chosen theme's colours.
ini=/tmp/agent-ide-demo-foot.ini
python3 - "$colors" "$ini" <<'PY'
import os, re, sys
user = os.path.expanduser('~/.config/foot/foot.ini')
kept = [l for l in open(user).read().splitlines() if not l.startswith('include=')] if os.path.exists(user) else []
c = dict(re.findall(r'^(\w+)\s*=\s*"(#\w+)"', open(sys.argv[1]).read(), re.M))
f = lambda k: c[k].lstrip('#')
regular = ['darker_background', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'foreground']
bright = ['lighter_background', 'bright_red', 'bright_green', 'bright_yellow', 'bright_blue', 'bright_magenta', 'bright_cyan', 'bright_foreground']
lines = ['', '[colors-dark]',
         f"background={f('background')}", f"foreground={f('foreground')}",
         f"selection-background={f('selection')}", f"selection-foreground={f('foreground')}"]
lines += [f"regular{i}={f(k)}" for i, k in enumerate(regular)]
lines += [f"bright{i}={f(k)}" for i, k in enumerate(bright)]
open(sys.argv[2], 'w').write('\n'.join(kept + lines) + '\n')
PY

# The window: zsh runs `make demo`; floated, sized to 2100x1186 and centred on workspace 1.
foot --config="$ini" --app-id=agent-ide-demo -- zsh -c "cd '$src' && make demo" >/dev/null 2>&1 &
sleep 6
hyprctl dispatch "hl.dsp.window.float({ action = 'enable', window = 'class:agent-ide-demo' })" >/dev/null
hyprctl dispatch "hl.dsp.window.resize({ x = 2100, y = 1186, window = 'class:agent-ide-demo' })" >/dev/null
hyprctl dispatch "hl.dsp.window.center({ window = 'class:agent-ide-demo' })" >/dev/null
hyprctl dispatch "hl.dsp.focus({ workspace = 1 })" >/dev/null
sleep 14
read -r x y w h < <(hyprctl clients -j | python3 -c "import json,sys; c=[c for c in json.load(sys.stdin) if c['class']=='agent-ide-demo'][0]; print(c['at'][0],c['at'][1],c['size'][0],c['size'][1])")
grim -g "$x,$y ${w}x${h}" "$out"
echo "wrote $out"
