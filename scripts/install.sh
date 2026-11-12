#!/usr/bin/env bash
# Install the skill for the selected CLIs. Existing files are never replaced.
set -euo pipefail
SKILL_DIR=$(cd "$(dirname "$0")/.." && pwd -P)

choose() {
    local label="$1" default="$2" answer
    printf '%s [%s]: ' "$label" "$default" >&2
    IFS= read -r answer || { echo 'Installation cancelled.' >&2; exit 1; }
    answer=${answer:-$default}
    case "$answer" in y|Y|yes|YES) return 0 ;; n|N|no|NO) return 1 ;;
        *) echo 'Please answer y or n.' >&2; choose "$label" "$default" ;;
    esac
}
install_link() {
    local dir="$1" link="$1/tandem-review"
    mkdir -p "$dir"
    if [ -L "$link" ] && [ "$(cd "$link" 2>/dev/null && pwd -P)" = "$SKILL_DIR" ]; then
        printf 'Already installed: %s\n' "$link"
    elif [ -e "$link" ] || [ -L "$link" ]; then
        printf 'Not replacing existing path: %s\n' "$link" >&2
        return 1
    else
        ln -s "$SKILL_DIR" "$link"
        printf 'Installed: %s\n' "$link"
    fi
}
claude=no codex=no vibe=no
choose 'Install for Claude Code? (y/n)' y && claude=yes
choose 'Install for Codex? (y/n)' y && codex=yes
choose 'Install for Mistral Vibe? (y/n)' n && vibe=yes
status=0
[ "$claude" = no ] || install_link "$HOME/.claude/skills" || status=1
[ "$codex" = no ] || install_link "$HOME/.agents/skills" || status=1
[ "$vibe" = no ] || install_link "$HOME/.vibe/skills" || status=1
exit "$status"
