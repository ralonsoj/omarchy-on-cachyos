#!/bin/bash
set -e

# --- NVIDIA Configuration for Omarchy on CachyOS ---
# Detects GPU(s), delegates driver selection to CachyOS chwd, then configures
# the Wayland/Hyprland prerequisites:
#   - DRM kernel modeset (modprobe.d + early KMS in mkinitcpio)
#   - VA-API hardware video decode (libva-nvidia-driver)
#   - Optimus / hybrid laptops (nvidia-prime for PRIME render offload)
#   - UWSM env vars for Hyprland
# Idempotent: safe to re-run.

# Exit early if no NVIDIA GPU is present
if ! lspci -nn -d 10de: | grep -qE "VGA|3D"; then
    echo "[*] No NVIDIA GPU found. Skipping."
    exit 0
fi

GPU_NAME=$(lspci -d 10de: | grep -E "VGA|3D" | head -n1 | sed 's/.*: //')
echo "[*] NVIDIA GPU detected: $GPU_NAME"

# Detect Optimus / hybrid (NVIDIA + Intel/AMD iGPU on the same machine)
HYBRID=false
if lspci -nn | grep -E "VGA|3D|Display" | grep -qiE "Intel.*Graphics|AMD.*(Graphics|Radeon)|ATI.*(Graphics|Radeon)"; then
    HYBRID=true
    echo "[*] Hybrid (Optimus) configuration detected — iGPU + NVIDIA dGPU."
fi

# --- Driver installation (delegated to CachyOS chwd) -------------------------
# chwd auto-selects the right NVIDIA branch for the detected hardware:
#   nvidia / nvidia-open (current, Turing+ open kernel module)
#   nvidia-470xx        (Kepler legacy)
#   nvidia-390xx        (Fermi/Tesla legacy)
# plus matching hybrid profiles for Optimus laptops.
NVIDIA_DRIVER=$(pacman -Qq 2>/dev/null | grep -E '^nvidia(-open)?(-470xx|-390xx)?(-dkms)?$' | head -n1 || true)

if [[ -z "$NVIDIA_DRIVER" ]] && lsmod 2>/dev/null | grep -q '^nvidia'; then
    echo "[*] NVIDIA kernel module already loaded — assuming driver provided by CachyOS kernel package."
    NVIDIA_DRIVER="nvidia-dkms"
fi

if [[ -z "$NVIDIA_DRIVER" ]]; then
    echo "[!] No NVIDIA driver detected — running CachyOS chwd auto-detection..."
    sudo chwd -a || echo "[!] chwd returned non-zero; continuing."
    NVIDIA_DRIVER=$(pacman -Qq 2>/dev/null | grep -E '^nvidia(-open)?(-470xx|-390xx)?(-dkms)?$' | head -n1 || true)

    # Fallback: chwd db can lag behind newer / niche cards. Install the
    # current proprietary DKMS driver directly. Maxwell+ (Quadro M/P series,
    # GTX 9xx/10xx/16xx, RTX 20xx+) all use nvidia-dkms.
    if [[ -z "$NVIDIA_DRIVER" ]]; then
        echo "[!] chwd did not install a driver — falling back to pacman -S nvidia-dkms."
        sudo pacman -S --needed --noconfirm nvidia-dkms nvidia-utils
        NVIDIA_DRIVER=$(pacman -Qq 2>/dev/null | grep -E '^nvidia(-open)?(-470xx|-390xx)?(-dkms)?$' | head -n1 || true)
    fi

    if [[ -z "$NVIDIA_DRIVER" ]]; then
        echo "[!] Warning: still no NVIDIA driver installed."
        echo "    Run 'chwd -l' to inspect profiles, or install manually:"
        echo "      Kepler   → yay -S nvidia-470xx-dkms nvidia-470xx-utils"
        echo "      Fermi    → yay -S nvidia-390xx-dkms nvidia-390xx-utils"
        echo "      Maxwell+ → sudo pacman -S nvidia-dkms nvidia-utils"
    fi
fi

if [[ -n "$NVIDIA_DRIVER" ]]; then
    DRIVER_VERSION=$(pacman -Q "$NVIDIA_DRIVER" 2>/dev/null | awk '{print $2}')
    echo "[*] Active NVIDIA driver: $NVIDIA_DRIVER $DRIVER_VERSION"
fi

# Identify legacy branches (their modprobe options and feature support differ)
LEGACY_390=false
LEGACY_470=false
[[ "$NVIDIA_DRIVER" == *"390xx"* ]] && LEGACY_390=true
[[ "$NVIDIA_DRIVER" == *"470xx"* ]] && LEGACY_470=true

