' Starts the Everhour widget silently - no console, no taskbar button.
' Double-click this once. It also sets itself to run at every Windows start.
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & here & "\EverhourWidget.ps1""", 0, False
