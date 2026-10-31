# ControlRAM (v0.5.0 R22)

> **Multi-Lane Dynamic Resource Optimization Architecture for RAM and CPU on Windows 10 and Windows 11.**

**Language / Lingua:** **English** | [ðŸ‡®ðŸ‡¹ Versione Italiana](README_IT.md)

[![Project Status](https://img.shields.io/badge/Status-Experimental%20%2F%20In%20Active%20Development-orange.svg)](#-experimental-status-declaration)
[![Platform](https://img.shields.io/badge/OS-Windows%2010%20%7C%20Windows%2011%20x64-blue.svg)](#system-requirements)
[![Native Core](https://img.shields.io/badge/Core-C%2B%2B20%20Native%20DLL-green.svg)](#5-lane-engine-architecture-multi-lane-system)
[![Interface](https://img.shields.io/badge/UI-WinForms%20Lightweight%20Dashboard-purple.svg)](#how-to-run-the-project)
[![Observed Savings](https://img.shields.io/badge/RAM%20Reclaimed-20%25%20--%2030%25%20Real-brightgreen.svg)](#real-world-field-results-and-measured-savings)

---

## ⚠️ EXPERIMENTAL STATUS DECLARATION

> [!WARNING]
> **WARNING: EXPERIMENTAL PROJECT AND NOT YET STABLE.**
> AdvancedMemoryEngine (AME) is currently an **experimental project (preview version 0.5.0 R22)** and is **NOT yet considered a stable or production-ready release**.
> 
> * **Measurable Real-World Savings:** The software is actively used in daily real-world workflows and demonstrably achieves a tangible benefit, consistently **reducing system RAM pressure by 20% to 30%** depending on the number and type of optimized processes.
> * **Open Long-Term Unknowns (CPU & Internal APIs):** Although the memory reduction is concrete and measurable, **it is NOT yet clear whether this continuous cycle of working set trimming, priority demotion, and scheduling adjustments could, over the long term, adversely affect, fatigue, or stress the processor (CPU), or trigger unexpected instability in internal Windows APIs or application runtimes.**
> * Anyone choosing to test or use AME does so in an active research context, with full awareness that long-term hardware and OS implications remain an open subject of observation and study.

---

## 💡 Why AME Exists and What It Does

On modern Windows installations, users frequently face severe physical RAM saturation (85%–95%), even with 16 GB or 32 GB of memory installed. This happens because:
1. **Background Desktop Applications** (messaging clients, AI assistants, UWP apps, system services) retain megabytes or gigabytes of operative memory (*Working Set*) long after active use has ceased.
2. **Modern Web Browsers (Chrome, Edge, Firefox)** spawn dozens of dedicated subprocesses (renderers, GPU, audio, utility) that hoard massive amounts of resident memory.
3. **Virtual Machines & Containers (WSL2 / `vmmemWSL` / Docker)** accumulate Linux kernel page caches that are not automatically reclaimed by Windows, easily devouring 2–3 GB of host RAM on their own.
4. **Windows NT Memory Compression** functions as an in-RAM safety cache to prevent disk thrashing; however, when physical RAM exceeds 88%–90%, the kernel locks compressed memory to avoid an Out-of-Memory (OOM) crash, preventing automatic deflation.

**AME is not a generic RAM cleaner** (which blindly flushes caches or forcefully terminates processes, causing system freezing). AME is an **intelligent Multi-Lane Decision Engine** that continuously monitors the system and intervenes using a structured hierarchy:
* Compacts memory exclusively for long-idle background processes;
* Demotes background scheduling priority to **EcoQoS** (Efficiency Mode);
* Strictly protects active foreground applications to ensure zero input lag;
* Instantly restores normal priority and memory allocations the moment a user switches back to an application.

---

## 📊 Real-World Field Results and Measured Savings

> [!IMPORTANT]
> **Daily Usage Experience & Verified Metrics:**
> In daily workflow testing on 16 GB development machines under typical multi-tasking workloads:
> * AME consistently achieves a **20% to 30% reduction in total RAM pressure** across open applications.
> * On a machine starting at 90% RAM pressure (~14.4 GB allocated), the coordinated multi-lane cycle brings resident memory down to **65%–72%**, freeing **2.5 to over 4.0 Gigabytes of physical RAM**.
> * On systems running WSL2 / Docker, combining AME with Linux in-guest cache flushing (`drop_caches`) freed **over 1,900 MB of RAM** from the single `vmmemWSL` virtual machine worker.
> 
> **The Flip Side of the Coin:** While this reclaimed memory provides breathing room and prevents disk thrashing, the experimental nature of the project demands caution: we cannot assume that continuous memory reorganization is completely free of long-term side effects on the CPU or operating system APIs.

---

## 🔍 Technical Analysis: CPU Behavior and Internal API Unknowns

Because AME operates closely with Windows NT subsystem APIs, it is essential to present an honest, transparent breakdown of both known architectural protections and **unresolved long-term questions**.

### 1. Known Hardware Protections & Engine Guard Rails
* **Physical CPU Safety:** Modern microprocessors (Intel Core / AMD Ryzen) cannot be physically damaged by user-mode memory management software. Silicon-level hardware limiters (PROCHOT, digital thermal sensors, power throttling, VRM controllers) prevent voltage or thermal overshoots. AME does not overclock or alter hardware voltages.
* **Documented Microsoft APIs:** AME avoids dangerous kernel hooks or DLL injection, relying strictly on official Win32/NT APIs (`SetProcessWorkingSetSizeEx`, `SetPriorityClass`, `SetProcessInformation`, `GlobalMemoryStatusEx`).
* **EcoQoS Efficiency Mode:** Applying EcoQoS to eligible background processes directs low-priority threads to Intel/AMD Efficiency cores (**E-cores**), lowering background clock frequencies and reducing heat output.
* **Safety Guard Rails:** To prevent continuous memory thrashing, AME enforces mandatory per-process cooldown periods (**120s to 600s**), a 30-second persistence threshold before taking action, and strict exclusion of the foreground application.

### 2. ⚠️ Open Unknowns: What Is NOT Yet Proven Over Time

Despite conforming to standard APIs and safety limits, because AME is an **experimental and not yet stable project**, critical questions remain open:

1. **Potential CPU Scheduler Fatigue & Overhead:**
   While EcoQoS aims to save power, continually toggling priority states, migrating threads between P-cores and E-cores, and managing hundreds of processes might create an unforeseen background burden on the Windows NT kernel scheduler over time, with cumulative effects on latency still to be measured.
2. **Third-Party Application API Resilience:**
   Many desktop frameworks (Electron, .NET CLR, JVM, modern game engines) are not designed for repeated external trimming of their Working Set. It is not yet clear whether frequent trimming could cause subtle memory leaks, unexpected exceptions, or internal API deadlocks in third-party runtimes.
3. **Cumulative Page Fault Cycles & Virtual Memory Wear:**
   When a trimmed process wakes up, it must fault required pages back into physical RAM. If this cycle repeats too frequently, the cumulative surge in soft/hard page faults could stress virtual memory management.

> [!CAUTION]
> **Safety Conclusions:**  
> AME demonstrably frees 20%–30% of RAM and serves as a powerful defense against memory exhaustion, but **its experimental nature requires full user awareness**: long-term effects on the processor and internal Windows APIs remain an open area of investigation. It is recommended for developers, enthusiasts, and users willing to monitor performance and share feedback.

---

## 🏛️ 5-Lane Engine Architecture (Multi-Lane System)

```
┌────────────────────────────────────────────────────────────────────────┐
│                   AdvancedMemoryEngine (AME v0.5.0 R22)                 │
└────────────────────────────────────┬───────────────────────────────────┘
                                     │
       ┌─────────────────────────────┼─────────────────────────────┐
       ▼                             ▼                             ▼
┌──────────────┐              ┌──────────────┐              ┌──────────────┐
│    LANE 1    │              │    LANE 2    │              │    LANE 3    │
│  Windows OS  │              │ Dev Runtimes │              │  Browser     │
│  Background  │              │  & Language  │              │ Subprocesses │
│  Processes   │              │   Servers    │              │  (OS Level)  │
└──────┬───────┘              └──────┬───────┘              └──────┬───────┘
       │                             │                             │
       ▼                             ▼                             ▼
 [Stage 14 Trim]               [Stage 10 Trim]               [Stage 10 Trim]
 Priority: VeryLow             Priority: Low                 Working Set Trim
 EcoQoS: Enabled               EcoQoS: EXCLUDED              Zero Extensions
 Memory: Trim WS               (Zero IDE Lag)                100% Autonomous
       │                             │                             │
       └─────────────────────────────┼─────────────────────────────┘
                                     │
       ┌─────────────────────────────┴─────────────────────────────┐
       ▼                                                           ▼
┌──────────────┐                                            ┌──────────────┐
│    LANE 4    │                                            │    LANE 5    │
│  Web Tabs    │                                            │ Virtual VM & │
│ (Extension)  │                                            │ Linux / WSL2 │
└──────┬───────┘                                            └──────┬───────┘
       │                                                           │
       ▼                                                           ▼
 Tab Discarding                                              `drop_caches`
 Whitelisted Domains                                         `autoMemoryReclaim`
 Data Safety Gate                                            `vmmemWSL` Trim
```

1. **Lane 1 — Windows OS Background Processes (Stage 14):**
   Targets desktop software, background AI tools, and UWP apps (e.g. `chatgpt.exe`, `claude.exe`, `searchhost.exe`), reducing working sets and applying EcoQoS.
2. **Lane 2 — Dev Runtimes & Productivity Tools (Stage 10):**
   Selectively identifies development environments (`python.exe`, `node.exe`, `language_server.exe`, `antigravity.exe`, `code.exe`, `pwsh.exe`). Compacts memory but **strictly excludes CPU throttling**, ensuring compilation and code completion remain lightning-fast.
3. **Lane 3 — OS-Level Browser Subprocesses:**
   Autonomously monitors child processes of Chrome, Edge, Firefox, and Brave (idle renderers, GPU processes, utility workers) without requiring any browser extension.
4. **Lane 4 — Authorized Web Tab Discarding (Optional Extension):**
   Communicates via Native Messaging Host with the AME browser extension. Hibernates tabs idle for over 15 minutes, strictly restricted to user-whitelisted domains to prevent data loss.
5. **Lane 5 — Virtualization Environments (WSL2 / Docker / `vmmemWSL`):**
   Coordinates with Hyper-V and the Linux kernel to drop in-guest disk caches (`drop_caches`), reclaiming gigabytes of RAM held by containers.
6. **Gaming Mode (RAM Clamping Mix A+B):**
   Allows locking a designated memory-heavy process to a rigid threshold (in MiB) using continuous, dynamic memory clamping.

---

## 🚀 How to Run the Project

AME is designed for straightforward execution via root `.cmd` batch scripts without requiring complex setup.

### System Requirements
* **Operating System:** Windows 10 (64-bit) Build 19041+ or Windows 11 (recommended).
* **Shell:** Windows PowerShell 5.1 (built into Windows) or PowerShell 7+.
* **Compiler (Only required if rebuilding native C++ components):**
  * Microsoft Visual Studio 2022 ("Desktop development with C++") or MinGW-w64 (GCC 11+).
  * *Note: If `build/ame.dll` is already compiled and validated, the build step is automatically skipped.*

---

### Main Startup Scripts

| Script | Mode | Description |
| :--- | :--- | :--- |
| [`AUTOMATICO.cmd`](AUTOMATICO.cmd) | **Background Engine (Daemon)** | Launches the core AME engine in a console window. Continuously gathers memory/CPU telemetry, executes balancing cycles, and writes live status. Can remain minimized. |
| [`STATO_AUTOMATICO.cmd`](STATO_AUTOMATICO.cmd) | **GUI Dashboard** | Opens the ultra-low-footprint WinForms interface (Deep Cyber Slate theme, <25 MB RAM). Displays 5 live KPI cards (including total system CPU usage), the managed process table, and action controls. |
| [`engine/AVVIA.cmd`](engine/AVVIA.cmd) | **Bootstrap & Validation** | Runs native compilation checks and executes the full validation test suite (83 automated unit checks). Useful after modifying source code. |

### Recommended Getting Started Steps:
1. Double-click [`AUTOMATICO.cmd`](AUTOMATICO.cmd) to start the background engine.
2. Double-click [`STATO_AUTOMATICO.cmd`](STATO_AUTOMATICO.cmd) to open the monitoring dashboard.
3. From the Dashboard you can:
   * Monitor live RAM pressure and total system CPU activity;
   * Click **"Ottimizza Ora" (Optimize Now)** for an immediate multi-lane memory reclaim;
   * Click **"Svuota Compressione" (Flush Compression)** to purge Windows kernel compressed memory;
   * Click **"Modalità Gioco (Clamp)"** to enforce a fixed RAM ceiling on a heavy process;
   * Click **"Ferma e Ripristina" (Stop & Restore)** to gracefully exit AME and restore all processes to normal Windows priority levels.

---

## 🛠️ Recommended Configuration for WSL2 / Docker

If you use Docker Desktop or WSL2 (Ubuntu, Debian, etc.), create or edit `.wslconfig` in your user directory (`C:\Users\<YourUser>\.wslconfig`):

```ini
[wsl2]
# Hard memory ceiling for the Linux VM (prevents vmmemWSL from exceeding 1.8 GB)
memory=1.8GB
# Number of virtual CPU cores assigned to Linux
processors=6
# Swap file size on disk
swap=2GB
# Windows 11 native feature: gradually deflates idle memory back to Windows host
autoMemoryReclaim=gradual
# Automatically shrinks the virtual disk (VHD) on free space
sparseVhd=true
```

After saving, open a Windows command prompt and execute `wsl --shutdown` to apply the new settings.

---

## ❓ Frequently Asked Questions (FAQ)

#### Q: The dashboard says "Osservo tutti i processi; attendo pressione RAM persistente. Nessun intervento necessario o ancora idoneo." Is it stuck?
> **A:** No, this is normal standby mode. AME acts only when RAM pressure exceeds the configured threshold (default: 80%–85%) for at least 30 consecutive seconds. Recently optimized processes are protected by a cooldown timer to prevent CPU thrashing.

#### Q: Does AME keep running if I close the Dashboard window?
> **A:** Yes. The GUI dashboard (`STATO_AUTOMATICO.cmd`) is an independent viewer. The core engine runs inside the `AUTOMATICO.cmd` console. To stop everything, click "Ferma e Ripristina" or close the console.

#### Q: How do I completely remove AME?
> **A:** AME is 100% portable. It does not write hidden registry keys or install permanent background services. To remove it, stop the engine and delete the directory. All process priorities and working sets immediately revert to standard Windows defaults.

---

## 📄 License & Legal Notice

Distributed under an open research license for testing, study, and Windows resource efficiency benchmarking.

*Microsoft, Windows, Windows NT, Hyper-V, and WSL are registered trademarks of Microsoft Corporation.*  
*Google Chrome is a registered trademark of Google LLC. Mozilla Firefox is a registered trademark of Mozilla Foundation.*
