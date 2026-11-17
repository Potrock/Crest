#!/bin/zsh
set -euo pipefail

# Keeps this fork current with upstream Crest, which is where Chromium's
# security fixes arrive: upstream pins each Chromium release and publishes its
# engine, and this fork takes both by merging upstream and rebuilding.
#
#   Scripts/update-fork.sh               merge upstream into this branch, then
#                                        rebuild and reinstall Crest
#   Scripts/update-fork.sh --check       report what upstream has that this
#                                        branch doesn't; exits 10 when an
#                                        update is waiting
#   Scripts/update-fork.sh --notify      --check, as a macOS notification when
#                                        an update is waiting
#   Scripts/update-fork.sh --schedule    run --notify every day at 10:00
#   Scripts/update-fork.sh --unschedule  stop the daily check
#
# Merges resolve the two files every fork commit touches: upstream's version
# wins in Config/Version.xcconfig, and Documentation/ReleaseNotes.json keeps
# both sides' entries. A conflict anywhere else stops the merge for you.

repository_root="${0:A:h:h}"
[[ -f "$repository_root/Config/LocalRelease.env" ]] && source "$repository_root/Config/LocalRelease.env"
upstream_url="${CREST_FORK_UPSTREAM_URL:-https://github.com/pauljoda/Crest.git}"
upstream_branch="${CREST_FORK_UPSTREAM_BRANCH:-main}"
upstream_ref="refs/remotes/upstream/$upstream_branch"
engine_lock="CrestEngines/Chromium/source.lock.json"
application_path="/Applications/Crest.app"
schedule_label="${CREST_LOCAL_BUNDLE_IDENTIFIER:-com.pauldavis.crest}.update-check"
schedule_path="$HOME/Library/LaunchAgents/$schedule_label.plist"
update_waiting=10

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
cd "$repository_root"

# The Chromium version the engine lock at `revision` pins.
chromium_at() {
  git show "$1:$engine_lock" | /usr/bin/python3 -I -c 'import json, sys; print(json.load(sys.stdin)["chromium"]["version"])'
}

# Chrome's current stable version for Mac, or nothing when it can't be read.
chrome_stable() {
  curl -fsS --max-time 10 'https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Mac&num=1' 2>/dev/null \
    | /usr/bin/python3 -I -c 'import json, sys; print(json.load(sys.stdin)[0]["version"])' 2>/dev/null || true
}

fetch_upstream() {
  git fetch --quiet "$upstream_url" "+$upstream_branch:$upstream_ref"
}

# Prints what upstream has that HEAD doesn't, and returns `update_waiting`
# when there is any.
report() {
  fetch_upstream
  local behind ours theirs stable installed security
  behind="$(git rev-list --count "HEAD..$upstream_ref")"
  ours="$(chromium_at HEAD)"
  theirs="$(chromium_at "$upstream_ref")"
  stable="$(chrome_stable)"
  installed="$(/usr/libexec/PlistBuddy -c 'Print CrestChromiumEngineVersion' "$application_path/Contents/Info.plist" 2>/dev/null || print -n "not installed")"

  print "Upstream commits to merge: $behind"
  print "Chromium: installed $installed, this branch $ours, upstream $theirs${stable:+, Chrome stable $stable}"
  [[ "$ours" != "$theirs" ]] && print "  Upstream moved Chromium to $theirs."
  if [[ -n "$stable" && "${stable%%.*}" -gt "${theirs%%.*}" ]]; then
    print "  Chrome ${stable%%.*} is out and upstream Crest hasn't moved to it yet."
  fi
  [[ "$installed" != "$ours" && "$installed" != "not installed" ]] \
    && print "  The installed Crest is older than this branch; rebuild with Scripts/install-local-macos-release.sh."
  security="$(git log --format='%h %s' "HEAD..$upstream_ref" | grep -i -E 'CVE|security|exploit|vulnerab|distrust|Update Chromium' || true)"
  [[ -n "$security" ]] && print "Security changes upstream:\n$security"
  (( behind > 0 )) && return $update_waiting
  return 0
}

