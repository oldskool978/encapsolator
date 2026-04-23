param (
    [string]$App,
    [string]$Runtime,
    [string]$Backend,
    [string]$Format,
    [string]$GCPolicy,
    [switch]$AutoDetect
)

$ErrorActionPreference = "Stop"
$WorkingRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($WorkingRoot)) { $WorkingRoot = $PWD.Path }

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

Set-Location -Path $WorkingRoot

Write-Host "[INFO] Purging legacy compilation artifacts..." -ForegroundColor DarkGray
if (Test-Path (Join-Path $WorkingRoot "build")) { Remove-Item (Join-Path $WorkingRoot "build") -Recurse -Force }
if (Test-Path (Join-Path $WorkingRoot "dist")) { Remove-Item (Join-Path $WorkingRoot "dist") -Recurse -Force }
Get-ChildItem -Path $WorkingRoot -Filter "*.spec" | Remove-Item -Force

$Step = 0
$ExitOpt = "[ EXIT ENCAPSULATOR ]"
$BackOpt = "[ GO BACK ]"
$AutoDetectOpt = "[ AUTO-DETECT HARDWARE ]"

while ($Step -lt 5) {
    if ($Step -eq 0) {
        if ($App) { $TargetScript = $App; $Step = 1; continue }
        $LocalScripts = @(Get-ChildItem -Path $WorkingRoot -Filter "*.py" | Select-Object -ExpandProperty Name | Where-Object { $_ -ne "setup_pipeline.py" })
        if ($LocalScripts.Count -eq 0) {
            Write-Host "[ERROR] No viable Python entry points detected in $WorkingRoot." -ForegroundColor Red
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
        
        $ProbePath = Join-Path $WorkingRoot "hardware_probe.ps1"
        if (-Not (Test-Path $ProbePath)) {
            Write-Host "[ERROR] hardware_probe.ps1 missing. HAL JSON Provider is strictly required." -ForegroundColor Red
            exit 1
        }
        
        try {
            if ($SelectedProfile) {
                $ConfigRaw = & $ProbePath -ForceBackend $SelectedProfile
            } else {
                Write-Host "[INFO] Executing hardware_probe.ps1 telemetry node..." -ForegroundColor DarkGray
                $ConfigRaw = & $ProbePath
            }
            $Config = $ConfigRaw | ConvertFrom-Json
        } catch {
            Write-Host "[ERROR] Failed to parse HAL JSON payload from hardware_probe.ps1." -ForegroundColor Red
            exit 1
        }
        
        $TargetBackend = $Config.BackendString
        $Step = 3
    }

    if ($Step -eq 3) {
        if ($Format) {
            $TargetFormat = if ($Format -match "OneFile") { "OneFile" } else { "OneDir" }
            $Step = 4
            continue
        }
        
        if ($TargetBackend -match "Standard Application") {
            $FormatOptions = @(
                "Directory Distribution (OneDir - Faster Execution)",
                "Single Executable (OneFile - Recommended for Standard Apps)",
                $BackOpt,
                $ExitOpt
            )
        } else {
            $FormatOptions = @(
                "Directory Distribution (OneDir - Recommended for ML Workloads)",
                "Single Executable (OneFile - Extreme I/O Latency for ML, Self-Extracting)",
                $BackOpt,
                $ExitOpt
            )
        }
        
        $FormatSelection = Invoke-InteractiveMenu -Title "SELECT OUTPUT FORMAT" -Options $FormatOptions
        if ($FormatSelection -eq $BackOpt) { $Step = 2; continue }
        $TargetFormat = if ($FormatSelection -match "OneFile") { "OneFile" } else { "OneDir" }
        
        if ($TargetFormat -eq "OneFile" -and -Not ($TargetBackend -match "Standard Application")) {
            Clear-Host
            Write-Host "WARNING: EXTREME I/O LATENCY DETECTED" -ForegroundColor Red
            Write-Host "You have selected a Single Executable (OneFile) for a Machine Learning workload." -ForegroundColor Yellow
            Write-Host "This topology forces the OS to extract 3GB+ of embedded C++ matrices to the `%TEMP%` directory during EVERY execution." -ForegroundColor Yellow
            Write-Host "Proceeding will result in severe initialization delays (30s+)." -ForegroundColor Gray
            Write-Host "`nAre you certain you wish to proceed? (y/N): " -NoNewline -ForegroundColor Cyan
            $confirm = Read-Host
            if ($confirm -notmatch "^y") {
                continue
            }
        }
        $Step = 4
    }

    if ($Step -eq 4) {
        if ($GCPolicy) {
            $TeardownPolicy = $GCPolicy
            $Step = 5
            continue
        }
        
        $GCPolicies = @(
            "Retain Environment (Recommended for Iterative Dev)",
            "Ephemeral Teardown (Reclaim Maximum Disk Space)",
            $BackOpt,
            $ExitOpt
        )
        $TeardownPolicy = Invoke-InteractiveMenu -Title "SELECT POST-COMPILE GC POLICY" -Options $GCPolicies
        if ($TeardownPolicy -eq $BackOpt) { $Step = 3; continue }
        $Step = 5
    }
}

Write-Host "=== ENCAPSULATION PARAMETERS LOCKED ===" -ForegroundColor Magenta
Write-Host "Target App : " -NoNewline; Write-Host $TargetScript -ForegroundColor Cyan
Write-Host "Runtime    : " -NoNewline; Write-Host $TargetRuntime -ForegroundColor Cyan
Write-Host "Backend    : " -NoNewline; Write-Host $TargetBackend -ForegroundColor Cyan
Write-Host "Format     : " -NoNewline; Write-Host $TargetFormat -ForegroundColor Cyan
Write-Host "GC Policy  : " -NoNewline; Write-Host $TeardownPolicy -ForegroundColor Cyan
Write-Host "`nInitializing Phase 2: Environment Acquisition..." -ForegroundColor Yellow

$EnvDir = Join-Path $WorkingRoot "build_env_$TargetRuntime"
$ArchiveName = "python-$TargetRuntime-embed-amd64.zip"
$DownloadUrl = "https://www.python.org/ftp/python/$TargetRuntime/$ArchiveName"
$PythonExe = Join-Path $EnvDir "python.exe"
$PipBootstrapper = Join-Path $EnvDir "get-pip.py"

if (-Not (Test-Path $EnvDir)) {
    Invoke-WebRequest -Uri $DownloadUrl -OutFile (Join-Path $WorkingRoot $ArchiveName)
    Expand-Archive -Path (Join-Path $WorkingRoot $ArchiveName) -DestinationPath $EnvDir -Force
    Remove-Item (Join-Path $WorkingRoot $ArchiveName) -Force
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

$RequirementsPath = Join-Path $WorkingRoot "requirements.txt"
$PipCommands = @($Config.PipCommands)
if ($PipCommands.Count -gt 0) {
    foreach ($cmd in $PipCommands) {
        Write-Host "[INFO] Processing HAL Directive: pip $cmd" -ForegroundColor DarkGray
        Invoke-Strict { & cmd.exe /c "`"$PythonExe`" -m pip $cmd" }
    }
    
    Write-Host "[INFO] Generating Application State Lock (constraints.txt)..."
    $ConstraintsFile = Join-Path $WorkingRoot "constraints.txt"
    $TempFreeze = Join-Path $WorkingRoot "constraints_tmp.txt"
    Invoke-Strict { & cmd.exe /c "`"$PythonExe`" -m pip freeze > `"$TempFreeze`"" }
    Get-Content -Path $TempFreeze | Where-Object { $_ -match "^torch" } | Set-Content -Path $ConstraintsFile -Force
    Remove-Item $TempFreeze -Force

    if (Test-Path $RequirementsPath) {
        Write-Host "[INFO] Executing constrained hardware resolution against requirements.txt..."
        Invoke-Strict { & $PythonExe -m pip install -r $RequirementsPath -c $ConstraintsFile --no-cache-dir --no-warn-script-location }
    }
} else {
    Write-Host "[INFO] Standard Application Mode. Bypassing Hardware Matrices." -ForegroundColor DarkGray
    if (Test-Path $RequirementsPath) {
        Invoke-Strict { & $PythonExe -m pip install -r $RequirementsPath --no-cache-dir --no-warn-script-location }
    }
}

Write-Host "`nInitializing Phase 4: Polymorphic AST Encapsulation..." -ForegroundColor Yellow
Invoke-Strict { & $PythonExe -m pip install pyinstaller --no-cache-dir --no-warn-script-location }

Write-Host "[INFO] Autonomously harvesting dynamic software dependencies..." -ForegroundColor DarkGray
$HarvesterPath = Join-Path $WorkingRoot "harvester.py"
$HarvesterContent = @"
import os
import sys
import importlib.metadata as metadata

reqs = set()
req_path = os.path.join(r'$($WorkingRoot -replace '\\', '\\\\')', 'requirements.txt')
if os.path.exists(req_path):
    with open(req_path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            # Defensively split away operators and package [extras]
            req = line.split('==')[0].split('>=')[0].split('~=')[0].split('<')[0].split('>')[0].split('[')[0].strip().lower()
            if req:
                reqs.add(req)

imports_to_collect = set()
for dist in metadata.distributions():
    dist_name = dist.metadata.get('Name')
    if dist_name and dist_name.lower() in reqs:
        top_level_txt = dist.read_text('top_level.txt')
        if top_level_txt:
            for tl in top_level_txt.splitlines():
                if tl.strip():
                    imports_to_collect.add(tl.strip())
        else:
            imports_to_collect.add(dist_name.replace('-', '_'))

print(';'.join(imports_to_collect))
"@
Set-Content -Path $HarvesterPath -Value $HarvesterContent -Force
$DynamicPkgsRaw = & $PythonExe $HarvesterPath
Remove-Item $HarvesterPath -Force

$CollectAllPkgs = @($Config.PyInstallerCollectAll)
if ($DynamicPkgsRaw) {
    $DynamicPkgs = $DynamicPkgsRaw -split ";"
    foreach ($pkg in $DynamicPkgs) {
        if ($pkg -notin $CollectAllPkgs) {
            $CollectAllPkgs += $pkg
            Write-Host " -> Dynamic Target Locked: $pkg" -ForegroundColor DarkCyan
        }
    }
}

$AppName = [System.IO.Path]::GetFileNameWithoutExtension($TargetScript)
$DeploymentDir = Join-Path $WorkingRoot "Deploy_$AppName"
if (Test-Path $DeploymentDir) { Remove-Item $DeploymentDir -Recurse -Force }
New-Item -ItemType Directory -Path $DeploymentDir | Out-Null

$SpecPath = Join-Path $WorkingRoot "$AppName.spec"
$PayloadNamespace = ".venv"
$EscapedNamespace = [regex]::Escape($PayloadNamespace)

$InjectPaths = @($Config.LauncherInjectPaths)
$PythonInjectPaths = @()
foreach ($p in $InjectPaths) {
    $cleanPath = $p
    if ($p -match "^$EscapedNamespace[\\/](.*)") {
        $cleanPath = $matches[1]
    }
    $PythonInjectPaths += "'$($cleanPath -replace '\\', '/')'"
}
$PythonInjectPathsStr = $PythonInjectPaths -join ", "

$EnvVarInjections = ""
$LauncherEnvVars = @($Config.LauncherEnvVars)
if ($LauncherEnvVars.Count -gt 0) {
    foreach ($ev in $LauncherEnvVars) {
        $Key = $ev.Key
        $Val = $ev.Value
        if ($Val -match "^$EscapedNamespace[\\/](.*)") {
            $Val = $matches[1]
        }
        $Val = $Val -replace '\\', '/'
        $EnvVarInjections += "`n    os.environ['$Key'] = os.path.join(base_dir, os.path.normpath('$Val'))"
    }
}

$HookPath = Join-Path $WorkingRoot "runtime_hook.py"
$HookContent = @"
import os
import sys

# Abstracted Base Directory Resolution (Invariant to OneDir/OneFile topologies)
base_dir = getattr(sys, '_MEIPASS', os.path.dirname(os.path.abspath(__file__)))

# Pre-Ctypes Stage: Strict Host Path Sanitization with Quote Stripping
if 'PATH' in os.environ:
    clean_paths = []
    for path_segment in os.environ['PATH'].split(os.pathsep):
        path_segment = path_segment.replace('"', '').strip()
        if not path_segment:
            continue
        norm_seg = os.path.normpath(path_segment).lower()
        bad_words = [r'\python', r'\conda', r'\miniconda', r'\rocm', r'\cuda']
        if not any(bad in norm_seg for bad in bad_words):
            clean_paths.append(path_segment)
    os.environ['PATH'] = os.pathsep.join(clean_paths)

# C-API Initialized safely within isolated namespace
import ctypes

if sys.platform.startswith('win'):
    try:
        ctypes.windll.kernel32.SetDefaultDllDirectories(0x00001000)
    except Exception:
        pass

    inject_paths = [$PythonInjectPathsStr]
    
    # CRITICAL: Explicitly whitelist the MEIPASS root for standard MSVC dependencies
    resolved_paths = [base_dir]
    try:
        os.add_dll_directory(base_dir)
    except Exception:
        pass
    
    for p in inject_paths:
        target = os.path.join(base_dir, os.path.normpath(p))
        if os.path.exists(target):
            resolved_paths.append(target)
            try:
                os.add_dll_directory(target)
            except Exception:
                pass

    if resolved_paths:
        os.environ['PATH'] = os.pathsep.join(resolved_paths) + os.pathsep + os.environ.get('PATH', '')
$EnvVarInjections

try:
    import rocm_sdk
    rocm_sdk.initialize_process = lambda *args, **kwargs: None
except Exception:
    pass
"@
Set-Content -Path $HookPath -Value $HookContent -Force

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

$HookInjection = ""
if (-Not ($TargetBackend -match "Standard Application")) {
    $HookInjection = "runtime_hooks=['$($HookPath -replace '\\', '/')'],"
} else {
    $HookInjection = "runtime_hooks=[],"
}

if ($TargetFormat -eq "OneFile") {
    $ExeParams = @"
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name='$AppName',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
"@
    $CollectBlock = ""
} else {
    $ExeParams = @"
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
"@
    $CollectBlock = @"
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
}

$SpecContent = @"
# -*- mode: python ; coding: utf-8 -*-

datas = [$DatasStr]
binaries = [$BinariesStr]
hiddenimports = [$HiddenImportsStr]

$CollectAllCode

a = Analysis(
    ['$((Join-Path $WorkingRoot $TargetScript) -replace '\\', '/')'],
    pathex=[$SpecPathexCode],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    $HookInjection
    excludes=[],
    noarchive=False,
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz,
$ExeParams
)
$CollectBlock
"@

Set-Content -Path $SpecPath -Value $SpecContent -Force

$PyInstallerExe = Join-Path $EnvDir "Scripts\pyinstaller.exe"
$WorkPath = Join-Path $WorkingRoot "build_tmp"

$NormDist = [System.IO.Path]::GetFullPath($DeploymentDir)
$NormWork = [System.IO.Path]::GetFullPath($WorkPath)
$UNC_Dist = "\\?\$NormDist"
$UNC_Work = "\\?\$NormWork"

Invoke-Strict { & $PyInstallerExe --noconfirm --clean --distpath $UNC_Dist --workpath $UNC_Work $SpecPath }

if ($TargetFormat -eq "OneFile") {
    $FinalExePath = Join-Path $NormDist "$AppName.exe"
} else {
    $FinalExePath = Join-Path $NormDist "$AppName\$AppName.exe"
}

Write-Host "`n[SUCCESS] Encapsulation Complete." -ForegroundColor Green
Write-Host "Hermetic Executable generated at: " -NoNewline; Write-Host $FinalExePath -ForegroundColor Cyan

Write-Host "`nInitializing Phase 5: Workspace Sanitization..." -ForegroundColor DarkGray
if (Test-Path $SpecPath) { Remove-Item $SpecPath -Force }
if (Test-Path $HookPath) { Remove-Item $HookPath -Force }
if (Test-Path $WorkPath) { Remove-Item $WorkPath -Recurse -Force }

if ($TeardownPolicy -match "Ephemeral Teardown") {
    if (Test-Path $EnvDir) { Remove-Item $EnvDir -Recurse -Force }
    if (Test-Path (Join-Path $WorkingRoot "build")) { Remove-Item (Join-Path $WorkingRoot "build") -Recurse -Force }
    if (Test-Path (Join-Path $WorkingRoot "constraints.txt")) { Remove-Item (Join-Path $WorkingRoot "constraints.txt") -Force }
    Write-Host "[INFO] Ephemeral Teardown executed. Only standalone payloads remain." -ForegroundColor DarkGray
}
