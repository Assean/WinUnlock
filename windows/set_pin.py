import ctypes
from ctypes import wintypes
import getpass
from pathlib import Path

class DATA_BLOB(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_byte))]

def dpapi_encrypt(raw_bytes: bytes) -> bytes:
    buf = ctypes.create_string_buffer(raw_bytes, len(raw_bytes))
    blob_in = DATA_BLOB(len(raw_bytes), ctypes.cast(buf, ctypes.POINTER(ctypes.c_byte)))
    blob_out = DATA_BLOB()
    # CRYPTPROTECT_LOCAL_MACHINE = 0x4，允許本機 SYSTEM 服務解密
    if not ctypes.windll.crypt32.CryptProtectData(
        ctypes.byref(blob_in), "WinUnlockPIN", None, None, None, 0x4, ctypes.byref(blob_out)
    ):
        raise ctypes.WinError()
    encrypted = ctypes.string_at(blob_out.pbData, blob_out.cbData)
    ctypes.windll.kernel32.LocalFree(blob_out.pbData)
    return encrypted

if __name__ == "__main__":
    pin = getpass.getpass("請輸入你的 Windows 登入 PIN 碼 (輸入時隱藏): ").strip()
    if not pin:
        print("❌ PIN 碼不能為空！")
        exit(1)
    secret_path = Path(__file__).parent / ".pin_secret"
    secret_path.write_bytes(dpapi_encrypt(pin.encode("utf-8")))
    print(f"✅ PIN 碼已透過 Windows DPAPI 加密儲存至 {secret_path}")
