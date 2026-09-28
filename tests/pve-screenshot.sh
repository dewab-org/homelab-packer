#!/usr/bin/env bash
# Capture the QEMU console of a Proxmox VM as a PNG, for build diagnostics.
#   ./pve-screenshot.sh <vmid> [outfile.png]
# Uses the QEMU monitor 'screendump' (PPM), converted to PNG on the node with a
# dependency-free python3 encoder (netpbm/ImageMagick are not installed on pve).
set -uo pipefail
VMID="${1:?usage: pve-screenshot.sh <vmid> [out.png]}"
OUT="${2:-/tmp/vm${VMID}-console.png}"
NODE="root@pve03.lab.local"
SSH="ssh -F /dev/null -o ProxyCommand=none -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no"

$SSH "$NODE" "bash -s" <<EOS >/dev/null 2>&1
set -e
rm -f /tmp/vm${VMID}.ppm /tmp/vm${VMID}.png
echo "screendump /tmp/vm${VMID}.ppm" | qm monitor ${VMID} >/dev/null
for i in \$(seq 1 20); do [ -s /tmp/vm${VMID}.ppm ] && break; sleep 0.3; done
python3 - /tmp/vm${VMID}.ppm /tmp/vm${VMID}.png <<'PYEOF'
import sys, zlib, struct
src, dst = sys.argv[1], sys.argv[2]
d = open(src, 'rb').read()
idx = 0
def tok():
    global idx
    while d[idx:idx+1].isspace(): idx += 1
    if d[idx:idx+1] == b'#':
        while d[idx:idx+1] not in (b'\n', b''): idx += 1
        return tok()
    s = idx
    while not d[idx:idx+1].isspace(): idx += 1
    return d[s:idx]
assert tok() == b'P6', 'not a P6 PPM'
w, h, _maxv = int(tok()), int(tok()), int(tok())
idx += 1
raw = d[idx:idx + w*h*3]
rows = b''.join(b'\x00' + raw[y*w*3:(y+1)*w*3] for y in range(h))
def chunk(t, data):
    return struct.pack('>I', len(data)) + t + data + struct.pack('>I', zlib.crc32(t+data) & 0xffffffff)
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(rows, 6))
       + chunk(b'IEND', b''))
open(dst, 'wb').write(png)
print(f'{w}x{h}')
PYEOF
EOS
rc=$?
[ $rc -ne 0 ] && { echo "screendump failed (VM ${VMID} running?)"; exit $rc; }
scp -F /dev/null -o ProxyCommand=none -o BatchMode=yes -o StrictHostKeyChecking=no -q \
    "$NODE:/tmp/vm${VMID}.png" "$OUT" || { echo "scp failed"; exit 1; }
echo "$OUT"
