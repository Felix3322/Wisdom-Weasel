!include "LogicLib.nsh"
!include "MUI2.nsh"

Unicode true
RequestExecutionLevel admin
ShowInstDetails show
AutoCloseWindow false
BrandingText "Wisdom-Weasel bootstrap installer"

!ifndef APP_NAME
!define APP_NAME "Wisdom-Weasel Installer"
!endif

!ifndef APP_VERSION
!define APP_VERSION "dev"
!endif

!ifndef APP_VERSION_NUMERIC
!define APP_VERSION_NUMERIC "0.0.0.0"
!endif

!ifndef OUTPUT_FILE
!error "OUTPUT_FILE is required"
!endif

!ifndef SOURCE_ROOT
!error "SOURCE_ROOT is required"
!endif

!ifndef LICENSE_FILE
!error "LICENSE_FILE is required"
!endif

!ifndef ICON_FILE
!error "ICON_FILE is required"
!endif

Name "${APP_NAME}"
OutFile "${OUTPUT_FILE}"
InstallDir "$TEMP\Wisdom-Weasel-bootstrap"

VIProductVersion "${APP_VERSION_NUMERIC}"
VIAddVersionKey /LANG=2052 "ProductName" "${APP_NAME}"
VIAddVersionKey /LANG=2052 "Comments" "Bootstrap installer without bundled Alpha models"
VIAddVersionKey /LANG=2052 "CompanyName" "Wisdom-Weasel"
VIAddVersionKey /LANG=2052 "FileDescription" "${APP_NAME}"
VIAddVersionKey /LANG=2052 "FileVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "ProductVersion" "${APP_VERSION}"

!define MUI_ABORTWARNING
!define MUI_ICON "${ICON_FILE}"
!define MUI_UNICON "${ICON_FILE}"
!define MUI_WELCOMEPAGE_TITLE "Install Wisdom-Weasel"
!define MUI_WELCOMEPAGE_TEXT "This bootstrap installer does not bundle Alpha models. Runtime files come from GitHub Release, and Alpha models can be downloaded from Hugging Face and converted locally."
!define MUI_FINISHPAGE_TITLE "Wisdom-Weasel bootstrap finished"
!define MUI_FINISHPAGE_TEXT "If the PowerShell installer has completed, click Finish."

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${LICENSE_FILE}"
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

Section "Bootstrap"
  InitPluginsDir
  SetOutPath "$PLUGINSDIR\bootstrap"
  File /r "${SOURCE_ROOT}\*.*"
  DetailPrint "Starting Wisdom-Weasel PowerShell installer..."
  ExecWait '"$SYSDIR\cmd.exe" /c ""$PLUGINSDIR\bootstrap\Install-Wisdom-Weasel.cmd"""' $0
  ${If} $0 != 0
    MessageBox MB_OK|MB_ICONSTOP "The PowerShell installer returned exit code $0. Please review the console output."
    SetErrorLevel $0
    Abort
  ${EndIf}
SectionEnd
