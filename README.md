# ☀️ sunCleaner

<p align="center">
  <b>lordofsunshine/sunCleaner</b> — solar care for Windows
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-1.0.0-ffb627?style=for-the-badge" />
  <img src="https://img.shields.io/badge/powershell-5.1-3178c6?style=for-the-badge&logo=powershell&logoColor=white" />
  <img src="https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078d6?style=for-the-badge" />
  <img src="https://img.shields.io/badge/license-MIT-ffffff?style=for-the-badge" />
</p>

<p align="center">
  <a href="#-english">🇬🇧 English</a> &nbsp;·&nbsp; <a href="#-русский">🇷🇺 Русский</a>
</p>

```
     \  |  /
      .---.
  -- (     ) --
      '---'
     /  |  \
  sunCleaner v1.0.0
  lordofsunshine/sunCleaner
```

---

<a id="-english"></a>
## 🇬🇧 English

> Disk cleanup, optimization, diagnostics and scheduler — declarative registries, honest `WhatIf`, 3-color sun palette. Made to drop your jaw!

**Palette:** `Amber #FFB627` · `White #FFF4E6` · `Coral #FF6B35` on dark background.

### 🚀 Quick start

```powershell
.\sunCleaner.ps1                 # interactive menu, auto-elevates
.\sunCleaner.ps1 -Plain          # ascii borders
.\sunCleaner.ps1 -InstallSchedule
.\sunCleaner.ps1 -RemoveSchedule
```

Menu: `↑`/`↓` navigate, `Enter` select, `Space` toggle, `a` all, `n` none, `Esc` back.

**Without install (pastebin):**
```powershell
powershell -ExecutionPolicy Bypass -Command "irm https://pastebin.com/raw/XXXX | iex"
```

### ✨ Capabilities

| Section | What it does |
|---------|--------------|
| **Disk cleanup** | Clears browser, dev-tools, apps, games, system, logs and update caches |
| **Optimize Windows** | Performance, privacy, debloat, network tweaks — full `Undo` |
| **Troubleshoot** | Scans 28 checks and offers to fix, heavy fixes on demand |
| **Tools** | `Network` (dns/reset/adapters), `Startup` (autostart), `Schedule` (scheduler) |
| **Manage tweaks** | Pick category → list with `[x]/[ ]` → on/off affects next run |
| **Safety** | `Undo` last optimization, create restore point |

### 📊 Stats

**158 tweaks total** *(Clean 69 · Optimize 61 · Repair 28)*

| Clean (69) | Optimize (61) | Repair (28) |
|------------|---------------|-------------|
| Browsers 6 | Appearance 10 | Devices 1 |
| DevTools 12 | Debloat 8 | Disk 4 |
| Apps 12 | Network 7 | Integrity 1 |
| Games 1 | Performance 10 | Network 3 |
| System 17 | Privacy 26 | Security 4 |
| Disks 2 |  | Services 2 |
| Logs 9 |  | System 10 |
| Updates 4 |  | Update 3 |
| Optimization 6 |  |  |

### 📦 What it cleans / tweaks / checks

<details>
<summary><b>🧹 Disk cleanup — 69 tasks</b></summary>

**Browsers (6)** — Chrome, Edge, Firefox, Opera, Yandex, Brave `Cache / Code Cache / GPUCache / Service Worker`

**DevTools (12)** — `npm`, `pip`, `Yarn`, `NuGet`, `Gradle`, `VS Code`, `JetBrains (caches/logs/tmp)`, `Nuitka`, `Docker`, `pnpm`, `winget/choco/scoop/conda/cargo/go/pub`, `PowerShell AnalysisCache`

**Apps (12)** — `Windows app cache`, `Teams` (classic+new), `Discord`, `Slack`, `Spotify`, `Office` (FileCache/Wef), `OneDrive logs`, `Adobe media/CameraRaw`, `RDP bitmap`, `Outlook RoamCache`, `Adobe Photoshop Logs`, `Store temp`

**Games (1)** — `Steam`/`Epic`/`Battle.net`/`GOG` caches

**System (17)** — `User/Windows Temp`, `WinINet`, `thumbnails`, `GPU shader (NVIDIA/AMD)`, `Driver leftovers`, `WebCache`, `DeliveryOptimization`, `Recent/JumpLists`, `FontCache`, `Win Logs`, `Prefetch`, `driver pnputil`, `Print spooler queue`