notify() {
  local output state=0
  output="$(report 2>&1)" || state=$?
  (( state == update_waiting )) || return $state
  local summary
  summary="$(print -r -- "$output" | head -2 | tr '\n' ' ')"
  [[ "$output" == *"Security changes upstream"* ]] && summary="Includes security fixes. $summary"
  /usr/bin/osascript - "$summary" <<'EOF'
on run arguments
  display notification (item 1 of arguments) with title "Crest update waiting" subtitle "Run Scripts/update-fork.sh"
end run
EOF
}

# Settles the conflicts every merge has: upstream's version, and both sides'
# release notes. Fails when any other file conflicts.
resolve_routine_conflicts() {
  local conflicted file
  conflicted=("${(@f)$(git diff --name-only --diff-filter=U)}")
  for file in "${conflicted[@]}"; do
    case "$file" in
      Config/Version.xcconfig)
        git checkout --theirs -- "$file"
        ;;
      Documentation/ReleaseNotes.json)
        git show ":2:$file" > "$file.ours"
        git show ":3:$file" > "$file.theirs"
        /usr/bin/python3 -I - "$file.ours" "$file.theirs" "$file" <<'EOF'
import json, sys
ours, theirs, out = sys.argv[1:4]
mine = json.load(open(ours))
merged = json.load(open(theirs))
for key, entry in mine["entries"].items():
    merged["entries"].setdefault(key, entry)
with open(out, "w") as handle:
    json.dump(merged, handle, indent=2, ensure_ascii=False)
    handle.write("\n")
EOF
        rm -f "$file.ours" "$file.theirs"
        ;;
      "") ;;
      *)
        return 1
        ;;
    esac
    [[ -n "$file" ]] && git add -- "$file"
  done
  return 0
}

update() {
  if [[ -n "$(git status --porcelain)" ]]; then
    print -u2 "Commit or stash your changes first; the merge needs a clean tree."
    exit 1
  fi
  local state=0
  report || state=$?
  if (( state == 0 )); then
    print "Already up to date with upstream."
    exit 0
  fi
  (( state == update_waiting )) || exit $state

  if ! git merge --no-edit "$upstream_ref" -m "Merge upstream Crest"; then
    if ! resolve_routine_conflicts; then
      print -u2 "These files conflict and need you:"
      git diff --name-only --diff-filter=U >&2
      print -u2 "Resolve them and commit, or run git merge --abort."
      exit 1
    fi
    git commit --no-edit --quiet
  fi
  # Upstream may have added files the committed project doesn't list yet.
  xcodegen generate --quiet >/dev/null 2>&1 || true
  git checkout -- Crest.xcodeproj/xcshareddata 2>/dev/null || true
  if [[ -n "$(git status --porcelain Crest.xcodeproj)" ]]; then
    git add Crest.xcodeproj
    git commit --quiet -m "Regenerate the Xcode project after merging upstream"
  fi
  print "Merged upstream. Rebuilding Crest…"
  Scripts/install-local-macos-release.sh
  print "Done. Push with: git push origin $(git branch --show-current)"
}

schedule() {
  mkdir -p "${schedule_path:h}" "$HOME/Library/Logs"
  cat > "$schedule_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$schedule_label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$repository_root/Scripts/update-fork.sh</string>
    <string>--notify</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>10</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/$schedule_label.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/$schedule_label.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$UID/$schedule_label" 2>/dev/null || true
  launchctl bootstrap "gui/$UID" "$schedule_path"
  print "Checking upstream every day at 10:00 ($schedule_label)."
}

unschedule() {
  launchctl bootout "gui/$UID/$schedule_label" 2>/dev/null || true
  rm -f "$schedule_path"
  print "Stopped the daily upstream check."
}

case "${1:-}" in
  "") update ;;
  --check) report ;;
  --notify) notify ;;
  --schedule) schedule ;;
  --unschedule) unschedule ;;
  *)
    print -u2 "usage: Scripts/update-fork.sh [--check | --notify | --schedule | --unschedule]"
    exit 64
    ;;
esac
