#!/usr/bin/env python3
"""The app's single privileged boundary for macOS system location preferences."""
import fcntl
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import signal
import stat
import subprocess
import sys
import time

DOMAINS = ("com.apple.locationd", "com.apple.locationd.notbackedup")
KEYS = ("SimulatedLocationLatitude", "SimulatedLocationLongitude", "SimulatedLocationAccuracy")
STATE = Path("/var/db/mac-location-control")
BACKUP = STATE / "original.plist"
BACKUP_RECORD = {"version": 1, "originallyAbsent": {domain: list(KEYS) for domain in DOMAINS}}


class LocationOperationError(RuntimeError):
    pass


def run(command, missing_message=None, timeout=20):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, timeout=timeout)
    if result.returncode:
        if result.returncode == 1 and missing_message is not None and result.stderr.strip() == missing_message:
            return None
        raise LocationOperationError(f"{Path(command[0]).name}: {result.stderr.strip()}")
    return result.stdout.strip()


def preference(domain, operation, key, value=None):
    uid = run(["/usr/bin/id", "-u", "_locationd"])
    command = ["/bin/launchctl", "asuser", uid, "/usr/bin/sudo", "-n", "-H", "-u", "_locationd",
               "/usr/bin/defaults", "-currentHost", operation, domain, key]
    if value is not None:
        command += ["-float", str(value)]
    missing = f"Error: Could not find key '{key}' in domain '{domain}'." if operation == "read" else None
    return run(command, missing_message=missing)


def snapshot():
    result = {}
    for domain in DOMAINS:
        result[domain] = {}
        for key in KEYS:
            raw = preference(domain, "read", key)
            value = None if raw is None else float(raw)
            if value is not None and not math.isfinite(value):
                raise LocationOperationError("现有模拟定位配置无效，未修改设置。")
            result[domain][key] = value
    return result


def restore_snapshot(values):
    for domain in DOMAINS:
        for key in KEYS:
            value = values[domain][key]
            if value is not None:
                preference(domain, "write", key, value)
            elif preference(domain, "read", key) is not None:
                preference(domain, "delete", key)


def refresh_location():
    previous = run(["/usr/bin/pgrep", "-x", "locationd"]).split()
    expected_uid = run(["/usr/bin/id", "-u", "_locationd"])
    for pid in previous:
        if run(["/bin/ps", "-p", pid, "-o", "uid="]) != expected_uid or run(["/bin/ps", "-p", pid, "-o", "comm="]) != "/usr/libexec/locationd":
            raise LocationOperationError("系统定位进程身份异常，未发送重启信号。")
    run(["/usr/bin/killall", "-u", "root", "cfprefsd"])
    time.sleep(2)
    for pid in previous:
        os.kill(int(pid), signal.SIGTERM)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        current = subprocess.run(["/usr/bin/pgrep", "-x", "locationd"], stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True, timeout=2)
        if current.returncode not in (0, 1):
            raise LocationOperationError("无法核对系统定位服务的重启结果。")
        pids = current.stdout.split()
        if pids and not set(previous).intersection(pids):
            run(["/usr/bin/notifyutil", "-p", "com.apple.locationd/Prefs"])
            return
        time.sleep(0.2)
    raise LocationOperationError("系统定位服务未在十秒内恢复。")


def read_backup():
    descriptor = os.open(BACKUP, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > 8192:
            raise LocationOperationError("恢复文件的权限或格式异常，已保留文件。")
        record = plistlib.load(source)
    if record != BACKUP_RECORD:
        raise LocationOperationError("恢复文件内容异常，已保留文件。")


def save_backup():
    descriptor = os.open(BACKUP, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        plistlib.dump(BACKUP_RECORD, output)
        output.flush()
        os.fsync(output.fileno())


def main(request):
    if not isinstance(request, dict):
        raise LocationOperationError("定位请求格式无效。")
    action = request.get("action")
    if action == "set":
        if set(request) != {"action", "latitude", "longitude"}:
            raise LocationOperationError("设置定位的字段无效。")
        for key, bound in (("latitude", 90), ("longitude", 180)):
            value = request[key]
            if type(value) not in (int, float) or not math.isfinite(value) or abs(value) > bound:
                raise LocationOperationError("纬度或经度超出有效范围。")
    elif action != "restore" or set(request) != {"action"}:
        raise LocationOperationError("定位操作无效。")
    if platform.system() != "Darwin" or os.geteuid() != 0:
        raise LocationOperationError("此操作需要 macOS 管理员权限。")
    os.setuid(0)
    STATE.mkdir(mode=0o700, exist_ok=True)
    info = STATE.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
        raise LocationOperationError("恢复目录权限异常，未修改设置。")
    descriptor = os.open(STATE / "lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if action == "restore":
            if not BACKUP.exists():
                return {"success": True, "changed": False, "message": "没有本应用需要恢复的定位会话。"}
            read_backup()
            original = {domain: {key: None for key in KEYS} for domain in DOMAINS}
            restore_snapshot(original)
            if snapshot() != original:
                raise LocationOperationError("原配置未完全恢复，恢复文件已保留。")
            refresh_location()
            BACKUP.unlink()
            return {"success": True, "changed": True, "message": "原系统定位配置已恢复。"}
        before = snapshot()
        if BACKUP.exists():
            read_backup()
        else:
            # A new session supports an unconfigured system. Refuse another
            # simulator's settings instead of taking ownership of its values.
            if any(value is not None for values in before.values() for value in values.values()):
                raise LocationOperationError("已有其他模拟定位配置，请先用原工具恢复。")
            save_backup()
        try:
            for domain in DOMAINS:
                for key, value in zip(KEYS, (request["latitude"], request["longitude"], 10.0)):
                    preference(domain, "write", key, value)
            refresh_location()
        except (LocationOperationError, OSError, subprocess.SubprocessError) as error:
            try:
                restore_snapshot(before)
                refresh_location()
            except (LocationOperationError, OSError, subprocess.SubprocessError) as recovery_error:
                raise LocationOperationError(f"设置失败且回滚未完成；请点击恢复。{error}；{recovery_error}") from recovery_error
            raise LocationOperationError(f"设置失败，已回到操作前的配置。{error}") from error
        return {"success": True, "changed": True, "message": "配置已应用，等待系统定位读数核验。"}


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise LocationOperationError("需要一个定位请求。")
        result = main(json.loads(sys.argv[1]))
    except (LocationOperationError, OSError, subprocess.SubprocessError, ValueError, plistlib.InvalidFileException) as error:
        result = {"success": False, "message": str(error)}
    print(json.dumps(result, ensure_ascii=False), flush=True)
    sys.exit(0 if result["success"] else 1)
