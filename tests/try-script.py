#!/usr/bin/env python3
"""Run one provisioning script against a live Windows clone, in seconds.

WHY THIS EXISTS
    A full Windows ISO build is ~2 hours, and build.py retries three times, so
    a single bad line can cost most of a day before it is even seen. Worse, the
    VM is destroyed on failure, taking its transcripts with it. Every script in
    builds/windows/common/scripts is an ordinary PowerShell script that expects
    an elevated, non-interactive session - which is reproducible on any running
    Windows VM in about a minute.

WHAT IT REPRODUCES
    Packer's elevated provisioner runs each script as a scheduled task under
    the build user. This harness does the same thing, deliberately, because the
    logon context is not incidental - it is what breaks scripts. Two failures in
    this repo came from exactly that: DISM refusing to run without a fully
    elevated token, and winget being staged but not yet registered for the
    session that staged it. Running the script over plain WinRM, or as SYSTEM
    through the guest agent, would NOT have reproduced either.

    What it does NOT reproduce: Packer's own environment_vars, its
    exit-$LastExitCode wrapper, and the cumulative state left by scripts that
    ran earlier in the chain. Use --before to run prerequisites first, and
    treat a pass here as "this script works", not "the build passes".

USAGE
    # first run: makes the scratch VM from a finished template, snapshots it
    ./tests/try-script.py --setup 80-desktop-info.ps1

    # subsequent runs: rolls back to the clean snapshot, then runs
    ./tests/try-script.py 80-desktop-info.ps1

    # run prerequisites first, in order, then the script under test
    ./tests/try-script.py --before 53-install-winget.ps1 56-install-winget-packages.ps1

    # log on for real (wallpaper, anything per-user) and screenshot the console
    ./tests/try-script.py 80-desktop-info.ps1 --logon --screenshot out.png

    # keep state between runs to test an idempotent re-run
    ./tests/try-script.py 80-desktop-info.ps1 --no-rollback

ENVIRONMENT
    PROXMOX_URL, PROXMOX_USERNAME, PROXMOX_PASSWORD, PROXMOX_NODE,
    BUILD_USERNAME, BUILD_PASSWORD - the same values the build uses; source
    them from Vault (secret/packer), never from a file.
"""
import argparse
import base64
import os
import subprocess
import sys
import time

from proxmoxer import ProxmoxAPI

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT_DIR = os.path.join(REPO, "builds", "windows", "common", "scripts")
SNAPSHOT = "try-clean"


def env(name):
    v = os.environ.get(name)
    if not v:
        sys.exit(f"error: {name} is not set (source it from Vault secret/packer)")
    return v


