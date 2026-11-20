#!/bin/zsh
# Build Topaz, Ben's fork of WezTerm (branch `dance`: Ghostty-style wobble in
# the WebGpu shader), into /Applications/Topaz.app, the one terminal on this
# Mac. Named Topaz on 2026-11-08 (Ben). The app is assembled as ci/deploy.sh
# assembles WezTerm's own macOS release, renamed in its Info.plist only. The
# binaries keep WezTerm's names (`wezterm`, `wezterm-gui`) and the config
# stays at ~/.config/wezterm, so upstream merges stay clean and `wezterm cli`
# keeps working.
#
# Topaz.app holds its helpers (2026-11-08): Loupe and Topaz Launcher, both
# from loupe/ in this repository (merged in from bbdaniels/claudehud on
# 2026-11-08, history kept), are built here and nested in
# Contents/Helpers, and Topaz launches them and keeps them alive
# (wezterm-gui/src/helpers.rs). This script is
# the one way either is built and installed; it replaced
# ~/Library/Caches/hud-install.sh.
#
#   ./topaz-build.sh               build, then install as --install does
#   ./topaz-build.sh --update      first merge upstream main and update Rust
#   ./topaz-build.sh --stage       build and sign into target/topaz/Topaz.app only
#   ./topaz-build.sh --install     install the staged app: quit Topaz, replace
#                                  /Applications/Topaz.app, install the config
#                                  from ~/Projects/personal, reopen Topaz
#   ./topaz-build.sh --helper loupe
#                                  rebuild the helpers, replace Loupe inside
#                                  the installed Topaz.app, re-sign that, and
#                                  end the running Loupe so Topaz relaunches
#                                  the new one; Topaz keeps running (`hud`,
#                                  its name before 2026-11-08, still works)
#   ./topaz-build.sh --helper launcher
#                                  the same for Topaz Launcher (once a full
#                                  build has installed a Topaz that has it)
#
# Signing: every binary with the "Topaz Dev" certificate and the hardened
# runtime, inside out and without --deep (which would stamp Topaz's
# entitlements on a helper): Loupe with its own entitlements, Topaz
# Launcher with none, then Topaz's other binaries, then the outer bundle
# with Topaz's. A stable signature keeps each permission (Topaz's
# microphone, each helper's Accessibility) across rebuilds; each helper
# keeps its bundle id and its designated requirement, which is checked
# against the installed copy, and after an install each app's report of the
# permissions macOS applies to it is checked (permissions).
# Signing reads the keychain, which an ssh login cannot, so run this in a
# window of the gate's tmux, for example:
#   /opt/homebrew/bin/tmux -L pi-gate new-window -d -t pi-gate-keep \
#     '~/Projects/topaz/topaz-build.sh --stage'
# Quitting Topaz ends the shells in its tabs, so an install started in a
# Topaz tab hands itself to a copy that outlives the tab and writes
# ~/Library/Caches/topaz-build/install.log (install_staged). The
# config goes in after the app because config_builder() rejects keys an
# older build does not know. Config: bbdaniels/personal, deploy/mac/wezterm.
# The helpers' tests (loupe/, LoupeTests, both helpers') must pass, or nothing is
# built or installed.
set -euo pipefail
cd "${0:A:h}"
export PATH="$HOME/.cargo/bin:$PATH" CARGO_NET_GIT_FETCH_WITH_CLI=true
STAGE=target/loupe/Loupe.app
APP=/Applications/Loupe.app
CONFIG_INSTALLER=$HOME/Projects/personal/deploy/mac/wezterm/install-wezterm.sh
IDENTITY="Loupe Dev"
# The helpers' source, and the last commit that changed it (HelpersCommit).
HELPERS_DIR=$PWD/helpers
HELPERS_COMMIT=$(git log -1 --format=%h -- helpers)
HELPERS_BUILD=/tmp/loupe-helpers-build
HUD_BUILT=$HELPERS_BUILD/Build/Products/Release/LoupeHUD.app
HUD_IN=Contents/Helpers/LoupeHUD.app
LAUNCHER_BUILT="$HELPERS_BUILD/Build/Products/Release/Loupe Launcher.app"
LAUNCHER_IN="Contents/Helpers/Loupe Launcher.app"
LOGS=$HOME/Library/Caches/loupe-build
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
mkdir -p $LOGS

