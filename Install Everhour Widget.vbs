' Installs the Everhour widget for this Windows user (no admin rights):
' copies it to %LOCALAPPDATA%\Programs\EverhourWidget and starts it there,
' so it keeps working even if this folder is deleted afterwards.
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "\EverhourWidget.ps1"" -Setup"
If fso.FileExists(sh.ExpandEnvironmentStrings("%WINDIR%") & "\System32\conhost.exe") Then cmd = "conhost.exe --headless " & cmd
sh.Run cmd, 0, False
