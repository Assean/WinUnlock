import socket, hmac, hashlib, time, ctypes, logging
from ctypes import wintypes
from pathlib import Path

LOG_FILE = Path(__file__).parent / "winlogon_helper.log"
PIN_FILE = Path(__file__).parent / ".pin_secret"
SECRET_KEY = b"MySuperSecretUnlockKey_2026"
logging.basicConfig(level=logging.INFO, format="%(asctime)s - [Helper] %(message)s", handlers=[logging.FileHandler(LOG_FILE, encoding="utf-8")])
logger = logging.getLogger("WinlogonHelper")

user32, kernel32, crypt32 = ctypes.windll.user32, ctypes.windll.kernel32, ctypes.windll.crypt32

class DATA_BLOB(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_byte))]
class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", ctypes.c_long), ("dy", ctypes.c_long), ("mouseData", ctypes.c_ulong), ("dwFlags", ctypes.c_ulong), ("time", ctypes.c_ulong), ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong))]
class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", ctypes.c_ushort), ("wScan", ctypes.c_ushort), ("dwFlags", ctypes.c_ulong), ("time", ctypes.c_ulong), ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong))]
class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [("uMsg", ctypes.c_ulong), ("wParamL", ctypes.c_short), ("wParamH", ctypes.c_ushort)]
class _INPUTunion(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]
class INPUT(ctypes.Structure):
    _fields_ = [("type", ctypes.c_ulong), ("union", _INPUTunion)]

user32.OpenInputDesktop.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
user32.OpenInputDesktop.restype = wintypes.HANDLE
user32.SetThreadDesktop.argtypes = [wintypes.HANDLE]
user32.SetThreadDesktop.restype = wintypes.BOOL
user32.CloseDesktop.argtypes = [wintypes.HANDLE]
user32.GetUserObjectInformationW.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
user32.SendInput.argtypes = [wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
user32.VkKeyScanW.argtypes = [wintypes.WCHAR]
user32.VkKeyScanW.restype = ctypes.c_short
user32.MapVirtualKeyW.argtypes = [wintypes.UINT, wintypes.UINT]
user32.MapVirtualKeyW.restype = wintypes.UINT
kernel32.LocalFree.argtypes = [wintypes.HLOCAL]
kernel32.ProcessIdToSessionId.argtypes = [wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
crypt32.CryptUnprotectData.argtypes = [ctypes.POINTER(DATA_BLOB), ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(DATA_BLOB)]
crypt32.CryptUnprotectData.restype = wintypes.BOOL

def get_pin() -> str:
    enc = PIN_FILE.read_bytes()
    buf = ctypes.create_string_buffer(enc, len(enc))
    b_in, b_out = DATA_BLOB(len(enc), ctypes.cast(buf, ctypes.POINTER(ctypes.c_byte))), DATA_BLOB()
    if not crypt32.CryptUnprotectData(ctypes.byref(b_in), None, None, None, None, 0, ctypes.byref(b_out)):
        raise ctypes.WinError()
    pin = ctypes.string_at(b_out.pbData, b_out.cbData).decode("utf-8")
    kernel32.LocalFree(b_out.pbData)
    return pin

def send_vk(vk: int, hold: float = 0.04):
    sc = user32.MapVirtualKeyW(vk, 0)
    user32.SendInput(1, ctypes.byref(INPUT(type=1, union=_INPUTunion(ki=KEYBDINPUT(wVk=vk, wScan=sc, dwFlags=0)))), ctypes.sizeof(INPUT))
    time.sleep(hold)
    user32.SendInput(1, ctypes.byref(INPUT(type=1, union=_INPUTunion(ki=KEYBDINPUT(wVk=vk, wScan=sc, dwFlags=2)))), ctypes.sizeof(INPUT))

def send_pin_keys(pin: str):
    for ch in pin:
        res = user32.VkKeyScanW(ch)
        vk, shift = res & 0xFF, (res >> 8) & 1
        if shift:
            sc_sh = user32.MapVirtualKeyW(0x10, 0)
            user32.SendInput(1, ctypes.byref(INPUT(type=1, union=_INPUTunion(ki=KEYBDINPUT(wVk=0x10, wScan=sc_sh)))), ctypes.sizeof(INPUT))
        send_vk(vk, 0.03)
        if shift:
            sc_sh = user32.MapVirtualKeyW(0x10, 0)
            user32.SendInput(1, ctypes.byref(INPUT(type=1, union=_INPUTunion(ki=KEYBDINPUT(wVk=0x10, wScan=sc_sh, dwFlags=2)))), ctypes.sizeof(INPUT))
        time.sleep(0.06)
    time.sleep(0.25)
    send_vk(0x0D, 0.04)

def attach_winlogon_desktop():
    h_desk = user32.OpenInputDesktop(0, False, 0x10000000) or user32.OpenInputDesktop(0, False, 0x01FF)
    if not h_desk:
        return None, "", f"OPEN_ERR({ctypes.GetLastError()})"
    name, needed = ctypes.create_unicode_buffer(256), wintypes.DWORD()
    user32.GetUserObjectInformationW(h_desk, 2, name, ctypes.sizeof(name), ctypes.byref(needed))
    if not user32.SetThreadDesktop(h_desk):
        err = ctypes.GetLastError()
        user32.CloseDesktop(h_desk)
        return None, name.value, f"SET_ERR({err})"
    return h_desk, name.value, "OK"

def unlock_winlogon() -> str:
    try:
        pin = get_pin()
    except Exception as e:
        return f"ERR:PIN_DECRYPT({e})"

    kernel32.SetThreadExecutionState(0x80000002)
    kernel32.SetThreadExecutionState(0x80000000)
    user32.SendInput(1, ctypes.byref(INPUT(type=0, union=_INPUTunion(mi=MOUSEINPUT(dx=3, dy=3, dwFlags=1)))), ctypes.sizeof(INPUT))
    time.sleep(0.8)

    h_desk, desk_name, st = attach_winlogon_desktop()
    if not h_desk:
        return f"ERR:{st}"
    try:
        if "winlogon" not in desk_name.lower():
            return f"SKIP:ALREADY_UNLOCKED({desk_name})"
        # 在 Session 1 內送出空白鍵掀開 LockApp 鎖屏簾幕，等待 1.3 秒讓 PIN 框取得焦點
        send_vk(0x20, 0.06)
        time.sleep(1.3)
        send_pin_keys(pin)
        return f"OK:PIN_INJECTED(len={len(pin)})"
    finally:
        user32.CloseDesktop(h_desk)

def serve():
    sid = wintypes.DWORD()
    kernel32.ProcessIdToSessionId(kernel32.GetCurrentProcessId(), ctypes.byref(sid))
    logger.info(f"Winlogon helper v7 started on 127.0.0.1:58923 (Session={sid.value})")
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", 58923))
        s.listen(5)
        while True:
            conn, _ = s.accept()
            with conn:
                parts = conn.recv(512).decode("utf-8", errors="ignore").strip().split("|")
                if len(parts) == 3 and parts[0] == "UNLOCK" and abs(time.time() - int(parts[1])) <= 15:
                    if hmac.compare_digest(hmac.new(SECRET_KEY, parts[1].encode(), hashlib.sha256).hexdigest(), parts[2]):
                        res = unlock_winlogon()
                        logger.info(f"Unlock result: {res}")
                        conn.sendall(res.encode("utf-8"))
                        continue
                conn.sendall(b"ERR:INVALID")

if __name__ == "__main__":
    serve()
