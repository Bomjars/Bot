@echo off
cd /d "%~dp0"

if not exist .venv (
    echo No virtual environment found here yet.
    echo Run first: uv sync --extra dev --extra dashboard
    pause
    exit /b 1
)

echo Starting the dashboard on http://localhost:8501
echo On your phone, use http://THIS-PC-LAN-IP:8501 while on the same Wi-Fi.
echo Close this window (or press Ctrl+C) to stop it.
uv run streamlit run dashboard\main.py
pause
