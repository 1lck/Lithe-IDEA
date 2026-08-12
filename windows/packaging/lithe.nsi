!ifndef PRODUCT_VERSION
  !define PRODUCT_VERSION "0.0.0"
!endif
!ifndef INPUT_DIR
  !define INPUT_DIR "dist\lithe-stage"
!endif
!ifndef OUTPUT_FILE
  !define OUTPUT_FILE "dist\Lithe-${PRODUCT_VERSION}-windows-x64.exe"
!endif

Name "Lithe ${PRODUCT_VERSION}"
OutFile "${OUTPUT_FILE}"
InstallDir "$PROGRAMFILES64\Lithe"
InstallDirRegKey HKLM "Software\Lithe" "InstallDir"
RequestExecutionLevel admin
Unicode True
SetCompressor /SOLID lzma
Icon "${__FILEDIR__}\lithe.ico"

!include "MUI2.nsh"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\Lithe.exe"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_LANGUAGE "English"

Section "Lithe"
  SetOutPath "$INSTDIR"
  File /r "${INPUT_DIR}\*.*"
  WriteRegStr HKLM "Software\Lithe" "InstallDir" "$INSTDIR"
  WriteUninstaller "$INSTDIR\uninstall.exe"
  CreateDirectory "$SMPROGRAMS\Lithe"
  CreateShortCut "$SMPROGRAMS\Lithe\Lithe.lnk" "$INSTDIR\Lithe.exe"
  CreateShortCut "$DESKTOP\Lithe.lnk" "$INSTDIR\Lithe.exe"
SectionEnd

Section "Uninstall"
  Delete "$DESKTOP\Lithe.lnk"
  Delete "$SMPROGRAMS\Lithe\Lithe.lnk"
  RMDir "$SMPROGRAMS\Lithe"
  DeleteRegKey HKLM "Software\Lithe"
  RMDir /r "$INSTDIR"
SectionEnd
