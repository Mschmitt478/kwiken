Unicode true
RequestExecutionLevel user
SetCompressor /SOLID lzma
SetCompressorDictSize 64

!include "MUI2.nsh"

!ifndef VERSION
  !error "VERSION is required"
!endif
!ifndef RELEASE_VERSION
  !define RELEASE_VERSION "${VERSION}"
!endif
!ifndef STAGING
  !error "STAGING is required"
!endif
!ifndef OUTFILE
  !error "OUTFILE is required"
!endif
!ifndef ICON
  !error "ICON is required"
!endif

Name "Kwiken"
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\Programs\Kwiken"
InstallDirRegKey HKCU "Software\Kwiken" "InstallLocation"
Icon "${ICON}"
UninstallIcon "${ICON}"
BrandingText "Kwiken - Chromium without the clutter"
VIProductVersion "${VERSION}"
VIAddVersionKey /LANG=1033 "ProductName" "Kwiken"
VIAddVersionKey /LANG=1033 "CompanyName" "Kwiken"
VIAddVersionKey /LANG=1033 "FileDescription" "Kwiken Browser Setup"
VIAddVersionKey /LANG=1033 "FileVersion" "${RELEASE_VERSION}"
VIAddVersionKey /LANG=1033 "ProductVersion" "${RELEASE_VERSION}"
VIAddVersionKey /LANG=1033 "LegalCopyright" "Kwiken contributors and The Chromium Authors"

!define MUI_ABORTWARNING
!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
!define MUI_FINISHPAGE_RUN "$INSTDIR\Kwiken.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Launch Kwiken"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

Function .onInit
  ReadRegStr $0 HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\9b916dfc-c8c9-5d81-99d6-26552d6a29f0" "UninstallString"
  StrCmp $0 "" migration_complete
  RMDir /r "$LOCALAPPDATA\Programs\Kwiken"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\9b916dfc-c8c9-5d81-99d6-26552d6a29f0"
  DeleteRegKey HKCU "Software\Classes\kwiken"
migration_complete:
FunctionEnd

