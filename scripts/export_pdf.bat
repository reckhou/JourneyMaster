@echo off
rem Exports every summarised, not deleted session to a PDF with its pictures, and each character's overview once.
rem Output goes to J:\My Drive\JourneyMaster\Sessions\<Character Name>\ by default.
rem Options are passed on, for example:
rem   export_pdf.bat --out "D:\Notes\Sessions"      another output folder
rem   export_pdf.bat --character Baldrake           one character only
rem   export_pdf.bat --force                        rebuild PDFs that are already up to date
rem   export_pdf.bat --list                         only show what would be exported
python -I "%~dp0export_pdf.py" %*
if errorlevel 1 (
    echo.
    echo The export did not finish. Read the message above.
)
pause
