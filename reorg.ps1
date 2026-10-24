<#
    reorg.ps1 — restructure the repository into prototype/ and final/

    Run this once, from the repository root, then review and commit:

        cd C:\AREAS\skool\Q5\cse475\EE542-RehabSense
        powershell -ExecutionPolicy Bypass -File .\reorg.ps1
        git status
        git commit -m "Reorganise into prototype/ and final/"

    Every move is `git mv`, so rename detection keeps the history attached to
    the files. Nothing is deleted and nothing is rewritten: if the result is
    wrong, `git reset --hard` puts it back exactly.

    Resulting layout
    ----------------
        docs/                   PRD and firmware spec, .tex and .pdf
        prototype/              Rusha's ESP32 NodeMCU-32S Arduino work
          session-viewer.md     reads rehabsense_v3 SERIAL logs, so it lives
                                here rather than with the S3 firmware
        final/
          firmware/             the ESP32-S3 ESP-IDF project
          python/               bleak client, protocol, session downloader
          schematics/           KiCad, un-nested one level

    The schematics come out of rehabsense-main/rehabsense-main/ — two levels
    of the same name, from a zip extracted into a folder named after itself.
#>

$ErrorActionPreference = "Stop"

function Require-CleanTree {
    $dirty = git status --porcelain
    if ($dirty) {
        Write-Host "Working tree is not clean. Commit or stash first:" -ForegroundColor Yellow
        Write-Host $dirty
        throw "refusing to reorganise on top of uncommitted changes"
    }
}

function Move-IfPresent($from, $to) {
    if (-not (Test-Path $from)) {
        Write-Host "  skip (absent): $from" -ForegroundColor DarkGray
        return
    }
    $parent = Split-Path $to -Parent
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    git mv -- $from $to
    Write-Host "  $from  ->  $to" -ForegroundColor Green
}

if (-not (Test-Path ".git")) { throw "run this from the repository root" }
Require-CleanTree

Write-Host "`nCreating the new tree..." -ForegroundColor Cyan
foreach ($d in @("docs", "prototype", "final")) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

Write-Host "`nDocumentation -> docs/" -ForegroundColor Cyan
Move-IfPresent "RehabSense_PRD.tex"  "docs/RehabSense_PRD.tex"
Move-IfPresent "RehabSense_PRD.pdf"  "docs/RehabSense_PRD.pdf"
Move-IfPresent "ESP32_Firmware.tex"  "docs/ESP32_Firmware.tex"
Move-IfPresent "ESP32_Firmware.pdf"  "docs/ESP32_Firmware.pdf"

Write-Host "`nPrototype (Rusha's NodeMCU-32S work)" -ForegroundColor Cyan
# The viewer parses Serial Monitor output from rehabsense_v3 on the prototype
# board, not BLE frames from the S3. It belongs with the firmware it reads.
Move-IfPresent "RehabSense Session Viewer (Copy).md" "prototype/session-viewer.md"

Write-Host "`nFinal board (ESP32-S3)" -ForegroundColor Cyan
Move-IfPresent "firmware" "final/firmware"
# The Python host moves out from under the firmware tree: it is a separate
# deliverable with its own dependencies, and burying it in an ESP-IDF project
# makes it look like part of the build.
Move-IfPresent "final/firmware/host" "final/python"

Write-Host "`nSchematics (un-nesting rehabsense-main/rehabsense-main/)" -ForegroundColor Cyan
if (Test-Path "rehabsense-main/rehabsense-main") {
    Move-IfPresent "rehabsense-main/rehabsense-main" "final/schematics"
    # The now-empty outer wrapper. Git does not track directories, so this is
    # a filesystem tidy rather than a tracked change.
    if ((Test-Path "rehabsense-main") -and
        -not (Get-ChildItem "rehabsense-main" -Force)) {
        Remove-Item "rehabsense-main" -Force
        Write-Host "  removed the empty outer rehabsense-main/" -ForegroundColor Green
    }
} elseif (Test-Path "rehabsense-main") {
    Move-IfPresent "rehabsense-main" "final/schematics"
}

Write-Host "`nUntracking build and backup noise..." -ForegroundColor Cyan
# KiCad writes a timestamped zip on every save. There are about forty of them,
# ~26 MB, and they are autosaves of files already under version control — the
# whole point of which is that you do not need them.
foreach ($p in @("final/schematics/rehabsense-main-backups",
                 "final/python/__pycache__",
                 "final/python/logs")) {
    if (Test-Path $p) {
        git rm -r --cached --ignore-unmatch -q -- $p 2>$null
        Write-Host "  untracked (left on disk): $p" -ForegroundColor Green
    }
}

Write-Host "`nDone. Review with:" -ForegroundColor Cyan
Write-Host "    git status"
Write-Host "    git diff --cached --stat -M"
Write-Host "`nThen commit. If anything looks wrong: git reset --hard" -ForegroundColor DarkGray
