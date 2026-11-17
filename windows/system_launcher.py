import sys, ctypes, time, traceback
from ctypes import wintypes
from pathlib import Path

LOG = Path(r"D:\WinUnlock\windows\launcher_runtime.log")
def log(m):
    LOG.open("a", encoding="utf-8").write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} - {m}\n")
k32, adv = ctypes.windll.kernel32, ctypes.windll.advapi32
class STARTUPINFOW(ctypes.Structure):
    _fields_ = [("cb", wintypes.DWORD), ("lpReserved", wintypes.LPWSTR), ("lpDesktop", wintypes.LPWSTR), ("lpTitle", wintypes.LPWSTR), ("dwX", wintypes.DWORD), ("dwY", wintypes.DWORD), ("dwXSize", wintypes.DWORD), ("dwYSize", wintypes.DWORD), ("dwXCountChars", wintypes.DWORD), ("dwYCountChars", wintypes.DWORD), ("dwFillAttribute", wintypes.DWORD), ("dwFlags", wintypes.DWORD), ("wShowWindow", wintypes.WORD), ("cbReserved2", wintypes.WORD), ("lpReserved2", ctypes.POINTER(ctypes.c_byte)), ("hStdInput", wintypes.HANDLE), ("hStdOutput", wintypes.HANDLE), ("hStdError", wintypes.HANDLE)]
class PROCESS_INFORMATION(ctypes.Structure):
    _fields_ = [("hProcess", wintypes.HANDLE), ("hThread", wintypes.HANDLE), ("dwProcessId", wintypes.DWORD), ("dwThreadId", wintypes.DWORD)]

k32.GetCurrentProcess.restype = wintypes.HANDLE
k32.WTSGetActiveConsoleSessionId.restype = wintypes.DWORD
adv.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE)]
adv.DuplicateTokenEx.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.POINTER(wintypes.HANDLE)]
adv.SetTokenInformation.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
adv.CreateProcessAsUserW.argtypes = [wintypes.HANDLE, wintypes.LPCWSTR, ctypes.c_wchar_p, ctypes.c_void_p, ctypes.c_void_p, wintypes.BOOL, wintypes.DWORD, ctypes.c_void_p, wintypes.LPCWSTR, ctypes.POINTER(STARTUPINFOW), ctypes.POINTER(PROCESS_INFORMATION)]
try:
    sid = wintypes.DWORD(k32.WTSGetActiveConsoleSessionId())
    h_tok, h_dup = wintypes.HANDLE(), wintypes.HANDLE()
    adv.OpenProcessToken(k32.GetCurrentProcess(), 0xF01FF, ctypes.byref(h_tok))
    adv.DuplicateTokenEx(h_tok, 0xF01FF, None, 2, 1, ctypes.byref(h_dup))
    adv.SetTokenInformation(h_dup, 12, ctypes.byref(sid), ctypes.sizeof(sid))
    si = STARTUPINFOW(cb=ctypes.sizeof(STARTUPINFOW), lpDesktop="winsta0\\default")
    pi = PROCESS_INFORMATION()
    cmd = ctypes.create_unicode_buffer(f'"{sys.executable}" "D:\\WinUnlock\\windows\\winlogon_helper.py"')
    if not adv.CreateProcessAsUserW(h_dup, None, cmd, None, None, False, 0x08000000, None, r"D:\WinUnlock\windows", ctypes.byref(si), ctypes.byref(pi)):
        raise ctypes.WinError()
    log(f"OK: Helper PID={pi.dwProcessId} Session={sid.value}")
except Exception:
    log(f"ERR:\n{traceback.format_exc()}")
    sys.exit(1)
