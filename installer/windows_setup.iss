; ============================================================
; NEXUS OneApp – Inno Setup Installationsskript
; Compiler: Inno Setup 6 (https://jrsoftware.org/isdl.php)
; Erstellen: ISCC.exe installer\windows_setup.iss
; ============================================================

#define AppName      "N.E.X.U.S. OneApp"
#define AppVersion   "0.1.4"
#define AppPublisher "Projekt N.E.X.U.S. — Die Menschheitsfamilie"
#define AppURL       "https://nexus-terminal.org"
#define AppExeName   "nexus_oneapp.exe"
#define SourceDir    "..\build\windows\x64\runner\Release"

[Setup]
; Eindeutige App-ID – NICHT ÄNDERN (wird für saubere Updates benötigt)
AppId={{F3A2B7C1-8D4E-4F92-A3B6-7E1D2C5A9F08}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} v{#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
AppUpdatesURL={#AppURL}

; Installationsverzeichnis
DefaultDirName={autopf}\NEXUS OneApp
DefaultGroupName=NEXUS OneApp
DisableProgramGroupPage=no

; Ausgabe-Datei
OutputDir=Output
OutputBaseFilename=Setup_NexusOneApp_v{#AppVersion}

; Icons
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName}

; Kompression
Compression=lzma2/ultra64
SolidCompression=yes
LZMAUseSeparateProcess=yes

; Lizenz (AGPL v3 – Datei relativ zum .iss-Skript)
LicenseFile=..\LICENSE

; Wizard
WizardStyle=modern
WizardResizable=no

; Mindest-Windows-Version: Windows 10
MinVersion=10.0

; Installationsrechte: Nutzer kann ohne Admin-Rechte in eigenen Ordner installieren
; Dialog erscheint wenn Admin-Rechte vorhanden sind (bietet {pf} an)
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

; Nur 64-Bit-Windows unterstützt
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible

[Languages]
Name: "german"; MessagesFile: "compiler:Languages\German.isl"

[Tasks]
Name: "desktopicon";   \
  Description: "Desktop-Verknüpfung erstellen"; \
  GroupDescription: "Zusätzliche Verknüpfungen:"; \
  Flags: checkedonce
Name: "startmenuicon"; \
  Description: "Startmenü-Eintrag im Startmenü anlegen"; \
  GroupDescription: "Zusätzliche Verknüpfungen:"; \
  Flags: checkedonce

[Files]
; Alle Flutter-Release-Dateien rekursiv (EXE, DLLs, data/, flutter_assets/ usw.)
Source: "{#SourceDir}\*"; \
  DestDir: "{app}"; \
  Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; Startmenü-Einträge
Name: "{group}\{#AppName}"; \
  Filename: "{app}\{#AppExeName}"; \
  WorkingDir: "{app}"; \
  Tasks: startmenuicon
Name: "{group}\{#AppName} deinstallieren"; \
  Filename: "{uninstallexe}"; \
  Tasks: startmenuicon

; Desktop-Verknüpfung
Name: "{autodesktop}\{#AppName}"; \
  Filename: "{app}\{#AppExeName}"; \
  WorkingDir: "{app}"; \
  Tasks: desktopicon

[Run]
; "OneApp jetzt starten"-Checkbox auf der letzten Wizard-Seite
Filename: "{app}\{#AppExeName}"; \
  Description: "OneApp jetzt starten"; \
  Flags: nowait postinstall skipifsilent; \
  WorkingDir: "{app}"

[UninstallDelete]
; Deinstallation löscht nur das Programmverzeichnis.
; App-Daten in %APPDATA%\nexus_oneapp (Proto-POD, Identität, Chat-Verlauf)
; werden ABSICHTLICH NICHT gelöscht – Nutzer-Daten bleiben erhalten.
Type: filesandordirs; Name: "{app}"

[Messages]
WelcomeLabel1=Willkommen beim Setup-Assistenten für [name]
WelcomeLabel2=Dieser Assistent führt Sie durch die Installation von [name/ver].%n%nBitte schließen Sie alle anderen Programme, bevor Sie mit der Installation fortfahren.
FinishedHeadingLabel=Installation abgeschlossen
FinishedLabel=Die Installation von [name] wurde erfolgreich abgeschlossen.%n%nSie können die Anwendung über das Startmenü oder die Desktop-Verknüpfung starten.
ClickFinish=Klicken Sie auf Fertigstellen, um den Setup-Assistenten zu beenden.
