#!/bin/bash
# A throwaway macOS 26 virtual machine (Tart, Apple Virtualization) for end-to-end tests that need real input: keys through the
# window server, real input methods, menus, drag and drop, system sheets. Everything happens on the VM's own desktop, so the
# user's desktop, focus, clipboard and files are never touched. Drive it with Scripts/vm/vmdo (VNC: keys, clicks, screenshots).
#
#   Scripts/vm/vm.sh up         start the VM headless (no window on the host), wait for its desktop; prints the VNC address
#   Scripts/vm/vm.sh install    copy the Debug build (`make app`) into the VM as ~/Applications/MacDown2.app
#   Scripts/vm/vm.sh exec CMD   run a shell command inside the VM as its user (ssh with a key made for this VM only)
#   Scripts/vm/vm.sh down       stop the VM
#   Scripts/vm/vm.sh reset      throw the VM's disk away and start again from the pulled image (fresh user, no state)
#
# One-time setup: Tart (https://github.com/cirruslabs/tart; the notarized release, e.g. in ~/Applications/tart.app) and the image,
# `tart pull ghcr.io/cirruslabs/macos-tahoe-vanilla:latest --concurrency 16` (24 GB; user admin / admin).
# Env: MD2_VM (VM name, default md2-test; each name has its own state in build/vm/<name>/), MACDOWN2_APP (the app to install).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
VM="${MD2_VM:-md2-test}"
IMAGE="ghcr.io/cirruslabs/macos-tahoe-vanilla:latest"
STATE="$ROOT_DIR/build/vm/$VM"
APP="${MACDOWN2_APP:-$ROOT_DIR/build/DerivedData/Build/Products/Debug/MacDown2.app}"
KEY="$STATE/id_ed25519"
# The VM's host key changes with every reset or reused address: none is remembered. The VM's own key only (an agent with many
# keys would use up the server's tries first); no connection sharing from the user's ssh config.
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR
          -o ControlMaster=no -o ControlPath=none -o IdentitiesOnly=yes)

die() { echo "vm: $*" >&2; exit 1; }
usage() { sed -n '2,14p' "$0"; exit 2; }
case "${1:-}" in up|install|exec|down|reset) ;; *) usage ;; esac
command -v tart >/dev/null || die "tart is not installed (see Scripts/vm/vm.sh's header)"
mkdir -p "$STATE"

state() { tart list --format json | python3 -c "import json,sys; print(next((v['State'] for v in json.load(sys.stdin) if v['Name'] == '$VM'), ''))"; }
ip() { tart ip "$VM"; }
in_vm() { ssh "${SSH_OPTS[@]}" -i "$KEY" -o BatchMode=yes "admin@$(ip)" "/bin/bash -lc $(printf '%q' "$1")"; }

# The image's account is admin / admin: the password is used once, to install a key that exists only in build/vm/<name>/.
authorize() {
  [ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -C md2-vm -f "$KEY"
  in_vm true 2>/dev/null && return 0
  printf '#!/bin/sh\necho admin\n' > "$STATE/askpass"; chmod +x "$STATE/askpass"
  SSH_ASKPASS="$STATE/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=none ssh "${SSH_OPTS[@]}" -o PubkeyAuthentication=no "admin@$(ip)" \
    'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys' < "$KEY.pub" 2>/dev/null || return 1
  in_vm true 2>/dev/null
}

start() {
  rm -f "$STATE/run.log" "$STATE/vnc"
  # Headless, with Virtualization.framework's own VNC server; no clipboard sharing (the host clipboard stays the user's), no audio,
  # no shared folder (the VM sees nothing of the host's disk; builds go in over ssh). In a session of its own: the VM must
  # outlive the shell (and process group) that started it.
  python3 -c 'import os, sys
if os.fork() == 0:
    os.setsid()
    log = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    os.dup2(os.open(os.devnull, os.O_RDONLY), 0); os.dup2(log, 1); os.dup2(log, 2)
    os.execvp("tart", sys.argv[2:])' "$STATE/run.log" tart run "$VM" --no-graphics --vnc-experimental --no-audio --no-clipboard
}

up() {
  [ -n "$(state)" ] || tart clone "$IMAGE" "$VM"
  # The VNC address is only in the log of the run that started the VM: a VM running without one (started by hand, or the build
  # folder was cleaned) is restarted, so the address is known.
  if [ "$(state)" = running ] && ! grep -qE 'vnc://' "$STATE/run.log" 2>/dev/null; then tart stop "$VM"; fi
  [ "$(state)" = running ] || start
  local url=""
  for n in $(seq 1 120); do
    url="$(grep -Eo 'vnc://[^ ]+' "$STATE/run.log" 2>/dev/null | tail -1 || true)"
    [ -n "$url" ] && ip >/dev/null 2>&1 && authorize && break
    # tart takes a few seconds to report the VM as running; after that, not running means the run failed
    [ "$n" -lt 10 ] || [ "$(state)" = running ] || { cat "$STATE/run.log" >&2 2>/dev/null || true; die "tart run stopped (log above)"; }
    sleep 2
  done
  [ -n "$url" ] || die "no VNC address in $STATE/run.log"
  in_vm true || die "the VM does not answer over ssh"
  # ssh answers before the desktop is up (the boot screen is still showing): wait for the logged-in user's Finder.
  for _ in $(seq 1 90); do in_vm 'pgrep -x Finder >/dev/null' && break; sleep 2; done
  in_vm 'pgrep -x Finder >/dev/null' || die "the VM's desktop did not come up"
  sleep 3
  echo "$url" > "$STATE/vnc"
  echo "VM=$VM"
  echo "VNC=$url"
}

install_app() {
  [ "$(state)" = running ] || die "the VM is not running (Scripts/vm/vm.sh up)"
  [ -d "$APP" ] || die "no app at $APP (make app)"
  # The tests drive it through its control socket, which only a Debug build has (as Scripts/run-isolated.sh checks).
  [ "$(/usr/libexec/PlistBuddy -c 'Print :MacDown2IsolationSupported' "$APP/Contents/Info.plist" 2>/dev/null || true)" = YES ] \
    || die "$APP is not a Debug build with isolation support"
  in_vm 'pkill -x MacDown2 || true; rm -rf ~/Applications/MacDown2.app ~/Applications/.md2-install && mkdir -p ~/Applications/.md2-install'
  # A tar stream keeps the bundle's symbolic links; whatever the bundle is called here, it is MacDown2.app in the VM.
  tar -C "$(dirname "$APP")" -cf - "$(basename "$APP")" | ssh "${SSH_OPTS[@]}" -i "$KEY" -o BatchMode=yes "admin@$(ip)" 'tar -xf - -C ~/Applications/.md2-install'
  in_vm 'mv ~/Applications/.md2-install/*.app ~/Applications/MacDown2.app && rmdir ~/Applications/.md2-install && xattr -cr ~/Applications/MacDown2.app &&
         /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/MacDown2.app &&
         echo installed: build $(defaults read ~/Applications/MacDown2.app/Contents/Info.plist CFBundleVersion)'
}

case "$1" in
  up) up ;;
  install) install_app ;;
  exec) shift; in_vm "$*" ;;
  down) tart stop "$VM" 2>/dev/null || true; rm -f "$STATE/vnc" ;;
  reset) tart stop "$VM" 2>/dev/null || true; tart delete "$VM" 2>/dev/null || true; up ;;
esac