# --- Companion packages ------------------------------------------------------
PKGS_TO_INSTALL=(libva-utils)

# libva-nvidia-driver: NVDEC via VA-API for browser HW decode (Pascal+ only)
if ! $LEGACY_390 && ! $LEGACY_470; then
    PKGS_TO_INSTALL+=(libva-nvidia-driver)
fi

# nvidia-prime: provides `prime-run` for PRIME render offload on Optimus
if $HYBRID; then
    PKGS_TO_INSTALL+=(nvidia-prime)
fi

sudo pacman -S --needed --noconfirm "${PKGS_TO_INSTALL[@]}"

# --- /etc/modprobe.d/nvidia.conf (DRM modeset + suspend/resume stability) ----
MODPROBE_CONF=/etc/modprobe.d/nvidia.conf
NEED_INITRAMFS_REGEN=0

if ! sudo grep -q "modeset=1" "$MODPROBE_CONF" 2>/dev/null; then
    echo "[*] Writing $MODPROBE_CONF"
    if $LEGACY_390; then
        # 390xx lacks fbdev support and does not need PreserveVideoMemoryAllocations
        echo "options nvidia-drm modeset=1" | sudo tee "$MODPROBE_CONF" > /dev/null
    else
        sudo tee "$MODPROBE_CONF" > /dev/null <<'EOF'
options nvidia-drm modeset=1 fbdev=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
EOF
    fi
    NEED_INITRAMFS_REGEN=1
else
    echo "[*] $MODPROBE_CONF already configured."
fi

# --- mkinitcpio MODULES (early KMS so the kernel takes over before SDDM) -----
if ! grep -qE '^MODULES=.*nvidia' /etc/mkinitcpio.conf; then
    echo "[*] Adding nvidia modules to /etc/mkinitcpio.conf MODULES"
    sudo sed -i -E 's/^MODULES=\((.*)\)/MODULES=(\1 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
    # Strip the leading space that creeps in when MODULES was previously empty
    sudo sed -i 's/^MODULES=( /MODULES=(/' /etc/mkinitcpio.conf
    NEED_INITRAMFS_REGEN=1
else
    echo "[*] mkinitcpio.conf already includes nvidia modules."
fi

# Regenerate the initramfs only if something actually changed
if [[ "$NEED_INITRAMFS_REGEN" == 1 ]]; then
    echo "[*] Regenerating initramfs (mkinitcpio -P)..."
    sudo mkinitcpio -P
fi

# --- UWSM env vars for Hyprland ----------------------------------------------
mkdir -p "$HOME/.config/uwsm"
ENV_FILE="$HOME/.config/uwsm/env"

if ! grep -q "LIBVA_DRIVER_NAME=nvidia" "$ENV_FILE" 2>/dev/null; then
    if $HYBRID; then
        # Optimus: keep iGPU as primary display; reach NVIDIA via `prime-run`.
        # Do NOT set GBM_BACKEND/__GLX_VENDOR_LIBRARY_NAME globally — that would
        # force every GL/Wayland client onto the dGPU and defeat the iGPU-primary setup.
        cat >> "$ENV_FILE" <<'EOF'

# NVIDIA (Optimus / hybrid) — iGPU drives the display, dGPU on demand.
# Use `prime-run <app>` to launch a specific app on the NVIDIA GPU.
# Uncomment and adjust WLR_DRM_DEVICES if Hyprland picks the wrong card at startup.
# export WLR_DRM_DEVICES=/dev/dri/card1
export LIBVA_DRIVER_NAME=nvidia
export NVD_BACKEND=direct
export MOZ_DISABLE_RDD_SANDBOX=1
EOF
        echo "[*] Optimus env vars written to $ENV_FILE"
        echo "[*] Tip: run apps on the NVIDIA dGPU with 'prime-run <app>'."
    else
        cat >> "$ENV_FILE" <<'EOF'

# NVIDIA (dGPU only)
export LIBVA_DRIVER_NAME=nvidia
export GBM_BACKEND=nvidia-drm
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export NVD_BACKEND=direct
export MOZ_DISABLE_RDD_SANDBOX=1
export CUDA_DISABLE_PERF_BOOST=1
EOF
        echo "[*] dGPU env vars written to $ENV_FILE"
    fi
else
    echo "[*] NVIDIA env vars already present in $ENV_FILE."
fi

echo "[*] NVIDIA configuration complete."
