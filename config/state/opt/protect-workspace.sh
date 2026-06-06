#!/bin/bash
# protect-workspace.sh — manage immutable file protection against prompt-injection writes
#
# Ada runs as the openclaw user inside the bwrap sandbox. So does Steve's SSH session.
# Standard Unix permissions cannot distinguish them. chattr +i protects files at the
# filesystem level — the sandbox (running as openclaw, no sudo) cannot remove the flag.
#
# MODES:
#   on                    set +i on all protected files          (root required)
#   off                   remove +i from all protected files     (root required)
#   on-skill  <skillname> set +i on one skill's files only       (root required)
#   off-skill <skillname> remove +i from one skill's files only  (root required)
#   check                 audit state; write JSON artifact        (no root needed)
#
# PROTECTED FILE SCOPE:
#   - workspace root identity files: SOUL.md, USER.md, IDENTITY.md, AGENTS.md, SECURITY.md
#   - workspace context instructions: .agents/context/*.md
#   - per-skill: SKILL.md, scripts/* (excluding __pycache__), templates/*
#   - sls-news-gemini prompt parts: .agents/skills/sls-news-gemini/parts/**/*.md
#   - NOT protected: config.json (legitimately edited when sources change)
#
# DAILY BRIEF INTEGRATION:
#   check writes workspace/working/sls-system/immutable-check.json in the same
#   schema as security.json. sls-system/build.py merges it into the System section.
#
# WORKFLOW:
#   Initial activation:         sudo bash /opt/protect-workspace.sh on
#   Before editing one skill:   sudo bash /opt/protect-workspace.sh off-skill sls-inbox
#   After editing:              sudo bash /opt/protect-workspace.sh on-skill sls-inbox
#   Bulk toggle (rare):         sudo bash /opt/protect-workspace.sh off / on

set -uo pipefail

WORKSPACE=/home/openclaw/.openclaw/workspace
ARTIFACT_DIR="$WORKSPACE/working/sls-system"
ARTIFACT="$ARTIFACT_DIR/immutable-check.json"

# ---------------------------------------------------------------------------
# root guard — required for any chattr operation
# ---------------------------------------------------------------------------
root_guard() {
    if [[ $EUID -ne 0 ]]; then
        echo "Error: '$*' requires root. Run: sudo bash /opt/protect-workspace.sh $*" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# enumerate all protected files across the workspace
# ---------------------------------------------------------------------------
list_protected() {
    local ws="$1"
    for f in SOUL.md USER.md IDENTITY.md AGENTS.md SECURITY.md; do
        [[ -f "$ws/$f" ]] && echo "$ws/$f"
    done
    find "$ws/.agents/context" -maxdepth 1 -type f -name "*.md" 2>/dev/null
    find "$ws/.agents/skills" -maxdepth 2 -name "SKILL.md" 2>/dev/null
    find "$ws/.agents/skills" -path "*/scripts/*" \
        ! -path "*/__pycache__/*" ! -type d 2>/dev/null
    find "$ws/.agents/skills" -path "*/templates/*" \
        ! -type d 2>/dev/null
    find "$ws/.agents/skills/sls-news-gemini/parts" -type f -name "*.md" 2>/dev/null
}

# ---------------------------------------------------------------------------
# enumerate protected files for one named skill
# ---------------------------------------------------------------------------
list_skill_protected() {
    local ws="$1" skill="$2"
    local skill_dir="$ws/.agents/skills/$skill"
    if [[ ! -d "$skill_dir" ]]; then
        echo "Error: skill not found: $skill_dir" >&2
        exit 1
    fi
    [[ -f "$skill_dir/SKILL.md" ]] && echo "$skill_dir/SKILL.md"
    find "$skill_dir/scripts" ! -path "*/__pycache__/*" ! -type d 2>/dev/null
    find "$skill_dir/templates" ! -type d 2>/dev/null
    if [[ "$skill" == "sls-news-gemini" ]]; then
        find "$skill_dir/parts" -type f -name "*.md" 2>/dev/null
    fi
}

# ---------------------------------------------------------------------------
# apply chattr to files from stdin; print summary
# ---------------------------------------------------------------------------
apply_chattr() {
    local flag="$1" label="$2"
    local count=0 errors=0
    while IFS= read -r f; do
        if chattr "$flag" "$f" 2>/dev/null; then
            ((count++)) || true
        else
            echo "Warning: could not set $flag on $f" >&2
            ((errors++)) || true
        fi
    done
    echo "Protection $label: $count file(s), $errors error(s)."
}

# ---------------------------------------------------------------------------
# main dispatch
# ---------------------------------------------------------------------------
cmd="${1:-}"

case "$cmd" in

    on)
        root_guard on
        list_protected "$WORKSPACE" | apply_chattr +i "enabled"
        ;;

    off)
        root_guard off
        list_protected "$WORKSPACE" | apply_chattr -i "disabled"
        ;;

    on-skill)
        skill="${2:-}"
        [[ -z "$skill" ]] && { echo "Error: on-skill requires a skill name." >&2; exit 1; }
        root_guard on-skill "$skill"
        list_skill_protected "$WORKSPACE" "$skill" | apply_chattr +i "enabled for $skill"
        ;;

    off-skill)
        skill="${2:-}"
        [[ -z "$skill" ]] && { echo "Error: off-skill requires a skill name." >&2; exit 1; }
        root_guard off-skill "$skill"
        list_skill_protected "$WORKSPACE" "$skill" | apply_chattr -i "disabled for $skill"
        ;;

    check)
        # No root required — lsattr is readable by any user
        mkdir -p "$ARTIFACT_DIR"

        total=0
        mutable=()
        while IFS= read -r f; do
            ((total++)) || true
            attrs=$(lsattr "$f" 2>/dev/null | awk '{print $1}')
            if [[ "$attrs" != *i* ]]; then
                mutable+=("$f")
            fi
        done < <(list_protected "$WORKSPACE")

        mutable_count=${#mutable[@]}
        immutable_count=$((total - mutable_count))

        if [[ $mutable_count -eq 0 ]]; then
            cat > "$ARTIFACT" <<EOF
{
  "status": "ok",
  "total": $total,
  "mutable_count": 0,
  "checks": [
    {
      "name": "Workspace file protection",
      "expected": "$total/$total immutable",
      "actual": "$total/$total immutable",
      "status": "ok"
    }
  ],
  "issues": []
}
EOF
            echo "All $total protected files are immutable."
            exit 0
        fi

        # Build issues array
        issues_json="["
        first=1
        for f in "${mutable[@]}"; do
            rel="${f#"$WORKSPACE"/}"
            rel="${rel//\"/\\\"}"
            [[ $first -eq 0 ]] && issues_json+=","
            issues_json+="{\"severity\":\"critical\",\"category\":\"file-protection\",\"message\":\"Protected file is writable: $rel\"}"
            first=0
        done
        issues_json+="]"

        cat > "$ARTIFACT" <<EOF
{
  "status": "critical",
  "total": $total,
  "mutable_count": $mutable_count,
  "checks": [
    {
      "name": "Workspace file protection",
      "expected": "$total/$total immutable",
      "actual": "$immutable_count/$total immutable — $mutable_count writable",
      "status": "critical"
    }
  ],
  "issues": $issues_json
}
EOF
        echo "VIOLATION: $mutable_count/$total protected files are writable." >&2
        exit 1
        ;;

    *)
        echo "Usage: protect-workspace.sh on | off | on-skill <name> | off-skill <name> | check" >&2
        exit 1
        ;;
esac
