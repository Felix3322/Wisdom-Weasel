@echo off

setlocal

if not exist env.bat copy env.bat.template env.bat

if exist env.bat call env.bat

if not defined WEASEL_ROOT set WEASEL_ROOT=%CD%

if not defined VERSION_MAJOR set VERSION_MAJOR=0
if not defined VERSION_MINOR set VERSION_MINOR=17
if not defined VERSION_PATCH set VERSION_PATCH=4

if not defined WEASEL_VERSION set WEASEL_VERSION=%VERSION_MAJOR%.%VERSION_MINOR%.%VERSION_PATCH%
if not defined WEASEL_BUILD set WEASEL_BUILD=0

rem use numeric build version for release build
set PRODUCT_VERSION=%WEASEL_VERSION%.%WEASEL_BUILD%
rem for non-release build, try to use git commit hash as product build version
if not defined RELEASE_BUILD (
  rem check if git is installed and available, then get the short commit id of head
  git --version >nul 2>&1
  if not errorlevel 1 (
    for /f "delims=" %%i in ('git tag --sort=-creatordate ^| findstr /r "%WEASEL_VERSION%"') do (
      set LAST_TAG=%%i
      goto found_tag
    )
    :found_tag
    for /f "delims=" %%i in ('git rev-list %LAST_TAG%..HEAD --count') do (
      set WEASEL_BUILD=%%i
    )
    rem get short commmit id of head
    for /F %%i in ('git rev-parse --short HEAD') do (set PRODUCT_VERSION=%WEASEL_VERSION%.%WEASEL_BUILD%.%%i)
  )
)

rem FILE_VERSION is always 4 numbers; same as PRODUCT_VERSION in release build
if not defined FILE_VERSION set FILE_VERSION=%WEASEL_VERSION%.%WEASEL_BUILD%

echo PRODUCT_VERSION=%PRODUCT_VERSION%
echo WEASEL_VERSION=%WEASEL_VERSION%
echo WEASEL_BUILD=%WEASEL_BUILD%
echo WEASEL_ROOT=%WEASEL_ROOT%
echo WEASEL_BUNDLED_RECIPES=%WEASEL_BUNDLED_RECIPES%
echo.

if defined GITHUB_ENV (
  setlocal enabledelayedexpansion
  echo git_ref_name=%PRODUCT_VERSION%>>!GITHUB_ENV!
)

if defined BOOST_ROOT (
  if exist "%BOOST_ROOT%\boost" goto boost_found
)
echo Error: Boost not found! Please set BOOST_ROOT in env.bat.
exit /b 1

:boost_found
echo BOOST_ROOT=%BOOST_ROOT%
echo.

if not defined BJAM_TOOLSET (
  rem the number actually means platform toolset, not %VisualStudioVersion%
  set BJAM_TOOLSET=msvc-14.3
)

if not defined PLATFORM_TOOLSET (
  set PLATFORM_TOOLSET=v143
)

if defined DEVTOOLS_PATH set PATH=%DEVTOOLS_PATH%%PATH%
set MSBUILD_EXE=

set build_config=Release
set build_option=/t:Build
set build_boost=0
set boost_build_variant=release
set build_data=0
set build_weasel=0
set build_installer=0
set build_arm64=0
set build_x64=0
set build_x86=0

rem parse the command line options
:parse_cmdline_options
  if "%1" == "" goto end_parsing_cmdline_options
  if "%1" == "debug" (
    set build_config=Debug
    set boost_build_variant=debug
  )
  if "%1" == "release" (
    set build_config=Release
    set boost_build_variant=release
  )
  if "%1" == "rebuild" set build_option=/t:Rebuild
  if "%1" == "boost" set build_boost=1
  if "%1" == "data" set build_data=1
  if "%1" == "weasel" set build_weasel=1
  if "%1" == "installer" set build_installer=1
  if "%1" == "arm64" set build_arm64=1
  if "%1" == "x64" set build_x64=1
  if "%1" == "x86" set build_x86=1
  if "%1" == "all" (
    set build_boost=1
    set build_data=1
    set build_weasel=1
    set build_installer=1
    set build_arm64=1
  )
  shift
  goto parse_cmdline_options
