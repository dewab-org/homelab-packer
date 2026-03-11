@echo off
setlocal

for %%i in (D E F G H I J K L M N O P) do (
  if exist "%%i:\bootstrap.ps1" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%%i:\bootstrap.ps1"
    exit /b 0
  )
)

exit /b 0

