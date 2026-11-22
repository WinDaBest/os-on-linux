#!/bin/sh

set -eu

say() { printf '%s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---- Privilege handling ----
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif have sudo; then
  SUDO="sudo"
else
  die "Run as root or install sudo."
fi

# ---- OS and architecture check ----
OS_KERNEL="$(uname -s)"
ARCH="$(uname -m)"
DISTRO_ID=""
DISTRO_LIKE=""
DISTRO_NAME="unknown"

case "$OS_KERNEL" in
  Linux)
    [ -r /etc/os-release ] || die "Cannot read /etc/os-release; unsupported Linux distribution."
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-}"
    DISTRO_LIKE="${ID_LIKE:-}"
    DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"
    ;;
  Darwin)
    DISTRO_NAME="macOS $(sw_vers -productVersion 2>/dev/null || echo '')"
    ;;
  *)
    die "Unsupported OS: $OS_KERNEL. On Windows, use the installer from virtualbox.org or broadcom.com."
    ;;
esac

case "$ARCH" in
  x86_64|amd64) ;;
  arm64|aarch64)
    say "Warning: $ARCH detected. Support for VirtualBox, VMware, and Waydroid varies on ARM hosts. Continuing."
    ;;
  *) die "Unsupported architecture: $ARCH" ;;
esac

say "Detected: $DISTRO_NAME ($ARCH)"

# ---- Selection ----
say ""
say "Select software to install:"
say "  1) VirtualBox"
say "  2) VMware (Workstation/Player on Linux, Fusion on macOS)"
say "  3) Waydroid (Android in a container, Linux only)"
printf 'Choice [1-3]: '
read -r choice
case "$choice" in
  1) TARGET="virtualbox" ;;
  2) TARGET="vmware" ;;
  3) TARGET="waydroid" ;;
  *) die "Invalid choice: $choice" ;;
esac

if [ "$TARGET" = "waydroid" ] && [ "$OS_KERNEL" != "Linux" ]; then
  die "Waydroid requires a Linux host with a Linux kernel. It cannot run on macOS or Windows. Use VirtualBox or VMware with an Android-x86 VM instead."
fi

is_debian_like() { case "$DISTRO_ID $DISTRO_LIKE" in *debian*|*ubuntu*) return 0 ;; esac; return 1; }
is_fedora_like() { case "$DISTRO_ID $DISTRO_LIKE" in *fedora*|*rhel*|*centos*) return 0 ;; esac; return 1; }
is_arch_like()   { case "$DISTRO_ID $DISTRO_LIKE" in *arch*) return 0 ;; esac; return 1; }
is_suse_like()   { case "$DISTRO_ID $DISTRO_LIKE" in *suse*) return 0 ;; esac; return 1; }

# ---- Already installed? ----
already_installed() {
  case "$OS_KERNEL:$TARGET" in
    Linux:virtualbox)   have VBoxManage ;;
    Darwin:virtualbox)  have VBoxManage ;;
    Linux:vmware)       have vmplayer || have vmware || [ -x /usr/lib/vmware/bin/vmware ] ;;
    Darwin:vmware)      [ -d "/Applications/VMware Fusion.app" ] ;;
    Linux:waydroid)     have waydroid ;;
    *) return 1 ;;
  esac
}

if already_installed; then
  say "$TARGET is already installed. Nothing to do."
  exit 0
fi

# ---- Kernel headers (needed by VMware and VirtualBox kernel modules) ----
install_kernel_headers_linux() {
  KVER="$(uname -r)"
  if [ -d "/lib/modules/$KVER/build" ] || [ -d "/usr/src/kernels/$KVER" ]; then
    say "Kernel headers for $KVER already present."
    return 0
  fi

  say "Installing kernel headers and build tools for $KVER..."
  if is_fedora_like; then
    if ! $SUDO dnf install -y "kernel-devel-$KVER" kernel-headers gcc make elfutils-libelf-devel; then
      say "Could not install kernel-devel-$KVER. This usually means the kernel was updated but not yet rebooted."
      say "Installing the latest kernel-devel instead. Reboot after this script finishes, then run it again."
      $SUDO dnf install -y kernel-devel kernel-headers gcc make elfutils-libelf-devel
    fi
  elif is_debian_like; then
    if ! $SUDO apt-get install -y "linux-headers-$KVER" build-essential; then
      say "linux-headers-$KVER not found. Installing the generic headers instead."
      $SUDO apt-get install -y linux-headers-generic build-essential
    fi
  elif is_arch_like; then
    $SUDO pacman -S --needed --noconfirm linux-headers base-devel
  elif is_suse_like; then
    $SUDO zypper --non-interactive install kernel-default-devel gcc make
  else
    die "Unsupported distribution for automatic header install: $DISTRO_NAME. Install the kernel headers for $KVER manually."
  fi

  if [ -d "/lib/modules/$KVER/build" ] || [ -d "/usr/src/kernels/$KVER" ]; then
    say "Kernel headers installed."
  else
    say "Warning: headers for $KVER are still not found. If you just updated the kernel, reboot and run this script again."
  fi
  say "If VMware's installer still asks for a location, use /usr/src/kernels/$KVER (Fedora) or /lib/modules/$KVER/build."
}

