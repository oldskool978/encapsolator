param (
    [string]$ForceBackend = ""
)

# Enforce strict execution and silence transient non-terminating errors
$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"
$VerbosePreference = "SilentlyContinue"

function Resolve-HardwareMatrix {
    if ($ForceBackend) {
        return $ForceBackend, "gfx120X" 
    }

    # Phase 1: Zero-Dependency Kernel Interrogation via CIM
    $GPUs = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
    
    $HasNvidia = $false
    $HasAmd    = $false
    $HasIntel  = $false
    
    # Baseline modern assumption, elevated by discrete presence
    $AmdTargetGfx = "gfx1100" 

    if ($null -ne $GPUs) {
        foreach ($gpu in $GPUs) {
            $Name = $gpu.Name
            $Inf  = $gpu.InfSection
            
            if ([string]::IsNullOrWhiteSpace($Name)) { continue }

            if ($Name -match "(?i)NVIDIA") { $HasNvidia = $true }
            if ($Name -match "(?i)Intel.*(Arc|Iris|Ultra)") { $HasIntel = $true }
            
            if ($Name -match "(?i)AMD|Radeon|Ryzen") {
                $HasAmd = $true
                
                # Phase 2: Multi-Factor LLVM Topography Mapping (Name + InfSection Driver String)
                if ($Name -match "(?i)R9700|R9\d00|AI\s*PRO\s*R|890M|880M|Strix|Ryzen\s*AI|RX\s*[89]\d{2,3}" -or $Inf -match "(?i)Navi48|Navi44") {
                    $AmdTargetGfx = "gfx120X"
                } 
                elseif ($Name -match "(?i)7900|W7900|7900M|7800|7700|W7800|W7700|7600" -or $Inf -match "(?i)Navi3") { 
                    $AmdTargetGfx = "gfx1100"
                } 
                elseif ($Name -match "(?i)780M|760M|740M|Phoenix|Hawk") { 
                    $AmdTargetGfx = "gfx1103" 
                } 
                elseif ($Name -match "(?i)6900|6800|6700|W6800" -or $Inf -match "(?i)Navi2") { 
                    $AmdTargetGfx = "gfx1030"
                } 
                elseif ($Name -match "(?i)MI300") {
                    $AmdTargetGfx = "gfx942"
                } elseif ($Name -match "(?i)MI250") {
                    $AmdTargetGfx = "gfx90a"
                }
            }
        }
    }

    # Phase 3: Strict Execution Hierarchy Resolution
    if ($HasNvidia) {
        $NvidiaSmi = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
        if ($NvidiaSmi) {
            try {
                $SmiOutput = & $NvidiaSmi.Source --query-gpu=driver_version --format=csv,noheader 2>$null
                if ($SmiOutput -match "^\d+\.") {
                    $MajorVersion = [int]($SmiOutput -split '\.')[0]
                    if ($MajorVersion -ge 520) { return "CUDA_12", "" }
                    if ($MajorVersion -ge 450) { return "CUDA_11", "" }
                }
            } catch {
                # Swallow SMI execution failures to guarantee fallback preservation
            }
        }
        return "CUDA_12", "" 
    }

    if ($HasAmd) {
        return "ROCM", $AmdTargetGfx
    }

    if ($HasIntel) {
        return "INTEL_XPU", ""
    }

    return "CPU", ""
}

$Profile, $LLVMTarget = Resolve-HardwareMatrix
$PayloadNamespace = ".venv"

# Phase 4: Strict Payload Schema Definition
$Config = @{
    BackendString            = ""
    PipCommands              = @()
    LauncherInjectPaths      = @()
    LauncherEnvVars          = @()
    PyInstallerCollectAll    = @()
    PyInstallerHiddenImports = @()
    SpecPathex               = @()
    ExplicitBinaries         = @()
    ExplicitDatas            = @()
}

switch ($Profile) {
    "ROCM" {
        $Config.BackendString = "AMD ROCm Target ($LLVMTarget/HIP)"
        
        # Unified Windows ROCm Pipeline: Upstream PyTorch does NOT host Windows ROCm binaries.
        # We must strictly utilize the dynamic LLVM architecture target against the AMD staging matrix.
        $GfxUrlParam = "$LLVMTarget-all"
        $GfxPkgName  = "_rocm_sdk_libraries_$($LLVMTarget)_all"
        
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
        $Config.PyInstallerCollectAll = @("torch", "torchvision", "torchaudio")
        $Config.PyInstallerHiddenImports = @("torch")
        $Config.SpecPathex = @("Lib\site-packages\torch\lib")
    }
    "CUDA_11" {
        $Config.BackendString = "NVIDIA CUDA 11.8 (Legacy Compute)"
        $Config.PipCommands = @(
            "install --index-url https://download.pytorch.org/whl/cu118 --pre -U torch torchvision torchaudio --no-cache-dir --no-warn-script-location"
        )
        $Config.LauncherInjectPaths = @("$PayloadNamespace\torch\lib")
        $Config.PyInstallerCollectAll = @("torch", "torchvision", "torchaudio")
        $Config.PyInstallerHiddenImports = @("torch")
        $Config.SpecPathex = @("Lib\site-packages\torch\lib")
    }
    "INTEL_XPU" {
        $Config.BackendString = "Intel OneAPI XPU (Arc/Core Ultra)"
        $Config.PipCommands = @(
            "install torch torchvision torchaudio intel-extension-for-pytorch --index-url https://pytorch-extension.intel.com/release-whl/stable/xpu/us/ --no-cache-dir --no-warn-script-location"
        )
        $Config.LauncherInjectPaths = @(
            "$PayloadNamespace\torch\lib",
            "$PayloadNamespace\intel_extension_for_pytorch\bin"
        )
        $Config.PyInstallerCollectAll = @("torch", "torchvision", "torchaudio", "intel_extension_for_pytorch")
        $Config.PyInstallerHiddenImports = @("torch", "intel_extension_for_pytorch")
        $Config.SpecPathex = @(
            "Lib\site-packages\torch\lib",
            "Lib\site-packages\intel_extension_for_pytorch\bin"
        )
    }
    "CPU" {
        $Config.BackendString = "Agnostic / CPU Fallback"
        $Config.PipCommands = @(
            "install --index-url https://download.pytorch.org/whl/cpu --pre -U torch torchvision torchaudio --no-cache-dir --no-warn-script-location"
        )
        $Config.LauncherInjectPaths = @("$PayloadNamespace\torch\lib")
        $Config.PyInstallerCollectAll = @("torch", "torchvision", "torchaudio")
        $Config.PyInstallerHiddenImports = @("torch")
        $Config.SpecPathex = @("Lib\site-packages\torch\lib")
    }
    "STANDARD" {
        $Config.BackendString = "Standard Application (No Machine Learning)"
    }
}

# Phase 5: Pipeline Serialization
# Emitted directly to standard output for strict capture by orchestrator processes
$Config | ConvertTo-Json -Depth 5 -Compress
