# The Polymorphic Encapsulator

## Overview
"Encapsulator" is a zero-configuration deployment toolchain designed to transform Python-based machine learning applications into hermetic, fully portable deployable artifacts. 

It solves intends to simplify distributing of hardware-accelerated applications (e.g., AMD ROCm, NVIDIA CUDA) by completely encapsulating both the Python runtime and dynamic C++ dependency matrix. The resulting deployment executes flawlessly on target machines as a **fully autonomous executable**, without requiring the end user to install external runtimes, SDKs, or system-level dependencies.

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

3. **Interactive Configuration:** The orchestrator will launch an interactive menu system. Navigate using arrow keys and `Enter` to select your parameters:
   - **Target Application:** Automatically detects and lists available `.py` entry points.
   - **Hermetic Runtime:** Select the exact Python version to embed.
   - **Computation Backend:** Choose ROCm, CUDA, CPU Fallback, or let the HAL probe auto-detect the host hardware.
   - **Output Format:** Choose between a fast Directory Distribution (`OneDir`) or a Self-Extracting Archive (`OneFile`).
   - **GC Policy:** Choose whether to retain the build environment or execute an ephemeral teardown.

4. **Deployment:** The compiler will autonomously resolve the dependency graph, inject native Windows kernel routing hooks, and construct an isolated `Deploy_[App]` directory. This directory represents your final distribution artifact.

## The Autonomous Executable Paradigm
Standard deployment architectures fail when analyzing dynamic C++ translation layers because static analyzers cannot map runtime-injected binary matrices. Previous workarounds relied on proxy scripts (`.bat`) to temporarily hijack environment variables. 

This architecture bypasses those limitations natively via **Process Environment Block (PEB) Hijacking** and **Topographical Mirroring**. The generated `.exe` is perfectly autonomous.

**Execution Lifecycle:**
1. The user executes the compiled `.exe` natively.
2. Before the CPython API initializes, a deeply embedded runtime hook executes.
3. The hook aggressively sanitizes the host OS environment, stripping hostile substrings and poisoned literal quotes from the system `PATH`.
4. It invokes the Win32 `SetDefaultDllDirectories` API at the kernel level, instantly blinding the Windows Portable Executable (PE) Loader to host-side toolchain pollution.
5. The exact topographical geometries of the required hardware libraries are dynamically mapped into the local namespace (`sys._MEIPASS`) via `os.add_dll_directory`.
6. The application executes with native hardware acceleration, completely deaf to the host operating system.

## Output Topologies & I/O Physics

The encapsulator supports two deployment topologies. It is mathematically invariant and will securely adapt kernel routing to either format automatically:

### 1. Directory Distribution (`OneDir` - Recommended for ML)
The payload is compiled into a localized folder containing the `.exe` and the extracted `.venv` namespace. 
* **Advantage:** Instantaneous execution. The Windows PE Loader maps the native C++ DLLs directly from the disk into system memory and VRAM with zero overhead.

### 2. Single Executable (`OneFile` - Severe I/O Penalty for ML)
The payload is flattened into a single, self-extracting `.exe`.
* **Warning:** Machine Learning workloads carry 3GB+ of embedded C++ matrices (AMD/NVIDIA kernels) to a temporary `%TEMP%` directory at runtime. 
* **Consequence:** While active compute performance remains 1:1, application init suffers a severe initialization penalty (~30s to minutes) and also suffers from teardown latency when the temporary files are deleted on exit. 