# Test, then build Loupe and Topaz Launcher (Release) into $LOUPE_BUILT
# and $LAUNCHER_BUILT.
build_helpers() {
  ( cd $HELPERS_DIR
    xcodebuild test -scheme HelpersTests -destination platform=macOS -jobs 2 \
      > $LOGS/helpers-test.log 2>&1 || true
    /usr/bin/grep -E "Executed [0-9]+ tests" $LOGS/helpers-test.log | tail -1
    if ! /usr/bin/grep -q "\*\* TEST SUCCEEDED \*\*" $LOGS/helpers-test.log; then
      /usr/bin/grep -E "error:|failed" $LOGS/helpers-test.log | tail -20
      echo "The helpers' tests failed ($LOGS/helpers-test.log); nothing built." >&2
      exit 1
    fi
    nice -n 10 xcodebuild -scheme LoupeHUD -configuration Release \
      -derivedDataPath $HELPERS_BUILD -jobs 2 build > $LOGS/hud-build.log 2>&1 || true
    if ! /usr/bin/grep -q "\*\* BUILD SUCCEEDED \*\*" $LOGS/hud-build.log; then
      /usr/bin/grep -E " error:" $LOGS/hud-build.log | tail -20
      echo "LoupeHUD did not build ($LOGS/hud-build.log)." >&2
      exit 1
    fi
    nice -n 10 xcodebuild -scheme LoupeLauncher -configuration Release \
      -derivedDataPath $HELPERS_BUILD -jobs 2 build > $LOGS/launcher-build.log 2>&1 || true
    if ! /usr/bin/grep -q "\*\* BUILD SUCCEEDED \*\*" $LOGS/launcher-build.log; then
      /usr/bin/grep -E " error:" $LOGS/launcher-build.log | tail -20
      echo "Loupe Launcher did not build ($LOGS/launcher-build.log)." >&2
      exit 1
    fi )
}

# Copy the built Loupe into the app at $1 and sign it. It is signed in a
# scratch folder under its own name (codesign seals a folder not named .app
# as a plain directory), then moved in whole.
nest_hud() {
  local tmp=$(mktemp -d /tmp/loupe-hud.XXXXXX)
  ditto $HUD_BUILT $tmp/LoupeHUD.app
  codesign --force --options runtime --timestamp=none \
    --entitlements $HELPERS_DIR/LoupeHUD/Resources/LoupeHUD.entitlements \
    --sign $IDENTITY $tmp/LoupeHUD.app
  codesign --verify --strict $tmp/LoupeHUD.app
  mkdir -p $1/Contents/Helpers
  rm -rf $1/$HUD_IN
  mv $tmp/LoupeHUD.app $1/$HUD_IN
  rmdir $tmp
}
# The same for Topaz Launcher, which has no entitlements.
nest_launcher() {
  local tmp=$(mktemp -d /tmp/loupe-launcher.XXXXXX)
  ditto $LAUNCHER_BUILT "$tmp/Loupe Launcher.app"
  codesign --force --options runtime --timestamp=none \
    --sign $IDENTITY "$tmp/Loupe Launcher.app"
  codesign --verify --strict "$tmp/Loupe Launcher.app"
  mkdir -p $1/Contents/Helpers
  rm -rf $1/$LAUNCHER_IN
  mv "$tmp/Loupe Launcher.app" $1/$LAUNCHER_IN
  rmdir $tmp
}

# Sign Topaz's own binaries, then the outer bundle at $1.
sign_loupe() {
  local bin
  for bin in wezterm wezterm-mux-server strip-ansi-escapes; do
    codesign --force --options runtime --timestamp=none \
      --entitlements ci/macos-entitlement.plist --sign $IDENTITY $1/Contents/MacOS/$bin
  done
  codesign --force --options runtime --timestamp=none \
    --entitlements ci/macos-entitlement.plist --sign $IDENTITY $1
}

designated() {
  codesign -d -r- $1 2>&1 | /usr/bin/sed -n 's/^designated => //p'
}

# Every signature valid, and each helper's designated requirement the one
# its permission grants were made to: $2 (Loupe) and $3 (Topaz Launcher)
# if given, else that of the installed Topaz's copy, if it has one.
# TOPAZ_NEW_IDENTITY=1 reports a changed requirement and goes on, for the one
# build after the signing certificate is replaced (loupe/signing/README.md);
# every permission must then be granted again.
verify() {
  codesign --verify --deep --strict $1
  codesign --verify --deep --strict $1/$HUD_IN
  codesign --verify --deep --strict $1/$LAUNCHER_IN
  echo "Loupe:          $(designated $1)"
  echo "LoupeHUD:       $(designated $1/$HUD_IN)"
  echo "Loupe Launcher: $(designated $1/$LAUNCHER_IN)"
  local launcher_want=${3:-}
  if [[ -z $launcher_want && $1 != $APP && -d $APP/$LAUNCHER_IN ]]; then
    launcher_want=$(designated $APP/$LAUNCHER_IN)
  fi
  if [[ -n $launcher_want && $launcher_want != "$(designated $1/$LAUNCHER_IN)" ]]; then
    echo "Loupe Launcher's designated requirement is not $launcher_want: its grants would not carry over." >&2
    [[ ${LOUPE_NEW_IDENTITY:-} == 1 ]] || exit 1
  fi
  local want=${2:-}
  if [[ -z $want && $1 != $APP && -d $APP/$HUD_IN ]]; then
    want=$(designated $APP/$HUD_IN)
  fi
  if [[ -n $want && $want != "$(designated $1/$HUD_IN)" ]]; then
    echo "LoupeHUD's designated requirement is not $want: its grants would not carry over." >&2
    [[ ${LOUPE_NEW_IDENTITY:-} == 1 ]] || exit 1
  fi
}

