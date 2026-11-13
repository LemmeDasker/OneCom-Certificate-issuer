@echo off
rem Starter installationen af Let's Encrypt-certifikatet (one.com).
rem Dobbeltklik paa denne fil. Den beder selv om administratorrettigheder.
setlocal
title Certifikat - installation

set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PSEXE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%PSEXE%" (
    echo Windows PowerShell blev ikke fundet: %PSEXE%
    pause
    exit /b 1
)

if not exist "%~dp0Install-Certificate.ps1" (
    echo Install-Certificate.ps1 blev ikke fundet ved siden af Install.cmd.
    echo Hvis du har aabnet en ZIP-fil, saa pak hele ZIP-filen ud foerst.
    pause
    exit /b 1
)

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Certificate.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo Faerdig.
) else (
    echo Installationen sluttede med fejl eller blev afbrudt ^(kode %RC%^).
)
pause
exit /b %RC%
