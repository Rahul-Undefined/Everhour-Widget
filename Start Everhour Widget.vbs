' Starts the Everhour widget silently - no console, no taskbar button.
' Double-click this once. It also sets itself to run at every Windows start.
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "\EverhourWidget.ps1"""
' conhost --headless creates no window, even when Windows Terminal is the default terminal
If fso.FileExists(sh.ExpandEnvironmentStrings("%WINDIR%") & "\System32\conhost.exe") Then cmd = "conhost.exe --headless " & cmd
sh.Run cmd, 0, False