**Disks (2)** — `Temp/tmp` on all drives, `FOUND.*`

**Logs (9)** — `WER`, `Panther/setupapi`, `LiveKernel`, `SRU`, `EventTranscript`, `CrashDumps`, `IIS (>14d)`, `Recycle Bin`, `Event logs` (dangerous)

**Updates (4)** — `WU Download`, `SoftwareDistribution`, `PatchCache` (dangerous), `Windows.old`

**Optimization (6)** — `DISM /Analyze`, `StartComponentCleanup`, `DISM cleanup`, `DISM ResetBase`, `DISM logs`, `sfc /scannow`, `Volume ReTrim`, `Store WSReset`

</details>

<details>
<summary><b>⚡ Optimize — 61 tweaks</b></summary>

**Performance (10)** — `visual effects best`, `menu delay 0`, `startup delay 0`, `background apps off`, `fast startup off`, `High Performance plan`, `Ultimate plan`, `SysMain off`, `WSearch off`, `hibernation off`

**Privacy (26)** — `telemetry min`, `advertising ID off`, `consumer features off`, `tips/spotlight off`, `activity feed off`, `web search off`, `Cortana off`, `DiagTrack off`, `dmwappush off`, `CEIP tasks off`, `Recall/ClickToDo off`, `Copilot off`, `tailored experiences off`, `Spotlight off`, `inking personalization off`, `typing upload off`, `speech cloud off`, `CEIP off`, `appcompat telemetry off`, `WER upload off`, `feedback off`, `DeliveryOptimization P2P off`, `OneDrive pre-signin off`, `clipboard sync off`, `location off`, `FindMyDevice off`

**Debloat (8)** — `junk UWP remove`, `Xbox remove`, `comms remove (Mail/Skype/Phone)`, `Start ads off`, `taskbar Widgets/Chat/Start/Explorer ads off`, `SCOOBE nag off`, `file extensions show`, `classic context menu`

**Network (7)** — `GameDVR off`, `GameDVR policy`, `Game Mode on`, `throttling off`, `Teredo off`, `NDU off`, `Nagle off`

**Appearance (10)** — `dark mode`, `transparency off`, `animations off`, `taskbar left`, `taskbar combine never`, `search hidden`, `Task View off`, `Start recommended off`, `hidden files on`, `NumLock on`, `mouse accel off`

</details>

<details>
<summary><b>🔧 Repair — 28 checks</b></summary>

**System (10)** — `WMI consistency`, `time sync`, `recent error events`, `System Restore`, `scheduled tasks`, `Store health`, `SSD wear/temp`, `crash history (BSOD)`, `startup bloat`, `volume fragmentation`

**Disk (4)** — `SMART`, `low space`, `dirty flag (chkdsk)`, `reliability`

**Security (4)** — `Defender health`, `firewall`, `Defender signatures`, `SMBv1`

**Network (3)** — `Internet/DNS`, `hosts hijack`, `proxy/PAC hijack`

**Update (3)** — `pending reboot`, `WU components`, `BITS queue`

**Other** — `Integrity (DISM)`, `Devices (driver errors)`, `Services (critical stopped)`, `winget updates`

`Safe`/`Moderate` fix immediately, `Aggressive`/`Heavy` only with `IncludeHeavy`.

</details>

### 🗂️ Structure

```
sunCleaner.ps1          — entry, honest loader
sunCleaner-standalone.ps1 — single file for pastebin raw (irm | iex) with module progress
src/
  Core/
    Common.ps1          — palette, logging, restore, reports
    UI.ps1              — TUI, viewport, sun
  Engines/
    Clean.ps1           — 69 tasks
    Optimize.ps1        — 61 tweaks
    Repair.ps1          — 28 checks
  Features/
    Schedule.ps1        — \sunCleaner\ weekly/monthly
    Network.ps1         — dns/reset/adapters/static/dhcp
    Startup.ps1         — StartupApproved manager
  Menu/
    Main.ps1            — banner, splash, menu, Manage
```

### 🛡️ Safety

