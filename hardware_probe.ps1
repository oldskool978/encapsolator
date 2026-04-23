param (
    [string]$ForceBackend = ""
)

$ErrorActionPreference = "Stop"

function Get-HardwareProfile {
    if ($ForceBackend) {
        return $ForceBackend
    }

    $NvidiaSmi = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
    if ($NvidiaSmi) {
        $SmiOutput = & $NvidiaSmi.Source --query-gpu=driver_version --format=csv,noheader 2>$null
        if ($SmiOutput -match "^\d+\.") {
            $MajorVersion = [int]($SmiOutput -split '\.')[0]
            if ($MajorVersion -ge 520) { return "CUDA_12" }
            if ($MajorVersion -ge 450) { return "CUDA_11" }
        }
    }

    $VideoControllers = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
    foreach ($vc in $VideoControllers) {
        if ($vc -match "AMD" -or $vc -match "Radeon") {
            return "ROCM"
        }
    }

    return "CPU"
}

$Profile = Get-HardwareProfile
$PayloadNamespace = ".venv"

$Config = @{
    BackendString = ""
    PipCommands = @()
    LauncherInjectPaths = @()
    LauncherEnvVars = @()
    PyInstallerCollectAll = @()
    PyInstallerHiddenImports = @()
    SpecPathex = @()
    ExplicitBinaries = @()
    ExplicitDatas = @()
}

switch ($Profile) {
    "ROCM" {
        $TargetGfx = "gfx120X"
        
        $GfxUrlParam = "$TargetGfx-all"
        $GfxPkgName  = "_rocm_sdk_libraries_$($TargetGfx)_all"

        $Config.BackendString = "AMD ROCm Nightly ($TargetGfx/HIP)"
        $Config.PipCommands = @(
            "install --index-url https://rocm.nightlies.amd.com/v2-staging/$GfxUrlParam/ --pre -U `"rocm[libraries,devel]`" --no-build-isolation --no-cache-dir --no-warn-script-location",
            "install --index-url https://rocm.nightlies.amd.com/v2-staging/$GfxUrlParam/ --pre -U torch torchaudio torchvision --no-cache-dir --no-warn-script-location"
        )
        
        $Config.LauncherInjectPaths = @(
            "$PayloadNamespace\$GfxPkgName\bin",
            "$PayloadNamespace\_rocm_sdk_core\bin", 
            "$PayloadNamespace\_rocm_sdk_devel\bin",
            "$PayloadNamespace\torch\lib"
        )
        
        $Config.LauncherEnvVars = @()
        
        $Config.PyInstallerCollectAll = @("torch", "torchvision", "torchaudio")
        $Config.PyInstallerHiddenImports = @("torch")
        
        $Config.SpecPathex = @(
            "Lib\site-packages\$GfxPkgName\bin",
            "Lib\site-packages\_rocm_sdk_core\bin", 
            "Lib\site-packages\_rocm_sdk_devel\bin",
            "Lib\site-packages\torch\lib"
        )
        
        $Config.ExplicitBinaries = @(
            @{ Source = "Lib\site-packages\$GfxPkgName\bin\*.dll"; Dest = "$GfxPkgName\bin" },
            @{ Source = "Lib\site-packages\_rocm_sdk_core\bin\*.dll"; Dest = "_rocm_sdk_core\bin" },
            @{ Source = "Lib\site-packages\_rocm_sdk_devel\bin\*.dll"; Dest = "_rocm_sdk_devel\bin" }
        )

        $Config.ExplicitDatas = @(
            @{ SourceDir = "Lib\site-packages\$GfxPkgName\bin"; DestDir = "$GfxPkgName\bin"; Extensions = @("*") },
            @{ SourceDir = "Lib\site-packages\_rocm_sdk_core\bin"; DestDir = "_rocm_sdk_core\bin"; Extensions = @("*") },
            @{ SourceDir = "Lib\site-packages\_rocm_sdk_devel\bin"; DestDir = "_rocm_sdk_devel\bin"; Extensions = @("*") }
        )
    }
    "CUDA_12" {
        $Config.BackendString = "NVIDIA CUDA 12.1 (PyTorch Default)"
        $Config.PipCommands = @(
            "install --index-url https://download.pytorch.org/whl/cu121 --pre -U torch torchvision torchaudio --no-cache-dir --no-warn-script-location"
        )
        $Config.LauncherInjectPaths = @("$PayloadNamespace\torch\lib")
        $Config.LauncherEnvVars = @()
        $Config.PyInstallerCollectAll = @("torch", "torchvision", "torchaudio")
        $Config.PyInstallerHiddenImports = @("torch")
        $Config.SpecPathex = @("Lib\site-packages\torch\lib")
        $Config.ExplicitBinaries = @()
        $Config.ExplicitDatas = @()
    }
    "CUDA_11" {
        $Config.BackendString = "NVIDIA CUDA 11.8 (Legacy Compute)"
        $Config.PipCommands = @(
            "install --index-url https://download.pytorch.org/whl/cu118 --pre -U torch torchvision torchaudio --no-cache-dir --no-warn-script-location"
        )
        $Config.LauncherInjectPaths = @("$PayloadNamespace\torch\lib")
        $Config.LauncherEnvVars = @()
        $Config.PyInstallerCollectAll = @("torch", "torchvision", "torchaudio")
        $Config.PyInstallerHiddenImports = @("torch")
        $Config.SpecPathex = @("Lib\site-packages\torch\lib")
        $Config.ExplicitBinaries = @()
        $Config.ExplicitDatas = @()
    }
    "CPU" {
        $Config.BackendString = "Agnostic / CPU Fallback"
        $Config.PipCommands = @(
            "install --index-url https://download.pytorch.org/whl/cpu --pre -U torch torchvision torchaudio --no-cache-dir --no-warn-script-location"
        )
        $Config.LauncherInjectPaths = @("$PayloadNamespace\torch\lib")
        $Config.LauncherEnvVars = @()
        $Config.PyInstallerCollectAll = @("torch", "torchvision", "torchaudio")
        $Config.PyInstallerHiddenImports = @("torch")
        $Config.SpecPathex = @("Lib\site-packages\torch\lib")
        $Config.ExplicitBinaries = @()
        $Config.ExplicitDatas = @()
    }
    "STANDARD" {
        $Config.BackendString = "Standard Application (No Machine Learning)"
        $Config.PipCommands = @()
        $Config.LauncherInjectPaths = @()
        $Config.LauncherEnvVars = @()
        $Config.PyInstallerCollectAll = @()
        $Config.PyInstallerHiddenImports = @()
        $Config.SpecPathex = @()
        $Config.ExplicitBinaries = @()
        $Config.ExplicitDatas = @()
    }
}

$Config | ConvertTo-Json -Depth 5 -Compress