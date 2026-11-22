@echo off
rem Xenite Frontier - import the project (first run / after pulling) and run the swarm benchmark.
rem Usage: run_benchmark.bat [path\to\Godot_v4.4.1-stable_win64_console.exe] [alien_count]
rem If no path is given, uses GODOT env var, then C:\Godot\Godot_v4.4.1-stable_win64_console.exe

setlocal
set "GD=%~1"
if "%GD%"=="" set "GD=%GODOT%"
if "%GD%"=="" set "GD=C:\Godot\Godot_v4.4.1-stable_win64_console.exe"
if not exist "%GD%" (
  echo Godot not found at "%GD%"
  echo Pass the path to Godot_v4.4.1-stable_win64_console.exe as the first argument.
  exit /b 1
)
set "COUNT=%~2"
if "%COUNT%"=="" (set "BENCH=--benchmark") else (set "BENCH=--benchmark=%COUNT%")

cd /d "%~dp0"
echo Importing project (builds the script class cache)...
"%GD%" --headless --path . --import >nul 2>&1
echo Running benchmark...
"%GD%" --path . -- %BENCH%
echo Exit code: %ERRORLEVEL%  (0 = pass, 2 = below target)
endlocal
