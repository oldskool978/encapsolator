param (
    [string]$App,
    [string]$Runtime,
    [string]$Backend,
    [string]$GCPolicy,
    [switch]$AutoDetect
)

$ErrorActionPreference = "Stop"

function Invoke-Strict {
    param ([scriptblock]$Command)
    & $Command
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n[FATAL] External process terminated with exit code $LASTEXITCODE." -ForegroundColor Red
        exit $LASTEXITCODE
    }
}

function Invoke-InteractiveMenu {
    param (
        [Parameter(Mandatory=$true)][string]$Title,
        [Parameter(Mandatory=$true)][string[]]$Options
    )

    $cursor = 0
    $Host.UI.RawUI.CursorSize = 0

    while ($true) {
        Clear-Host
        Write-Host "=== $Title ===" -ForegroundColor Magenta
        Write-Host "[UP/DOWN] Navigate | [ENTER] Select`n" -ForegroundColor Cyan

        for ($i = 0; $i -lt $Options.Length; $i++) {
            if ($i -eq $cursor) {
                Write-Host " ►  $($Options[$i])" -ForegroundColor Black -BackgroundColor Green
            } else {
                if ($Options[$i] -match "\[ EXIT") {
                    Write-Host "    $($Options[$i])" -ForegroundColor Red
                } elseif ($Options[$i] -match "\[ GO BACK") {
                    Write-Host "    $($Options[$i])" -ForegroundColor Yellow
                } elseif ($Options[$i] -match "\[ AUTO-DETECT") {
                    Write-Host "    $($Options[$i])" -ForegroundColor Magenta
                } else {
                    Write-Host "    $($Options[$i])" -ForegroundColor Gray
                }
            }
        }

        $Key = [System.Console]::ReadKey($true)

        if ($Key.Key -eq 'UpArrow' -and $cursor -gt 0) {
            $cursor--
        } elseif ($Key.Key -eq 'DownArrow' -and $cursor -lt ($Options.Length - 1)) {
            $cursor++
        } elseif ($Key.Key -eq 'Enter') {
            $Host.UI.RawUI.CursorSize = 25
            Clear-Host
            
            if ($Options[$cursor] -match "\[ EXIT") {
                Write-Host "Execution terminated by user." -ForegroundColor Red
                exit 0
            }
            return $Options[$cursor]
        }
    }
}

Write-Host "[INFO] Purging legacy compilation artifacts..." -ForegroundColor DarkGray
if (Test-Path "build") { Remove-Item "build" -Recurse -Force }
if (Test-Path "dist") { Remove-Item "dist" -Recurse -Force }
Get-ChildItem -Filter "*.spec" | Remove-Item -Force

$Step = 0
$ExitOpt = "[ EXIT ENCAPSULATOR ]"
$BackOpt = "[ GO BACK ]"
$AutoDetectOpt = "[ AUTO-DETECT HARDWARE ]"

