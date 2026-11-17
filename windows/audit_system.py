import socket, py_compile
from pathlib import Path

WIN = Path(r"D:\WinUnlock\windows")
IOS = Path(r"D:\WinUnlock\ios\Sources")

print("=== [1] Windows 端程式碼與服務檢查 ===")
for name in ["win_unlock_server.py", "winlogon_helper.py", "system_launcher.py"]:
    p = WIN / name
    if p.exists():
        lines = p.read_text(encoding="utf-8", errors="ignore").splitlines()
        try:
            py_compile.compile(str(p), doraise=True)
            st = "語法OK"
        except Exception as e:
            st = f"語法錯:{e}"
        print(f"- {name}: {len(lines)} 行 | {st}")
    else:
        print(f"- {name}: [缺少檔案]")

with socket.socket() as s:
    s.settimeout(1.0)
    print(f"- 58923 SYSTEM 代理: {'[OK] 監聽中' if s.connect_ex(('127.0.0.1', 58923)) == 0 else '[FAIL] 未啟動'}")

for log_name in ["winlogon_helper.log", "server.log"]:
    lp = WIN / log_name
    print(f"\n--- {log_name} (最新 8 行) ---")
    print("\n".join(lp.read_text(encoding="utf-8", errors="ignore").splitlines()[-8:]) if lp.exists() else "(尚無紀錄)")
print("\n=== [2] iOS 端 Swift 程式碼與連線邏輯檢查 ===")
ble = IOS / "BLEManager.swift"
if ble.exists():
    code = ble.read_text(encoding="utf-8", errors="ignore")
    checks = {
        "Service UUID (fff0)": "fff0" in code.lower(),
        "Char UUID (fff1)": "fff1" in code.lower(),
        "iBeacon UUID": "a1b2c3d4" in code.lower(),
        "共用金鑰一致": "MySuperSecretUnlockKey_2026" in code,
        "寫入後主動斷線 (cancelPeripheralConnection)": "cancelPeripheralConnection" in code,
        "背景狀態還原 (RestoreIdentifier)": "CBCentralManagerOptionRestoreIdentifierKey" in code,
        "RSSI 距離門檻過濾": "rssi" in code.lower()
    }
    for k, v in checks.items():
        print(f"- {k}: {'[OK]' if v else '[注意/缺少]'}")
    print("\n--- BLEManager.swift 完整內容 ---")
    print(code)
else:
    print("[FAIL] 找不到 D:\\WinUnlock\\ios\\Sources\\BLEManager.swift")
