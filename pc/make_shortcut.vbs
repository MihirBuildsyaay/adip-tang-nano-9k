' Creates a desktop shortcut "ADiP Matrix Accelerator" that opens the app without a console.
' Usage (from install_autostart.bat):  cscript //nologo pc\make_shortcut.vbs
Option Explicit
Dim sh, fso, root, lnk
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName))
Set lnk = sh.CreateShortcut(sh.SpecialFolders("Desktop") & "\ADiP Matrix Accelerator.lnk")
lnk.TargetPath       = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\wscript.exe"
lnk.Arguments        = """" & root & "\ADiP_App.vbs" & """"
lnk.WorkingDirectory = root
lnk.Description      = "ADiP matrix accelerator - Tang Nano 9K"
lnk.IconLocation     = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\shell32.dll,12"
lnk.Save
WScript.Echo "Desktop shortcut created: ADiP Matrix Accelerator"