* `Test-SafeToDelete` blocks `C:\`, `C:\Windows`, `System32`, `C:\Users`, shallow paths
* `Checkpoint-Computer` restore point (clears 24h throttle)
* Every tweak backs up value → `Undo`
* Start with `Preview` (`WhatIf`) — honest count, not estimate

---

<a id="-русский"></a>
## 🇷🇺 Русский

> Чистка диска, оптимизация, диагностика и планировщик — реестры, честный `WhatIf`, 3-цветная палитра солнца. Всё сделано для того, чтобы челюсть у вас отвисла!

**Палитра:** `Amber #FFB627` · `White #FFF4E6` · `Coral #FF6B35` на тёмном фоне.

### 🚀 Быстрый старт

```powershell
.\sunCleaner.ps1                 # интерактивное меню, сам повышает права
.\sunCleaner.ps1 -Plain          # ascii рамки
.\sunCleaner.ps1 -InstallSchedule
.\sunCleaner.ps1 -RemoveSchedule
```

Меню: `↑`/`↓` перемещение, `Enter` выбор, `Space` вкл/выкл, `a` все, `n` ни одного, `Esc` назад.

**Без установки (pastebin):**
```powershell
powershell -ExecutionPolicy Bypass -Command "irm https://pastebin.com/raw/XXXX | iex"
```

### ✨ Возможности

| Раздел | Что делает |
|--------|------------|
| **Disk cleanup** | Чистит кэши браузеров, дев-тулов, приложений, игр, системы, логов, обновлений |
| **Optimize Windows** | Твики производительности, приватности, де-блока, сети — с полным `Undo` |
| **Troubleshoot** | Сканирует 28 проверок и предлагает починить, heavy-фиксы по выбору |
| **Tools** | `Network` (dns/reset/adapters), `Startup` (автозагрузка), `Schedule` (планировщик) |
| **Manage tweaks** | Выбор категории → список с `[x]/[ ]` → вкл/выкл влияет на следующий запуск |
| **Safety** | `Undo` последней оптимизации, создание точки восстановления |

### 📊 Статистика

**Всего 158 твиков** *(Clean 69 · Optimize 61 · Repair 28)*

| Clean (69) | Optimize (61) | Repair (28) |
|------------|---------------|-------------|
| Browsers 6 | Appearance 10 | Devices 1 |
| DevTools 12 | Debloat 8 | Disk 4 |
| Apps 12 | Network 7 | Integrity 1 |
| Games 1 | Performance 10 | Network 3 |
| System 17 | Privacy 26 | Security 4 |
| Disks 2 |  | Services 2 |
| Logs 9 |  | System 10 |
| Updates 4 |  | Update 3 |
| Optimization 6 |  |  |

### 📦 Что чистит / твикает / проверяет

<details>
<summary><b>🧹 Disk cleanup — 69 задач</b></summary>

**Browsers (6)** — Chrome, Edge, Firefox, Opera, Yandex, Brave `Cache / Code Cache / GPUCache / Service Worker`

**DevTools (12)** — `npm`, `pip`, `Yarn`, `NuGet`, `Gradle`, `VS Code`, `JetBrains (caches/logs/tmp)`, `Nuitka`, `Docker`, `pnpm`, `winget/choco/scoop/conda/cargo/go/pub`, `PowerShell AnalysisCache`

**Apps (12)** — `Windows app cache`, `Teams` (classic+new), `Discord`, `Slack`, `Spotify`, `Office` (FileCache/Wef), `OneDrive logs`, `Adobe media/CameraRaw`, `RDP bitmap`, `Outlook RoamCache`, `Adobe Photoshop Logs`, `Store temp`

**Games (1)** — `Steam`/`Epic`/`Battle.net`/`GOG` кэши

**System (17)** — `User/Windows Temp`, `WinINet`, `thumbnails`, `GPU shader (NVIDIA/AMD)`, `Driver leftovers`, `WebCache`, `DeliveryOptimization`, `Recent/JumpLists`, `FontCache`, `Win Logs`, `Prefetch`, `driver pnputil`, `Print spooler queue`

**Disks (2)** — `Temp/tmp` на всех дисках, `FOUND.*`

**Logs (9)** — `WER`, `Panther/setupapi`, `LiveKernel`, `SRU`, `EventTranscript`, `CrashDumps`, `IIS (>14д)`, `Recycle Bin`, `Event logs` (dangerous)