while ($Step -lt 4) {
    if ($Step -eq 0) {
        if ($App) { $TargetScript = $App; $Step = 1; continue }
        $LocalScripts = @(Get-ChildItem -Filter "*.py" | Select-Object -ExpandProperty Name | Where-Object { $_ -ne "setup_pipeline.py" })
        if ($LocalScripts.Count -eq 0) {
            Write-Host "[ERROR] No viable Python entry points detected." -ForegroundColor Red
            exit 1
        }
        $LocalScripts += $ExitOpt
        $TargetScript = Invoke-InteractiveMenu -Title "SELECT APPLICATION ENTRY POINT" -Options $LocalScripts
        $Step = 1
    }
    
    if ($Step -eq 1) {
        if ($Runtime) { $TargetRuntime = $Runtime; $Step = 2; continue }
        $PythonRuntimes = @(
            "3.9.13  (Legacy Target)",
            "3.10.11 (Stable LTS)",
            "3.11.9  (Stable)",
            "3.12.3  (Modern)",
            "3.13.13 (Modern)",
            "3.14.4  (Latest Target)",
            $BackOpt,
            $ExitOpt
        )
        $TargetRuntimeSelection = Invoke-InteractiveMenu -Title "SELECT HERMETIC RUNTIME" -Options $PythonRuntimes
        if ($TargetRuntimeSelection -eq $BackOpt) { $Step = 0; continue }
        
        $TargetRuntime = ($TargetRuntimeSelection -split ' ')[0]
        $Step = 2
    }
    
    if ($Step -eq 2) {
        $SelectedProfile = ""
        if ($Backend) {
            $SelectedProfile = $Backend
        } elseif ($AutoDetect) {
            $SelectedProfile = ""
        } else {
            $HardwareBackends = @(
                $AutoDetectOpt,
                "Standard Application (No Machine Learning)",
                "NVIDIA CUDA 12.1 (PyTorch Default)",
                "NVIDIA CUDA 11.8 (Legacy Compute)",
                "AMD ROCm Nightly (GFX120X/HIP)",
                "Agnostic / CPU Fallback",
                $BackOpt,
                $ExitOpt
            )
            $TargetBackendSelection = Invoke-InteractiveMenu -Title "SELECT COMPUTATION BACKEND" -Options $HardwareBackends
            if ($TargetBackendSelection -eq $BackOpt) { $Step = 1; continue }
            
            switch ($TargetBackendSelection) {
                $AutoDetectOpt { $SelectedProfile = "" }
                "Standard Application (No Machine Learning)" { $SelectedProfile = "STANDARD" }
                "NVIDIA CUDA 12.1 (PyTorch Default)" { $SelectedProfile = "CUDA_12" }
                "NVIDIA CUDA 11.8 (Legacy Compute)" { $SelectedProfile = "CUDA_11" }
                "AMD ROCm Nightly (GFX120X/HIP)" { $SelectedProfile = "ROCM" }
                "Agnostic / CPU Fallback" { $SelectedProfile = "CPU" }
            }
        }
        
        if (-Not (Test-Path "hardware_probe.ps1")) {
            Write-Host "[ERROR] hardware_probe.ps1 missing. HAL JSON Provider is strictly required." -ForegroundColor Red
            exit 1
        }
        
        try {
            if ($SelectedProfile) {
                $ConfigRaw = & ".\hardware_probe.ps1" -ForceBackend $SelectedProfile
            } else {
                Write-Host "[INFO] Executing hardware_probe.ps1 telemetry node..." -ForegroundColor DarkGray
                $ConfigRaw = & ".\hardware_probe.ps1"
            }
            $Config = $ConfigRaw | ConvertFrom-Json
        } catch {
            Write-Host "[ERROR] Failed to parse HAL JSON payload from hardware_probe.ps1." -ForegroundColor Red
            exit 1
        }
        
        $TargetBackend = $Config.BackendString
        
        if ($TargetBackend -match "AMD ROCm" -and $TargetRuntime -match "^3\.9") {
            Write-Host "[ERROR] AMD ROCm requires Python 3.10+. Python 3.9 syntax is fundamentally incompatible." -ForegroundColor Red
            if ($AutoDetect -or $Backend) { exit 1 }
            Write-Host "Press ENTER to reselect hardware backend..." -ForegroundColor Yellow
            $null = [System.Console]::ReadKey($true)
            continue
        }
        $Step = 3
    }

    if ($Step -eq 3) {
        if ($GCPolicy) {
            $TeardownPolicy = $GCPolicy
            $Step = 4
            continue
        }
        
        $GCPolicies = @(
            "Retain Environment (Recommended for Iterative Dev)",
            "Ephemeral Teardown (Reclaim Maximum Disk Space)",
            $BackOpt,
            $ExitOpt
        )
        $TeardownPolicy = Invoke-InteractiveMenu -Title "SELECT POST-COMPILE GC POLICY" -Options $GCPolicies
        if ($TeardownPolicy -eq $BackOpt) { $Step = 2; continue }
        $Step = 4
    }
}

