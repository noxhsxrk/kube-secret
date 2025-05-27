#!/bin/bash

# Remove the existing installation
sudo rm -f /usr/local/bin/k8s-secret

# Download and run the installation script
curl -s https://raw.githubusercontent.com/noxhsxrk/k8s-secret/main/install.sh | bash -s --
