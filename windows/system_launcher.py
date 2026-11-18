import sys, time, ctypes, subprocess
from ctypes import wintypes
from pathlib import Path

LOG = Path(__file__).parent / "launcher_runtime.log"
HELPER = Path(__file__).parent / "winlogon_helper.py"
kernel32, advapi32 = ctypes.windll.kernel32, ctypes.windll.advapi32

class PROCESSENTRY32W(ctypes.Structure):
    _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD), ("th32ProcessID", wintypes.DWORD),
                ("th32DefaultHeapID", ctypes.POINTER(ctypes.c_ulong)), ("th32ModuleID", wintypes.DWORD),
                ("cntThreads", wintypes.DWORD), ("th32ParentProcessID", wintypes.DWORD),
                ("pcPriClassBase", wintypes.LONG), ("dwFlags", wintypes.DWORD), ("szExeFile", wintypes.WCHAR * 260)]

class STARTUPINFOW(ctypes.Structure):
    _fields_ = [("cb", wintypes.DWORD), ("lpReserved", wintypes.LPWSTR), ("lpDesktop", wintypes.LPWSTR),
                ("lpTitle", wintypes.LPWSTR), ("dwX", wintypes.DWORD), ("dwY", wintypes.DWORD),
                ("dwXSize", wintypes.DWORD), ("dwYSize", wintypes.DWORD), ("dwXCountChars", wintypes.DWORD),
                ("dwYCountChars", wintypes.DWORD), ("dwFillAttribute", wintypes.DWORD), ("dwFlags", wintypes.DWORD),
                ("wShowWindow", wintypes.WORD), ("cbReserved2", wintypes.WORD), ("lpReserved2", ctypes.POINTER(ctypes.c_byte)),
                ("hStdInput", wintypes.HANDLE), ("hStdOutput", wintypes.HANDLE), ("hStdError", wintypes.HANDLE)]

class PROCESS_INFORMATION(ctypes.Structure):
    _fields_ = [("hProcess", wintypes.HANDLE), ("hThread", wintypes.HANDLE), ("dwProcessId", wintypes.DWORD), ("dwThreadId", wintypes.DWORD)]

kernel32.WTSGetActiveConsoleSessionId.restype = wintypes.DWORD
kernel32.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
kernel32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
kernel32.Process32FirstW.argtypes = [wintypes.HANDLE, ctypes.POINTER(PROCESSENTRY32W)]
kernel32.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(PROCESSENTRY32W)]
kernel32.ProcessIdToSessionId.argtypes = [wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel32.OpenProcess.restype = wintypes.HANDLE
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
advapi32.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE)]
advapi32.DuplicateTokenEx.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.POINTER(wintypes.HANDLE)]
advapi32.CreateProcessAsUserW.argtypes = [wintypes.HANDLE, wintypes.LPCWSTR, wintypes.LPWSTR, ctypes.c_void_p, ctypes.c_void_p, wintypes.BOOL, wintypes.DWORD, ctypes.c_void_p, wintypes.LPCWSTR, ctypes.POINTER(STARTUPINFOW), ctypes.POINTER(PROCESS_INFORMATION)]

def launch_in_active_session() -> bool:
    sess_id = kernel32.WTSGetActiveConsoleSessionId()
    if sess_id == 0xFFFFFFFF:
        return False
    snap = kernel32.CreateToolhelp32Snapshot(0x00000002, 0)
    pe = PROCESSENTRY32W(dwSize=ctypes.sizeof(PROCESSENTRY32W))
    winlogon_pid = 0
    if kernel32.Process32FirstW(snap, ctypes.byref(pe)):
        while True:
            if pe.szExeFile.lower() == "winlogon.exe":
                psid = wintypes.DWORD()
                if kernel32.ProcessIdToSessionId(pe.th32ProcessID, ctypes.byref(psid)) and psid.value == sess_id:
                    winlogon_pid = pe.th32ProcessID
                    break
            if not kernel32.Process32NextW(snap, ctypes.byref(pe)):
                break
    kernel32.CloseHandle(snap)
    if not winlogon_pid:
        return False
    h_proc = kernel32.OpenProcess(0x0400, False, winlogon_pid)
    h_tok, h_dup = wintypes.HANDLE(), wintypes.HANDLE()
    if not h_proc or not advapi32.OpenProcessToken(h_proc, 0x000B, ctypes.byref(h_tok)):
        return False
    ok = advapi32.DuplicateTokenEx(h_tok, 0x02000000, None, 2, 1, ctypes.byref(h_dup))
    kernel32.CloseHandle(h_tok)
    kernel32.CloseHandle(h_proc)
    if not ok:
        return False
    si = STARTUPINFOW(cb=ctypes.sizeof(STARTUPINFOW), lpDesktop="winsta0\\default")
    pi = PROCESS_INFORMATION()
    cmd = ctypes.create_unicode_buffer(f'"{sys.executable}" "{HELPER}"')
    created = advapi32.CreateProcessAsUserW(h_dup, None, cmd, None, None, False, 0x08000000, None, str(HELPER.parent), ctypes.byref(si), ctypes.byref(pi))
    kernel32.CloseHandle(h_dup)
    if created:
        LOG.write_text(f"Launched in Session {sess_id} (PID={pi.dwProcessId})\n", encoding="utf-8")
        kernel32.CloseHandle(pi.hThread)
        kernel32.CloseHandle(pi.hProcess)
    return bool(created)

if __name__ == "__main__":
    for _ in range(15):
        if launch_in_active_session():
            sys.exit(0)
        time.sleep(1)
    subprocess.Popen([sys.executable, str(HELPER)], creationflags=0x08000000)