Write-Host "=== ENCAPSULATION PARAMETERS LOCKED ===" -ForegroundColor Magenta
Write-Host "Target App : " -NoNewline; Write-Host $TargetScript -ForegroundColor Cyan
Write-Host "Runtime    : " -NoNewline; Write-Host $TargetRuntime -ForegroundColor Cyan
Write-Host "Backend    : " -NoNewline; Write-Host $TargetBackend -ForegroundColor Cyan
Write-Host "GC Policy  : " -NoNewline; Write-Host $TeardownPolicy -ForegroundColor Cyan
Write-Host "`nInitializing Phase 2: Environment Acquisition..." -ForegroundColor Yellow

$EnvDir = Join-Path $PWD "build_env_$TargetRuntime"
$ArchiveName = "python-$TargetRuntime-embed-amd64.zip"
$DownloadUrl = "https://www.python.org/ftp/python/$TargetRuntime/$ArchiveName"
$PythonExe = Join-Path $EnvDir "python.exe"
$PipBootstrapper = Join-Path $EnvDir "get-pip.py"

if (-Not (Test-Path $EnvDir)) {
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $ArchiveName
    Expand-Archive -Path $ArchiveName -DestinationPath $EnvDir -Force
    Remove-Item $ArchiveName -Force
}

$PthFile = Get-ChildItem -Path $EnvDir -Filter "*._pth" | Select-Object -First 1
$PthContent = Get-Content $PthFile.FullName
if ($PthContent -match '^#import site') {
    $PthContent -replace '^#import site', 'import site' | Set-Content $PthFile.FullName
}

if (-Not (Test-Path $PipBootstrapper)) {
    Invoke-WebRequest -Uri "https://bootstrap.pypa.io/get-pip.py" -OutFile $PipBootstrapper
}

Invoke-Strict { & $PythonExe $PipBootstrapper --no-cache-dir --no-warn-script-location | Out-Null }
Invoke-Strict { & $PythonExe -m pip install wheel setuptools --upgrade --no-cache-dir --no-warn-script-location | Out-Null }

Write-Host "`nInitializing Phase 3: HAL JSON Hydration Routing..." -ForegroundColor Yellow

