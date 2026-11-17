import py_compile, socket, subprocess
from pathlib import Path
BASE = Path(r"D:\WinUnlock\windows")
print("=== 1. 檔案與語法檢查 ===")
for f in [".pin_secret", "winlogon_helper.py", "system_launcher.py", "register_task.ps1"]:
    p = BASE / f
    if not p.exists(): print(f"[FAIL] 缺少 {f}")
    elif f.endswith(".py"):
        try: py_compile.compile(str(p), doraise=True); print(f"[OK] {f} 語法正常 ({p.stat().st_size}B)")
        except Exception as e: print(f"[FAIL] {f} 語法錯誤: {e}")
    else: print(f"[OK] {f} 存在 ({p.stat().st_size}B)")
print("\n=== 2. 排程與連接埠狀態 ===")
cmd = "Get-ScheduledTask -TaskName 'WinUnlockAutoLogin' -EA SilentlyContinue | % {\"State=$($_.State), LastResult=$((Get-ScheduledTaskInfo $_).LastTaskResult)\"}"
r = subprocess.run(["powershell", "-NoProfile", "-Command", cmd], capture_output=True, text=True)
print(f"排程狀態: {r.stdout.strip() or '[FAIL] 排程不存在'}")
with socket.socket() as s:
    s.settimeout(1.0)
    ok = s.connect_ex(("127.0.0.1", 58923)) == 0
    print(f"58923 連接埠: {'[OK] 代理監聽中' if ok else '[FAIL] 未啟動(拒絕連線)'}")
print("\n=== 3. 最新日誌內容 ===")
for log_name in ["launcher.log", "winlogon_helper.log"]:
    lp = BASE / log_name
    print(f"--- {log_name} ---")
    print("\n".join(lp.read_text(encoding="utf-8", errors="ignore").splitlines()[-5:]) if lp.exists() else "(尚無檔案)")