# ---- Installers ----
install_virtualbox_linux() {
  if is_debian_like; then
    $SUDO apt-get update
    $SUDO apt-get install -y virtualbox
  elif is_fedora_like; then
    say "Note: VirtualBox on Fedora/RHEL requires the RPM Fusion repository."
    $SUDO dnf install -y VirtualBox
  elif is_arch_like; then
    $SUDO pacman -S --needed --noconfirm virtualbox
    say "On Arch, if the kernel modules fail to load, also install virtualbox-host-modules-arch (or virtualbox-host-dkms)."
  elif is_suse_like; then
    $SUDO zypper --non-interactive install virtualbox
  else
    die "Unsupported Linux distribution for automatic VirtualBox install: $DISTRO_NAME. Install from virtualbox.org."
  fi
}

install_vmware_linux() {
  install_kernel_headers_linux

  say ""
  say "VMware Workstation Pro or Player for Linux is not in standard distro repositories."
  say "Download the installer from https://www.broadcom.com/products/software/vmware-workstation-player"
  printf 'Path to the downloaded installer (.bundle, .deb or .rpm): '
  read -r pkg
  [ -f "$pkg" ] || die "File not found: $pkg"
  case "$pkg" in
    *.bundle)
      $SUDO sh "$pkg" --console --eulas-agreed --required ;;
    *.deb)
      if is_debian_like; then
        $SUDO apt-get install -y "$(cd "$(dirname "$pkg")" && pwd)/$(basename "$pkg")"
      else
        die "A .deb installer needs a Debian/Ubuntu system."
      fi ;;
    *.rpm)
      if is_fedora_like; then
        $SUDO dnf install -y "$pkg"
      elif is_suse_like; then
        $SUDO zypper --non-interactive install "$pkg"
      else
        die "An .rpm installer needs a Fedora/RHEL or openSUSE system."
      fi ;;
    *) die "Unrecognized installer type: $pkg" ;;
  esac

  # Build and load the VMware kernel modules against the installed headers.
  if [ -x /usr/bin/vmware-modconfig ]; then
    say "Building VMware kernel modules..."
    $SUDO /usr/bin/vmware-modconfig --console --install-all || \
      say "Warning: module build failed. Check the errors above. Newer kernels may need updated VMware modules."
  fi
}

install_virtualbox_macos() {
  have brew || die "Homebrew is required. Install it from https://brew.sh, or download VirtualBox from virtualbox.org."
  brew install --cask virtualbox
}

install_vmware_macos() {
  have brew || die "Homebrew is required, or download VMware Fusion from broadcom.com."
  brew install --cask vmware-fusion || {
    say "Homebrew install failed. Download VMware Fusion from https://www.broadcom.com/products/software/vmware-fusion"
    exit 1
  }
}

install_waydroid_linux() {
  if is_debian_like; then
    $SUDO apt-get update
    $SUDO apt-get install -y waydroid
  elif is_fedora_like; then
    $SUDO dnf install -y waydroid
  elif is_arch_like; then
    $SUDO pacman -S --needed --noconfirm waydroid
  elif is_suse_like; then
    $SUDO zypper --non-interactive install waydroid
  else
    die "Unsupported Linux distribution for automatic Waydroid install: $DISTRO_NAME. See https://docs.waydro.id"
  fi

  # The container service runs Waydroid in the background.
  if have systemctl; then
    $SUDO systemctl enable --now waydroid-container.service || \
      say "Warning: could not start waydroid-container.service. Check that the Waydroid package installed correctly."
  fi
}

check_binder_linux() {
  # Waydroid needs binder support in the kernel.
  if [ -e /dev/binder ] || [ -e /dev/binderfs/binder ] || [ -d /dev/binderfs ]; then
    say "Binder support detected."
  else
    say "Warning: no binder device found. Waydroid needs binder support in the kernel."
    say "Ubuntu and Debian kernels usually include it. On other kernels, check that CONFIG_ANDROID_BINDER_IPC is enabled, or try: sudo modprobe binder_linux"
  fi
}

# ---- Run install ----
say "Installing $TARGET..."
case "$OS_KERNEL:$TARGET" in
  Linux:virtualbox)   install_virtualbox_linux ;;
  Linux:vmware)       install_vmware_linux ;;
  Linux:waydroid)     check_binder_linux; install_waydroid_linux ;;
  Darwin:virtualbox)  install_virtualbox_macos ;;
  Darwin:vmware)      install_vmware_macos ;;
esac

# ---- Verify ----
if already_installed; then
  say "$TARGET installed successfully."
else
  say "Install finished, but $TARGET was not detected. Check the output above, or reboot and try again."
  exit 1
fi

# VirtualBox on Linux needs your user in the vboxusers group for USB and some features.
if [ "$TARGET" = "virtualbox" ] && [ "$OS_KERNEL" = "Linux" ]; then
  if getent group vboxusers >/dev/null 2>&1; then
    $SUDO usermod -aG vboxusers "${SUDO_USER:-$(id -un)}" || true
    say "Added your user to the vboxusers group. Log out and back in for it to take effect."
  fi
fi

if [ "$TARGET" = "waydroid" ]; then
  say ""
  say "Next steps for Waydroid:"
  say "  1. Run: sudo waydroid init   (downloads the Android image, needs internet)"
  say "  2. Run: waydroid session start   (from a graphical session)"
  say "  3. Run: waydroid show-full-ui   (opens the Android screen)"
fi

say "Done."