$PipCommands = @($Config.PipCommands)
if ($PipCommands.Count -gt 0) {
    foreach ($cmd in $PipCommands) {
        Write-Host "[INFO] Processing HAL Directive: pip $cmd" -ForegroundColor DarkGray
        Invoke-Strict { & cmd.exe /c "`"$PythonExe`" -m pip $cmd" }
    }
    
    Write-Host "[INFO] Generating Application State Lock (constraints.txt)..."
    $ConstraintsFile = Join-Path $PWD "constraints.txt"
    $TempFreeze = Join-Path $PWD "constraints_tmp.txt"
    Invoke-Strict { & cmd.exe /c "`"$PythonExe`" -m pip freeze > `"$TempFreeze`"" }
    Get-Content -Path $TempFreeze | Where-Object { $_ -match "^torch" } | Set-Content -Path $ConstraintsFile -Force
    Remove-Item $TempFreeze -Force

    if (Test-Path "requirements.txt") {
        Write-Host "[INFO] Executing constrained hardware resolution against requirements.txt..."
        Invoke-Strict { & $PythonExe -m pip install -r requirements.txt -c $ConstraintsFile --no-cache-dir --no-warn-script-location }
    }
} else {
    Write-Host "[INFO] Standard Application Mode. Bypassing Hardware Matrices." -ForegroundColor DarkGray
    if (Test-Path "requirements.txt") {
        Invoke-Strict { & $PythonExe -m pip install -r requirements.txt --no-cache-dir --no-warn-script-location }
    }
}

Write-Host "`nInitializing Phase 4: Polymorphic AST Encapsulation..." -ForegroundColor Yellow
Invoke-Strict { & $PythonExe -m pip install pyinstaller --no-cache-dir --no-warn-script-location }

$AppName = [System.IO.Path]::GetFileNameWithoutExtension($TargetScript)
$DeploymentDir = Join-Path $PWD "Deploy_$AppName"
if (Test-Path $DeploymentDir) { Remove-Item $DeploymentDir -Recurse -Force }
New-Item -ItemType Directory -Path $DeploymentDir | Out-Null

$SpecPath = Join-Path $PWD "$AppName.spec"
$PayloadNamespace = ".venv"
$InjectPaths = @($Config.LauncherInjectPaths)

$PythonInjectPaths = @()
foreach ($p in $InjectPaths) {
    $PythonInjectPaths += "'$($p -replace '\\', '/')'"
}
$PythonInjectPathsStr = $PythonInjectPaths -join ", "

$HookPath = Join-Path $PWD "runtime_hook.py"
$HookContent = @"
import os
import sys

if sys.platform == 'win32':
    base_dir = os.path.dirname(os.path.abspath(sys.argv[0]))
    inject_paths = [$PythonInjectPathsStr]
    
    for p in inject_paths:
        target = os.path.join(base_dir, os.path.normpath(p))
        if os.path.exists(target):
            try:
                os.add_dll_directory(target)
            except Exception:
                pass

try:
    import rocm_sdk
    rocm_sdk.initialize_process = lambda *args, **kwargs: None
except Exception:
    pass
"@
Set-Content -Path $HookPath -Value $HookContent -Force

$CollectAllPkgs = @($Config.PyInstallerCollectAll)
$HiddenImports = @($Config.PyInstallerHiddenImports)

$CollectAllCode = ""
if ($CollectAllPkgs.Count -gt 0) {
    $CollectAllCode = "from PyInstaller.utils.hooks import collect_all`n"
    foreach ($pkg in $CollectAllPkgs) {
        $CollectAllCode += "d, b, h = collect_all('$pkg')`n"
        $CollectAllCode += "datas.extend(d)`n"
        $CollectAllCode += "binaries.extend(b)`n"
        $CollectAllCode += "hiddenimports.extend(h)`n"
    }
}

$HiddenImportsStr = $HiddenImports -join "', '"
if ($HiddenImportsStr) { $HiddenImportsStr = "'$HiddenImportsStr'" }

$SpecPathex = @($Config.SpecPathex)
$SpecPathexCode = ""
if ($SpecPathex.Count -gt 0) {
    $PathArray = @()
    foreach ($p in $SpecPathex) {
        $fullPath = Join-Path $EnvDir $p
        if (Test-Path $fullPath) {
            $PathArray += "'$($fullPath -replace '\\', '/')'"
        }
    }
    $SpecPathexCode = $PathArray -join ", "
}

$ExplicitBinaries = @($Config.ExplicitBinaries)
$BinariesList = @()
if ($ExplicitBinaries.Count -gt 0) {
    foreach ($b in $ExplicitBinaries) {
        $srcPattern = Join-Path $EnvDir $b.Source
        if (Test-Path $srcPattern) {
            $src = $srcPattern -replace '\\', '/'
            $dst = $b.Dest -replace '\\', '/'
            $BinariesList += "('$src', '$dst')"
        }
    }
}
$BinariesStr = $BinariesList -join ", "

$ExplicitDatas = @($Config.ExplicitDatas)
$DatasList = @()
if ($ExplicitDatas.Count -gt 0) {
    foreach ($d in $ExplicitDatas) {
        $srcDir = Join-Path $EnvDir $d.SourceDir
        if (Test-Path $srcDir) {
            foreach ($ext in $d.Extensions) {
                $files = Get-ChildItem -Path $srcDir -Filter $ext -Recurse -File -ErrorAction SilentlyContinue
                foreach ($file in $files) {
                    $src = $file.FullName -replace '\\', '/'
                    $relPath = $file.DirectoryName.Substring($srcDir.Length).TrimStart('\')
                    if ($relPath) {
                        $dst = Join-Path $d.DestDir $relPath
                    } else {
                        $dst = $d.DestDir
                    }
                    $dst = $dst -replace '\\', '/'
                    $DatasList += "('$src', '$dst')"
                }
            }
        }
    }
}
$DatasStr = $DatasList -join ", "

$SpecContent = @"
# -*- mode: python ; coding: utf-8 -*-

datas = [$DatasStr]
binaries = [$BinariesStr]
hiddenimports = [$HiddenImportsStr]

$CollectAllCode

a = Analysis(
    ['$($TargetScript -replace '\\', '/')'],
    pathex=[$SpecPathexCode],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=['$($HookPath -replace '\\', '/')'],
    excludes=[],
    noarchive=False,
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='$AppName',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    contents_directory='$PayloadNamespace',
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name='$AppName',
)
"@

Set-Content -Path $SpecPath -Value $SpecContent -Force

$PyInstallerExe = Join-Path $EnvDir "Scripts\pyinstaller.exe"
$WorkPath = Join-Path $PWD "build_tmp"
$UNC_Dist = "\\?\$DeploymentDir"
$UNC_Work = "\\?\$WorkPath"
Invoke-Strict { & $PyInstallerExe --noconfirm --clean --distpath $UNC_Dist --workpath $UNC_Work $SpecPath }

Write-Host "`nInitializing Phase 5: Boundary Proxy Generation..." -ForegroundColor Yellow

$PathInjectString = ""
if ($InjectPaths.Count -gt 0) {
    $PathArray = @()
    foreach ($p in $InjectPaths) {
        $PathArray += "%~dp0$AppName\$p"
    }
    $PathInjectString = $PathArray -join ";"
}

$LauncherPath = Join-Path $DeploymentDir "launch_$AppName.bat"
$LauncherContent = @"
@echo off
setlocal EnableDelayedExpansion
echo [INFO] Establishing localized proxy boundary...
echo [INFO] Sanitizing host environment variables...

set "CLEAN_PATH="
for %%a in ("%PATH:;=" "%") do (
    set "ITEM=%%~a"
    if not "!ITEM!"=="" (
        echo "!ITEM!" | findstr /i /c:"\python" /c:"\conda" /c:"\miniconda" /c:"\rocm" /c:"\cuda" >nul
        if errorlevel 1 (
            set "CLEAN_PATH=!CLEAN_PATH!!ITEM!;"
        )
    )
)
"@

if ($PathInjectString) {
    $LauncherContent += "`nset `"PATH=$PathInjectString;!CLEAN_PATH!`""
} else {
    $LauncherContent += "`nset `"PATH=!CLEAN_PATH!`""
}

$LauncherEnvVars = @($Config.LauncherEnvVars)
if ($LauncherEnvVars.Count -gt 0) {
    foreach ($ev in $LauncherEnvVars) {
        $LauncherContent += "`nset `"$($ev.Key)=%~dp0$AppName\$($ev.Value)`""
    }
}

$LauncherContent += "`necho [INFO] Invoking encapsulated payload: $AppName.exe"
$LauncherContent += "`ncall `"%~dp0$AppName\$AppName.exe`" %*"
$LauncherContent += "`nset `"EXIT_CODE=!ERRORLEVEL!`""
$LauncherContent += "`nexit /b !EXIT_CODE!"
Set-Content -Path $LauncherPath -Value $LauncherContent -Force

Write-Host "`n[SUCCESS] Encapsulation Complete." -ForegroundColor Green
Write-Host "Binary payload generated at: " -NoNewline; Write-Host (Join-Path $DeploymentDir "$AppName\$AppName.exe") -ForegroundColor Cyan
Write-Host "Proxy launcher generated at: " -NoNewline; Write-Host $LauncherPath -ForegroundColor Cyan

Write-Host "`nInitializing Phase 6: Workspace Sanitization..." -ForegroundColor DarkGray
if (Test-Path $SpecPath) { Remove-Item $SpecPath -Force }
if (Test-Path $HookPath) { Remove-Item $HookPath -Force }
if (Test-Path $WorkPath) { Remove-Item $WorkPath -Recurse -Force }

if ($TeardownPolicy -match "Ephemeral Teardown") {
    if (Test-Path $EnvDir) { Remove-Item $EnvDir -Recurse -Force }
    if (Test-Path "build") { Remove-Item "build" -Recurse -Force }
    if (Test-Path "constraints.txt") { Remove-Item "constraints.txt" -Force }
    Write-Host "[INFO] Ephemeral Teardown executed. Only standalone payloads remain." -ForegroundColor DarkGray
}