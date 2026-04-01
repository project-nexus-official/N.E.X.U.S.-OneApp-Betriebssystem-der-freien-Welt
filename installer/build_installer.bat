@echo off
setlocal EnableDelayedExpansion

echo ================================================================
echo  NEXUS OneApp – Windows Installer Build
echo ================================================================
echo.

:: Wechsel in das Repo-Root-Verzeichnis (ein Level über /installer)
cd /d "%~dp0.."

:: ----------------------------------------------------------------
:: Schritt 1: Flutter Windows Release Build
:: ----------------------------------------------------------------
echo [1/2] Flutter Windows Release Build...
echo.
flutter build windows --release
if %ERRORLEVEL% neq 0 (
    echo.
    echo FEHLER: Flutter Build fehlgeschlagen (Exit-Code %ERRORLEVEL%).
    echo Bitte prüfen Sie die Ausgabe oben.
    pause
    exit /b %ERRORLEVEL%
)
echo.
echo Flutter Build erfolgreich.
echo.

:: ----------------------------------------------------------------
:: Schritt 2: Inno Setup Compiler
:: ----------------------------------------------------------------
echo [2/2] Inno Setup Compiler (ISCC)...
echo.

:: Standard-Installationspfad von Inno Setup 6
set ISCC="C:\Program Files (x86)\Inno Setup 6\ISCC.exe"

if not exist %ISCC% (
    echo FEHLER: Inno Setup 6 wurde nicht gefunden unter:
    echo   C:\Program Files (x86)\Inno Setup 6\ISCC.exe
    echo.
    echo Bitte Inno Setup 6 installieren:
    echo   https://jrsoftware.org/isdl.php
    echo   (Standard-Installation genuegt)
    echo.
    pause
    exit /b 1
)

%ISCC% installer\windows_setup.iss
if %ERRORLEVEL% neq 0 (
    echo.
    echo FEHLER: Inno Setup Compiler fehlgeschlagen (Exit-Code %ERRORLEVEL%).
    pause
    exit /b %ERRORLEVEL%
)

:: ----------------------------------------------------------------
:: Fertig
:: ----------------------------------------------------------------
echo.
echo ================================================================
echo  FERTIG!
echo ================================================================
echo.
echo  Installer liegt in:
echo    %CD%\installer\Output\
echo.
echo  Datei: Setup_NexusOneApp_v0.1.3.exe
echo.
echo  Naechste Schritte:
echo    1. Installer testen (auf sauberer Windows-VM empfohlen)
echo    2. EXE auf GitHub Release hochladen
echo.
pause
endlocal
