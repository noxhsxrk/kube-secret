#!/bin/bash

INSTALL_DIR="/usr/local/bin"
# Remove the existing installation
sudo rm -f "$INSTALL_DIR/k8sec"

# Download and run the installation script
sudo curl -s "https://raw.githubusercontent.com/noxhsxrk/kube-secret/main/k8sec.sh" -o "$INSTALL_DIR/k8sec"

# Make the script executable
sudo chmod +x "$INSTALL_DIR/k8sec"

echo "k8sec has been updated successfully!"
