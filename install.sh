#!/bin/bash

# Install Cortland.app to Applications, and bring an existing agent-status
# integration along with it. ./build-app.sh && ./install.sh is the whole
# from-source upgrade: no follow-up script to remember.

set -e

APP_NAME="Cortland.app"
BUILD_DIR="build"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -d "${BUILD_DIR}/${APP_NAME}" ]; then
    echo "❌ ${APP_NAME} not found. Run ./build-app.sh first."
    exit 1
fi

echo "🚀 Installing Cortland to Applications..."

# Check if Cortland is running
if pgrep -x "Cortland" > /dev/null; then
    echo "⚠️  Cortland is currently running. Please quit it first."
    read -p "   Kill Cortland now? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        killall Cortland 2>/dev/null || true
        sleep 1
    else
        echo "❌ Installation cancelled. Please quit Cortland and try again."
        exit 1
    fi
fi

# Remove existing installation if present (sudo only when a previous
# install is root-owned).
if [ -d "/Applications/${APP_NAME}" ]; then
    echo "📦 Removing existing Cortland installation..."
    rm -rf "/Applications/${APP_NAME}" 2>/dev/null || sudo rm -rf "/Applications/${APP_NAME}"
fi

# Copy to Applications. ditto, not cp: Sparkle.framework is a versioned bundle
# held together by symlinks, and cp -r follows them into real copies, which
# breaks the framework's code signature and kills the app at launch.
ditto "${BUILD_DIR}/${APP_NAME}" "/Applications/${APP_NAME}" 2>/dev/null || sudo ditto "${BUILD_DIR}/${APP_NAME}" "/Applications/${APP_NAME}"

echo "✅ Cortland installed to /Applications/"

# Optionally install CLI tools
read -p "📦 Install CLI tools to /usr/local/bin? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    if [ ! -d /usr/local/bin ]; then
        echo "📁 Creating /usr/local/bin..."
        sudo mkdir -p /usr/local/bin
    fi
    sudo ln -sf "/Applications/${APP_NAME}/Contents/MacOS/cortland-ctl" /usr/local/bin/cortland-ctl
    sudo ln -sf "/Applications/${APP_NAME}/Contents/MacOS/cortland-agent-status" /usr/local/bin/cortland-agent-status
    # The pre-rename symlinks point into a bundle that may not exist any more.
    # Only symlinks, and only the two names we created.
    for stale in /usr/local/bin/sidekick-ctl /usr/local/bin/sidekick-agent-status; do
        if [ -L "$stale" ]; then
            sudo rm -f "$stale"
        fi
    done
    echo "✅ CLI tools installed"
fi

# Refresh the agent-status integration — the ~/.local/bin helpers, the
# cortland-panes skill, and the hook entries in ~/.claude/settings.json and
# ~/.codex/config.toml. The installer script does the work (and the opt-in
# detection): if this machine never opted in it changes nothing and just prints
# how to. --binaries-from points it at the app we just installed, so it copies
# those exact binaries instead of kicking off a second release build.
echo ""
echo "🔄 Refreshing agent integration..."
if ! "${REPO_DIR}/scripts/install-agent-status-hooks" \
        --refresh-only \
        --binaries-from "/Applications/${APP_NAME}/Contents/MacOS"; then
    # A refresh failure is not an install failure: the app is in /Applications
    # either way, and it self-heals these same files on launch.
    echo "⚠️  Could not refresh the agent integration. Cortland is installed; run"
    echo "    scripts/install-agent-status-hooks by hand to see what went wrong."
fi

echo ""
echo "🎉 Installation complete!"
if [ -d "/Applications/Sidekick.app" ]; then
    echo ""
    echo "ℹ️  /Applications/Sidekick.app is the pre-rename app. Your settings were"
    echo "    copied to ~/.config/cortland on first launch; delete it when ready."
fi
echo ""
echo "To run:"
echo "  - Launch from Applications folder"
echo "  - Or: open /Applications/${APP_NAME}"
echo "  - CLI: cortland-ctl ping"
echo "  - Agent hooks: cortland-agent-status busy"
