"""Fixed, allowlisted OS operations. No remote shell or arbitrary command API."""
import ctypes
import os
import platform
import re
import socket
import shutil
import struct
import subprocess
from pathlib import Path

GUID = '{8BE4DF61-93CA-11D2-AA0D-00E098032B8C}'

class WindowsEFI:
    def __init__(self):
        from ctypes import wintypes as w
        self.k = ctypes.WinDLL('kernel32', use_last_error=True)
        a = ctypes.WinDLL('advapi32', use_last_error=True)
        class LUID(ctypes.Structure):
            _fields_ = [('LowPart', w.DWORD), ('HighPart', w.LONG)]
        class PRIV(ctypes.Structure):
            _fields_ = [('Count', w.DWORD), ('Luid', LUID), ('Attributes', w.DWORD)]
        self.k.GetCurrentProcess.restype = w.HANDLE
        self.k.CloseHandle.argtypes = [w.HANDLE]
        a.OpenProcessToken.argtypes = [w.HANDLE, w.DWORD, ctypes.POINTER(w.HANDLE)]
        a.LookupPrivilegeValueW.argtypes = [w.LPCWSTR, w.LPCWSTR, ctypes.POINTER(LUID)]
        a.AdjustTokenPrivileges.argtypes = [w.HANDLE, w.BOOL, ctypes.POINTER(PRIV), w.DWORD, ctypes.c_void_p, ctypes.c_void_p]
        token = w.HANDLE()
        if not a.OpenProcessToken(self.k.GetCurrentProcess(), 0x28, ctypes.byref(token)):
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            p = PRIV(); p.Count = 1; p.Attributes = 2
            if not a.LookupPrivilegeValueW(None, 'SeSystemEnvironmentPrivilege', ctypes.byref(p.Luid)):
                raise ctypes.WinError(ctypes.get_last_error())
            ctypes.set_last_error(0)
            if not a.AdjustTokenPrivileges(token, False, ctypes.byref(p), 0, None, None) or ctypes.get_last_error():
                raise ctypes.WinError(ctypes.get_last_error())
        finally:
            self.k.CloseHandle(token)
        self.k.GetFirmwareEnvironmentVariableW.argtypes = [w.LPCWSTR, w.LPCWSTR, ctypes.c_void_p, w.DWORD]
        self.k.GetFirmwareEnvironmentVariableW.restype = w.DWORD
        self.k.SetFirmwareEnvironmentVariableExW.argtypes = [w.LPCWSTR, w.LPCWSTR, ctypes.c_void_p, w.DWORD, w.DWORD]
        self.k.SetFirmwareEnvironmentVariableExW.restype = w.BOOL

    def read(self, name):
        b = ctypes.create_string_buffer(65536)
        n = self.k.GetFirmwareEnvironmentVariableW(name, GUID, b, len(b))
        if not n:
            raise ctypes.WinError(ctypes.get_last_error())
        return b.raw[:n]

    def entries(self):
        data = self.read('BootOrder')
        result = {}
        for (num,) in struct.iter_unpack('<H', data):
            raw = self.read(f'Boot{num:04X}')
            if len(raw) < 8 or not struct.unpack_from('<I', raw)[0] & 1:
                continue
            end = 6
            while end + 1 < len(raw) and raw[end:end+2] != b'\x00\x00':
                end += 2
            result[f'{num:04X}'] = raw[6:end].decode('utf-16-le', errors='replace')
        return result

    def set_next(self, entry):
        raw = ctypes.create_string_buffer(struct.pack('<H', int(entry, 16)))
        if not self.k.SetFirmwareEnvironmentVariableExW('BootNext', GUID, raw, 2, 7):
            raise ctypes.WinError(ctypes.get_last_error())
        if self.read('BootNext') != raw.raw[:2]:
            raise RuntimeError('Firmware did not retain BootNext')


def run(args):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=20).stdout


def efi_tool():
    tool = shutil.which('efibootmgr', path='/usr/sbin:/usr/bin:/sbin:/bin')
    if not tool:
        raise RuntimeError('Install efibootmgr before configuring boot selection')
    return tool


def boot_entries():
    if platform.system() == 'Windows':
        return WindowsEFI().entries()
    if not Path('/sys/firmware/efi').exists():
        raise RuntimeError('UEFI boot required; legacy BIOS is not supported')
    result = {}
    for line in run([efi_tool()]).splitlines():
        m = re.match(r'^Boot([0-9A-Fa-f]{4})\*\s+(.*)', line)
        if m:
            result[m[1].upper()] = m[2].split('\t')[0]
    return result


def set_boot(entry):
    if not re.fullmatch(r'[0-9A-Fa-f]{4}', entry) or entry.upper() not in boot_entries():
        raise ValueError('Configured UEFI entry is missing or inactive; rerun boot discovery')
    if platform.system() == 'Windows':
        WindowsEFI().set_next(entry)
    else:
        run([efi_tool(), '-n', entry])
        if f'BootNext: {entry.upper()}' not in run([efi_tool()]):
            raise RuntimeError('Firmware did not retain BootNext')


def power(action):
    if action not in ('shutdown', 'restart'):
        raise ValueError('Unsupported power action')
    if platform.system() == 'Windows':
        exe = str(Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32' / 'shutdown.exe')
        # No /f: applications may block shutdown to protect unsaved work.
        run([exe, '/s' if action == 'shutdown' else '/r', '/t', '0'])
    else:
        run(['/usr/bin/systemctl', 'poweroff' if action == 'shutdown' else 'reboot'])


def magic_packet(mac):
    if not re.fullmatch(r'(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}', mac):
        raise ValueError('MAC must be six colon-separated hexadecimal bytes')
    return b'\xff' * 6 + bytes.fromhex(mac.replace(':', '')) * 16


def wake(mac, broadcast):
    packet = magic_packet(mac)
    socket.inet_pton(socket.AF_INET, broadcast)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        for _ in range(3):
            s.sendto(packet, (broadcast, 9))
