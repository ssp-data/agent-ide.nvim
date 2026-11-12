#!/usr/bin/env bash
# Start Neovim on the synthetic demo in demo/ (make demo). Everything it reads or writes lives under
# /tmp/agent-ide-demo, rebuilt on every run, so the user's own sessions, prompts and status are untouched.
set -euo pipefail
cd "$(dirname "$0")/.."
src="$PWD"

root=/tmp/agent-ide-demo
rm -rf "$root"
mkdir -p "$root/git" "$root/projects" "$root/xdg/state/nvim/agent-ide" "$root/xdg/run"
chmod 700 "$root/xdg/run"
cp -r demo/prompts "$root/prompts"
cp demo/live.json "$root/live.json"
# The model a session without one starts with: the prompt's winbar names it (`↑ title · opus 5.5`).
printf '{"version": 1, "model": "claude-opus-5-5"}\n' > "$root/xdg/state/nvim/agent-ide/prefs.json"
chmod 600 "$root/xdg/state/nvim/agent-ide/prefs.json"
# Quota of the demo, stamped now: a quota file older than 30 minutes is not shown in the footer.
python3 - "$root/quota.json" <<'PY'
import json, sys, time
now = int(time.time())
json.dump({"limits": [{"label": "5h", "percent": 0.18, "resetsAt": now + 3 * 3600},
                      {"label": "week", "percent": 0.36, "resetsAt": now + 4 * 86400}],
           "updatedAt": now}, open(sys.argv[1], "w"))
PY

# Repositories, with a history that gives the drawer its branches, commits and changes.
export GIT_AUTHOR_NAME=Demo GIT_AUTHOR_EMAIL=demo@example.invalid
export GIT_COMMITTER_NAME=Demo GIT_COMMITTER_EMAIL=demo@example.invalid
commit() { # commit <when> <message>: a commit of everything staged, dated <when> ago
  local when
  when="$(date -u -d "$1 ago" +%Y-%m-%dT%H:%M:%S)"
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git commit -q -m "$2"
}
repo() { mkdir -p "$root/git/$1"; cd "$root/git/$1"; git init -q -b main; }

repo dataflow
cp "$src/demo/repos/dataflow/README.md" .
mkdir models
cp "$src/demo/repos/dataflow/models/customers.sql" models/
cat > models/orders.sql <<'SQL'
select order_id, customer_id, amount, updated_at
from {{ source('shop', 'orders') }}
SQL
head -5 "$src/demo/repos/dataflow/pipeline.py" > pipeline.py
git add -A && commit "3 weeks" "Initial commit"
# A side branch merged into main: the commit graph shows a second lane.
git checkout -q -b fix/customers-freshness
printf 'select *, now() as loaded_at from {{ source(%s, %s) }}\n' "'shop'" "'customers'" > models/customers.sql
git add -A && commit "3 weeks" "customers: add loaded_at"
git checkout -q main
GIT_AUTHOR_DATE="$(date -u -d "2 weeks ago" +%Y-%m-%dT%H:%M:%S)" GIT_COMMITTER_DATE="$(date -u -d "2 weeks ago" +%Y-%m-%dT%H:%M:%S)" git merge -q --no-ff -m "Merge branch 'fix/customers-freshness'" fix/customers-freshness
git checkout -q -b feat/incremental-orders
cp "$src/demo/repos/dataflow/models/orders.sql" models/
git add -A && commit "2 hours" "orders: incremental materialization"
cp "$src/demo/repos/dataflow/models/schema.yml" models/
git add -A && commit "5 hours" "orders: add uniqueness tests"
# Work in progress: not committed yet.
cp "$src/demo/repos/dataflow/pipeline.py" .
mkdir tests && cp "$src/demo/repos/dataflow/tests/test_orders.py" tests/
git checkout -q main
git checkout -q feat/incremental-orders

repo dataflow-docs
cp "$src/demo/repos/dataflow-docs/README.md" .
cp "$src/demo/repos/dataflow-docs/pipeline.py" .
mkdir models && cp "$src/demo/repos/dataflow-docs/models/"*.sql models/
git add -A && commit "3 weeks" "Initial commit"
git checkout -q -b docs/lineage
# A stub committed on the branch, rewritten by the session and not committed yet: a real diff.
mkdir docs && printf '# Lineage\n\norders -> customers -> revenue\n' > docs/lineage.md
git add -A && commit "1 day" "docs: lineage stub"
cp "$src/demo/repos/dataflow-docs/docs/lineage.md" docs/

repo neomd
cp "$src/demo/repos/neomd/main.go" "$src/demo/repos/neomd/config.yaml" .
git add -A && commit "4 weeks" "Initial commit"
cp "$src/demo/repos/neomd/config.go" .
git add -A && commit "3 days" "config: load from XDG_CONFIG_HOME"

repo ssp-blog
mkdir content && cp "$src/demo/repos/ssp-blog/content/"*.md content/
git add -A && commit "1 week" "Initial commit"
cd "$src"

# Claude's history per repository, in the folder name Claude derives from the path.
for d in demo/history/*/; do
  name="$(basename "$d")"
  dir="$root/projects/$(printf '%s' "$root/git/$name" | tr '/.' '--')"
  mkdir -p "$dir" && cp "$d"*.jsonl "$dir/"
done

cd "$root/git/dataflow"
# Config, plugins and caches stay the user's (the demo runs their Neovim); the state and runtime
# folders, where the plugin keeps drafts, preferences and status, are the demo's.
export XDG_STATE_HOME="$root/xdg/state" XDG_RUNTIME_DIR="$root/xdg/run"
exec nvim -u "$src/demo/init.lua" "$@"
