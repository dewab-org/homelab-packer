#!/usr/bin/env python3
"""Link-clone a built template and prove it actually works.

For each template this:
  1. linked-clones it to an ephemeral VMID,
  2. attaches a Proxmox cloud-init payload (user, password, SSH key, DHCP),
  3. boots it and waits for the QEMU guest agent,
  4. verifies — per OS — that cloud-init actually configured the guest:
       * a login user was created from the cloud-init data,
       * remote access works (SSH for Linux; validated credential for Windows),
       * the hostname became the clone's name (proves cloud-init re-armed;
         a template that did not re-arm keeps the build hostname),
       * the homelab CA is present in the trust store,
  5. destroys the clone — always, even on failure.

This exists because a template can build "successfully" and still be unusable:
Linux cloud-init that never re-arms silently skips every per-instance module,
and a Windows template can ship with no Cloudbase-Init or no cloud-init drive.
Only a clone-and-check catches that, so it runs in CI, not by hand.

Connection + auth come from the environment, matching the other scripts:
PROXMOX_URL / PROXMOX_USERNAME / PROXMOX_PASSWORD / PROXMOX_NODE / PROXMOX_STORAGE.
Exit code is non-zero if any template fails its checks.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

if __name__ == "__main__":
    repo_root = next(
        (p for p in Path(__file__).resolve().parents if (p / ".venv").is_dir()),
        Path(__file__).resolve().parents[1],
    )
    venv_python = repo_root / ".venv" / "bin" / "python3"
    if venv_python.is_file() and os.access(venv_python, os.X_OK) and sys.executable != str(venv_python):
        os.execv(str(venv_python), [str(venv_python)] + sys.argv)

import argparse
import base64
import subprocess
import tempfile
import time
import urllib.parse

from proxmoxer import ProxmoxAPI

CIUSER = "citest"
CIPASS = "ClOneVerify#2026!"          # ephemeral, lives only for the test clone
CLONE_BASE = 9600                     # test clones land at 9600 + (template % 100)


def log(msg: str) -> None:
    print(msg, flush=True)


def require(value, name):
    if not value:
        raise SystemExit(f"{name} is required")
    return value


def client(url, user, password):
    p = urllib.parse.urlparse(url)
    return ProxmoxAPI(p.hostname, user=user, password=password,
                      verify_ssl=False, port=p.port or 443)


def find_node(prox, vm_id, requested):
    if requested:
        return requested
    for r in prox.cluster.resources.get(type="vm"):
        if int(r.get("vmid", -1)) == vm_id:
            return r["node"]
    raise SystemExit(f"cannot find VMID {vm_id}")


def wait_task(prox, node, upid, timeout=1800):
    end = time.time() + timeout
    while time.time() < end:
        st = prox.nodes(node).tasks(upid).status.get()
        if st.get("status") == "stopped":
            if st.get("exitstatus") != "OK":
                raise RuntimeError(f"task {upid} failed: {st.get('exitstatus')}")
            return
        time.sleep(2)
    raise RuntimeError(f"task {upid} timed out")


def wait_agent(prox, node, vm_id, timeout=600):
    """Wait until the guest agent answers ping. Returns True, or False on timeout."""
    end = time.time() + timeout
    while time.time() < end:
        try:
            prox.nodes(node).qemu(vm_id).agent.ping.post()
            return True
        except Exception:
            time.sleep(10)
    return False


def agent_ipv4(prox, node, vm_id):
    """First non-loopback IPv4 the guest agent reports."""
    data = prox.nodes(node).qemu(vm_id).agent("network-get-interfaces").get()
    for iface in data.get("result", []):
        for addr in iface.get("ip-addresses", []) or []:
            ip = addr.get("ip-address", "")
            if addr.get("ip-address-type") == "ipv4" and not ip.startswith("127."):
                return ip
    return None


def agent_exec(prox, node, vm_id, command, timeout=120):
    """Run a command via the guest agent (Windows path; RHEL blocks this)."""
    pid = prox.nodes(node).qemu(vm_id).agent.exec.post(command=command)["pid"]
    end = time.time() + timeout
    while time.time() < end:
        res = prox.nodes(node).qemu(vm_id).agent("exec-status").get(pid=pid)
        if res.get("exited"):
            return res.get("exitcode"), (res.get("out-data") or "") + (res.get("err-data") or "")
        time.sleep(3)
    raise RuntimeError("guest agent exec timed out")


def ssh(ip, key_path, user, cmd, timeout=25):
    """SSH to a Linux clone as the cloud-init user with the injected key."""
    full = [
        "ssh", "-i", key_path,
        "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        "-o", "ConnectTimeout=10", "-o", "PreferredAuthentications=publickey",
        "-o", "BatchMode=yes",
        f"{user}@{ip}", cmd,
    ]
    r = subprocess.run(full, capture_output=True, text=True, timeout=timeout)
    return r.returncode, (r.stdout + r.stderr).strip()


def wait_ssh(ip, key_path, user, timeout=300, interval=5):
    """Poll SSH until login succeeds, or return the last error at the deadline.

    A freshly-cloned cloud image answers the guest agent (network is up) well
    before cloud-init has created the user and started sshd, so the first
    connect routinely gets 'Connection refused'. Waiting for the agent + a fixed
    sleep is not enough — retry the actual login until sshd accepts it. Returns
    (True, "") on success or (False, last_error) on timeout.
    """
    end = time.time() + timeout
    last = "no attempt made"
    while time.time() < end:
        rc, out = ssh(ip, key_path, user, "echo ok")
        if rc == 0 and "ok" in out:
            return True, ""
        last = f"rc={rc}: {out[:120]}"
        time.sleep(interval)
    return False, last


# --------------------------------------------------------------------------- #
# per-OS verification
# --------------------------------------------------------------------------- #

def verify_linux(prox, node, vm_id, clone_name, ip, key_path):
    fails = []

    ready, why = wait_ssh(ip, key_path, CIUSER)
    if not ready:
        fails.append(f"SSH login as {CIUSER} never came up within timeout ({why})")
        return fails                       # nothing else works without login

    rc, out = ssh(ip, key_path, CIUSER, "echo ok; hostname; id -un")
    if rc != 0 or "ok" not in out:
        fails.append(f"SSH login as {CIUSER} failed (rc={rc}): {out[:120]}")
        return fails                       # nothing else works without login
    got_host = out.splitlines()[1] if len(out.splitlines()) > 1 else ""
    log(f"    login OK, hostname={got_host}")

    if got_host != clone_name:
        fails.append(f"hostname is '{got_host}', expected '{clone_name}' "
                     "(cloud-init did not re-arm)")

    rc, _ = ssh(ip, key_path, CIUSER, "sudo -n true")
    if rc != 0:
        fails.append("passwordless sudo not configured for cloud-init user")
    else:
        log("    sudo OK")

    rc, out = ssh(ip, key_path, CIUSER,
                  "trust list 2>/dev/null | grep -qi 'HomeLab' && echo CA_OK || "
                  "grep -rqi 'HomeLab' /etc/pki/ca-trust/source/anchors/ 2>/dev/null && echo CA_OK || echo CA_MISSING")
    if "CA_OK" not in out:
        fails.append("homelab CA not found in the trust store")
    else:
        log("    CA present")

    return fails


def verify_windows(prox, node, vm_id, clone_name):
    fails = []

    # Hostname is applied on the second boot, so reboot once first.
    log("    rebooting to apply hostname...")
    prox.nodes(node).qemu(vm_id).status.reboot.post()
    time.sleep(20)
    if not wait_agent(prox, node, vm_id):
        return ["guest agent did not return after reboot"]

    # Credential check: ValidateCredentials confirms the cloud-init password
    # actually authenticates (not just that the account exists).
    ps = (
        "Add-Type -AssemblyName System.DirectoryServices.AccountManagement;"
        "$c=New-Object System.DirectoryServices.AccountManagement.PrincipalContext("
        "[System.DirectoryServices.AccountManagement.ContextType]::Machine);"
        f"if($c.ValidateCredentials('Admin','{CIPASS}')){{'CRED_VALID'}}else{{'CRED_REJECTED'}}"
    )
    enc = base64.b64encode(ps.encode("utf-16-le")).decode()
    rc, out = agent_exec(prox, node, vm_id,
                         ["powershell.exe", "-NoProfile", "-EncodedCommand", enc])
    if "CRED_VALID" not in out:
        fails.append(f"cloud-init credential did not validate: {out[:120]}")
    else:
        log("    credential VALID")

    rc, out = agent_exec(prox, node, vm_id, ["cmd.exe", "/c", "hostname"])
    got_host = out.strip().splitlines()[-1].strip() if out.strip() else ""
    # Windows caps NetBIOS names at 15 chars; compare on that prefix.
    if got_host.lower() != clone_name[:15].lower():
        fails.append(f"hostname is '{got_host}', expected '{clone_name[:15]}' "
                     "(cloud-init did not set it)")
    else:
        log(f"    hostname OK ({got_host})")

    rc, out = agent_exec(prox, node, vm_id,
                         ["cmd.exe", "/c", "certutil -store Root | findstr /i HomeLab"])
    if "HomeLab" not in out:
        fails.append("homelab CA not found in the Root store")
    else:
        log("    CA present")

    return fails


# --------------------------------------------------------------------------- #

def verify_template(prox, node_default, tmpl, storage):
    node = find_node(prox, tmpl, node_default)
    cfg = prox.nodes(node).qemu(tmpl).config.get()
    name = cfg.get("name", f"vmid-{tmpl}")
    is_windows = str(cfg.get("ostype", "")).startswith("win")
    clone_id = CLONE_BASE + (tmpl % 100)
    clone_name = (f"citest-{tmpl}")[:15] if is_windows else f"citest-{tmpl}"

    log(f"\n=== {tmpl} {name} ({'windows' if is_windows else 'linux'}) -> clone {clone_id} ===")

    keydir = tempfile.mkdtemp()
    key_path = os.path.join(keydir, "k")
    subprocess.run(["ssh-keygen", "-t", "ed25519", "-f", key_path, "-N", "", "-q"], check=True)
    pub = Path(key_path + ".pub").read_text().strip()

    created = False
    try:
        # Remove a stale clone from a previous aborted run.
        try:
            prox.nodes(node).qemu(clone_id).config.get()
            log(f"  removing stale clone {clone_id}")
            try:
                prox.nodes(node).qemu(clone_id).status.stop.post()
                time.sleep(5)
            except Exception:
                pass
            wait_task(prox, node, prox.nodes(node).qemu(clone_id).delete(purge=1))
        except Exception:
            pass

        log(f"  cloning {tmpl} -> {clone_id}")
        wait_task(prox, node, prox.nodes(node).qemu(tmpl).clone.post(newid=clone_id, name=clone_name))
        created = True

        # cloud-init payload. sshkeys must be URL-encoded for the API.
        prox.nodes(node).qemu(clone_id).config.post(
            ciuser=CIUSER, cipassword=CIPASS,
            sshkeys=urllib.parse.quote(pub, safe=""),
            ipconfig0="ip=dhcp",
        )
        log("  starting clone")
        prox.nodes(node).qemu(clone_id).status.start.post()

        if not wait_agent(prox, node, clone_id, timeout=900):
            return [f"{tmpl} {name}: guest agent never came up"]

        # Give cloud-init/Cloudbase-Init a moment past agent-up to finish its run.
        time.sleep(60)

        if is_windows:
            fails = verify_windows(prox, node, clone_id, clone_name)
        else:
            ip = agent_ipv4(prox, node, clone_id)
            if not ip:
                return [f"{tmpl} {name}: no IPv4 from guest agent"]
            log(f"  clone IP {ip}")
            fails = verify_linux(prox, node, clone_id, clone_name, ip, key_path)

        return [f"{tmpl} {name}: {f}" for f in fails]

    finally:
        if created:
            log(f"  destroying clone {clone_id}")
            try:
                prox.nodes(node).qemu(clone_id).status.stop.post()
                time.sleep(5)
            except Exception:
                pass
            try:
                prox.nodes(node).qemu(clone_id).delete(purge=1)
            except Exception as e:
                log(f"  WARNING: could not destroy {clone_id}: {e}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("templates", nargs="+", type=int, help="template VMIDs to verify")
    ap.add_argument("--node", default=os.environ.get("PROXMOX_NODE"))
    args = ap.parse_args()

    prox = client(
        require(os.environ.get("PROXMOX_URL"), "PROXMOX_URL"),
        require(os.environ.get("PROXMOX_USERNAME"), "PROXMOX_USERNAME"),
        require(os.environ.get("PROXMOX_PASSWORD"), "PROXMOX_PASSWORD"),
    )
    storage = os.environ.get("PROXMOX_STORAGE", "local-lvm")

    all_fails = []
    for tmpl in args.templates:
        try:
            all_fails += verify_template(prox, args.node, tmpl, storage)
        except Exception as e:
            all_fails.append(f"{tmpl}: harness error: {e}")

    print("\n" + "=" * 60)
    if all_fails:
        print(f"FAILED ({len(all_fails)} issue(s)):")
        for f in all_fails:
            print(f"  - {f}")
        return 1
    print(f"OK: all {len(args.templates)} template(s) passed clone verification")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
