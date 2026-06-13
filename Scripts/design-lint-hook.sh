#!/usr/bin/env bash
# PostToolUse hook: lint the just-edited Swift file against the design system.
# Reads the tool-call JSON on stdin, extracts the edited file, and runs the
# design linter on it. Exit 2 surfaces any violations back to the agent so they
# get fixed before moving on. Non-Swift edits and clean files are silent.
set -uo pipefail

f=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))' 2>/dev/null || true)
[[ "$f" == *.swift ]] || exit 0

dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
lint="$dir/Scripts/design-lint.sh"
[[ -x "$lint" ]] || exit 0

if ! out=$("$lint" "$f" 2>&1); then
    {
        echo "Design-system violations in $f — fix with DesignTokens/Typography,"
        echo "or annotate a justified signature effect with // design-lint:allow."
        echo "See DESIGN_GUIDELINES.md."
        echo "$out"
    } >&2
    exit 2
fi
exit 0