:end_parsing_cmdline_options

if %build_weasel% == 0 (
if %build_boost% == 0 (
if %build_data% == 0 (
  set build_weasel=1
)))

rem quit WeaselServer.exe before building
cd /d %WEASEL_ROOT%
if exist output\weaselserver.exe (
  output\weaselserver.exe /q
)

rem build booost
if %build_boost% == 1 (
  call :build_boost
  if errorlevel 1 exit /b 1
  cd /d %WEASEL_ROOT%
)

rem -------------------------------------------------------------------------
if %build_weasel% == 1 (
  if not exist output\data\essay.txt (
    set build_data=1
  )
)
if %build_data% == 1 call :build_data

if %build_weasel% == 0 goto end

cd /d %WEASEL_ROOT%

set WEASEL_PROJECT_PROPERTIES=BOOST_ROOT^
  PLATFORM_TOOLSET^
  VERSION_MAJOR^
  VERSION_MINOR^
  VERSION_PATCH^
  PRODUCT_VERSION^
  FILE_VERSION

call :render_weasel_props
if errorlevel 1 goto error_render_props

del msbuild*.log

if defined SDKVER set build_sdk_option=/p:WindowsTargetPlatformVersion=%SDKVER%
if not defined SDKVER set build_sdk_option=

call :ensure_msbuild
if errorlevel 1 goto error_msbuild_not_found

if %build_arm64% == 1 (

  "%MSBUILD_EXE%" weasel.sln %build_option% /p:Configuration=%build_config% /p:Platform="ARM" /fl6 %build_sdk_option%
  if errorlevel 1 goto error
  "%MSBUILD_EXE%" weasel.sln %build_option% /p:Configuration=%build_config% /p:Platform="ARM64" /fl5 %build_sdk_option%
  if errorlevel 1 goto error
)

rem if neither x64 nor x86 is specified, build both (backward compatibility)
if %build_x64% == 0 (
if %build_x86% == 0 (
  set build_x64=1
))

if %build_x64% == 1 (
  "%MSBUILD_EXE%" weasel.sln %build_option% /p:Configuration=%build_config% /p:Platform="x64" /fl2 %build_sdk_option%
  if errorlevel 1 goto error
  call :build_alpha_rerank_core x64
  if errorlevel 1 goto error
)

if %build_x86% == 1 (
  "%MSBUILD_EXE%" weasel.sln %build_option% /p:Configuration=%build_config% /p:Platform="Win32" /fl1 %build_sdk_option%
  if errorlevel 1 goto error
  call :build_alpha_rerank_core Win32
  if errorlevel 1 goto error
)

if %build_arm64% == 1 (
  pushd arm64x_wrapper
  call build.bat
  if errorlevel 1 goto error
  popd

  copy arm64x_wrapper\weaselARM64X.dll output
  if errorlevel 1 goto error
  copy arm64x_wrapper\weaselARM64X.ime output
  if errorlevel 1 goto error
)

if %build_installer% == 1 (
  "%ProgramFiles(x86)%"\NSIS\Bin\makensis.exe ^
  /DWEASEL_VERSION=%WEASEL_VERSION% ^
  /DWEASEL_BUILD=%WEASEL_BUILD% ^
  /DPRODUCT_VERSION=%PRODUCT_VERSION% ^
  output\install.nsi
  if errorlevel 1 goto error
)

goto end

