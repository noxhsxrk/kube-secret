#!/bin/bash
# Installation script for k8sec

INSTALL_DIR="/usr/local/bin"
TOOL_NAME="k8sec"
CONFIG_DIR="$HOME/.k8sec"
GITHUB_RAW_URL="https://raw.githubusercontent.com/noxhsxrk/kube-secret/main/"

sudo mkdir -p "$INSTALL_DIR"
mkdir -p "$CONFIG_DIR"

echo "Downloading k8s-secret script..."
sudo curl -s "$GITHUB_RAW_URL/k8s-secret.sh" -o "$INSTALL_DIR/$TOOL_NAME"

if [ $? -ne 0 ]; then
    echo "Error: Failed to download the script. Please check your internet connection and the URL."
    exit 1
fi

if [ ! -s "$INSTALL_DIR/$TOOL_NAME" ]; then
    echo "Error: The downloaded file is empty. The URL may be incorrect."
    exit 1
fi

sudo chmod +x "$INSTALL_DIR/$TOOL_NAME"

echo "Installation complete!"
