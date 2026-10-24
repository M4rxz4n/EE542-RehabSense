"""
rehab_fetch.py — download a sealed session from the sleeve over Wi-Fi.

The flow, end to end:

    1. Over the BLE link that is already connected, send CMD_START_TRANSFER.
    2. The device seals nothing new — the session is already sealed — brings
       up a WPA2 SoftAP, and answers on the transfer characteristic with the
       SSID, password, address and port.
    3. Join that network. This script does not do it for you: joining a
       network is an operating-system action and scripting it portably is
       worse than asking. On macOS and Linux it is one `networksetup` or
       `nmcli` command; on Windows it is the taskbar.
    4. Run this script. It fetches the manifest, then each stream, resuming
       any that were partly downloaded.
    5. It POSTs /complete, and the device drops the AP.

Resumability is the reason this is a script rather than five curl commands.
The EMG stream is about 4.5 MB and a laptop that sleeps mid-download should
not have to start again — every .bin endpoint honours Range, and so does this.

Why not do the whole thing over BLE
-----------------------------------
Paced over BLE the same payload takes roughly as long as the session did:
about 10 kB/s against a phone, so ten minutes of exercise is ten minutes of
transfer. Over SoftAP it is seconds. The radio is shared, which is why the AP
only exists between sessions.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_HOST = "192.168.4.1"      # the ESP-IDF SoftAP gateway default
DEFAULT_PORT = 80

STREAMS = ("emg", "imu", "features", "events", "reps")

# Big enough that the per-read overhead vanishes against a megabyte, small
# enough that progress moves visibly.
CHUNK = 64 * 1024


def _url(host: str, port: int, path: str) -> str:
    return f"http://{host}:{port}{path}"


def fetch_manifest(host: str, port: int, timeout: float) -> dict:
    with urllib.request.urlopen(_url(host, port, "/manifest.json"),
                                timeout=timeout) as r:
        return json.loads(r.read().decode())


def fetch_stream(host: str, port: int, path: str, dest: Path,
                 expect_bytes: int, timeout: float,
                 progress: bool = True) -> int:
    """Download one stream, resuming if `dest` is already partly written.

    Returns the file's final size. A file that is already the expected size is
    left alone, so re-running after a partial failure costs nothing for the
    streams that did land.
    """
    have = dest.stat().st_size if dest.exists() else 0

    if expect_bytes and have == expect_bytes:
        if progress:
            print(f"  {dest.name:<14} already complete ({have:,} B)")
        return have

    if have > expect_bytes:
        # A leftover from a different session. Starting over is correct:
        # appending to it would splice two recordings together.
        dest.unlink()
        have = 0

    req = urllib.request.Request(_url(host, port, path))
    if have:
        req.add_header("Range", f"bytes={have}-")

    started = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            if have and r.status != 206:
                # The server ignored the Range. Rewriting from zero is the
                # only safe reading of that, since the body is the whole file.
                have = 0
                mode = "wb"
            else:
                mode = "ab" if have else "wb"

            with dest.open(mode) as f:
                while True:
                    block = r.read(CHUNK)
                    if not block:
                        break
                    f.write(block)
                    have += len(block)
                    if progress and expect_bytes:
                        pct = 100.0 * have / expect_bytes
                        print(f"\r  {dest.name:<14} {have:>9,} / "
                              f"{expect_bytes:,} B  {pct:5.1f}%", end="")
    except urllib.error.HTTPError as e:
        if e.code == 409:
            raise SystemExit(
                "device reports the session is still running — stop the set "
                "before downloading"
            ) from e
        raise

    if progress:
        elapsed = max(time.monotonic() - started, 1e-6)
        rate = have / elapsed / 1024
        print(f"\r  {dest.name:<14} {have:>9,} B  "
              f"{elapsed:5.1f} s  {rate:,.0f} kB/s")
    return have


def mark_complete(host: str, port: int, timeout: float) -> None:
    """Tell the device we have everything, so it drops the AP.

    Best-effort: the session stays in PSRAM until the next START either way,
    so a failure here costs an idle timeout, not the data.
    """
    req = urllib.request.Request(_url(host, port, "/complete"),
                                 data=b"", method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout):
            pass
    except (urllib.error.URLError, OSError) as e:
        print(f"  note: could not confirm completion ({e}); the access point "
              f"will time out on its own", file=sys.stderr)


def fetch_session(host: str = DEFAULT_HOST, port: int = DEFAULT_PORT,
                  out_dir: str | Path = "sessions",
                  timeout: float = 30.0,
                  progress: bool = True) -> Path:
    manifest = fetch_manifest(host, port, timeout)

    if not manifest.get("sealed"):
        raise SystemExit("device reports the session is still running")

    # Directory named for when the session started, so repeated downloads of
    # the same session land in the same place and resume rather than multiply.
    stamp = time.strftime("%Y%m%d-%H%M%S",
                          time.localtime(manifest["start_us"] / 1e6)
                          if manifest["start_us"] > 1e15 else time.localtime())
    dest = Path(out_dir) / f"session-{stamp}"
    dest.mkdir(parents=True, exist_ok=True)

    (dest / "manifest.json").write_text(json.dumps(manifest, indent=2))

    total = sum(
        (manifest["streams"][s]["count"] - manifest["streams"][s]["first"]) *
        manifest["streams"][s]["record_bytes"] for s in STREAMS
    )
    if progress:
        print(f"session {stamp}: {total / 1048576:.2f} MB in {len(STREAMS)} streams")
        if manifest.get("gap_occurred"):
            print("  WARNING: a buffer wrapped during this session — the "
                  "record is incomplete and the device says so rather than "
                  "serving a short file as if it were whole")

    started = time.monotonic()
    for name in STREAMS:
        meta = manifest["streams"][name]
        expect = (meta["count"] - meta["first"]) * meta["record_bytes"]
        fetch_stream(host, port, meta["path"],
                     dest / Path(meta["path"]).name,
                     expect, timeout, progress)

    # The calibration profile this session was scored against. Without it the
    # %MVC numbers in the features have no reference and the angles have no
    # neutral, so a viewer cannot honestly plot either.
    try:
        fetch_stream(host, port, "/calib.bin", dest / "calib.bin", 0,
                     timeout, progress)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            print("  note: no calibration profile stored on the device",
                  file=sys.stderr)
        else:
            raise

    if progress:
        elapsed = time.monotonic() - started
        print(f"done in {elapsed:.1f} s "
              f"({total / elapsed / 1048576:.1f} MB/s) → {dest}")

    mark_complete(host, port, timeout)
    return dest


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Download a sealed RehabSense session over the sleeve's "
                    "Wi-Fi access point.",
        epilog="Send CMD_START_TRANSFER over BLE first (rehab_client.py does "
               "this), join the RehabSense-XXXX network, then run this.",
    )
    ap.add_argument("--host", default=DEFAULT_HOST,
                    help=f"device address (default {DEFAULT_HOST})")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--out", default="sessions",
                    help="directory to write sessions into")
    ap.add_argument("--timeout", type=float, default=30.0)
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--summary", action="store_true",
                    help="print a summary of the session after downloading")
    args = ap.parse_args()

    try:
        dest = fetch_session(args.host, args.port, args.out,
                             args.timeout, not args.quiet)
    except urllib.error.URLError as e:
        print(f"cannot reach the device at {args.host}:{args.port} — are you "
              f"joined to its network? ({e})", file=sys.stderr)
        return 1

    if args.summary:
        import rehab_session
        print()
        print(rehab_session.load(dest).summary())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
