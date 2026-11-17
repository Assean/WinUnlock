import sys, socket, subprocess, ctypes
from pathlib import Path

BASE = Path(r"D:\WinUnlock\windows")
print("=== 1. 環境與管理員權限檢查 ===")
print(f"目前終端機是否為管理員: {bool(ctypes.windll.shell32.IsUserAnAdmin())}")
print(f"虛擬環境 Python: {sys.executable}")
print(f"系統基底 Python: {Path(sys.base_prefix) / 'python.exe'}")

print("\n=== 2. 檔案行數與 DPAPI PIN 解密測試 ===")
for name in ["system_launcher.py", "winlogon_helper.py", "register_task.ps1"]:
    p = BASE / name
    lines = p.read_text(encoding="utf-8", errors="ignore").splitlines() if p.exists() else []
    print(f"{name}: {len(lines)} 行 | 末行: {lines[-1] if lines else '無'}")

try:
    sys.path.insert(0, str(BASE))
    import winlogon_helper
    pin = winlogon_helper.get_pin()
    print(f"PIN 解密測試: [OK] 成功 (長度 {len(pin)} 碼)")
except Exception as e:
    print(f"PIN 解密測試: [FAIL] {type(e).__name__}: {e}")
print("\n=== 3. 提權排程執行過程完整紀錄 ===")
rep = BASE / "bug_report.txt"
if rep.exists(): rep.unlink()
diag_ps = BASE / "_diag_elevated.ps1"
diag_ps.write_text(
    f"Start-Transcript -Path '{rep}' -Force\n"
    f"whoami\n"
    f"& '{BASE / 'register_task.ps1'}'\n"
    f"Get-ScheduledTask -TaskName 'WinUnlockAutoLogin' -EA SilentlyContinue | Format-List State, TaskName\n"
    f"Get-ScheduledTaskInfo -TaskName 'WinUnlockAutoLogin' -EA SilentlyContinue | Format-List LastTaskResult, LastRunTime\n"
    f"Stop-Transcript\n", encoding="utf-8"
)
subprocess.run(["powershell", "-NoProfile", "-Command", f"Start-Process powershell -Verb RunAs -Wait -ArgumentList '-ExecutionPolicy Bypass -File \"{diag_ps}\"'"])
print(rep.read_text(encoding="utf-8", errors="ignore") if rep.exists() else "[FAIL] 未產生 bug_report.txt（UAC 未點擊「是」或帳戶無管理員權限）")

print("\n=== 4. 背景代理日誌與 58923 連接埠 ===")
for lf in ["launcher_runtime.log", "winlogon_helper.log"]:
    lp = BASE / lf
    print(f"[{lf}]:\n{lp.read_text(encoding='utf-8', errors='ignore') if lp.exists() else '(尚無檔案)'}")
with socket.socket() as s:
    s.settimeout(1.0)
    print(f"58923 連接埠: {'[OK] 代理監聽中' if s.connect_ex(('127.0.0.1', 58923)) == 0 else '[FAIL] 拒絕連線(10061)'}")
