#!/usr/bin/env python3
"""Map the TV's external TCP connections to the processes that own them.

Reads /proc/net/tcp{,6} for socket inodes, then scans /proc/*/fd to find which
process holds each one. Without this, an AWS endpoint looks like LG telemetry
when it is often the Netflix app or Google FCM.

Usage: sockets.py            report every process with an external socket
       sockets.py <comm> [n] watch one process over n 5-second rounds
"""
import glob
import os
import socket
import struct
import sys
import time

STATES = {"01": "ESTABLISHED", "02": "SYN_SENT", "03": "SYN_RECV",
          "06": "TIME_WAIT", "08": "CLOSE_WAIT", "09": "LAST_ACK"}
LOCAL_PREFIXES = ("127.", "0.0.0.0", "::1", "::ffff:192.168", "192.168.",
                  "10.", "169.254.", "fe80:")


def parse_addr(hexaddr):
    if len(hexaddr) == 8:
        return socket.inet_ntoa(struct.pack("<I", int(hexaddr, 16)))
    raw = bytes.fromhex(hexaddr)
    raw = b"".join(raw[i:i + 4][::-1] for i in range(0, 16, 4))
    return socket.inet_ntop(socket.AF_INET6, raw)


def external_sockets():
    """inode -> "ip:port STATE" for every non-local connection."""
    found = {}
    for path in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            lines = open(path).read().splitlines()[1:]
        except OSError:
            continue
        for line in lines:
            fields = line.split()
            state = STATES.get(fields[3])
            if not state:
                continue
            host, port = fields[2].split(":")
            addr = parse_addr(host)
            if addr.startswith(LOCAL_PREFIXES):
                continue
            found[fields[9]] = f"{addr}:{int(port, 16)} {state}"
    return found


def owners(only=None):
    """(comm, pid) -> set of endpoint strings."""
    conns = external_sockets()
    result = {}
    for procdir in glob.glob("/proc/[0-9]*"):
        try:
            comm = open(procdir + "/comm").read().strip()
        except OSError:
            continue
        if only is not None and comm != only:
            continue
        endpoints = set()
        for fd in glob.glob(procdir + "/fd/*"):
            try:
                target = os.readlink(fd)
            except OSError:
                continue
            if target.startswith("socket:["):
                inode = target[8:-1]
                if inode in conns:
                    endpoints.add(conns[inode])
        if endpoints or only is not None:
            result[(comm, procdir.split("/")[-1])] = endpoints
    return result


def main():
    if len(sys.argv) > 1:
        name = sys.argv[1]
        rounds = int(sys.argv[2]) if len(sys.argv) > 2 else 1
        for i in range(rounds):
            found = owners(only=name)
            if not found:
                print(f"  t+{i * 5}s  {name}: not running")
            for (comm, pid), eps in sorted(found.items()):
                label = ", ".join(sorted(eps)) if eps else "no external sockets"
                print(f"  t+{i * 5}s  {comm} (pid {pid}): {label}")
            if i < rounds - 1:
                time.sleep(5)
        return
    found = owners()
    if not found:
        print("  no process holds an external connection")
    for (comm, pid), eps in sorted(found.items()):
        print(f"  {comm} (pid {pid})")
        for ep in sorted(eps):
            print(f"      {ep}")


if __name__ == "__main__":
    main()
