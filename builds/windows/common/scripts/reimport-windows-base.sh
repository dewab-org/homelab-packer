#!/usr/bin/env bash
# Re-create a Windows cloud-base template from its vendor evaluation image.
#
# Run from the repo root on the workstation (needs Vault env + ssh to the node):
#   builds/windows/common/scripts/reimport-windows-base.sh 2022
#   builds/windows/common/scripts/reimport-windows-base.sh 2025
#   builds/windows/common/scripts/reimport-windows-base.sh both
#
# The base templates are deliberately NOT kept around: each is ~10GB of a
# 338GB thin pool and only exists so `packer build` can clone without
# re-importing the VHD. The vendor images stay on the ISO store, so recreating
# a base is a ~5 minute import rather than a re-download.
#
# This wrapper exists because the manual sequence is easy to get wrong — the
# answer file must be rendered from the .pkrtpl with real build credentials and
# injected offline into \Windows\Panther\unattend.xml. Injecting a stale or
# mis-rendered unattend produces a base that hangs at OOBE with no obvious
# cause, which cost several 15-minute build cycles to diagnose once already.
set -euo pipefail

TARGET="${1:-}"
NODE="${PVE_NODE_HOST:-root@pve03.lab.local}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
COMMON="$REPO/builds/windows/common"
PY="$REPO/.venv/bin/python"

case "$TARGET" in
  2022|2025|both) ;;
  *) echo "usage: $(basename "$0") 2022|2025|both" >&2; exit 2 ;;
esac

for v in VAULT_ADDR VAULT_TOKEN; do
  [ -n "${!v:-}" ] || { echo "$v must be set (source the repo .env)" >&2; exit 1; }
done

echo "==> rendering unattend from the .pkrtpl with Vault build credentials"
U=$(vault kv get -field=BUILD_USERNAME secret/packer)
P=$(vault kv get -field=BUILD_PASSWORD secret/packer)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

BUILD_USERNAME="$U" BUILD_PASSWORD="$P" "$PY" - "$COMMON/files/autounattend-vhd.pkrtpl.xml" "$TMP/unattend.xml" <<'PYEOF'
import os, sys, pathlib, xml.dom.minidom
src, dst = sys.argv[1], sys.argv[2]
out = (pathlib.Path(src).read_text()
       .replace('${win_language}', 'en-US')
       .replace('${win_keyboard}', 'en-US')
       .replace('${win_timezone}', 'Central Standard Time')
       .replace('${build_username}', os.environ['BUILD_USERNAME'])
       .replace('${build_password}', os.environ['BUILD_PASSWORD']))
assert '${' not in out, "unresolved placeholders in rendered unattend"
xml.dom.minidom.parseString(out)          # fail loudly on malformed XML
pathlib.Path(dst).write_text(out)
print(f"    rendered {len(out)} bytes, XML well-formed")
PYEOF

scp -q "$TMP/unattend.xml" "$NODE:/tmp/unattend.xml"
scp -q "$COMMON/scripts/bootstrap-windows-base.sh" "$NODE:/tmp/"
ssh "$NODE" 'chmod +x /tmp/bootstrap-windows-base.sh'

run_one() {
  local rel="$1" img="$2" vmid="$3" fw="$4" part="$5"
  echo "==> $rel: importing $(basename "$img") -> VMID $vmid ($fw)"
  ssh "$NODE" "bash /tmp/bootstrap-windows-base.sh \
    --image '$img' --vm-id $vmid \
    --name windows-server-${rel}-desktop-experience-cloud-base \
    --firmware $fw --win-part $part --unattend /tmp/unattend.xml --force"
}

# 2022 ships a .vhd (MBR, single partition, SeaBIOS);
# 2025 ships a .vhdx (GPT: ESP + MSR + Windows on p3, OVMF). Not interchangeable.
# Base images are the Datacenter eval VHD/VHDX, staged in iso_images under the
# same human names as the lab mirror (build number in the name). If a newer eval
# base is mirrored, stage it and bump the build number in these two paths.
[ "$TARGET" = "2022" ] || [ "$TARGET" = "both" ] && \
  run_one 2022 /mnt/pve/iso_images/template/iso/windows-server-2022-datacenter-eval-x64-en-us-20348.169.vhd  9422 seabios 1
[ "$TARGET" = "2025" ] || [ "$TARGET" = "both" ] && \
  run_one 2025 /mnt/pve/iso_images/template/iso/windows-server-2025-datacenter-eval-x64-en-us-26100.1742.vhdx 9424 ovmf    3

ssh "$NODE" 'rm -f /tmp/unattend.xml'
echo "==> done. Build with:"
echo "    ./build.py builds/windows/windows-server-<rel>-desktop-experience-cloud"