class Guest:
    def __init__(self, vmid, node, prox):
        self.vmid, self.node, self.prox = vmid, node, prox

    def _qemu(self):
        return self.prox.nodes(self.node).qemu(self.vmid)

    def ping(self):
        try:
            self._qemu().agent.ping.post()
            return True
        except Exception:
            return False

    def wait_agent(self, timeout=900, label="guest agent"):
        print(f"[..] waiting for {label}", end="", flush=True)
        end = time.time() + timeout
        while time.time() < end:
            if self.ping():
                print(" up")
                return True
            print(".", end="", flush=True)
            time.sleep(5)
        print(" TIMED OUT")
        return False

    def ps(self, script, timeout=1800):
        """Run PowerShell as SYSTEM via the guest agent. Fine for inspection;
        NOT the right context for running a provisioning script - see
        run_as_build_user().

        Returns (exitcode, stdout, stderr) SEPARATELY and on purpose. PowerShell
        writes its progress stream to stderr as a CLIXML blob, so merging the
        two means every parsed value can arrive with a wall of XML glued to it.
        $ProgressPreference suppresses most of it; keeping the streams apart is
        what actually makes stdout parseable."""
        script = "$ProgressPreference='SilentlyContinue'\n" + script
        enc = base64.b64encode(script.encode("utf-16-le")).decode()
        pid = self._qemu().agent.exec.post(
            command=["powershell.exe", "-NoProfile", "-NonInteractive",
                     "-ExecutionPolicy", "Bypass", "-EncodedCommand", enc])["pid"]
        end = time.time() + timeout
        while time.time() < end:
            r = self._qemu().agent("exec-status").get(pid=pid)
            if r.get("exited"):
                return r.get("exitcode", -1), (r.get("out-data") or ""), (r.get("err-data") or "")
            time.sleep(3)
        raise RuntimeError("guest agent exec timed out")

    def put(self, local_path, remote_path):
        """Copy a file in via base64 chunks. Chunked because a whole script in
        one -EncodedCommand overflows the command line for the larger ones."""
        data = base64.b64encode(open(local_path, "rb").read()).decode()
        self.ps(f"Remove-Item -LiteralPath '{remote_path}' -Force -ErrorAction SilentlyContinue;"
                f"New-Item -ItemType Directory -Force -Path (Split-Path '{remote_path}') | Out-Null")
        chunk, b64file = 3000, remote_path + ".b64"
        for i in range(0, len(data), chunk):
            self.ps(f"Add-Content -LiteralPath '{b64file}' -Value '{data[i:i + chunk]}' -NoNewline")
        rc, out, err = self.ps(
            f"$b=[Convert]::FromBase64String((Get-Content -LiteralPath '{b64file}' -Raw));"
            f"[IO.File]::WriteAllBytes('{remote_path}',$b);"
            f"Remove-Item -LiteralPath '{b64file}' -Force;"
            f"(Get-Item -LiteralPath '{remote_path}').Length")
        if rc != 0:
            raise RuntimeError(f"upload failed: {out} {err}")
        digits = [l.strip() for l in out.splitlines() if l.strip().isdigit()]
        if not digits:
            raise RuntimeError(f"upload produced no size on stdout: {out!r} / {err!r}")
        return int(digits[-1])

    def run_as_build_user(self, remote_path, user, password, minutes=30, env_vars=None):
        """THE point of this harness: an elevated scheduled task under the
        build user, which is how Packer's elevated provisioner runs scripts."""
        out = "C:\\Windows\\Temp\\try-script-out.txt"
        prelude = ""
        for k, v in (env_vars or {}).items():
            prelude += f"$env:{k}='{v}'; "
        inner = f"{prelude}& '{remote_path}'; exit $LASTEXITCODE"
        b64 = base64.b64encode(inner.encode("utf-16-le")).decode()

        # Start the task and RETURN. Do not wait inside the guest: a long
        # blocking guest-exec stops the agent servicing anything else, and PVE
        # then fails the poll with "qga command 'guest-exec-status' failed - got
        # timeout". Every call from here on is short, and the waiting happens on
        # this side where a stall is visible and interruptible.
        rc, out_s, err_s = self.ps(f"""
$ErrorActionPreference='Stop'
Remove-Item '{out}' -Force -ErrorAction SilentlyContinue
Get-ScheduledTask -TaskName 'try-script' -EA SilentlyContinue |
    Unregister-ScheduledTask -Confirm:$false -EA SilentlyContinue
$a = New-ScheduledTaskAction -Execute 'cmd.exe' `
     -Argument '/c powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand {b64} > {out} 2>&1'
Register-ScheduledTask -TaskName 'try-script' -Action $a -User '{user}' -Password '{password}' `
    -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName 'try-script'
'STARTED'
""", timeout=180)
        if "STARTED" not in out_s:
            raise RuntimeError(f"could not start the task: {out_s!r} / {err_s!r}")

        deadline = time.time() + minutes * 60
        state = "Running"
        while time.time() < deadline:
            time.sleep(5)
            try:
                _, st, _ = self.ps("(Get-ScheduledTask -TaskName 'try-script').State", timeout=60)
            except Exception as exc:
                # A single hiccup while the guest is busy is not a failure.
                print(f"   [harness] poll hiccup ({type(exc).__name__}), retrying")
                continue
            state = (st.strip().splitlines() or ["?"])[-1].strip()
            if state and state != "Running":
                break
        if state == "Running":
            print(f"   [harness] TIMED OUT after {minutes} min; task still Running")

        code = None
        try:
            _, meta, _ = self.ps(
                "\"EXITCODE={0}\" -f (Get-ScheduledTaskInfo -TaskName 'try-script').LastTaskResult",
                timeout=120)
            for line in meta.splitlines():
                if line.startswith("EXITCODE="):
                    code = line.split("=", 1)[1].strip()
        except Exception as exc:
            print(f"   [harness] could not read the task result: {exc}")

        body = ""
        try:
            _, body, _ = self.ps(
                f"if (Test-Path '{out}') {{ Get-Content '{out}' -Raw }} else {{ '(no output)' }}",
                timeout=300)
        except Exception as exc:
            print(f"   [harness] could not read the transcript: {exc}")

        try:
            self.ps("Unregister-ScheduledTask -TaskName 'try-script' -Confirm:$false", timeout=60)
        except Exception:
            pass
        return code, body


