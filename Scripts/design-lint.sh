#!/usr/bin/env bash
# =============================================================================
#  design-lint.sh — enforce DESIGN_GUIDELINES.md.
#
#  Greps view code for RAW LITERALS that must be design tokens instead. This is
#  the deterministic source of truth for "does the code comply" — it does not
#  depend on anyone remembering the rules.
#
#  Usage:
#    ./Scripts/design-lint.sh            # full scan, detailed report
#    ./Scripts/design-lint.sh --summary  # per-rule counts only (used by build.sh)
#    ./Scripts/design-lint.sh <file>...  # lint only the given file(s) (used by hook)
#
#  Exit code: 0 = clean, 1 = violations found.
#  Escape hatch: put `// design-lint:allow` on a line to exempt it (use sparingly,
#  for documented signature effects like the favorite burst / accent glow).
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUMMARY=0
declare -a TARGETS

for arg in "$@"; do
    case "$arg" in
        --summary) SUMMARY=1 ;;
        *) TARGETS+=("$arg") ;;
    esac
done

# Files allowed to contain raw literals: they DEFINE the tokens, are precise
# layout geometry, or derive colors dynamically (artwork).
EXEMPT_RE='DesignTokens\.swift|Typography\.swift|IslandConfiguration\.swift|ArtworkColor\.swift'

# Rule name | forbidden regex
RULES=(
    "raw color literal (use Palette)|Color\(red:|Color\(white:|Color\(hue:"
    "raw white/black color (use Palette)|\.(white|black)\.opacity\(|\bColor\.(white|black)\b|\.(foregroundStyle|foregroundColor|fill|stroke|strokeBorder|tint|background)\(\.(white|black)\b"
    "raw font/icon size (use Typography / IconSize)|\.system\(size: *[0-9]"
    "raw cornerRadius (use Radius)|cornerRadius: *[0-9]"
    "raw spring (use Motion)|\.spring\("
    "raw easing (use Motion)|\.(easeIn|easeInOut|easeOut|linear)\("
    "raw shadow (use shellShadow / raisedShadow)|\.shadow\("
    "raw spacing literal (use Spacing)|spacing: *[1-9]"
    "raw padding literal (use Spacing / Layout)|\.padding\([^)]*[1-9]"
    "non-island button style (use .island / .islandSubtle / .islandFlat)|\.buttonStyle\((\.(plain|bordered|borderedProminent|borderless|automatic|link)|Plain|Bordered|Borderless|Default|Link)"
    "custom ButtonStyle type (use IslandButtonStyle)|: *ButtonStyle\b"
    "card/window geometry literal in a view (use IslandConfiguration / Layout)|\.frame\([^)]*[0-9]{3,}"
)

# What to scan.
if [[ ${#TARGETS[@]} -gt 0 ]]; then
    SCAN=("${TARGETS[@]}")
else
    SCAN=("$ROOT/Sources/DynamicIsland")
fi

total=0
report=""
for rule in "${RULES[@]}"; do
    name="${rule%%|*}"
    pat="${rule#*|}"
    hits=$(grep -rnE "$pat" "${SCAN[@]}" --include='*.swift' 2>/dev/null \
           | grep -vE "$EXEMPT_RE" \
           | grep -v 'design-lint:allow' || true)
    [[ -z "$hits" ]] && continue
    n=$(printf '%s\n' "$hits" | grep -c . )
    total=$((total + n))
    if [[ $SUMMARY -eq 1 ]]; then
        report+=$(printf '   %3d  %s\n' "$n" "$name")$'\n'
    else
        report+="── ${name} (${n})"$'\n'
        report+=$(printf '%s\n' "$hits" | sed "s|$ROOT/||" | sed 's/^/   /')$'\n\n'
    fi
done

if [[ $total -eq 0 ]]; then
    echo "✅ design-lint: 0 violations"
    exit 0
fi

printf '%s' "$report"
echo "❌ design-lint: $total violation(s) — see DESIGN_GUIDELINES.md"
exit 1
