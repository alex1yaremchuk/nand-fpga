@echo off
setlocal EnableExtensions

rem One-command build + SRAM program for blink_test (Tang Primer 20K Dock).
rem Usage:
rem   flash_blink_sram.cmd
rem   flash_blink_sram.cmd [cable_index] [device]
rem Example:
rem   flash_blink_sram.cmd 4 GW2A-18C

set "CABLE_INDEX=4"
set "DEVICE=GW2A-18C"

if not "%~1"=="" set "CABLE_INDEX=%~1"
if not "%~2"=="" set "DEVICE=%~2"

set "ROOT_DIR=%~dp0"
if "%ROOT_DIR:~-1%"=="\" set "ROOT_DIR=%ROOT_DIR:~0,-1%"

set "PROJECT_DIR=%ROOT_DIR%\blink_test"
set "PROJECT_GPRJ=%PROJECT_DIR%\blink_test.gprj"
set "PROJECT_GPRJ_FWD=%PROJECT_GPRJ:\=/%"
set "FS_FILE=%PROJECT_DIR%\impl\pnr\blink_test.fs"
set "PNR_LOG=%PROJECT_DIR%\impl\pnr\blink_test.log"

if not exist "%PROJECT_GPRJ%" (
  echo [ERROR] Project file not found: "%PROJECT_GPRJ%"
  exit /b 1
)

set "GOWIN_ROOT="
if defined GOWIN_HOME (
  if exist "%GOWIN_HOME%\IDE\bin\gw_sh.exe" set "GOWIN_ROOT=%GOWIN_HOME%"
)

if not defined GOWIN_ROOT (
  for /f "delims=" %%D in ('dir /b /ad /o-n "C:\Gowin\Gowin_V*_*x64" 2^>nul') do (
    if exist "C:\Gowin\%%D\IDE\bin\gw_sh.exe" (
      set "GOWIN_ROOT=C:\Gowin\%%D"
      goto :gowin_found
    )
  )
)

if not defined GOWIN_ROOT (
  for /f "delims=" %%D in ('dir /b /ad /o-n "C:\Gowin\Gowin_V*" 2^>nul') do (
    if exist "C:\Gowin\%%D\IDE\bin\gw_sh.exe" (
      set "GOWIN_ROOT=C:\Gowin\%%D"
      goto :gowin_found
    )
  )
)

:gowin_found
if not defined GOWIN_ROOT (
  echo [ERROR] Gowin install not found.
  echo         Set GOWIN_HOME, e.g.:
  echo         setx GOWIN_HOME "C:\Gowin\Gowin_V1.9.12.01_x64"
  exit /b 1
)

set "GW_SH=%GOWIN_ROOT%\IDE\bin\gw_sh.exe"
set "PROGRAMMER_CLI=%GOWIN_ROOT%\Programmer\bin\programmer_cli.exe"

if not exist "%GW_SH%" (
  echo [ERROR] gw_sh not found: "%GW_SH%"
  exit /b 1
)

if not exist "%PROGRAMMER_CLI%" (
  echo [ERROR] programmer_cli not found: "%PROGRAMMER_CLI%"
  exit /b 1
)

echo [INFO] Gowin root: "%GOWIN_ROOT%"
echo [INFO] Project   : "%PROJECT_GPRJ%"
echo [INFO] Device    : %DEVICE%
echo [INFO] Cable idx : %CABLE_INDEX%
echo.
echo [1/2] Build (synthesis + pnr)...

set "TCL_FILE=%TEMP%\nand-fpga-blink-build-%RANDOM%%RANDOM%.tcl"
(
  echo open_project "%PROJECT_GPRJ_FWD%"
  echo set_option -use_sspi_as_gpio 0
  echo run all
  echo exit
) > "%TCL_FILE%"

type "%TCL_FILE%" | "%GW_SH%"
set "BUILD_RC=%ERRORLEVEL%"
del "%TCL_FILE%" >nul 2>&1

if not "%BUILD_RC%"=="0" (
  echo [ERROR] Build failed with exit code %BUILD_RC%.
  exit /b %BUILD_RC%
)

if exist "%PNR_LOG%" (
  findstr /C:"ERROR  (" "%PNR_LOG%" >nul
  if not errorlevel 1 (
    echo [ERROR] PnR reported errors. Check "%PNR_LOG%"
    exit /b 1
  )
)

if not exist "%FS_FILE%" (
  echo [ERROR] Bitstream not found after build: "%FS_FILE%"
  exit /b 1
)

echo.
echo [2/2] SRAM program...
"%PROGRAMMER_CLI%" --device %DEVICE% --run 2 --fsFile "%FS_FILE%" --cable-index %CABLE_INDEX%
set "PROG_RC=%ERRORLEVEL%"

if not "%PROG_RC%"=="0" (
  echo [ERROR] Programming failed with exit code %PROG_RC%.
  exit /b %PROG_RC%
)

echo.
echo [OK] Build + SRAM program finished.
echo      Bitstream: "%FS_FILE%"
exit /b 0