rem -------------------------------------------------------------------------
rem find msbuild and render props without relying on WSH/cscript
:ensure_msbuild
  if defined MSBUILD_EXE goto end_ensure_msbuild
  where msbuild.exe >nul 2>&1
  if not errorlevel 1 (
    set MSBUILD_EXE=msbuild.exe
    goto end_ensure_msbuild
  )

  set VSWHERE_EXE=
  if exist "%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" set "VSWHERE_EXE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
  if not defined VSWHERE_EXE if exist "%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe" set "VSWHERE_EXE=%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"

  if defined VSWHERE_EXE (
    for /f "usebackq delims=" %%i in (`"%VSWHERE_EXE%" -latest -products * -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe`) do (
      if not defined MSBUILD_EXE set MSBUILD_EXE=%%i
    )
  )

  if not defined MSBUILD_EXE exit /b 1

  for %%i in ("%MSBUILD_EXE%") do set "MSBUILD_DIR=%%~dpi"
  if defined MSBUILD_DIR set "PATH=%MSBUILD_DIR%;%PATH%"
  exit /b 0
:end_ensure_msbuild
  exit /b 0

:ensure_msvc_tools
  set MSVC_TARGET_ARCH=%1
  if "%MSVC_TARGET_ARCH%" == "" set MSVC_TARGET_ARCH=x64
  where cl.exe >nul 2>&1
  if errorlevel 1 goto load_msvc_tools
  where link.exe >nul 2>&1
  if errorlevel 1 goto load_msvc_tools
  exit /b 0

:load_msvc_tools
  if not defined VSWHERE_EXE (
    if exist "%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" set "VSWHERE_EXE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
    if not defined VSWHERE_EXE if exist "%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe" set "VSWHERE_EXE=%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"
  )

  set VS_INSTALL_DIR=
  if defined VSWHERE_EXE (
    for /f "usebackq delims=" %%i in (`"%VSWHERE_EXE%" -latest -products * -requires Microsoft.Component.MSBuild -property installationPath`) do (
      if not defined VS_INSTALL_DIR set "VS_INSTALL_DIR=%%i"
    )
  )

  if not defined VS_INSTALL_DIR exit /b 1
  if not exist "%VS_INSTALL_DIR%\Common7\Tools\VsDevCmd.bat" exit /b 1

  call "%VS_INSTALL_DIR%\Common7\Tools\VsDevCmd.bat" -host_arch=x64 -arch=%MSVC_TARGET_ARCH% >nul
  where cl.exe >nul 2>&1
  if errorlevel 1 exit /b 1
  where link.exe >nul 2>&1
  if errorlevel 1 exit /b 1
  exit /b 0

:render_weasel_props
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "$props = @('BOOST_ROOT','PLATFORM_TOOLSET','VERSION_MAJOR','VERSION_MINOR','VERSION_PATCH','PRODUCT_VERSION','FILE_VERSION');" ^
    "$template = Get-Content 'weasel.props.template' -Raw -Encoding UTF8;" ^
    "foreach ($name in $props) { $value = [Environment]::GetEnvironmentVariable($name, 'Process'); $template = $template.Replace('$' + $name, $value) };" ^
    "Set-Content 'weasel.props' -Value $template -Encoding UTF8;" ^
    "foreach ($name in $props) { Write-Host ($name + '=' + [Environment]::GetEnvironmentVariable($name, 'Process')) };" ^
    "Write-Host 'Generated weasel.props'"
  exit /b %ERRORLEVEL%

rem -------------------------------------------------------------------------
rem build boost
:build_boost
  set BJAM_OPTIONS_COMMON=-j%NUMBER_OF_PROCESSORS%^
    --with-serialization^
    define=BOOST_USE_WINAPI_VERSION=0x0603^
    toolset=%BJAM_TOOLSET%^
    link=static^
    runtime-link=static^
    --build-type=complete
  
  set BJAM_OPTIONS_X86=%BJAM_OPTIONS_COMMON%^
    architecture=x86^
    address-model=32
  
  set BJAM_OPTIONS_X64=%BJAM_OPTIONS_COMMON%^
    architecture=x86^
    address-model=64
  
  set BJAM_OPTIONS_ARM32=%BJAM_OPTIONS_COMMON%^
    define=BOOST_USE_WINAPI_VERSION=0x0A00^
    architecture=arm^
    address-model=32
  
  set BJAM_OPTIONS_ARM64=%BJAM_OPTIONS_COMMON%^
    define=BOOST_USE_WINAPI_VERSION=0x0A00^
    architecture=arm^
    address-model=64
  
  cd /d %BOOST_ROOT%
  if not exist b2.exe call bootstrap.bat
  if errorlevel 1 goto error
  b2 %BJAM_OPTIONS_X86% stage %BOOST_COMPILED_LIBS%
  if errorlevel 1 goto error
  b2 %BJAM_OPTIONS_X64% stage %BOOST_COMPILED_LIBS%
  if errorlevel 1 goto error
  
  if %build_arm64% == 1 (
    b2 %BJAM_OPTIONS_ARM32% stage %BOOST_COMPILED_LIBS%
    if errorlevel 1 goto error
    b2 %BJAM_OPTIONS_ARM64% stage %BOOST_COMPILED_LIBS%
    if errorlevel 1 goto error
  )
  exit /b