# After an install, read each app's own report of the permissions macOS
# applies to it (Topaz: Accessibility, Input Monitoring, Microphone, in its
# log file; each helper: Accessibility, in the unified log), logged once at
# launch (dictation/everywhere.rs log_permissions, TopazKit
# PermissionReport). A grant made to an earlier signature stays listed in
# System Settings but is never applied, which is how the certificate change
# of 2026-11-08 left Topaz without Input Monitoring until 2026-11-10, so fn
# dictation heard no key outside Topaz. The apps ask macOS themselves
# because the permission databases cannot be read from the gate's tmux
# (no Full Disk Access). $1 is when the apps were (re)launched, as
# `log show --start` takes it; then any of topaz, loupe, launcher. Names
# each permission not applied, with its reset, and returns 1; also returns
# 1 when an app has not reported within 30 seconds.
permissions() {
  local since=$1 short=1 which name id file line service pid
  shift
  for which in $@; do
    case $which in
      loupe) name=Loupe id=com.bbdaniels.loupe ;;
      hud) name=LoupeHUD id=com.bbdaniels.loupe.hud ;;
      launcher) name="Loupe Launcher" id=com.bbdaniels.loupe.launcher ;;
    esac
    line=
    for _ in {1..15}; do
      if [[ $which == loupe ]]; then
        pid=$(pgrep -a -n -f $APP/Contents/MacOS/wezterm-gui || true)
        file=$HOME/.local/share/wezterm/wezterm-gui-log-$pid.txt
        [[ -n $pid && -f $file ]] && line=$(grep -o 'permissions: .*' $file | tail -1 || true)
      else
        line=$(/usr/bin/log show --start "$since" --style compact \
          --predicate "subsystem == \"$id\" AND category == \"Permissions\"" 2>/dev/null \
          | grep -o 'permissions: .*' | tail -1 || true)
      fi
      [[ -n $line ]] && break
      sleep 2
    done
    if [[ -z $line ]]; then
      echo "$name has not reported its permissions within 30 s of $since, so they are not checked." >&2
      short=0
      continue
    fi
    echo "$name: ${line#permissions: }"
    for service in ${=${line#permissions: }}; do
      [[ $service == *=no ]] || continue
      service=${service%=no}
      echo "$name does not have $service. If System Settings shows it on, the grant names an earlier signature: run tccutil reset $service $id and grant it again." >&2
      short=0
    done
  done
  (( short ))
}

# Whether this script runs inside Topaz: wezterm-gui is one of its ancestors.
inside_loupe() {
  local pid=$$ comm
  while (( pid > 1 )); do
    comm=$(ps -o comm= -p $pid) || return 1
    [[ $comm == */wezterm-gui ]] && return 0
    pid=$(( $(ps -o ppid= -p $pid) ))
  done
  return 1
}

install_staged() {
  verify $STAGE
  # 2026-11-17: run in a Topaz tab, the script died with the tab at the
  # quit below, before it had replaced the app, and nothing said so.
  if [[ -z ${LOUPE_INSTALL_DETACHED:-} ]] && inside_loupe; then
    mkdir -p $LOGS
    echo "Run in a Loupe tab, which closes when Loupe quits: the install goes on without it. Its log: $LOGS/install.log"
    LOUPE_INSTALL_DETACHED=1 nohup $PWD/loupe-build.sh --install > $LOGS/install.log 2>&1 < /dev/null &!
    exit 0
  fi
  osascript -e 'tell application "Loupe" to quit' 2>/dev/null || true
  for _ in {1..40}; do
    pgrep -aqf $APP/Contents/MacOS/wezterm-gui || break
    sleep 0.5
  done
  if pgrep -aqf $APP/Contents/MacOS/wezterm-gui; then
    echo "Loupe did not quit; nothing installed." >&2
    exit 1
  fi
  rm -rf $APP /Applications/WezTerm.app
  ditto $STAGE $APP
  # From here Topaz is reopened whatever else fails, so a failed config
  # install never leaves it closed; the failure is reported and returned.
  local failed=
  $LSREGISTER -f $APP || failed="lsregister"
  "$CONFIG_INSTALLER" || failed="${failed:+$failed, }the config installer ($CONFIG_INSTALLER)"
  local since=$(date '+%Y-%m-%d %H:%M:%S') applied=1
  open $APP
  echo "Installed $(/usr/libexec/PlistBuddy -c 'Print :LoupeCommit' $APP/Contents/Info.plist) to $APP and reopened it."
  permissions $since loupe hud launcher || applied=0
  if [[ -n $failed ]]; then
    echo "But $failed failed; Loupe is running on the config it had." >&2
    exit 1
  fi
  (( applied )) || exit 1
}

# Replace helper $1 (loupe, or hud, its old name; or launcher) inside the
# installed Topaz.app and have Topaz relaunch it.
install_helper() {
  local name inside
  case $1 in
    hud) name=LoupeHUD inside=$HUD_IN ;;
    launcher) name="Loupe Launcher" inside=$LAUNCHER_IN ;;
  esac
  [[ -d $APP/$inside ]] || { echo "$APP has no $inside; build and install Loupe first." >&2; exit 1; }
  # -a: macOS pgrep leaves out its own ancestors by default, and run from a
  # Topaz tab, Topaz is one of them.
  pgrep -aqf $APP/Contents/MacOS/wezterm-gui || { echo "Loupe is not running, so nothing would relaunch $name." >&2; exit 1; }
  local hud_want=$(designated $APP/$HUD_IN) launcher_want=
  [[ -d $APP/$LAUNCHER_IN ]] && launcher_want=$(designated $APP/$LAUNCHER_IN)
  build_helpers
  if [[ $name == LoupeHUD ]]; then nest_hud $APP; else nest_launcher $APP; fi
  sign_loupe $APP
  verify $APP "$hud_want" "$launcher_want"
  $LSREGISTER -f $APP/$inside
  local exe="$APP/$inside/Contents/MacOS/$name" old new since=$(date '+%Y-%m-%d %H:%M:%S')
  old=$(pgrep -f $exe || true)
  [[ -n $old ]] && kill -TERM ${(f)old}
  for _ in {1..40}; do
    new=$(pgrep -f $exe || true)
    [[ -n $new && $new != $old ]] && break
    sleep 0.5
  done
  if [[ -z $new || $new == $old ]]; then
    echo "Loupe has not relaunched $name after 20 s." >&2
    exit 1
  fi
  echo "$name $HELPERS_COMMIT is running inside $APP (pid $new)."
  permissions $since $1 || exit 1
}

