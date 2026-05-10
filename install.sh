#!/bin/sh
set -e

VERSION="${1:-v0.8.0}"
REPO="connoranastasio/Ishiiruka-rocknix"

INSTALL_DIR="/storage/slippi-dolphin"
PORTS_DIR="/storage/roms/ports"

ASSET="slippi-dolphin-rocknix-aarch64-${VERSION}.tar.gz"
URL="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"

echo ""
echo "========================================"
echo " Slippi Dolphin ROCKNIX Installer"
echo " Version: ${VERSION}"
echo "========================================"
echo ""

echo "Downloading release bundle..."
echo "${URL}"

mkdir -p /storage
cd /storage

rm -f "${ASSET}"

curl -L "${URL}" -o "${ASSET}"

echo ""
echo "Removing previous install..."
rm -rf "${INSTALL_DIR}"

echo ""
echo "Extracting bundle..."
tar -xzf "${ASSET}" -C /storage

echo ""
echo "Fixing permissions..."

chmod +x "${INSTALL_DIR}/launch-slippi.sh" || true
chmod +x "${INSTALL_DIR}/dolphin-emu" || true
chmod +x "${INSTALL_DIR}/slippi-account" || true

echo ""
echo "Creating Ports launcher..."

mkdir -p "${PORTS_DIR}"

cat > "${PORTS_DIR}/Slippi Melee.sh" <<'INNER_EOF'
#!/bin/sh
/storage/slippi-dolphin/launch-slippi.sh
INNER_EOF

chmod +x "${PORTS_DIR}/Slippi Melee.sh"

sync

echo ""
echo "========================================"
echo " Installation complete"
echo "========================================"
echo ""
echo "Launch from:"
echo "Ports -> Slippi Melee"
echo ""
