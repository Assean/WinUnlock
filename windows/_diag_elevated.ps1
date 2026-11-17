Start-Transcript -Path 'D:\WinUnlock\windows\bug_report.txt' -Force
whoami
& 'D:\WinUnlock\windows\register_task.ps1'
Get-ScheduledTask -TaskName 'WinUnlockAutoLogin' -EA SilentlyContinue | Format-List State, TaskName
Get-ScheduledTaskInfo -TaskName 'WinUnlockAutoLogin' -EA SilentlyContinue | Format-List LastTaskResult, LastRunTime
Stop-Transcript
