@echo off
cd /d "%~dp0"

if not exist .venv (
    echo No virtual environment found here yet.
    echo Run the one-time setup from README.md first:
    echo   python -m venv .venv
    echo   .venv\Scripts\Activate.ps1
    echo   pip install -r requirements.txt
    pause
    exit /b 1
)

call .venv\Scripts\activate.bat
echo Starting Item Price Check on http://localhost:5000
echo Close this window (or press Ctrl+C) to stop it.
python server.py
pause
