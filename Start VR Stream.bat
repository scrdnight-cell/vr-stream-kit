@echo off
REM VR Stream Kit - stream the desktop to a headset on a virtual display.
REM Works with Bigscreen Remote Desktop. Unofficial - see TERMS.md.
REM By scrdnight-cell - https://github.com/scrdnight-cell - MIT licence.
REM The menu lets you pick, create and check stream profiles. See README.md.

title VR Stream Kit

REM ---------------------------------------------------------------- SETTINGS
REM Part of the adapter name your virtual display driver shows in Device Manager.
set "VIRTUAL_ADAPTER=Virtual Display Driver"
REM Leave empty to find Bigscreen automatically, or set its app-x.y.z folder.
set "BIGSCREEN_DIR="
REM yes = detach the virtual display whenever the kit is not running, so an idle
REM monitor switching off can never leave the desktop stranded on it.
REM no  = leave it attached all the time.
set "PARK_VIRTUAL_DISPLAY=yes"
REM What happens when a monitor comes back on mid-session. Either way the stream
REM keeps going - Bigscreen is restarted so it captures what is attached now.
REM monitor = hand the desktop back to the monitor (you are back at the desk)
REM virtual = stay on the virtual display (you are still in the headset)
set "ON_MONITOR_RETURN=monitor"

if "%VIRTUAL_ADAPTER%"=="" set "VIRTUAL_ADAPTER=Virtual Display Driver"
REM Optional values are passed only when set: an empty argument can arrive as a
REM parameter with no value, and the script then refuses to start.
set "DIRARG="
if defined BIGSCREEN_DIR set DIRARG=-BigscreenDir "%BIGSCREEN_DIR%"
set "KEEPARG="
if /i not "%PARK_VIRTUAL_DISPLAY%"=="yes" set "KEEPARG=-KeepVirtualDisplay"
set "RETURNARG="
if defined ON_MONITOR_RETURN set RETURNARG=-OnMonitorReturn "%ON_MONITOR_RETURN%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\menu.ps1" -VirtualAdapter "%VIRTUAL_ADAPTER%" %DIRARG% %KEEPARG% %RETURNARG%
if errorlevel 1 (
    echo.
    echo   Something did not finish cleanly - see above and logs\session.log
    echo.
    pause
    exit /b 1
)
exit /b 0
