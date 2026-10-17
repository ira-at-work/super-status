#!/usr/bin/env bash
# Copies the committed statusline.sh and doctor.sh into the live install at
# ${CLAUDE_CONFIG_DIR:-~/.claude}/super-status, so the statusline in use always
# matches the repo's HEAD. Run by the post-commit, post-merge and post-rewrite
# git hooks; safe to run by hand.
#
# Reads from HEAD, not the working tree, so uncommitted edits never go live.
# Each file is replaced with an atomic rename: Claude Code runs statusline.sh
# every couple of seconds and must never read a half-written file.
# settings.json is left alone — run install.sh once for the initial wiring.
set -uo pipefail

repo_root="$(git rev-parse --show-toplevel)" || exit 0
dest_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/super-status"
[ -d "$dest_dir" ] || exit 0

synced=()
for file in statusline.sh doctor.sh; do
  tmp="$dest_dir/.$file.sync.$$"
  git -C "$repo_root" show "HEAD:$file" > "$tmp" 2>/dev/null || { rm -f "$tmp"; continue; }
  if cmp -s "$tmp" "$dest_dir/$file"; then
    rm -f "$tmp"
    continue
  fi
  chmod 755 "$tmp"
  mv -f "$tmp" "$dest_dir/$file"
  synced+=("$file")
done

[ "${#synced[@]}" -gt 0 ] && echo "🔄 Synced ${synced[*]} to $dest_dir"
exit 0