case ${1:-} in
  --install) install_staged; exit 0 ;;
  --helper)
    [[ ${2:-} == (hud|launcher) ]] || { echo "usage: $0 --helper hud|launcher" >&2; exit 2; }
    install_helper $2; exit 0 ;;
  --update)
    git fetch -q upstream main
    git merge --no-edit upstream/main
    git submodule update --init --recursive -q
    rustup update stable ;;
esac

build_helpers

BINS=(wezterm wezterm-mux-server wezterm-gui strip-ansi-escapes)
PKGS=(); for b in $BINS; do PKGS+=(-p $b); done
nice -n 10 cargo build --release -j 2 $PKGS

rm -rf target/loupe && mkdir -p target/loupe
cp -R assets/macos/WezTerm.app $STAGE
PB=/usr/libexec/PlistBuddy
$PB -c "Set :CFBundleName Loupe" -c "Set :CFBundleDisplayName Loupe" \
    -c "Set :CFBundleIdentifier com.bbdaniels.loupe" \
    -c "Set :NSMicrophoneUsageDescription Loupe listens while you hold fn to dictate, and programs running in Loupe may ask to use the microphone." \
    -c "Add :LoupeCommit string $(git rev-parse --short HEAD)" \
    -c "Add :HelpersCommit string $HELPERS_COMMIT" \
    $STAGE/Contents/Info.plist
rm -f $STAGE/*.dylib
mkdir -p $STAGE/Contents/MacOS $STAGE/Contents/Resources
cp -R assets/shell-integration/* $STAGE/Contents/Resources
cp -R assets/shell-completion $STAGE/Contents/Resources
tic -xe wezterm -o $STAGE/Contents/Resources/terminfo termwiz/data/wezterm.terminfo
for bin in $BINS; do cp target/release/$bin $STAGE/Contents/MacOS/$bin; done
nest_hud $STAGE
nest_launcher $STAGE
sign_loupe $STAGE
verify $STAGE

if [[ ${1:-} == --stage ]]; then
  echo "Staged $(git rev-parse --short HEAD) at $PWD/$STAGE; install with ./loupe-build.sh --install."
  exit 0
fi
install_staged
