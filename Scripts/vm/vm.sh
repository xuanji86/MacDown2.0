#!/bin/bash
# A throwaway macOS 26 virtual machine (Tart, Apple Virtualization) for end-to-end tests that need real input: keys through the
# window server, real input methods, menus, drag and drop, system sheets. Everything happens on the VM's own desktop, so the
# user's desktop, focus, clipboard and files are never touched. Drive it with Scripts/vm/vmdo (VNC: keys, clicks, screenshots).
#
#   Scripts/vm/vm.sh up         start the VM headless (no window on the host), wait until it answers; prints the VNC address
#   Scripts/vm/vm.sh install    copy the Debug build (`make app`) into the VM's ~/Applications and clear its quarantine
#   Scripts/vm/vm.sh exec CMD   run a shell command inside the VM as its user (ssh with a key made for this VM only)
#   Scripts/vm/vm.sh down       stop the VM
#   Scripts/vm/vm.sh reset      throw the VM's disk away and start again from the pulled image (fresh user, no state)
#
# One-time setup: Tart (https://github.com/cirruslabs/tart, notarized release in ~/Applications/tart.app) and the image,
# pulled on first `up` (~25 GB): ghcr.io/cirruslabs/macos-tahoe-vanilla (user admin / admin).
# Env: MD2_VM (VM name, default md2-test), MACDOWN2_APP (the app to install, default the Debug build).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
VM="${MD2_VM:-md2-test}"
IMAGE="ghcr.io/cirruslabs/macos-tahoe-vanilla:latest"
STATE="$ROOT_DIR/build/vm"
APP="${MACDOWN2_APP:-$ROOT_DIR/build/DerivedData/Build/Products/Debug/MacDown2.app}"
mkdir -p "$STATE"

die() { echo "vm: $*" >&2; exit 1; }
command -v tart >/dev/null || die "tart is not installed (see the header of this script)"
exists() { tart list --format json | python3 -c "import json,sys; sys.exit(0 if any(v['Name'] == '$VM' for v in json.load(sys.stdin)) else 1)"; }
running() { [ "$(tart list --format json | python3 -c "import json,sys; print(next((v['State'] for v in json.load(sys.stdin) if v['Name'] == '$VM'), ''))")" = running ]; }
KEY="$STATE/id_ed25519"
ssh_opts() { echo -o StrictHostKeyChecking=no -o UserKnownHostsFile="$STATE/known_hosts" -o ConnectTimeout=5 -o LogLevel=ERROR -o ControlMaster=no -o ControlPath=none; }
in_vm() { ssh $(ssh_opts) -i "$KEY" -o BatchMode=yes "admin@$(tart ip "$VM")" "/bin/bash -lc $(printf '%q' "$1")"; }

# The image's account is admin / admin: the password is used once, to install a key that exists only in build/vm/.
authorize() {
  [ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -C md2-vm -f "$KEY"
  in_vm true 2>/dev/null && return 0
  printf '#!/bin/sh\necho admin\n' > "$STATE/askpass"; chmod +x "$STATE/askpass"
  SSH_ASKPASS="$STATE/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=none ssh $(ssh_opts) -o PubkeyAuthentication=no "admin@$(tart ip "$VM")" \
    'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys' < "$KEY.pub"
}

up() {
  exists || tart clone "$IMAGE" "$VM"
  if ! running; then
    # Headless, with Virtualization.framework's own VNC server; no clipboard sharing (the host clipboard stays the user's), no audio.
    # No shared folder: the VM sees nothing of the host's disk; builds go in over ssh.
    # In a session of its own: the VM must outlive the shell (and process group) that started it.
    python3 -c 'import os, sys
if os.fork() == 0:
    os.setsid()
    log = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    os.dup2(os.open(os.devnull, os.O_RDONLY), 0); os.dup2(log, 1); os.dup2(log, 2)
    os.execvp("tart", sys.argv[2:])' "$STATE/run.log" tart run "$VM" --no-graphics --vnc-experimental --no-audio --no-clipboard
  fi
  for _ in $(seq 1 180); do
    url="$(grep -Eo 'vnc://[^ ]+' "$STATE/run.log" | tail -1 || true)"
    [ -n "$url" ] && tart ip "$VM" >/dev/null 2>&1 && authorize 2>/dev/null && break
    sleep 2
  done
  [ -n "${url:-}" ] || die "no VNC address in $STATE/run.log"
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
  running || die "the VM is not running (Scripts/vm/vm.sh up)"
  [ -d "$APP" ] || die "no app at $APP (make app)"
  in_vm 'pkill -x MacDown2 || true; mkdir -p ~/Applications && rm -rf ~/Applications/MacDown2.app'
  # A tar stream keeps the bundle's symbolic links (a virtiofs share does not follow them).
  tar -C "$(dirname "$APP")" -cf - "$(basename "$APP")" | ssh $(ssh_opts) -i "$KEY" -o BatchMode=yes "admin@$(tart ip "$VM")" 'tar -xf - -C ~/Applications'
  in_vm '[ -d ~/Applications/MacDown2.app ] && xattr -cr ~/Applications/MacDown2.app &&
         /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/MacDown2.app &&
         echo installed: $(defaults read ~/Applications/MacDown2.app/Contents/Info.plist CFBundleVersion)'
}

case "${1:-}" in
  up) up ;;
  install) install_app ;;
  exec) shift; in_vm "$*" ;;
  down) tart stop "$VM" 2>/dev/null || true; rm -f "$STATE/vnc" ;;
  reset) tart stop "$VM" 2>/dev/null || true; tart delete "$VM" 2>/dev/null || true; rm -f "$STATE/vnc"; up ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
