$Out = "D:\WinUnlock\windows\task_out.txt"
Remove-Item $Out -Force -EA SilentlyContinue
$Py = "C:\Users\user\AppData\Local\Programs\Python\Python313\python.exe"
$Cmd = "/c `"`"$Py`" `"D:\WinUnlock\windows\system_launcher.py`" > `"$Out`" 2>&1`""
$Act = New-ScheduledTaskAction -Execute "cmd.exe" -Argument $Cmd -WorkingDirectory "D:\WinUnlock\windows"
Set-ScheduledTask -TaskName "WinUnlockAutoLogin" -Action $Act | Out-Null
Start-ScheduledTask -TaskName "WinUnlockAutoLogin"
Start-Sleep -Seconds 2