**Updates (4)** — `WU Download`, `SoftwareDistribution`, `PatchCache` (dangerous), `Windows.old`

**Optimization (6)** — `DISM /Analyze`, `StartComponentCleanup`, `DISM cleanup`, `DISM ResetBase`, `DISM logs`, `sfc /scannow`, `Volume ReTrim`, `Store WSReset`

</details>

<details>
<summary><b>⚡ Optimize — 61 твик</b></summary>

**Performance (10)** — `visual effects best`, `menu delay 0`, `startup delay 0`, `background apps off`, `fast startup off`, `High Performance plan`, `Ultimate plan`, `SysMain off`, `WSearch off`, `hibernation off`

**Privacy (26)** — `telemetry min`, `advertising ID off`, `consumer features off`, `tips/spotlight off`, `activity feed off`, `web search off`, `Cortana off`, `DiagTrack off`, `dmwappush off`, `CEIP tasks off`, `Recall/ClickToDo off`, `Copilot off`, `tailored experiences off`, `Spotlight off`, `inking personalization off`, `typing upload off`, `speech cloud off`, `CEIP off`, `appcompat telemetry off`, `WER upload off`, `feedback off`, `DeliveryOptimization P2P off`, `OneDrive pre-signin off`, `clipboard sync off`, `location off`, `FindMyDevice off`

**Debloat (8)** — `junk UWP remove`, `Xbox remove`, `comms remove (Mail/Skype/Phone)`, `Start ads off`, `taskbar Widgets/Chat/Start/Explorer ads off`, `SCOOBE nag off`, `file extensions show`, `classic context menu`

**Network (7)** — `GameDVR off`, `GameDVR policy`, `Game Mode on`, `throttling off`, `Teredo off`, `NDU off`, `Nagle off`

**Appearance (10)** — `dark mode`, `transparency off`, `animations off`, `taskbar left`, `taskbar combine never`, `search hidden`, `Task View off`, `Start recommended off`, `hidden files on`, `NumLock on`, `mouse accel off`

</details>

<details>
<summary><b>🔧 Repair — 28 проверок</b></summary>

**System (10)** — `WMI consistency`, `time sync`, `recent error events`, `System Restore`, `scheduled tasks`, `Store health`, `SSD wear/temp`, `crash history (BSOD)`, `startup bloat`, `volume fragmentation`

**Disk (4)** — `SMART`, `low space`, `dirty flag (chkdsk)`, `reliability`

**Security (4)** — `Defender health`, `firewall`, `Defender signatures`, `SMBv1`

**Network (3)** — `Internet/DNS`, `hosts hijack`, `proxy/PAC hijack`

**Update (3)** — `pending reboot`, `WU components`, `BITS queue`

**Other** — `Integrity (DISM)`, `Devices (driver errors)`, `Services (critical stopped)`, `winget updates`

`Safe`/`Moderate` чинятся сразу, `Aggressive`/`Heavy` — только с `IncludeHeavy`.

</details>

### 🗂️ Структура

```
sunCleaner.ps1          — entry, honest loader
sunCleaner-standalone.ps1 — single file for pastebin raw (irm | iex) с прогрессом по модулям
src/
  Core/
    Common.ps1          — палитра, логи, restore, отчёты
    UI.ps1              — TUI, viewport, солнце
  Engines/
    Clean.ps1           — 69 задач
    Optimize.ps1        — 61 твик
    Repair.ps1          — 28 проверок
  Features/
    Schedule.ps1        — \sunCleaner\ weekly/monthly
    Network.ps1         — dns/reset/adapters/static/dhcp
    Startup.ps1         — StartupApproved менеджер
  Menu/
    Main.ps1            — баннер, сплэш, меню, Manage
```

### 🛡️ Немного про безопасность

* `Test-SafeToDelete` блокирует `C:\`, `C:\Windows`, `System32`, `C:\Users`, мелкий путь
* `Checkpoint-Computer` точка восстановления (снимает 24ч троттл)
* Каждый твик бэкапит значение → `Undo`
* Начни с `Preview` (`WhatIf`) — честный подсчёт, не оценка

---

<p align="center">MIT © 2026 <b>lordofsunshine/sunCleaner</b> — keep it sunny ☀️</p>
