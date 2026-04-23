# The Polymorphic Encapsulator

## Overview
The Polymorphic Encapsulator is a zero-configuration deployment toolchain designed to transform Python-based machine learning applications into hermetic, fully portable deployment artifacts. 

It solves the fundamental problem of distributing hardware-accelerated applications (e.g., AMD ROCm, NVIDIA CUDA) by completely encapsulating both the Python runtime and the dynamic C++ dependency matrices. The resulting deployment executes flawlessly on target machines without requiring the end user to install external runtimes, SDKs, or system-level dependencies.

## Encapsulation Guide
Encapsulation is structurally automated and driven entirely by an interactive terminal UI. **No complex command-line flags, arguments, or manual configuration files are required.**

1. **Preparation:** Ensure the following assets share a single root directory:
   - Your application entry point (e.g., `diagnostic.py`)
   - Your dependency manifest (`requirements.txt`)
   - The orchestrator (`encapsulator.ps1`)
   - The telemetry node (`hardware_probe.ps1`)

2. **Execution:** Open a PowerShell terminal in the target directory and invoke the script directly:
   ```powershell
   .\encapsulator.ps1
   ```

3. **Interactive Configuration:** The orchestrator will launch an interactive menu system. Use your arrow keys and `Enter` to navigate and select your parameters:
   - **Target Application:** Automatically detects and lists available `.py` entry points in the directory.
   - **Hermetic Runtime:** Select the exact Python version to embed.
   - **Computation Backend:** Choose ROCm, CUDA, CPU Fallback, or let the HAL probe auto-detect the host hardware.
   - **GC Policy:** Choose whether to retain the build environment or execute an ephemeral teardown.

4. **Deployment:** The compiler will autonomously resolve the dependency graph and construct an isolated `Deploy_[App]` directory. This directory represents your final, self-contained distribution artifact.

## End-User Execution
The generated payload is strictly insulated within its deployment geometry to prevent dynamic resolution collisions. To guarantee absolute hermeticism, the end user must execute the application via the generated Proxy Launcher.

**To run the application:**
```cmd
.\launch_[App].bat
```

### The Ephemeral Proxy Paradigm
Traditional deployment architectures fail when analyzing dynamic C++ translation layers because static analyzers cannot map runtime-injected binary matrices. This toolchain bypasses these limitations using Topographical Mirroring and Ephemeral Environment Mutation.

When the batch launcher is invoked:
1. An ephemeral, localized memory boundary is instantly established.
2. Existing host environment variables are heuristically sanitized to prevent host-side dependency pollution.
3. The explicit topographical geometries of the required hardware libraries are dynamically injected into the Windows PE Loader's active path sequence.
4. The C-bootloader (`.exe`) executes natively, resolving all C++ instructions seamlessly.
5. Upon termination, the localized boundary collapses, leaving zero trace on the host operating system while transparently propagating the exact exit code (`ERRORLEVEL`) to the parent process.
