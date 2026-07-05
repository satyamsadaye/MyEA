@echo off
set "common=%APPDATA%\MetaQuotes\Terminal\Common\Files"

echo Deleting all Partial_*.csv files from MT5 Common Files...
del /q "%common%\Partial_*.csv" 2>nul

echo Done. Cleaned up any leftover partial files.
pause
