#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Meeting Recorder — Arch Linux Install ==="

# System deps
echo "Installing system dependencies..."
sudo pacman -S --needed --noconfirm \
    python python-pip python-gobject gtk3 \
    python-pystray libnotify \
    ffmpeg pipewire pipewire-pulse wireplumber \
    python-cairo

# gpu-screen-recorder (AUR — needed for screen recording)
if ! command -v gpu-screen-recorder &>/dev/null; then
    if command -v yay &>/dev/null; then
        echo "Installing gpu-screen-recorder from AUR..."
        yay -S --needed --noconfirm gpu-screen-recorder
    elif command -v paru &>/dev/null; then
        echo "Installing gpu-screen-recorder from AUR..."
        paru -S --needed --noconfirm gpu-screen-recorder
    else
        echo ""
        echo "gpu-screen-recorder not found and no AUR helper (yay/paru) available."
        echo "Install manually: yay -S gpu-screen-recorder"
        echo "(Screen recording will be disabled without it)"
    fi
fi

# Python deps via uv
INSTALL_DIR="$HOME/.local/share/meeting-recorder"
VENV_DIR="$INSTALL_DIR/.venv"

if ! command -v uv &>/dev/null; then
    echo "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi

SYSTEM_PYTHON="$(command -v python3)"
echo "Setting up Python environment with uv (using $SYSTEM_PYTHON)..."
uv venv "$VENV_DIR" --python "$SYSTEM_PYTHON" --system-site-packages --clear
uv pip install --python "$VENV_DIR/bin/python" "$REPO_DIR"

# Copy source
echo "Installing source files..."
rm -rf "$INSTALL_DIR/src"
cp -r "$REPO_DIR/src" "$INSTALL_DIR/src"

# Log dir
mkdir -p "$HOME/.local/share/meeting-recorder/logs"

# Launcher
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/meeting-recorder" << LAUNCHER
#!/usr/bin/env bash
export PYTHONPATH="$INSTALL_DIR/src"
exec "$VENV_DIR/bin/python" -m meeting_recorder "\$@"
LAUNCHER
chmod +x "$HOME/.local/bin/meeting-recorder"

# Desktop entry
mkdir -p "$HOME/.local/share/applications"
cat > "$HOME/.local/share/applications/meeting-recorder.desktop" << DESKTOP
[Desktop Entry]
Type=Application
Name=Meeting Recorder
Comment=Record, transcribe and summarize meetings
Exec=$HOME/.local/bin/meeting-recorder
Icon=$INSTALL_DIR/src/meeting_recorder/assets/icons/meeting-recorder.svg
Terminal=false
Categories=AudioVideo;Audio;Utility;
StartupNotify=false
DESKTOP

echo ""
echo "=== Installation complete ==="
echo "Run 'meeting-recorder' or find it in your application menu."

if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    echo ""
    echo "NOTE: Add ~/.local/bin to your PATH:"
    echo '  echo '\''export PATH="$HOME/.local/bin:$PATH"'\'' >> ~/.zshrc'
fi
