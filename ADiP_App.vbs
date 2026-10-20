' ADiP_App.vbs - starts the ADiP laptop app WITHOUT a black command window.
' Double-click this file (or the desktop shortcut made by install_autostart.bat).
Option Explicit
Dim sh, fso, here, gui
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
gui  = """" & here & "\pc\adip_gui.py" & """"
sh.CurrentDirectory = here & "\pc"

On Error Resume Next
sh.Run "pythonw " & gui, 0, False          ' pythonw = Python without console
If Err.Number <> 0 Then
    Err.Clear
    sh.Run "pyw " & gui, 0, False          ' Python launcher, also console-free
    If Err.Number <> 0 Then
        MsgBox "Python was not found." & vbCrLf & _
               "Install Python from python.org and tick 'Add python.exe to PATH'," & vbCrLf & _
               "then run run_gui.bat once (it installs pyserial).", vbExclamation, "ADiP"
    End If
End If