rem ---------------------------------------------------------------------------
:build_alpha_rerank_core
  set alpha_platform=%1
  if "%alpha_platform%" == "" exit /b 1

  set alpha_outdir=
  set alpha_machine=
  set alpha_rime_lib=
  set alpha_vs_arch=
  if "%alpha_platform%" == "x64" (
    set alpha_outdir=output\lua\wanxiang
    set alpha_machine=/MACHINE:X64
    set alpha_rime_lib=lib64\rime.lib
    set alpha_vs_arch=x64
  )
  if "%alpha_platform%" == "Win32" (
    set alpha_outdir=output\Win32\lua\wanxiang
    set alpha_machine=/MACHINE:X86
    set alpha_rime_lib=lib\rime.lib
    set alpha_vs_arch=x86
  )
  if not defined alpha_outdir exit /b 1

  call :ensure_msvc_tools %alpha_vs_arch%
  if errorlevel 1 goto error

  if not exist %alpha_outdir% mkdir %alpha_outdir%

  set alpha_runtime=/MT
  set alpha_opt=/O2 /DNDEBUG
  if /I "%build_config%" == "Debug" (
    set alpha_runtime=/MTd
    set alpha_opt=/Od /Zi
  )

  cl.exe /nologo /LD /std:c++17 /EHsc /utf-8 %alpha_runtime% %alpha_opt% ^
    /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN ^
    /I include ^
    /Fo%alpha_outdir%\alpha_rerank_core.obj ^
    /Fd%alpha_outdir%\alpha_rerank_core.pdb ^
    /Fe%alpha_outdir%\alpha_rerank_core.dll ^
    RimeLuaAlpha\alpha_rerank_core.cpp ^
    /link /NOLOGO %alpha_machine% %alpha_rime_lib% kernel32.lib
  if errorlevel 1 goto error
  if exist %alpha_outdir%\alpha_rerank_core.lib del /q %alpha_outdir%\alpha_rerank_core.lib
  if exist %alpha_outdir%\alpha_rerank_core.exp del /q %alpha_outdir%\alpha_rerank_core.exp
  exit /b

rem ---------------------------------------------------------------------------
:build_data
  copy %WEASEL_ROOT%\LICENSE.txt output\
  copy %WEASEL_ROOT%\README.md output\README.txt
  copy %WEASEL_ROOT%\plum\rime-install.bat output\
  set plum_dir=plum
  set rime_dir=output/data
  set WSLENV=plum_dir:rime_dir
  bash plum/rime-install %WEASEL_BUNDLED_RECIPES%
  if errorlevel 1 goto error
  exit /b

rem ---------------------------------------------------------------------------
rem %1 src
rem %2 dest
:copye
  xcopy /Y %1 %2
  if errorlevel 1 goto error
  exit /b

rem ---------------------------------------------------------------------------

:error

cd %WEASEL_ROOT%
echo error building weasel...
exit /b 1

:error_msbuild_not_found
cd %WEASEL_ROOT%
echo error locating msbuild.exe...
exit /b 1

:error_render_props
cd %WEASEL_ROOT%
echo error rendering weasel.props...
exit /b 1

:end
cd %WEASEL_ROOT%