def clean(text):
    for line in (text or "").splitlines():
        line = line.rstrip()
        if line and "CLIXML" not in line and "<Objs" not in line:
            yield line


def wait_upid(prox, node, upid, timeout=900):
    end = time.time() + timeout
    while time.time() < end:
        st = prox.nodes(node).tasks(upid).status.get()
        if st["status"] == "stopped":
            return st.get("exitstatus") == "OK"
        time.sleep(3)
    return False


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("script", help="script name in builds/windows/common/scripts")
    ap.add_argument("--before", nargs="*", default=[],
                    help="scripts to run first, in order (prerequisites)")
    ap.add_argument("--template", type=int, default=int(os.environ.get("TRY_TEMPLATE", "9432")),
                    help="finished Windows template to clone (default 9432, 2022 Desktop)")
    ap.add_argument("--vmid", type=int, default=int(os.environ.get("TRY_VMID", "9419")))
    ap.add_argument("--setup", action="store_true", help="(re)create the scratch VM and snapshot it")
    ap.add_argument("--no-rollback", action="store_true", help="keep state from the previous run")
    ap.add_argument("--logon", action="store_true",
                    help="enable autologon and reboot, to trigger at-logon behaviour")
    ap.add_argument("--screenshot", metavar="PNG", help="capture the console after running")
    ap.add_argument("--pull-wallpaper", metavar="PNG",
                    help="fetch the rendered desktop bitmap itself, full resolution and "
                         "unobstructed - better evidence than a scaled console grab")
    ap.add_argument("--minutes", type=int, default=30, help="per-script timeout")
    ap.add_argument("--env", nargs="*", default=[], metavar="K=V",
                    help="environment variables the script expects")
    args = ap.parse_args()

    node, user, pw = env("PROXMOX_NODE"), env("BUILD_USERNAME"), env("BUILD_PASSWORD")
    prox = ProxmoxAPI(env("PROXMOX_URL").replace("https://", "").split(":")[0],
                      user=env("PROXMOX_USERNAME"), password=env("PROXMOX_PASSWORD"),
                      verify_ssl=False, timeout=120)
    g = Guest(args.vmid, node, prox)
    env_vars = dict(kv.split("=", 1) for kv in args.env if "=" in kv)

    scripts = list(args.before) + [args.script]
    for name in scripts:
        if not os.path.exists(os.path.join(SCRIPT_DIR, name)):
            sys.exit(f"error: no such script: {os.path.join(SCRIPT_DIR, name)}")

    exists = True
    try:
        prox.nodes(node).qemu(args.vmid).status.current.get()
    except Exception:
        exists = False

    if args.setup or not exists:
        if exists:
            print(f"[..] removing existing {args.vmid}")
            try:
                prox.nodes(node).qemu(args.vmid).status.stop.post()
                time.sleep(8)
            except Exception:
                pass
            wait_upid(prox, node, prox.nodes(node).qemu(args.vmid).delete(), 300)
        print(f"[..] linked-cloning {args.template} -> {args.vmid}")
        if not wait_upid(prox, node, prox.nodes(node).qemu(args.template).clone.post(
                newid=args.vmid, name="try-script", full=0)):
            sys.exit("clone failed")
        prox.nodes(node).qemu(args.vmid).status.start.post()
        if not g.wait_agent():
            sys.exit("guest agent never came up")
        time.sleep(20)
        print(f"[..] snapshotting as '{SNAPSHOT}' so later runs start clean")
        wait_upid(prox, node, prox.nodes(node).qemu(args.vmid).snapshot.post(
            snapname=SNAPSHOT, vmstate=0), 600)
    else:
        if not args.no_rollback:
            print(f"[..] rolling back to '{SNAPSHOT}'")
            try:
                prox.nodes(node).qemu(args.vmid).status.stop.post()
                time.sleep(6)
            except Exception:
                pass
            if not wait_upid(prox, node, prox.nodes(node).qemu(args.vmid)
                             .snapshot(SNAPSHOT).rollback.post(), 600):
                sys.exit(f"rollback failed - re-run with --setup")
            prox.nodes(node).qemu(args.vmid).status.start.post()
        if not g.ping() and not g.wait_agent():
            sys.exit("guest agent never came up")

    overall = 0
    for name in scripts:
        local = os.path.join(SCRIPT_DIR, name)
        remote = f"C:\\Install\\{name}"
        size = g.put(local, remote)
        print(f"\n=== {name} ({size} bytes) ===")
        code, body = g.run_as_build_user(remote, user, pw, args.minutes, env_vars)
        for line in clean(body):
            print("   " + line[:220])
        print(f"   --> exit code: {code}")
        if code not in ("0",):
            overall = 1
            print(f"   *** {name} FAILED - stopping here")
            break

    if args.logon and overall == 0:
        print("\n[..] enabling autologon and rebooting to trigger at-logon behaviour")
        g.ps(f"""
$k='HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon'
Set-ItemProperty $k AutoAdminLogon '1'
Set-ItemProperty $k DefaultUserName '{user}'
Set-ItemProperty $k DefaultPassword '{pw}'
# Suppress the Shutdown Event Tracker. This harness reboots hard, so Server
# shows the "why did the computer shut down unexpectedly" dialog on the way
# back up - and it lands in the middle of the screen, covering whatever we are
# trying to look at. HARNESS-ONLY: this is not applied to any template.
$rel='HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Reliability'
New-Item -Path $rel -Force | Out-Null
Set-ItemProperty $rel ShutdownReasonOn 0 -Type DWord
Set-ItemProperty $rel ShutdownReasonUI 0 -Type DWord
""")
        try:
            g.ps("Restart-Computer -Force", timeout=30)
        except Exception:
            pass
        time.sleep(30)
        if not g.wait_agent(label="guest agent after reboot"):
            print("   [FAIL] no agent after reboot")
            overall = 1
        else:
            print("[..] logged on; giving logon tasks time to run")
            time.sleep(75)

    if args.pull_wallpaper:
        # Read it out of the LOGGED-ON user's profile. The agent runs as SYSTEM,
        # so $env:LOCALAPPDATA here is the systemprofile, not theirs.
        rc, out, err = g.ps(f"""
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
$sid = (New-Object System.Security.Principal.NTAccount('{user}')).Translate(
        [System.Security.Principal.SecurityIdentifier]).Value
$dir = (Get-ItemProperty ("HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\ProfileList\\" + $sid)).ProfileImagePath
$bmp = Join-Path $dir 'AppData\\Local\\DesktopInfo\\desktopinfo.bmp'
if (-not (Test-Path -LiteralPath $bmp)) {{ "MISSING:$bmp"; exit 1 }}
$img=[System.Drawing.Image]::FromFile($bmp)
$png="$env:TEMP\\di.png"
$img.Save($png,[System.Drawing.Imaging.ImageFormat]::Png); $img.Dispose()
[Convert]::ToBase64String([IO.File]::ReadAllBytes($png))
""", timeout=600)
        blob = "".join(l.strip() for l in out.splitlines()
                       if l.strip() and not l.startswith("MISSING:"))
        if "MISSING:" in out or not blob:
            print(f"[--] could not fetch the wallpaper bitmap: {out.strip()[:200]}")
            overall = 1
        else:
            with open(args.pull_wallpaper, "wb") as fh:
                fh.write(base64.b64decode(blob))
            print(f"[..] wallpaper bitmap -> {args.pull_wallpaper} "
                  f"({os.path.getsize(args.pull_wallpaper)} bytes)")

    if args.screenshot:
        sh = os.path.join(REPO, "tests", "pve-screenshot.sh")
        if os.path.exists(sh):
            subprocess.run([sh, str(args.vmid), args.screenshot], check=False)
            print(f"[..] console screenshot -> {args.screenshot}")
        else:
            print(f"[--] {sh} not found; skipping screenshot")

    print(f"\n[..] VM {args.vmid} left running. Next run rolls back to '{SNAPSHOT}' automatically.")
    return overall


if __name__ == "__main__":
    sys.exit(main())
