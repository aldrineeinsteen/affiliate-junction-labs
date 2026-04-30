#!/bin/bash

set -e

# ==============================================================================
# Affiliate Junction Labs Setup Script
#
# This script is for SINGLE VM systemd-based deployment on RHEL/Linux.
# For Kubernetes deployment, use one of these instead:
#   - ./setup\ 2.sh (IBM Cloud IKS with infrastructure provisioning)
#   - Manual deployment following docs/KUBERNETES_DEPLOYMENT.md
# ==============================================================================

# Detect OS
OS="$(uname -s)"
case "${OS}" in
    Linux*)     MACHINE=Linux;;
    Darwin*)    MACHINE=Mac;;
    *)          MACHINE="UNKNOWN:${OS}"
esac

if [ "$MACHINE" != "Linux" ]; then
    echo "================================================================================"
    echo "ERROR: This setup.sh is designed for Linux/RHEL with systemd"
    echo "================================================================================"
    echo ""
    echo "You are running on: $MACHINE"
    echo ""
    echo "For Kubernetes deployment on macOS/IBM Cloud, use one of these options:"
    echo ""
    echo "Option 1: Full IBM Cloud IKS deployment with infrastructure provisioning"
    echo "  ./setup\\ 2.sh --domain affiliate-junction \\"
    echo "                --mission-control-license \"YOUR_LICENSE\" \\"
    echo "                --phase all"
    echo ""
    echo "Option 2: Manual Kubernetes deployment (if infrastructure already exists)"
    echo "  1. Follow the guide: docs/KUBERNETES_DEPLOYMENT.md"
    echo "  2. Build container image: podman build -t affiliate-junction:v1.0.0 ."
    echo "  3. Deploy to K8s: kubectl apply -k k8s/overlays/affiliate-junction/"
    echo ""
    echo "Option 3: Local development (Python only, no systemd)"
    echo "  python3.11 -m venv .venv"
    echo "  source .venv/bin/activate"
    echo "  pip install -r requirements.txt"
    echo "  cp env-sample .env"
    echo "  # Edit .env with your database credentials"
    echo "  uvicorn web.main:app --reload --host 0.0.0.0 --port 10000"
    echo ""
    echo "================================================================================"
    exit 1
fi

# Check if systemd is available
if ! command -v systemctl &> /dev/null; then
    echo "ERROR: systemctl not found. This script requires systemd."
    echo "For Kubernetes deployment, use ./setup\\ 2.sh or follow docs/KUBERNETES_DEPLOYMENT.md"
    exit 1
fi

# Bootstrap infrastructure
sudo perl -i -pe 'if($.==1 && !/ibm-lh-presto-svc/){s/$/ ibm-lh-presto-svc/}' /etc/hosts
sudo dnf -y install java-17-openjdk java-17-openjdk-devel

# Bootstrap python environment
echo "Setup Python"
python3.11 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
echo "python setup done"

cp env-sample .env

git config --global user.email "you@example.com"
git config --global user.name "Your Name"

# Enable backend services
echo "Configuring systemctl"
sudo cp *.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable generate_traffic hcd_to_presto presto_to_hcd presto_insights presto_cleanup uvicorn.service truncate_all_tables.service
sudo systemctl start generate_traffic hcd_to_presto uvicorn.service
sleep 60 	# Wait for Presto DDL commands to complete
sudo systemctl start presto_to_hcd presto_insights presto_cleanup
echo "systemctl done"

# Add virtual environment activation to .bashrc if not already present
if ! grep -q "source $(pwd)/.venv/bin/activate" ~/.bashrc; then
    echo "source $(pwd)/.venv/bin/activate" >> ~/.bashrc
fi

echo ""
echo "================================================================================"
echo "Setup complete!"
echo "================================================================================"
echo ""
echo "Services are running via systemd. Check status with:"
echo "  sudo systemctl status uvicorn"
echo "  sudo systemctl status generate_traffic"
echo ""
echo "Access the web UI at: http://localhost:10000"
echo "Login: watsonx / watsonx.data"
echo ""
echo "================================================================================"