Section "Kwiken" MainSection
  SetShellVarContext current
  SetOverwrite on
  SetOutPath "$INSTDIR"
  File /r "${STAGING}\*"
  WriteUninstaller "$INSTDIR\Uninstall Kwiken.exe"

  CreateDirectory "$SMPROGRAMS\Kwiken"
  CreateShortcut "$SMPROGRAMS\Kwiken\Kwiken.lnk" "$INSTDIR\Kwiken.exe" "" "$INSTDIR\Kwiken.exe" 0
  CreateShortcut "$SMPROGRAMS\Kwiken\Choose Kwiken as default.lnk" "$SYSDIR\cmd.exe" '/c start ms-settings:defaultapps?registeredAppUser=Kwiken' "$INSTDIR\Kwiken.exe" 0 SW_SHOWNORMAL "" "Open Windows default-app settings for Kwiken"
  CreateShortcut "$DESKTOP\Kwiken.lnk" "$INSTDIR\Kwiken.exe" "" "$INSTDIR\Kwiken.exe" 0
  ExecWait '"$INSTDIR\Kwiken.exe" --repair-shortcuts'

  WriteRegStr HKCU "Software\Kwiken" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\App Paths\Kwiken.exe" "" "$INSTDIR\Kwiken.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\App Paths\Kwiken.exe" "Path" "$INSTDIR\runtime"

  WriteRegStr HKCU "Software\Classes\KwikenURL" "" "Kwiken Web Document"
  WriteRegStr HKCU "Software\Classes\KwikenURL" "URL Protocol" ""
  WriteRegStr HKCU "Software\Classes\KwikenURL\DefaultIcon" "" "$INSTDIR\Kwiken.exe,0"
  WriteRegStr HKCU "Software\Classes\KwikenURL\shell\open\command" "" '$\"$INSTDIR\Kwiken.exe$\" $\"%1$\"'

  WriteRegStr HKCU "Software\Classes\KwikenHTML" "" "Kwiken HTML Document"
  WriteRegStr HKCU "Software\Classes\KwikenHTML\DefaultIcon" "" "$INSTDIR\Kwiken.exe,0"
  WriteRegStr HKCU "Software\Classes\KwikenHTML\shell\open\command" "" '$\"$INSTDIR\Kwiken.exe$\" $\"%1$\"'

  WriteRegStr HKCU "Software\Classes\KwikenPDF" "" "Kwiken PDF Document"
  WriteRegStr HKCU "Software\Classes\KwikenPDF\DefaultIcon" "" "$INSTDIR\Kwiken.exe,0"
  WriteRegStr HKCU "Software\Classes\KwikenPDF\shell\open\command" "" '$\"$INSTDIR\Kwiken.exe$\" $\"%1$\"'

  WriteRegStr HKCU "Software\Clients\StartMenuInternet\Kwiken" "" "Kwiken"
  WriteRegStr HKCU "Software\Clients\StartMenuInternet\Kwiken\DefaultIcon" "" "$INSTDIR\Kwiken.exe,0"
  WriteRegStr HKCU "Software\Clients\StartMenuInternet\Kwiken\shell\open\command" "" '$\"$INSTDIR\Kwiken.exe$\"'
  WriteRegStr HKCU "Software\Clients\StartMenuInternet\Kwiken\Capabilities" "ApplicationDescription" "A calm, lightweight Chromium browser with native vertical tabs."
  WriteRegStr HKCU "Software\Clients\StartMenuInternet\Kwiken\Capabilities" "ApplicationIcon" "$INSTDIR\Kwiken.exe,0"
  WriteRegStr HKCU "Software\Clients\StartMenuInternet\Kwiken\Capabilities" "ApplicationName" "Kwiken"
  WriteRegStr HKCU "Software\Clients\StartMenuInternet\Kwiken\Capabilities\FileAssociations" ".htm" "KwikenHTML"
  WriteRegStr HKCU "Software\Clients\StartMenuInternet\Kwiken\Capabilities\FileAssociations" ".html" "KwikenHTML"
  WriteRegStr HKCU "Software\Clients\StartMenuInternet\Kwiken\Capabilities\FileAssociations" ".pdf" "KwikenPDF"
  WriteRegStr HKCU "Software\Clients\StartMenuInternet\Kwiken\Capabilities\URLAssociations" "http" "KwikenURL"
  WriteRegStr HKCU "Software\Clients\StartMenuInternet\Kwiken\Capabilities\URLAssociations" "https" "KwikenURL"
  WriteRegStr HKCU "Software\RegisteredApplications" "Kwiken" "Software\Clients\StartMenuInternet\Kwiken\Capabilities"

  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Kwiken" "DisplayName" "Kwiken"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Kwiken" "DisplayIcon" "$INSTDIR\Kwiken.exe,0"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Kwiken" "DisplayVersion" "${RELEASE_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Kwiken" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Kwiken" "Publisher" "Kwiken"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Kwiken" "UninstallString" '$\"$INSTDIR\Uninstall Kwiken.exe$\"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Kwiken" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Kwiken" "NoRepair" 1

  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  Delete "$DESKTOP\Kwiken.lnk"
  RMDir /r "$SMPROGRAMS\Kwiken"

  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Kwiken"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\App Paths\Kwiken.exe"
  DeleteRegValue HKCU "Software\RegisteredApplications" "Kwiken"
  DeleteRegKey HKCU "Software\Clients\StartMenuInternet\Kwiken"
  DeleteRegKey HKCU "Software\Classes\KwikenURL"
  DeleteRegKey HKCU "Software\Classes\KwikenHTML"
  DeleteRegKey HKCU "Software\Classes\KwikenPDF"
  DeleteRegKey HKCU "Software\Kwiken"

  RMDir /r "$INSTDIR"
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'
SectionEnd
