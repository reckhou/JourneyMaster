@echo off
rem Starts the JourneyMaster app in watch mode: it summarises each finished play session and writes the journal
rem snapshot the game shows at the next /reload or login. Close the window or press Ctrl+C to stop.
rem Any extra options are passed on, for example: run_app.bat -DebugMode
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\src\App\JourneyMaster.ps1" -Watch %*
