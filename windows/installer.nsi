; Usage Manager for Windows — per-user installer (no administrator rights).
; Built by scripts/build.sh:  makensis -DVERSION=x.y.z -DSRC=<release dir> -DOUT=<setup.exe> installer.nsi

Unicode true
!include "MUI2.nsh"

Name "Usage Manager"
OutFile "${OUT}"
InstallDir "$LOCALAPPDATA\Programs\Usage Manager"
RequestExecutionLevel user
SetCompressor /SOLID lzma

!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\UsageManager"
!define MUI_ICON "icons\icon.ico"
!define MUI_UNICON "icons\icon.ico"
!define MUI_FINISHPAGE_RUN "$INSTDIR\UsageManager.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Usage Manager 실행"

!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "Korean"

VIProductVersion "${VERSION}.0"
VIAddVersionKey /LANG=${LANG_KOREAN} "ProductName" "Usage Manager"
VIAddVersionKey /LANG=${LANG_KOREAN} "FileDescription" "Usage Manager 설치"
VIAddVersionKey /LANG=${LANG_KOREAN} "FileVersion" "${VERSION}"
VIAddVersionKey /LANG=${LANG_KOREAN} "ProductVersion" "${VERSION}"
VIAddVersionKey /LANG=${LANG_KOREAN} "LegalCopyright" "MIT"

; The window is drawn by WebView2, which Windows 11 ships with. Windows 10 may not.
Function CheckWebView2
  ReadRegStr $0 HKLM "SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
  StrCmp $0 "" 0 found
  ReadRegStr $0 HKCU "Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
  StrCmp $0 "" 0 found
  MessageBox MB_OK|MB_ICONINFORMATION "이 PC에 Microsoft Edge WebView2 런타임이 없습니다.$\n설치는 계속되지만, 창을 열려면 런타임이 필요합니다:$\nhttps://developer.microsoft.com/microsoft-edge/webview2/"
  found:
FunctionEnd

Section "Install"
  Call CheckWebView2
  ; A running copy holds the files open.
  nsExec::Exec 'taskkill /IM UsageManager.exe /F'
  Sleep 500
  SetOutPath "$INSTDIR"
  File "${SRC}\UsageManager.exe"
  File "${SRC}\WebView2Loader.dll"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateShortcut "$SMPROGRAMS\Usage Manager.lnk" "$INSTDIR\UsageManager.exe"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayName" "Usage Manager"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINST_KEY}" "Publisher" "beyondworks"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\UsageManager.exe"
  WriteRegStr HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINST_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "${UNINST_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  nsExec::Exec 'taskkill /IM UsageManager.exe /F'
  Sleep 500
  ; Take our hooks back out of Claude Code first; left behind, they would point at an
  ; executable that is about to be deleted.
  ExecWait '"$INSTDIR\UsageManager.exe" --hooks off'
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "Usage Manager"
  Delete "$INSTDIR\UsageManager.exe"
  Delete "$INSTDIR\WebView2Loader.dll"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\Usage Manager.lnk"
  DeleteRegKey HKCU "${UNINST_KEY}"
  ; ~/.usage-manager (settings, logs) is the user's and stays, as on macOS.
SectionEnd
