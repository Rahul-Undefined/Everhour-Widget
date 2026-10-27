<#
    EverhourWidget.ps1  -  v5
    =========================
    A customisable desktop widget showing your live Everhour timer.

    RUNS INVISIBLY
      No console window, no taskbar button. Starts itself when Windows
      starts. To quit: right-click the widget -> Exit.

    CONTROLS
      Round button      start / stop (resumes your last task)
      Click             expand / collapse (collapses itself when you move away)
      Drag              move it (position is remembered, any monitor)
      Right-click       menu: start, resume, stop, refresh, settings, exit
      Ctrl+Alt+E        start / stop from anywhere (change in Settings)

    FILES
      Config:  %APPDATA%\EverhourWidget\config.json   (API key encrypted)
      Log:     %APPDATA%\EverhourWidget\error.log
#>

param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$NoAutoInstall,
    [switch]$ShowConsole,
    [switch]$Diagnose,
    [switch]$TestAutostart,
    [switch]$StopOthers,
    [switch]$Setup,            # copy this folder to %LOCALAPPDATA% and start it from there
    [switch]$BuildShare,       # make the "Share" folder + zip for other laptops
    [string]$RenderPreview     # folder: draws sample widget images there and exits
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security

$Script:Version = "5.0"

$ConfigDir    = Join-Path $env:APPDATA "EverhourWidget"
$ConfigPath   = Join-Path $ConfigDir "config.json"
$LogPath      = Join-Path $ConfigDir "error.log"
$ScriptPath   = $MyInvocation.MyCommand.Path
$ScriptDir    = Split-Path $ScriptPath
$StartupDir   = [Environment]::GetFolderPath("Startup")
$ShortcutPath = Join-Path $StartupDir "EverhourWidget.lnk"
$InstallDir   = Join-Path $env:LOCALAPPDATA "Programs\EverhourWidget"
$ApiBase      = "https://api.everhour.com"

function Write-Log([string]$msg) {
    try {
        if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
        if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 512KB) {
            Move-Item $LogPath "$LogPath.old" -Force -ErrorAction SilentlyContinue
        }
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg" | Add-Content -Path $LogPath -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------------------
# Win32 helpers: hide our console, per-pixel-alpha (layered) window, DPI,
# Windows 11 rounded corners, private fonts, a global hotkey, a dark menu.
# ---------------------------------------------------------------------------
$Script:NativeSrc = @"
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class EhWin {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll", SetLastError=true)] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", SetLastError=true)] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")]   public static extern bool SetProcessDPIAware();
    [DllImport("dwmapi.dll")]   public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, string l);
    [DllImport("gdi32.dll", CharSet=CharSet.Unicode)] public static extern int AddFontResourceEx(string file, uint fl, IntPtr res);
    [DllImport("user32.dll")]   public static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint affinity);

    [StructLayout(LayoutKind.Sequential)] struct PT { public int x, y; }
    [StructLayout(LayoutKind.Sequential)] struct SZ { public int cx, cy; }
    [StructLayout(LayoutKind.Sequential, Pack=1)] struct BLEND { public byte Op, Flags, Alpha, Format; }
    [DllImport("user32.dll", SetLastError=true)]
    static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref PT pptDst, ref SZ psize,
        IntPtr hdcSrc, ref PT pptSrc, int crKey, ref BLEND pblend, int dwFlags);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")]  static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")]  static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")]  static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [DllImport("gdi32.dll")]  static extern bool DeleteObject(IntPtr o);

    // Puts a 32-bit ARGB bitmap on screen as the whole window: real
    // anti-aliased corners, soft shadow, see-through background, crisp text.
    public static bool PushLayered(IntPtr hwnd, Bitmap bmp, int x, int y) {
        IntPtr screen = GetDC(IntPtr.Zero);
        IntPtr mem = CreateCompatibleDC(screen);
        IntPtr hb = IntPtr.Zero, old = IntPtr.Zero;
        try {
            hb = bmp.GetHbitmap(Color.FromArgb(0));
            old = SelectObject(mem, hb);
            SZ size; size.cx = bmp.Width; size.cy = bmp.Height;
            PT src; src.x = 0; src.y = 0;
            PT dst; dst.x = x; dst.y = y;
            BLEND b; b.Op = 0; b.Flags = 0; b.Alpha = 255; b.Format = 1;
            return UpdateLayeredWindow(hwnd, screen, ref dst, ref size, mem, ref src, 0, ref b, 2);
        } finally {
            ReleaseDC(IntPtr.Zero, screen);
            if (hb != IntPtr.Zero) { SelectObject(mem, old); DeleteObject(hb); }
            DeleteDC(mem);
        }
    }
}

public class EhHotkey : NativeWindow, IDisposable {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    bool registered;
    public event EventHandler Pressed;
    public EhHotkey() { CreateHandle(new CreateParams()); }
    public bool Register(uint mod, uint vk) {
        Unregister();
        registered = RegisterHotKey(Handle, 1, mod | 0x4000, vk);
        return registered;
    }
    public void Unregister() { if (registered) { UnregisterHotKey(Handle, 1); registered = false; } }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312 && Pressed != null) { Pressed(this, EventArgs.Empty); }
        base.WndProc(ref m);
    }
    public void Dispose() { Unregister(); DestroyHandle(); }
}

public class EhMenuColors : ProfessionalColorTable {
    public static Color Bg = Color.FromArgb(34, 34, 40), Hover = Color.FromArgb(50, 50, 60), Line = Color.FromArgb(54, 54, 62);
    public override Color MenuItemSelected { get { return Hover; } }
    public override Color MenuItemSelectedGradientBegin { get { return Hover; } }
    public override Color MenuItemSelectedGradientEnd { get { return Hover; } }
    public override Color MenuItemBorder { get { return Hover; } }
    public override Color MenuBorder { get { return Line; } }
    public override Color ToolStripDropDownBackground { get { return Bg; } }
    public override Color ImageMarginGradientBegin { get { return Bg; } }
    public override Color ImageMarginGradientMiddle { get { return Bg; } }
    public override Color ImageMarginGradientEnd { get { return Bg; } }
    public override Color SeparatorDark { get { return Line; } }
    public override Color SeparatorLight { get { return Bg; } }
}
public class EhMenuRenderer : ToolStripProfessionalRenderer {
    public EhMenuRenderer() : base(new EhMenuColors()) { RoundedEdges = false; }
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
        e.TextColor = e.Item.Enabled ? Color.FromArgb(232, 232, 237) : Color.FromArgb(110, 110, 120);
        base.OnRenderItemText(e);
    }
}
"@

# Compiling C# starts csc.exe, which can flash console windows at login.
# Compile once into %APPDATA% and load the DLL on every later start.
function Import-Native {
    try {
        if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
        $sha = [Security.Cryptography.SHA1]::Create()
        $bytes = [Text.Encoding]::UTF8.GetBytes($Script:NativeSrc + $PSVersionTable.CLRVersion)
        $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace "-", "").Substring(0, 12)
        $dll = Join-Path $ConfigDir "EhNative-$hash.dll"
        if (-not (Test-Path $dll)) {
            Add-Type -TypeDefinition $Script:NativeSrc -ReferencedAssemblies System.Windows.Forms, System.Drawing `
                -OutputAssembly $dll -OutputType Library -ErrorAction Stop
            Get-ChildItem $ConfigDir -Filter "EhNative-*.dll" | Where-Object { $_.FullName -ne $dll } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
        if (-not ("EhWin" -as [type])) { Add-Type -Path $dll -ErrorAction Stop }
        return $true
    } catch {
        Write-Log "Cached helpers unavailable ($($_.Exception.Message)); compiling in memory"
        try {
            if (-not ("EhWin" -as [type])) {
                Add-Type -TypeDefinition $Script:NativeSrc -ReferencedAssemblies System.Windows.Forms, System.Drawing -ErrorAction Stop
            }
            return $true
        } catch { return $false }
    }
}
$Script:HasWinApi = Import-Native

$Script:ConsoleMode = ($ShowConsole -or $Diagnose -or $TestAutostart -or $StopOthers -or $BuildShare -or $RenderPreview)
if ($Script:HasWinApi) {
    try { [EhWin]::SetProcessDPIAware() | Out-Null } catch { }
    if (-not $Script:ConsoleMode) {
        try {
            $con = [EhWin]::GetConsoleWindow()
            if ($con -ne [IntPtr]::Zero) { [EhWin]::ShowWindow($con, 0) | Out-Null }  # 0 = SW_HIDE
        } catch { }
    }
}
[System.Windows.Forms.Application]::EnableVisualStyles()

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# Everything is laid out at 96 DPI and scaled, so it stays sharp and
# un-clipped on 125% / 150% displays.
$Script:Scale = 1.0
try {
    $g0 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $Script:Scale = [double]$g0.DpiX / 96.0
    $g0.Dispose()
} catch { }
function Px([double]$n) { return [int][Math]::Round($n * $Script:Scale) }

# ===========================================================================
#  FONTS  (bundled open-source fonts in .\fonts, loaded privately - nothing
#  is installed on the PC)
# ===========================================================================
$Script:FontCatalog = [ordered]@{
    "Inter"             = @{ File = "Inter";           Hint = "iPhone style" }
    "Geist"             = @{ File = "Geist";           Hint = "clean, Vercel" }
    "Space Grotesk"     = @{ File = "SpaceGrotesk";    Hint = "Nothing style" }
    "Doto"              = @{ File = "Doto";            Hint = "Nothing dot-matrix" }
    "Space Mono"        = @{ File = "SpaceMono";       Hint = "retro mono" }
    "Poppins"           = @{ File = "Poppins";         Hint = "friendly, round" }
    "Manrope"           = @{ File = "Manrope";         Hint = "modern" }
    "Outfit"            = @{ File = "Outfit";          Hint = "geometric" }
    "Plus Jakarta Sans" = @{ File = "PlusJakartaSans"; Hint = "startup style" }
    "Sora"              = @{ File = "Sora";            Hint = "wide, techy" }
    "DM Sans"           = @{ File = "DMSans";          Hint = "Google style" }
    "JetBrains Mono"    = @{ File = "JetBrainsMono";   Hint = "coder mono" }
    "Segoe UI Variable" = @{ System = "Segoe UI Variable Display"; Hint = "Windows 11" }
    "Bahnschrift"       = @{ System = "Bahnschrift";   Hint = "DIN, Windows" }
    "Cascadia Code"     = @{ System = "Cascadia Code"; Hint = "Windows mono" }
    "Segoe UI"          = @{ System = "Segoe UI";      Hint = "classic Windows" }
    "Arial"             = @{ System = "Arial";         Hint = "classic" }
}
$Script:Pfc = New-Object System.Drawing.Text.PrivateFontCollection
$Script:FontNames = @{}     # catalog key -> real family name inside the collection
$Script:FamCache = @{}

function Load-Fonts {
    $dir = Join-Path $ScriptDir "fonts"
    if (-not (Test-Path $dir)) { return }
    foreach ($key in $Script:FontCatalog.Keys) {
        $e = $Script:FontCatalog[$key]
        if (-not $e.File) { continue }
        $reg = Join-Path $dir "$($e.File)-Regular.ttf"
        $bold = Join-Path $dir "$($e.File)-Bold.ttf"
        if (-not (Test-Path $reg)) { continue }
        try {
            # static instances of variable fonts carry odd names ("Outfit Thin"),
            # so read the real one from the file
            $tmp = New-Object System.Drawing.Text.PrivateFontCollection
            $tmp.AddFontFile($reg)
            $Script:FontNames[$key] = $tmp.Families[0].Name
            $tmp.Dispose()
            $Script:Pfc.AddFontFile($reg)
            if (Test-Path $bold) { $Script:Pfc.AddFontFile($bold) }
            if ($Script:HasWinApi) {
                # also visible to GDI, so ordinary WinForms controls can use them
                [EhWin]::AddFontResourceEx($reg, 0x10, [IntPtr]::Zero) | Out-Null
                if (Test-Path $bold) { [EhWin]::AddFontResourceEx($bold, 0x10, [IntPtr]::Zero) | Out-Null }
            }
        } catch { Write-Log "Font $key failed to load: $($_.Exception.Message)" }
    }
}

function Get-FontFamilyObj([string]$key) {
    if ($Script:FamCache.ContainsKey($key)) { return $Script:FamCache[$key] }
    $fam = $null
    if ($Script:FontNames.ContainsKey($key)) {
        $fam = $Script:Pfc.Families | Where-Object { $_.Name -eq $Script:FontNames[$key] } | Select-Object -First 1
    }
    if (-not $fam) {
        $sys = $key
        if ($Script:FontCatalog.Contains($key) -and $Script:FontCatalog[$key].System) { $sys = $Script:FontCatalog[$key].System }
        try { $fam = New-Object System.Drawing.FontFamily($sys) } catch { $fam = $null }
    }
    if (-not $fam) { $fam = New-Object System.Drawing.FontFamily("Segoe UI") }
    $Script:FamCache[$key] = $fam
    return $fam
}

function Get-AvailableFonts {
    $installed = @{}
    foreach ($ff in [System.Drawing.FontFamily]::Families) { $installed[$ff.Name] = $true }
    $out = @()
    foreach ($key in $Script:FontCatalog.Keys) {
        $e = $Script:FontCatalog[$key]
        if ($Script:FontNames.ContainsKey($key) -or ($e.System -and $installed.ContainsKey($e.System))) { $out += $key }
    }
    return $out
}

Load-Fonts

# ===========================================================================
#  AUTOSTART  (launched through wscript + a headless console host, so no
#  console window ever appears - not even a flash at login)
# ===========================================================================
$VbsLauncher = Join-Path $ConfigDir "launch.vbs"

function Get-LauncherVbs([string]$psPath, [string]$extraArgs = "") {
    return @"
' Launches the Everhour widget with no console window at all.
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$psPath"" $extraArgs"
' conhost --headless creates no window, even when Windows Terminal is the default terminal
If fso.FileExists(sh.ExpandEnvironmentStrings("%WINDIR%") & "\System32\conhost.exe") Then cmd = "conhost.exe --headless " & cmd
sh.Run cmd, 0, False
"@
}

function Write-VbsLauncher {
    try {
        if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
        (Get-LauncherVbs $ScriptPath) | Set-Content -Path $VbsLauncher -Encoding ASCII
        return $true
    } catch { Write-Log "VBS launcher write failed: $($_.Exception.Message)"; return $false }
}

function Install-Autostart {
    try {
        Write-VbsLauncher | Out-Null
        $wsh = New-Object -ComObject WScript.Shell
        $sc = $wsh.CreateShortcut($ShortcutPath)
        if (Test-Path $VbsLauncher) {
            $sc.TargetPath = "wscript.exe"
            $sc.Arguments  = "`"$VbsLauncher`""
        } else {
            $sc.TargetPath = "powershell.exe"
            $sc.Arguments  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""
        }
        $sc.WorkingDirectory = $ScriptDir
        $sc.Description      = "Everhour timer widget"
        $sc.Save()
        return $true
    } catch {
        Write-Log "Autostart install failed: $($_.Exception.Message)"
        return $false
    }
}

function Remove-Autostart {
    if (Test-Path $ShortcutPath) { Remove-Item $ShortcutPath -Force -ErrorAction SilentlyContinue }
}
function Test-Autostart { return (Test-Path $ShortcutPath) }

# Autostart records an absolute path to this script. If the folder is moved or
# renamed, or an older version installed a powershell.exe shortcut (which leaves
# a taskbar button), the entry goes stale. Rewriting it on every start is cheap
# and makes "move the folder" a non-event.
function Repair-Autostart {
    if (-not (Test-Path $ShortcutPath)) { return }
    try { Install-Autostart | Out-Null } catch { }
}

if ($Install)   { if (Install-Autostart) { Write-Host "Installed." } else { Write-Host "Failed." } ; exit }
if ($Uninstall) { Remove-Autostart; Write-Host "Autostart removed."; exit }

# Find running widgets. Must exclude THIS process: our own command line
# contains "EverhourWidget.ps1", so a naive match counts itself.
function Get-WidgetProcesses {
    try {
        return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
            Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*EverhourWidget.ps1*' -and $_.CommandLine -notlike '*-Setup*' })
    } catch { return @() }
}

# ===========================================================================
#  SHARE FOLDER + SETUP
#  -BuildShare writes .\Share\Everhour Widget (and a zip) to hand to anyone.
#  On their laptop, "Install Everhour Widget.vbs" runs -Setup, which copies
#  the widget to %LOCALAPPDATA%\Programs\EverhourWidget and starts it there,
#  so it keeps working even if the shared folder is deleted.
# ===========================================================================
$Script:AppFiles = @("EverhourWidget.ps1", "Start Everhour Widget.vbs", "Install Everhour Widget.vbs", "Stop Widget.bat",
                     "Test Autostart Now.bat", "Troubleshoot.bat", "READ ME FIRST.txt")

function Copy-AppFiles([string]$from, [string]$to) {
    New-Item -ItemType Directory -Force -Path $to | Out-Null
    foreach ($f in $Script:AppFiles) {
        $src = Join-Path $from $f
        if (Test-Path $src) { Copy-Item $src (Join-Path $to $f) -Force }
    }
    if (Test-Path (Join-Path $from "fonts")) {
        New-Item -ItemType Directory -Force -Path (Join-Path $to "fonts") | Out-Null
        Copy-Item (Join-Path $from "fonts\*") (Join-Path $to "fonts") -Force
    }
}

if ($BuildShare) {
    $shareRoot = Join-Path $ScriptDir "Share"
    $out = Join-Path $shareRoot "Everhour Widget"
    if (Test-Path $out) { Remove-Item $out -Recurse -Force }
    Copy-AppFiles $ScriptDir $out
    @"
EVERHOUR WIDGET - HOW TO INSTALL
================================

1. Copy this whole folder to the laptop (or unzip "Everhour Widget.zip").
2. Double-click:  Install Everhour Widget.vbs
   (If Windows asks "Do you want to open this file?", click Open.)
3. A short guide shows you where to copy your Everhour API token. Paste it,
   pick a look, done.

The widget installs itself for this Windows user only (no admin rights),
starts automatically at every login, and keeps working even if you delete
this folder afterwards.

Need help? Run Troubleshoot.bat inside
    %LOCALAPPDATA%\Programs\EverhourWidget
and send the troubleshoot-log.txt it creates.
"@ | Set-Content (Join-Path $out "HOW TO INSTALL.txt") -Encoding UTF8
    $zip = Join-Path $shareRoot "Everhour Widget.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path $out -DestinationPath $zip
    Write-Host "Share folder ready:"
    Write-Host "  $out"
    Write-Host "  $zip"
    exit
}

if ($Setup) {
    try {
        if ($ScriptDir -ne $InstallDir) {
            foreach ($p in (Get-WidgetProcesses)) { try { Stop-Process -Id $p.ProcessId -Force } catch { } }
            Start-Sleep -Milliseconds 800
            Copy-AppFiles $ScriptDir $InstallDir
            # files copied from a download or zip carry "blocked" marks; clear them
            Get-ChildItem $InstallDir -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
        }
        $target = Join-Path $InstallDir "EverhourWidget.ps1"
        $tmpVbs = Join-Path $env:TEMP "everhour-widget-start.vbs"
        (Get-LauncherVbs $target) | Set-Content -Path $tmpVbs -Encoding ASCII
        Start-Process wscript.exe -ArgumentList "`"$tmpVbs`""
    } catch {
        Write-Log "Setup failed: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Setup could not copy the widget:`r`n$($_.Exception.Message)", "Everhour Widget") | Out-Null
    }
    exit
}

# ===========================================================================
#  CONFIG
# ===========================================================================
$Script:Defaults = [ordered]@{
    ConfigVersion       = 5
    ApiKey              = ""      # legacy plain-text key; migrated to ApiKeyProtected
    ApiKeyProtected     = ""
    OnboardingDone      = $false
    RefreshSeconds      = 20
    Opacity             = 92      # background only - text always stays solid
    BackColor           = "#1C1C21"
    AccentColor         = "#4ADE80"
    IdleColor           = "#6B6B76"
    ErrorColor          = "#F87171"
    TaskColor           = "#C9C9D1"
    TimeColor           = "#FFFFFF"
    FontFamily          = "Inter"
    TimerFontFamily     = ""      # "" = same as FontFamily
    TimeFontSize        = 18
    TaskFontSize        = 9
    Shape               = "Wide"  # Wide or Square
    Width               = 300
    SquareSize          = 180
    CornerRadius        = 14
    Animations          = $true
    EdgeLights          = $true
    RedWhenStopped      = $true
    BreakKeywords       = "break, lunch"
    BreakLimitMinutes   = 60
    AlwaysOnTop         = $false
    HideFromCapture     = $true   # invisible in screen shares / screenshots
    ShowTodayTotal      = $true
    ShowSeconds         = $true
    ShowWeekTotal       = $true
    DailyTargetHours    = 8
    AutoCollapseSeconds = 15
    ConfirmSwitch       = $true
    HotkeyEnabled       = $true
    Hotkey              = "Ctrl+Alt+E"
    PosX                = $null
    PosY                = $null
    IdleNudge           = $false
    IdleNudgeMinutes    = 15
    WorkStart           = "09:30"
    WorkEnd             = "18:30"
    WorkDays            = "Mon,Tue,Wed,Thu,Fri"
    LastTaskId          = ""
    LastTaskName        = ""
    LastStopAt          = ""
}

$Script:Themes = [ordered]@{
    "Graphite" = @{ BackColor = "#1C1C21"; TaskColor = "#C9C9D1"; TimeColor = "#FFFFFF"; AccentColor = "#4ADE80"; IdleColor = "#6B6B76"; ErrorColor = "#F87171" }
    "Ocean"    = @{ BackColor = "#141A22"; TaskColor = "#C7D2DE"; TimeColor = "#FFFFFF"; AccentColor = "#38BDF8"; IdleColor = "#5E6B7A"; ErrorColor = "#F87171" }
    "Midnight" = @{ BackColor = "#0F172A"; TaskColor = "#CBD5E1"; TimeColor = "#F8FAFC"; AccentColor = "#A78BFA"; IdleColor = "#64748B"; ErrorColor = "#F87171" }
    "Forest"   = @{ BackColor = "#122019"; TaskColor = "#C7D7CE"; TimeColor = "#F0FFF6"; AccentColor = "#34D399"; IdleColor = "#5F7A6C"; ErrorColor = "#F87171" }
    "Sunset"   = @{ BackColor = "#1F1720"; TaskColor = "#E4D3DA"; TimeColor = "#FFF7F0"; AccentColor = "#FB923C"; IdleColor = "#7D6870"; ErrorColor = "#F87171" }
    "Light"    = @{ BackColor = "#F7F7FA"; TaskColor = "#3F3F46"; TimeColor = "#111114"; AccentColor = "#16A34A"; IdleColor = "#A1A1AA"; ErrorColor = "#DC2626" }
}

function Read-Config {
    $cfg = [ordered]@{}
    foreach ($k in $Script:Defaults.Keys) { $cfg[$k] = $Script:Defaults[$k] }
    $ver = 5
    if (Test-Path $ConfigPath) {
        try {
            $saved = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            foreach ($k in $Script:Defaults.Keys) {
                if ($null -ne $saved.PSObject.Properties[$k]) { $cfg[$k] = $saved.$k }
            }
            $ver = 3
            if ($null -ne $saved.PSObject.Properties["ConfigVersion"]) { $ver = [int]$saved.ConfigVersion }
        } catch { Write-Log "Config read failed: $($_.Exception.Message)" }
    }
    if ($ver -lt 4) {
        # v3 configs: anything still on an old default moves to the new design's
        # default. v3 also silently raised RefreshSeconds after rate limits.
        $old = @{ BackColor = "#1E1E22"; AccentColor = "#5AC882"; IdleColor = "#5A5A60"; ErrorColor = "#D25A5A"
                  TaskColor = "#DCDCE1"; TimeColor = "#FFFFFF"; Width = 260; TimeFontSize = 16; Opacity = 94; CornerRadius = 10 }
        foreach ($k in $old.Keys) { if ([string]$cfg[$k] -eq [string]$old[$k]) { $cfg[$k] = $Script:Defaults[$k] } }
        if ([int]$cfg.RefreshSeconds -gt 20 -and [int]$cfg.RefreshSeconds -le 60) { $cfg.RefreshSeconds = 20 }
    }
    if ($ver -lt 5) {
        # v5: modern bundled fonts replace the old Windows defaults
        if ([string]$cfg.FontFamily -in @("Segoe UI", "Arial", "Segoe UI Semibold", "Calibri", "Tahoma", "Verdana")) { $cfg.FontFamily = "Inter" }
        $cfg.OnboardingDone = $false     # show the new setup guide once
    }
    $cfg.ConfigVersion = 5
    return $cfg
}

function Limit([double]$v, [double]$lo, [double]$hi) { return [Math]::Max($lo, [Math]::Min($hi, $v)) }

function Normalize-Config {
    $c = $Script:Cfg
    try { $c.RefreshSeconds      = [int](Limit $c.RefreshSeconds 10 300) }       catch { $c.RefreshSeconds = 20 }
    try { $c.Opacity             = [int](Limit $c.Opacity 30 100) }              catch { $c.Opacity = 92 }
    try { $c.Width               = [int](Limit $c.Width 240 600) }               catch { $c.Width = 300 }
    try { $c.SquareSize          = [int](Limit $c.SquareSize 150 280) }          catch { $c.SquareSize = 180 }
    try { $c.TimeFontSize        = [int](Limit $c.TimeFontSize 10 40) }          catch { $c.TimeFontSize = 18 }
    try { $c.TaskFontSize        = [int](Limit $c.TaskFontSize 7 18) }           catch { $c.TaskFontSize = 9 }
    try { $c.CornerRadius        = [int](Limit $c.CornerRadius 0 40) }           catch { $c.CornerRadius = 14 }
    try { $c.AutoCollapseSeconds = [int](Limit $c.AutoCollapseSeconds 0 300) }   catch { $c.AutoCollapseSeconds = 15 }
    try { $c.IdleNudgeMinutes    = [int](Limit $c.IdleNudgeMinutes 5 240) }      catch { $c.IdleNudgeMinutes = 15 }
    try { $c.DailyTargetHours    = [double](Limit $c.DailyTargetHours 0 24) }    catch { $c.DailyTargetHours = 8 }
    try { $c.BreakLimitMinutes   = [int](Limit $c.BreakLimitMinutes 0 600) }     catch { $c.BreakLimitMinutes = 60 }
    if ($c.Shape -ne "Square") { $c.Shape = "Wide" }
    if (-not (Parse-HHmm $c.WorkStart)) { $c.WorkStart = "09:30" }
    if (-not (Parse-HHmm $c.WorkEnd))   { $c.WorkEnd   = "18:30" }
    if ($null -eq $c.WorkDays) { $c.WorkDays = "Mon,Tue,Wed,Thu,Fri" }
    if ($null -eq $c.BreakKeywords) { $c.BreakKeywords = "break, lunch" }
}

function Save-Config {
    if ($RenderPreview) { return }    # preview uses sample data; never persist it
    try {
        if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
        # write-then-rename so a crash mid-save can't leave a half-written file
        $tmp = "$ConfigPath.tmp"
        [pscustomobject]$Script:Cfg | ConvertTo-Json -Depth 4 | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $ConfigPath -Force
    } catch { Write-Log "Config save failed: $($_.Exception.Message)" }
}

function Copy-Config {
    $o = [ordered]@{}
    foreach ($k in $Script:Cfg.Keys) { $o[$k] = $Script:Cfg[$k] }
    return $o
}

function Parse-HHmm([string]$s) {
    $m = [regex]::Match([string]$s, '^\s*(\d{1,2})[:.](\d{2})\s*$')
    if (-not $m.Success) { return $null }
    $h = [int]$m.Groups[1].Value; $mi = [int]$m.Groups[2].Value
    if ($h -gt 23 -or $mi -gt 59) { return $null }
    return New-Object TimeSpan($h, $mi, 0)
}

# ---- API key: kept encrypted with Windows DPAPI (only this Windows user on
#      this PC can decrypt it) instead of plain text in config.json ----
$Script:ApiKeyCache = $null
function Protect-Key([string]$plain) {
    $b = [Text.Encoding]::UTF8.GetBytes($plain)
    $e = [Security.Cryptography.ProtectedData]::Protect($b, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($e)
}
function Unprotect-Key([string]$b64) {
    try {
        $e = [Convert]::FromBase64String($b64)
        $b = [Security.Cryptography.ProtectedData]::Unprotect($e, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [Text.Encoding]::UTF8.GetString($b)
    } catch { return "" }
}
function Get-ApiKey {
    if ($Script:ApiKeyCache) { return $Script:ApiKeyCache }
    $k = ""
    if (-not [string]::IsNullOrWhiteSpace($Script:Cfg.ApiKeyProtected)) { $k = Unprotect-Key $Script:Cfg.ApiKeyProtected }
    if (-not $k -and -not [string]::IsNullOrWhiteSpace($Script:Cfg.ApiKey)) { $k = [string]$Script:Cfg.ApiKey }
    $Script:ApiKeyCache = $k
    return $k
}
function Set-ApiKey([string]$key) {
    $key = $key.Trim()
    $Script:ApiKeyCache = $key
    try {
        $Script:Cfg.ApiKeyProtected = Protect-Key $key
        $Script:Cfg.ApiKey = ""
    } catch {
        Write-Log "Key encryption failed, storing plain: $($_.Exception.Message)"
        $Script:Cfg.ApiKey = $key
    }
    Save-Config
}

$Script:Cfg = Read-Config
Normalize-Config
if (-not [string]::IsNullOrWhiteSpace($Script:Cfg.ApiKey)) { Set-ApiKey ([string]$Script:Cfg.ApiKey) }
Save-Config

function ToColor([string]$hex) {
    try { return [System.Drawing.ColorTranslator]::FromHtml($hex) } catch { return [System.Drawing.Color]::Gray }
}
function ToHex($color) { return ("#{0:X2}{1:X2}{2:X2}" -f $color.R, $color.G, $color.B) }
function IsLight($color) {
    return ((0.299 * $color.R) + (0.587 * $color.G) + (0.114 * $color.B)) -gt 150
}

# ===========================================================================
#  DIAGNOSTICS / AUTOSTART TEST
#  These run before the single-instance lock, because the widget may already
#  be running and holding it.
# ===========================================================================
if ($StopOthers) {
    $procs = Get-WidgetProcesses
    if ($procs.Count -eq 0) { Write-Host "No widget was running." }
    foreach ($p in $procs) {
        try { Stop-Process -Id $p.ProcessId -Force; Write-Host "Stopped widget (PID $($p.ProcessId))." } catch { }
    }
    exit
}

if ($Diagnose) {
    Write-Host ""
    Write-Host "==== EVERHOUR WIDGET v$($Script:Version) - DIAGNOSTICS ====" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "[1] Environment" -ForegroundColor Yellow
    Write-Host "    PowerShell   : $($PSVersionTable.PSVersion)"
    Write-Host "    Language mode: $($ExecutionContext.SessionState.LanguageMode)"
    if ($ExecutionContext.SessionState.LanguageMode -ne "FullLanguage") {
        Write-Host "    ** This PC restricts PowerShell. The widget cannot run here. **" -ForegroundColor Red
    }
    Write-Host "    Win32 helpers: $(if ($Script:HasWinApi) { 'OK' } else { 'NOT AVAILABLE (basic look only)' })"
    Write-Host "    Fonts loaded : $($Script:FontNames.Count) bundled"
    Write-Host "    Display scale: $([int]($Script:Scale * 100))%"
    Write-Host "    Script path  : $ScriptPath"
    Write-Host ""

    Write-Host "[2] Will it start when Windows starts?" -ForegroundColor Yellow
    $ok = $true
    if (-not (Test-Path $ShortcutPath)) {
        Write-Host "    NO - no startup entry found." -ForegroundColor Red
        Write-Host "    Fix: start the widget once, or turn it on in Settings."
        $ok = $false
    } else {
        Write-Host "    Startup entry: FOUND"
        try {
            $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($ShortcutPath)
            Write-Host "      runs: $($sc.TargetPath) $($sc.Arguments)"
            if ($sc.TargetPath -notmatch "wscript") {
                Write-Host "    ** Old-style entry - will show a taskbar button. **" -ForegroundColor Yellow
            }
        } catch { Write-Host "    Could not read the shortcut." -ForegroundColor Red; $ok = $false }

        if (-not (Test-Path $VbsLauncher)) {
            Write-Host "    Launcher file: MISSING ($VbsLauncher)" -ForegroundColor Red
            $ok = $false
        } else {
            Write-Host "    Launcher file: FOUND"
            $vbsText = Get-Content $VbsLauncher -Raw
            if ($vbsText -notmatch "headless") { Write-Host "    ** Old launcher - may flash a console at login. Start the widget once to update it. **" -ForegroundColor Yellow }
            $m = [regex]::Match($vbsText, '-File\s+""([^"]+)""')
            if ($m.Success) {
                $target = $m.Groups[1].Value
                Write-Host "      points at: $target"
                if (Test-Path $target) {
                    Write-Host "      that file exists: YES"
                    if ($target -ne $ScriptPath) {
                        Write-Host "    ** Points at a DIFFERENT copy than the one you just ran. **" -ForegroundColor Yellow
                        Write-Host "       Start the widget from the copy you want and this corrects itself."
                    }
                } else {
                    Write-Host "      that file exists: NO - startup is broken" -ForegroundColor Red
                    Write-Host "       Fix: run 'Start Everhour Widget.vbs' once from this folder."
                    $ok = $false
                }
            }
        }
    }
    Write-Host ""
    if ($ok) { Write-Host "    VERDICT: autostart is correctly configured." -ForegroundColor Green }
    else     { Write-Host "    VERDICT: autostart will NOT work - see above." -ForegroundColor Red }
    Write-Host ""

    Write-Host "[3] Running right now?" -ForegroundColor Yellow
    $procs = Get-WidgetProcesses
    if ($procs.Count -eq 0) { Write-Host "    Not running." }
    elseif ($procs.Count -eq 1) { Write-Host "    Running (1 copy, correct)." -ForegroundColor Green }
    else { Write-Host "    Running $($procs.Count) copies - that's a duplicate." -ForegroundColor Yellow }
    Write-Host ""

    Write-Host "[4] Everhour connection" -ForegroundColor Yellow
    $key = Get-ApiKey
    if ([string]::IsNullOrWhiteSpace($key)) {
        Write-Host "    No API key saved yet."
    } else {
        Write-Host "    Key storage: $(if ($Script:Cfg.ApiKeyProtected) { 'encrypted (Windows DPAPI)' } else { 'plain text' })"
        $hdr = @{ "X-Api-Key" = $key }
        try {
            $me = Invoke-RestMethod -Uri "$ApiBase/users/me" -Headers $hdr -TimeoutSec 20
            Write-Host "    Key works. Signed in as: $($me.name)" -ForegroundColor Green

            # Numbers behind "today" - lets us check the widget adds them up the
            # same way Everhour does.
            $t = Invoke-RestMethod -Uri "$ApiBase/timers/current" -Headers $hdr -TimeoutSec 20
            $d = (Get-Date).ToString("yyyy-MM-dd")
            $recs = @(Invoke-RestMethod -Uri "$ApiBase/users/$($me.id)/time?from=$d&to=$d&limit=500" -Headers $hdr -TimeoutSec 20)
            $sum = 0; $forTask = 0
            foreach ($r in $recs) {
                if ($null -eq $r) { continue }
                $sum += [int]$r.time
                if ($t.task -and $r.task -and $r.task.id -eq $t.task.id) { $forTask += [int]$r.time }
            }
            Write-Host "    Timer status : $($t.status)"
            if ($t.status -eq "active") {
                Write-Host "      timer.duration = $($t.duration)s   timer.today = $($t.today)s"
                Write-Host "      saved time on this task today = $($forTask)s"
            }
            Write-Host "    Saved time entries today: $(@($recs | Where-Object { $_ }).Count), total $($sum)s"
        } catch {
            $code = $null
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            if ($code -eq 401 -or $code -eq 403) {
                Write-Host "    Key REJECTED by Everhour (HTTP $code). Re-enter it in Settings." -ForegroundColor Red
            } else {
                Write-Host "    Could not reach Everhour: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
    Write-Host ""

    Write-Host "[5] Recent errors" -ForegroundColor Yellow
    if (Test-Path $LogPath) { Get-Content $LogPath -Tail 15 | ForEach-Object { "    $_" } }
    else { Write-Host "    None logged." }
    Write-Host ""
    exit
}

if ($TestAutostart) {
    Write-Host ""
    Write-Host "==== TESTING THE REAL STARTUP PATH ====" -ForegroundColor Cyan
    Write-Host "This runs the exact command Windows runs at login, so you don't"
    Write-Host "have to reboot to find out whether it works."
    Write-Host ""

    if (-not (Test-Path $ShortcutPath)) {
        Write-Host "FAIL: there is no startup entry to test." -ForegroundColor Red
        Write-Host "Start the widget once first." ; Write-Host ""
        exit
    }
    $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($ShortcutPath)
    $tgt = $sc.TargetPath; $arg = $sc.Arguments
    Write-Host "Windows will run:  $tgt $arg"
    Write-Host ""

    Write-Host "Closing any widget that's already open..."
    foreach ($p in (Get-WidgetProcesses)) { try { Stop-Process -Id $p.ProcessId -Force } catch { } }
    Start-Sleep -Seconds 3

    $before = (Get-WidgetProcesses).Count
    Write-Host "Widgets running now: $before  (should be 0)"
    Write-Host ""
    Write-Host "Launching it the way Windows would..."
    try { Start-Process -FilePath $tgt -ArgumentList $arg }
    catch { Write-Host "FAIL: could not launch - $($_.Exception.Message)" -ForegroundColor Red; Write-Host ""; exit }

    for ($i = 1; $i -le 10; $i++) {
        Start-Sleep -Seconds 1
        if ((Get-WidgetProcesses).Count -gt 0) { break }
    }
    Start-Sleep -Seconds 2
    $after = (Get-WidgetProcesses).Count

    Write-Host ""
    if ($after -gt 0) {
        Write-Host "PASS - the widget started from the startup entry." -ForegroundColor Green
        Write-Host "It will do exactly this when you power on. The widget should"
        Write-Host "be visible on your desktop now."
    } else {
        Write-Host "FAIL - nothing started." -ForegroundColor Red
        Write-Host "Run Troubleshoot.bat and send the output."
    }
    Write-Host ""
    exit
}

# Only one widget at a time.
$Script:Mutex = New-Object System.Threading.Mutex($false, "Local\EverhourWidgetSingleInstance")
if (-not $RenderPreview) {
    try { if (-not $Script:Mutex.WaitOne(0, $false)) { exit } }
    catch [System.Threading.AbandonedMutexException] { } catch { }
}

# ===========================================================================
#  BACKGROUND API ENGINE
#  Every Everhour call runs on a background runspace, so a slow network can
#  never freeze the widget. A UI timer collects finished calls and hands the
#  results to a callback on the UI thread.
# ===========================================================================
$Script:Pool = [runspacefactory]::CreateRunspacePool(1, 4)
$Script:Pool.Open()
$Script:Jobs = New-Object System.Collections.ArrayList

$Script:ApiWorker = {
    param($Base, $Key, $Requests)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    foreach ($rq in $Requests) {
        $res = [pscustomobject]@{ Name = $rq.Name; Ok = $false; Code = 0; Data = $null; Error = "" }
        try {
            $p = @{ Uri = $Base + $rq.Path; Headers = @{ "X-Api-Key" = $Key }; Method = $rq.Method; TimeoutSec = 20; UseBasicParsing = $true }
            if ($rq.Body) {
                $p.Body = [Text.Encoding]::UTF8.GetBytes($rq.Body)
                $p.ContentType = "application/json; charset=utf-8"
            }
            $res.Data = Invoke-RestMethod @p
            $res.Ok = $true; $res.Code = 200
        } catch {
            if ($_.Exception.Response) { try { $res.Code = [int]$_.Exception.Response.StatusCode } catch { } }
            $res.Error = $_.Exception.Message
        }
        $res
    }
}.ToString()

function Invoke-Api {
    param([object[]]$Requests, [scriptblock]$OnDone, [string]$Key)
    if (-not $Key) { $Key = Get-ApiKey }
    $reqs = @(foreach ($r in $Requests) {
        $method = "Get"; if ($r.Method) { $method = $r.Method }
        $body = $null; if ($null -ne $r.Body) { $body = $r.Body | ConvertTo-Json -Depth 5 -Compress }
        @{ Name = $r.Name; Path = $r.Path; Method = $method; Body = $body }
    })
    $ps = [powershell]::Create()
    $ps.RunspacePool = $Script:Pool
    [void]$ps.AddScript($Script:ApiWorker).AddArgument($ApiBase).AddArgument($Key).AddArgument($reqs)
    $handle = $ps.BeginInvoke()
    [void]$Script:Jobs.Add([pscustomobject]@{ PS = $ps; Handle = $handle; OnDone = $OnDone })
}

$Script:BackoffUntil = [DateTime]::MinValue
$Script:SlowUntil    = [DateTime]::MinValue

function Note-ApiResult($r) {
    if ($r.Ok) { return }
    if ($r.Code -eq 429) {
        # Back off in memory only. v3 wrote a slower refresh into the config
        # and never undid it.
        $Script:BackoffUntil = (Get-Date).AddSeconds(60)
        $Script:SlowUntil    = (Get-Date).AddMinutes(10)
        Write-Log "Rate limited (429) on $($r.Name); slowing down for 10 minutes"
    } elseif ($r.Code -ne 401 -and $r.Code -ne 403) {
        Write-Log "API $($r.Name) failed ($($r.Code)): $($r.Error)"
    }
}

function Pump-Jobs {
    for ($i = $Script:Jobs.Count - 1; $i -ge 0; $i--) {
        $j = $Script:Jobs[$i]
        if (-not $j.Handle.IsCompleted) { continue }
        $Script:Jobs.RemoveAt($i)
        $results = @()
        try { $results = @($j.PS.EndInvoke($j.Handle)) } catch { Write-Log "Worker failed: $($_.Exception.Message)" }
        try { $j.PS.Dispose() } catch { }
        $map = @{}
        foreach ($r in $results) { if ($r) { $map[[string]$r.Name] = $r; Note-ApiResult $r } }
        if ($j.OnDone) {
            try { & $j.OnDone $map } catch { Write-Log "Callback failed: $($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)" }
        }
    }
}

# Runs inside every message loop, including open dialogs.
$Script:JobTimer = New-Object System.Windows.Forms.Timer
$Script:JobTimer.Interval = 120
$Script:JobTimer.Add_Tick({ Pump-Jobs })
$Script:JobTimer.Start()

# ===========================================================================
#  STATE
# ===========================================================================
$Script:UserId        = $null
$Script:UserName      = ""
$Script:IsRunning     = $false
$Script:TaskId        = ""
$Script:TaskName      = ""
$Script:BaseDuration  = 0
$Script:TimerToday    = 0
$Script:LastPollAt    = Get-Date
$Script:LastPollReq   = [DateTime]::MinValue
$Script:LastRunAt     = Get-Date
$Script:NudgedAt      = [DateTime]::MinValue
$Script:LastError     = ""          # "", AUTH, RATE, OFFLINE
$Script:FirstPollDone = $false
$Script:PollBusy      = $false
$Script:PollAgain     = $false
$Script:ActionBusy    = $false
$Script:RecBusy       = $false
$Script:RecordsAt     = [DateTime]::MinValue
$Script:RecordsDate   = ""
$Script:RecordsLoaded = $false
$Script:TodayByTask   = @{}
$Script:TodayRecordsTotal = 0
$Script:WeekRecordsTotal  = 0
$Script:WeekLoaded    = $false
$Script:WeekAt        = [DateTime]::MinValue
$Script:WeekDate      = ""
$Script:Toast         = ""
$Script:ToastUntil    = [DateTime]::MinValue
$Script:ToastIsError  = $false
$Script:Clock         = [Diagnostics.Stopwatch]::StartNew()

# When did the timer stop? Remembered across restarts so "off for 0:42" is right.
$Script:StoppedSince = Get-Date
try {
    if ($Script:Cfg.LastStopAt) {
        $ls = [DateTime]::Parse([string]$Script:Cfg.LastStopAt, [Globalization.CultureInfo]::InvariantCulture)
        if (((Get-Date) - $ls).TotalHours -lt 20) { $Script:StoppedSince = $ls }
    }
} catch { }

function Set-Toast([string]$text, [int]$seconds = 3, [switch]$IsError) {
    $Script:Toast = $text
    $Script:ToastUntil = (Get-Date).AddSeconds($seconds)
    $Script:ToastIsError = [bool]$IsError
    Render
}

# ===========================================================================
#  FORMATTING
# ===========================================================================
function Format-HMS([double]$sec) {
    if ($sec -lt 0) { $sec = 0 }
    $ts = [TimeSpan]::FromSeconds([int]$sec)
    $h = [int][Math]::Floor($ts.TotalHours)   # v3 used [int], which rounds 0:40 up to 1:40
    if ($Script:Cfg.ShowSeconds) { return "{0:D2}:{1:D2}:{2:D2}" -f $h, $ts.Minutes, $ts.Seconds }
    return "{0:D2}:{1:D2}" -f $h, $ts.Minutes
}
function Format-Short([double]$sec) {
    if ($sec -lt 0) { $sec = 0 }
    $ts = [TimeSpan]::FromSeconds([int]$sec)
    $h = [int][Math]::Floor($ts.TotalHours)
    if ($h -gt 0) { return "{0}h {1:D2}m" -f $h, $ts.Minutes }
    return "{0}m" -f $ts.Minutes
}
function Format-Target([double]$hours) {
    return ("{0:0.#}h" -f $hours)
}
function Format-Day([string]$isoDate) {
    try {
        $d = [DateTime]::ParseExact($isoDate, "yyyy-MM-dd", $null)
        $diff = ((Get-Date).Date - $d.Date).Days
        if ($diff -eq 0) { return "Today" }
        if ($diff -eq 1) { return "Yesterday" }
        if ($diff -lt 7) { return $d.ToString("dddd") }
        return $d.ToString("ddd d MMM")
    } catch { return "" }
}

# ===========================================================================
#  TIME MATHS
#  Saved time entries don't move while a timer runs, so the running task's
#  share comes from the timer (timer.today, which counts the current run).
#  Taking the larger of the two keeps it right either way.
# ===========================================================================
function Get-LiveElapsed {
    if (-not $Script:IsRunning) { return 0 }
    return $Script:BaseDuration + ((Get-Date) - $Script:LastPollAt).TotalSeconds
}
function Get-LiveTaskToday {
    if (-not $Script:IsRunning) { return 0 }
    $live = $Script:TimerToday + ((Get-Date) - $Script:LastPollAt).TotalSeconds
    return [Math]::Max($live, (Get-LiveElapsed))
}
function Get-RecordedForTask([string]$id) {
    if ($id -and $Script:TodayByTask.ContainsKey($id)) { return [double]$Script:TodayByTask[$id].Sec }
    return 0
}
function Get-TodayTotal {
    $rec = [double]$Script:TodayRecordsTotal
    if (-not $Script:IsRunning) { return $rec }
    $recTask = Get-RecordedForTask $Script:TaskId
    return ($rec - $recTask) + [Math]::Max($recTask, (Get-LiveTaskToday))
}
function Get-WeekTotal {
    if (-not $Script:WeekLoaded) { return -1 }
    $w = [double]$Script:WeekRecordsTotal
    if ($Script:IsRunning) {
        $recTask = Get-RecordedForTask $Script:TaskId
        $w = $w - $recTask + [Math]::Max($recTask, (Get-LiveTaskToday))
    }
    return $w
}
function Get-BreakdownRows {
    $rows = @{}
    foreach ($k in $Script:TodayByTask.Keys) {
        $v = $Script:TodayByTask[$k]
        $rows[$k] = [pscustomobject]@{ Name = $v.Name; Sec = [double]$v.Sec; Running = $false }
    }
    if ($Script:IsRunning) {
        $live = Get-LiveTaskToday
        if ($rows.ContainsKey($Script:TaskId)) {
            $rows[$Script:TaskId].Sec = [Math]::Max($rows[$Script:TaskId].Sec, $live)
            $rows[$Script:TaskId].Running = $true
        } else {
            $rows[$Script:TaskId] = [pscustomobject]@{ Name = $Script:TaskName; Sec = $live; Running = $true }
        }
    }
    return @($rows.Values | Where-Object { $_.Sec -gt 0 } | Sort-Object -Property Sec -Descending)
}
function Get-WeekStart {
    $d = (Get-Date).Date
    $off = (([int]$d.DayOfWeek) + 6) % 7    # Monday-based week
    return $d.AddDays(-$off)
}

# ---- breaks: any task whose name contains one of the break words ----
function Test-IsBreak([string]$name) {
    if ([string]::IsNullOrWhiteSpace($name)) { return $false }
    foreach ($w in (([string]$Script:Cfg.BreakKeywords) -split ",")) {
        $w = $w.Trim()
        if ($w -and $name.IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}
function Get-BreakTotal {
    $sum = 0.0
    foreach ($r in (Get-BreakdownRows)) { if (Test-IsBreak $r.Name) { $sum += $r.Sec } }
    return $sum
}

# When a timer stops, count its run into today's entries straight away, so
# the total doesn't dip until the next refresh.
function Fold-RunningIntoRecords {
    if (-not $Script:RecordsLoaded -or -not $Script:TaskId) { return }
    $live = Get-LiveTaskToday
    if (-not $Script:TodayByTask.ContainsKey($Script:TaskId)) {
        $Script:TodayByTask[$Script:TaskId] = @{ Name = $Script:TaskName; Sec = 0 }
    }
    $e = $Script:TodayByTask[$Script:TaskId]
    $diff = [Math]::Max(0, $live - $e.Sec)
    $e.Sec += $diff
    $Script:TodayRecordsTotal += $diff
    if ($Script:WeekLoaded) { $Script:WeekRecordsTotal += $diff }
}

# ===========================================================================
#  POLLING
# ===========================================================================
function Apply-TimerData($d) {
    $wasRunning = $Script:IsRunning
    $wasTask = $Script:TaskId
    if ($d -and $d.status -eq "active" -and $d.task) {
        $Script:IsRunning    = $true
        $Script:TaskId       = [string]$d.task.id
        $Script:TaskName     = [string]$d.task.name
        $Script:BaseDuration = 0; try { $Script:BaseDuration = [int]$d.duration } catch { }
        $Script:TimerToday   = 0; try { $Script:TimerToday = [int]$d.today } catch { }
        $Script:LastPollAt   = Get-Date
        $Script:LastRunAt    = Get-Date
        if ($Script:Cfg.LastTaskId -ne $Script:TaskId -or $Script:Cfg.LastTaskName -ne $Script:TaskName) {
            $Script:Cfg.LastTaskId = $Script:TaskId
            $Script:Cfg.LastTaskName = $Script:TaskName
            Save-Config
        }
    } else {
        if ($wasRunning) {
            Fold-RunningIntoRecords
            $Script:LastRunAt = Get-Date
            $Script:StoppedSince = Get-Date
            $Script:Cfg.LastStopAt = (Get-Date).ToString("o")
            Save-Config
        }
        $Script:IsRunning = $false
        $Script:TaskId = ""
        $Script:TaskName = ""
    }
    if ($wasRunning -ne $Script:IsRunning -or $wasTask -ne $Script:TaskId) {
        $Script:RecordsAt = [DateTime]::MinValue    # refetch today's entries soon
    }
}

function Request-Poll([switch]$Force) {
    if ($Script:PollBusy) { if ($Force) { $Script:PollAgain = $true }; return }
    if (-not $Force -and (Get-Date) -lt $Script:BackoffUntil) { return }
    if ([string]::IsNullOrWhiteSpace((Get-ApiKey))) { return }
    $Script:PollBusy = $true
    $Script:LastPollReq = Get-Date
    $reqs = @()
    if (-not $Script:UserId) { $reqs += @{ Name = "me"; Path = "/users/me" } }
    $reqs += @{ Name = "timer"; Path = "/timers/current" }
    Invoke-Api -Requests $reqs -OnDone { param($m) On-Poll $m }
}

function On-Poll($m) {
    $Script:PollBusy = $false
    $me = $m["me"]
    if ($me -and $me.Ok -and $me.Data -and $me.Data.id) {
        $Script:UserId = $me.Data.id
        $Script:UserName = [string]$me.Data.name
    }
    $t = $m["timer"]
    if ($t) {
        if ($t.Ok) {
            $Script:LastError = ""
            Apply-TimerData $t.Data
            $Script:FirstPollDone = $true
        } else {
            $err = "OFFLINE"
            if ($t.Code -eq 401 -or $t.Code -eq 403) { $err = "AUTH" }
            elseif ($t.Code -eq 429) { $err = "RATE" }
            if ($err -eq "AUTH" -and $Script:LastError -ne "AUTH") {
                Show-Balloon "Everhour key rejected" "Your API key no longer works. Click here to enter a new one." "key"
            }
            $Script:LastError = $err
        }
    }
    if ($Script:PollAgain) { $Script:PollAgain = $false; Request-Poll -Force }
    Check-IdleNudge
    Render
}

function Request-Records([switch]$WithWeek) {
    if (-not $Script:UserId -or $Script:RecBusy) { return }
    if ((Get-Date) -lt $Script:BackoffUntil) { return }
    $Script:RecBusy = $true
    $today = (Get-Date).ToString("yyyy-MM-dd")
    $Script:RecReqDate = $today
    $reqs = @(@{ Name = "today"; Path = "/users/$($Script:UserId)/time?from=$today&to=$today&limit=500" })
    if ($WithWeek -and $Script:Cfg.ShowWeekTotal) {
        $mon = (Get-WeekStart).ToString("yyyy-MM-dd")
        $reqs += @{ Name = "week"; Path = "/users/$($Script:UserId)/time?from=$mon&to=$today&limit=500" }
    }
    Invoke-Api -Requests $reqs -OnDone { param($m) On-Records $m }
}

function Sum-Records($data) {
    $by = @{}; $sum = 0
    foreach ($r in @($data)) {
        if ($null -eq $r) { continue }
        $sec = 0; try { $sec = [int]$r.time } catch { }
        $id = "none"; $name = "(no task)"
        if ($r.task -and $r.task.id) { $id = [string]$r.task.id; $name = [string]$r.task.name }
        if (-not $by.ContainsKey($id)) { $by[$id] = @{ Name = $name; Sec = 0 } }
        $by[$id].Sec += $sec
        $sum += $sec
    }
    return @{ By = $by; Sum = $sum }
}

function On-Records($m) {
    $Script:RecBusy = $false
    $Script:RecordsAt = Get-Date      # also on failure, so offline doesn't hammer the API
    $t = $m["today"]
    if ($t -and $t.Ok) {
        $s = Sum-Records $t.Data
        $Script:TodayByTask = $s.By
        $Script:TodayRecordsTotal = $s.Sum
        $Script:RecordsDate = $Script:RecReqDate
        $Script:RecordsLoaded = $true
    }
    $w = $m["week"]
    if ($w) {
        $Script:WeekAt = Get-Date
        if ($w.Ok) {
            $Script:WeekRecordsTotal = (Sum-Records $w.Data).Sum
            $Script:WeekLoaded = $true
            $Script:WeekDate = $Script:RecReqDate
        }
    }
    Render
}

# ===========================================================================
#  TIMER ACTIONS
# ===========================================================================
function Start-Timer([string]$TaskId, [string]$TaskName, [string]$Comment) {
    if ($Script:ActionBusy -or -not $TaskId) { return }
    $Script:ActionBusy = $true
    $body = @{ task = $TaskId; userDate = (Get-Date).ToString("yyyy-MM-dd") }
    if (-not [string]::IsNullOrWhiteSpace($Comment)) { $body.comment = $Comment.Trim() }
    Set-Toast "Starting..." 20
    Invoke-Api -Requests @(@{ Name = "start"; Path = "/timers"; Method = "Post"; Body = $body }) -OnDone {
        param($m)
        $Script:ActionBusy = $false
        $r = $m["start"]
        if ($r -and $r.Ok) {
            if ($r.Data -and $r.Data.status -eq "active") { Apply-TimerData $r.Data }
            $Script:LastError = ""
            Set-Toast "Started" 2
        } elseif ($r -and ($r.Code -eq 401 -or $r.Code -eq 403)) {
            Set-Toast "Key rejected" 5 -IsError
        } else {
            Set-Toast "Couldn't start the timer" 5 -IsError
        }
        Request-Poll -Force
    }
}

function Stop-Timer {
    if ($Script:ActionBusy) { return }
    $Script:ActionBusy = $true
    Set-Toast "Stopping..." 20
    Invoke-Api -Requests @(@{ Name = "stop"; Path = "/timers/current"; Method = "Delete" }) -OnDone {
        param($m)
        $Script:ActionBusy = $false
        $r = $m["stop"]
        if ($r -and $r.Ok) {
            Apply-TimerData $null
            Set-Toast "Timer stopped" 2
        } else {
            Set-Toast "Couldn't stop the timer" 5 -IsError
        }
        Request-Poll -Force
    }
}

function Resume-LastTask {
    if ($Script:Cfg.LastTaskId) { Start-Timer $Script:Cfg.LastTaskId $Script:Cfg.LastTaskName "" }
    else { Show-TaskPicker }
}

function Toggle-Timer {
    if ($Script:LastError -eq "AUTH") { Change-ApiKey | Out-Null; return }
    if ($Script:IsRunning) { Stop-Timer } else { Resume-LastTask }
}

# ===========================================================================
#  UI TOOLKIT (dialogs)
# ===========================================================================
$UI = @{
    Bg      = [System.Drawing.ColorTranslator]::FromHtml("#17171B")
    Card    = [System.Drawing.ColorTranslator]::FromHtml("#222228")
    Sel     = [System.Drawing.ColorTranslator]::FromHtml("#2C2C35")
    Line    = [System.Drawing.ColorTranslator]::FromHtml("#33333B")
    Text    = [System.Drawing.ColorTranslator]::FromHtml("#E8E8ED")
    Muted   = [System.Drawing.ColorTranslator]::FromHtml("#8B8B96")
    Accent  = [System.Drawing.ColorTranslator]::FromHtml("#3B82F6")
    AccentH = [System.Drawing.ColorTranslator]::FromHtml("#5B96F8")
    Good    = [System.Drawing.ColorTranslator]::FromHtml("#4ADE80")
    Danger  = [System.Drawing.ColorTranslator]::FromHtml("#F87171")
}

# Dialog fonts: Inter when bundled (private font, registered for GDI too),
# otherwise Segoe UI.
function New-UiFont([double]$pt, [switch]$Bold) {
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    if ($Script:HasWinApi -and $Script:FontNames.ContainsKey("Inter")) {
        try { return New-Object System.Drawing.Font((Get-FontFamilyObj "Inter"), [single]$pt, $style, [System.Drawing.GraphicsUnit]::Point) } catch { }
    }
    $fam = if ($Bold) { "Segoe UI Semibold" } else { "Segoe UI" }
    return New-Object System.Drawing.Font($fam, [single]$pt)
}
$FontUI     = New-UiFont 9.25
$FontUIBold = New-UiFont 9.25 -Bold
$FontTitle  = New-UiFont 12.5 -Bold
$FontHero   = New-UiFont 15 -Bold
$FontSmall  = New-UiFont 8.25
$FontCaps   = New-UiFont 7.5 -Bold

$Script:DwmRounded = $false
function Set-DwmLook($f) {
    if (-not $Script:HasWinApi) { return }
    try {
        $pref = 2   # DWMWCP_ROUND
        if ([EhWin]::DwmSetWindowAttribute($f.Handle, 33, [ref]$pref, 4) -eq 0) {
            $Script:DwmRounded = $true
            $col = ([int]$UI.Line.B -shl 16) -bor ([int]$UI.Line.G -shl 8) -bor [int]$UI.Line.R
            [EhWin]::DwmSetWindowAttribute($f.Handle, 34, [ref]$col, 4) | Out-Null
        }
    } catch { }
}

# Screen sharing (Teams, Zoom, Meet...) and screenshots skip windows marked
# WDA_EXCLUDEFROMCAPTURE; you still see them on your own screen.
function Set-CaptureHidden($f) {
    if (-not $Script:HasWinApi -or -not $f.IsHandleCreated) { return }
    try {
        $aff = if ($Script:Cfg.HideFromCapture) { 0x11 } else { 0 }
        if (-not [EhWin]::SetWindowDisplayAffinity($f.Handle, $aff) -and $aff -ne 0) {
            Write-Log "Hide-from-screen-share not supported on this Windows version"
        }
    } catch { }
}

function Set-DoubleBuffered($ctrl) {
    try {
        $ctrl.GetType().GetProperty("DoubleBuffered", [Reflection.BindingFlags]"NonPublic,Instance").SetValue($ctrl, $true, $null)
    } catch { }
}

function Set-Cue($tb, [string]$text) {
    if (-not $Script:HasWinApi) { return }
    $tb.Tag = $text
    $tb.Add_HandleCreated({ param($s, $e) try { [EhWin]::SendMessage($s.Handle, 0x1501, [IntPtr]1, [string]$s.Tag) | Out-Null } catch { } })
}

function Enable-Drag($ctrl) {
    $ctrl.Add_MouseDown({
        param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $fm = $s.FindForm()
            $Script:DlgDrag = @{ Form = $fm; Start = [System.Windows.Forms.Cursor]::Position; Orig = $fm.Location }
        }
    })
    $ctrl.Add_MouseMove({
        if ($Script:DlgDrag) {
            $n = [System.Windows.Forms.Cursor]::Position; $d = $Script:DlgDrag
            $d.Form.Location = New-Object System.Drawing.Point(($d.Orig.X + $n.X - $d.Start.X), ($d.Orig.Y + $n.Y - $d.Start.Y))
        }
    })
    $ctrl.Add_MouseUp({ $Script:DlgDrag = $null })
}

function New-FlatButton {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 92, [int]$H = 32, [switch]$Primary, [switch]$Ghost)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Font = $FontUI
    $b.Location = New-Object System.Drawing.Point((Px $X), (Px $Y))
    $b.Size = New-Object System.Drawing.Size((Px $W), (Px $H))
    $b.FlatStyle = "Flat"
    $b.Cursor = "Hand"
    $b.UseVisualStyleBackColor = $false
    if ($Primary) {
        $b.BackColor = $UI.Accent; $b.ForeColor = [System.Drawing.Color]::White
        $b.FlatAppearance.BorderSize = 0
        $b.FlatAppearance.MouseOverBackColor = $UI.AccentH
        $b.Font = $FontUIBold
    } elseif ($Ghost) {
        $b.BackColor = $UI.Bg; $b.ForeColor = $UI.Muted
        $b.FlatAppearance.BorderSize = 1
        $b.FlatAppearance.BorderColor = $UI.Line
        $b.FlatAppearance.MouseOverBackColor = $UI.Card
    } else {
        $b.BackColor = $UI.Card; $b.ForeColor = $UI.Text
        $b.FlatAppearance.BorderSize = 1
        $b.FlatAppearance.BorderColor = $UI.Line
        $b.FlatAppearance.MouseOverBackColor = $UI.Sel
    }
    return $b
}

function New-Label([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, $Font = $FontUI, $Color = $null) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Font = $Font
    $l.ForeColor = if ($Color) { $Color } else { $UI.Text }
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.Location = New-Object System.Drawing.Point((Px $X), (Px $Y))
    $l.Size = New-Object System.Drawing.Size((Px $W), (Px $H))
    return $l
}

function New-TextBox([int]$X, [int]$Y, [int]$W, [string]$Text = "", [string]$Cue = "") {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Font = $FontUI; $t.BorderStyle = "FixedSingle"
    $t.BackColor = $UI.Card; $t.ForeColor = $UI.Text
    $t.Location = New-Object System.Drawing.Point((Px $X), (Px $Y))
    $t.Width = Px $W
    $t.Text = $Text
    if ($Cue) { Set-Cue $t $Cue }
    return $t
}

function New-NumBox([double]$min, [double]$max, [double]$val, [int]$x, [int]$y, [int]$decimals = 0, [double]$step = 1) {
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.DecimalPlaces = $decimals; $n.Increment = $step
    $n.Minimum = $min; $n.Maximum = $max; $n.Value = [Math]::Max($min, [Math]::Min($max, $val))
    $n.Font = $FontUI
    $n.BorderStyle = "FixedSingle"
    $n.BackColor = $UI.Card; $n.ForeColor = $UI.Text
    $n.Location = New-Object System.Drawing.Point((Px $x), (Px $y))
    $n.Width = Px 100
    return $n
}

# Dark, owner-drawn drop-down. -FontPreview draws each font name in its own font.
function New-DarkCombo([string[]]$items, [string]$selected, [int]$x, [int]$y, [int]$w, [switch]$FontPreview) {
    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.DropDownStyle = "DropDownList"
    $cb.FlatStyle = "Flat"
    $cb.Font = $FontUI
    $cb.DrawMode = "OwnerDrawFixed"
    $cb.ItemHeight = if ($FontPreview) { Px 26 } else { Px 22 }
    $cb.BackColor = $UI.Card; $cb.ForeColor = $UI.Text
    $cb.Location = New-Object System.Drawing.Point((Px $x), (Px $y))
    $cb.Width = Px $w
    $cb.Tag = [bool]$FontPreview
    foreach ($i in $items) { [void]$cb.Items.Add($i) }
    $cb.SelectedItem = $selected
    if ($cb.SelectedIndex -lt 0 -and $cb.Items.Count -gt 0) { $cb.SelectedIndex = 0 }
    $cb.Add_DrawItem({
        param($s, $e)
        if ($e.Index -lt 0) { return }
        $sel = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
        $bg = if ($sel) { $UI.Sel } else { $UI.Card }
        $br = New-Object System.Drawing.SolidBrush($bg); $e.Graphics.FillRectangle($br, $e.Bounds); $br.Dispose()
        $name = [string]$s.Items[$e.Index]
        $r = New-Object System.Drawing.Rectangle(($e.Bounds.X + (Px 6)), $e.Bounds.Y, ($e.Bounds.Width - (Px 8)), $e.Bounds.Height)
        $flags = [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix
        $font = $FontUI; $own = $false
        if ($s.Tag -and $Script:FontCatalog.Contains($name)) {
            try { $font = New-Object System.Drawing.Font((Get-FontFamilyObj $name), [single]10.5); $own = $true } catch { }
        }
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $name, $font, $r, $UI.Text, $flags)
        if ($s.Tag -and $Script:FontCatalog.Contains($name)) {
            $hint = [string]$Script:FontCatalog[$name].Hint
            [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $hint, $FontSmall, $r, $UI.Muted,
                ([System.Windows.Forms.TextFormatFlags]::Right -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter))
        }
        if ($own) { $font.Dispose() }
    })
    return $cb
}

# Borderless dark dialog with a draggable title bar and a close button.
function New-Dialog([string]$Title, [int]$W, [int]$H) {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title
    $f.FormBorderStyle = "None"
    $f.StartPosition = "Manual"
    $f.BackColor = $UI.Bg
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.KeyPreview = $true
    $wa = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
    $w = Px $W
    $h = [Math]::Min((Px $H), $wa.Height - (Px 40))
    $f.Size = New-Object System.Drawing.Size($w, $h)
    $f.Location = New-Object System.Drawing.Point(($wa.Left + [int](($wa.Width - $w) / 2)), ($wa.Top + [int](($wa.Height - $h) / 2)))

    $bar = New-Object System.Windows.Forms.Panel
    $bar.Location = New-Object System.Drawing.Point(0, 0)
    $bar.Size = New-Object System.Drawing.Size($w, (Px 54))
    $bar.BackColor = $UI.Bg
    $f.Controls.Add($bar)

    $lbl = New-Label $Title 22 15 360 28 $FontTitle
    $bar.Controls.Add($lbl)

    $x = New-Object System.Windows.Forms.Label
    $x.Text = [char]0x2715
    $x.Font = New-Object System.Drawing.Font("Segoe UI", 10.5)
    $x.ForeColor = $UI.Muted
    $x.BackColor = [System.Drawing.Color]::Transparent
    $x.TextAlign = "MiddleCenter"
    $x.Location = New-Object System.Drawing.Point(($w - (Px 48)), (Px 13))
    $x.Size = New-Object System.Drawing.Size((Px 32), (Px 30))
    $x.Cursor = "Hand"
    $x.Add_MouseEnter({ param($s, $e) $s.ForeColor = $UI.Text; $s.BackColor = $UI.Card })
    $x.Add_MouseLeave({ param($s, $e) $s.ForeColor = $UI.Muted; $s.BackColor = [System.Drawing.Color]::Transparent })
    $x.Add_Click({ param($s, $e) $s.FindForm().Close() })
    $bar.Controls.Add($x)

    Enable-Drag $bar
    Enable-Drag $lbl

    $f.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $s.Close() } })
    $f.Add_Shown({ param($s, $e) Set-DwmLook $s; Set-CaptureHidden $s; $s.Activate(); $s.BringToFront() })
    $f.Add_Paint({
        param($s, $e)
        if (-not $Script:DwmRounded) {
            $p = New-Object System.Drawing.Pen($UI.Line)
            $e.Graphics.DrawRectangle($p, 0, 0, $s.Width - 1, $s.Height - 1)
            $p.Dispose()
        }
    })
    return @{ Form = $f; Bar = $bar; Title = $lbl; Close = $x }
}

function Show-Message([string]$Title, [string]$Text, [string]$OkText = "OK", [string]$CancelText = "") {
    $sz = [System.Windows.Forms.TextRenderer]::MeasureText($Text, $FontUI,
        (New-Object System.Drawing.Size((Px 356), 0)), [System.Windows.Forms.TextFormatFlags]::WordBreak)
    $textH = [int][Math]::Ceiling($sz.Height / $Script:Scale) + 6
    $d = New-Dialog $Title 400 (58 + $textH + 74)
    $f = $d.Form
    $f.Controls.Add((New-Label $Text 22 56 356 $textH $FontUI $UI.Text))
    $Script:MsgResult = $false
    $by = 58 + $textH + 16
    $ok = New-FlatButton -Text $OkText -X 286 -Y $by -W 92 -H 34 -Primary
    $ok.Add_Click({ $Script:MsgResult = $true; $this.FindForm().Close() })
    $f.Controls.Add($ok)
    $f.AcceptButton = $ok
    if ($CancelText) {
        $cn = New-FlatButton -Text $CancelText -X 186 -Y $by -W 92 -H 34
        $cn.Add_Click({ $this.FindForm().Close() })
        $f.Controls.Add($cn)
    }
    [void]$f.ShowDialog()
    $f.Dispose()
    return $Script:MsgResult
}

# ===========================================================================
#  API KEY DIALOG  (for changing the key later; first run uses the guide)
# ===========================================================================
function Show-KeyDialog {
    $d = New-Dialog "Change API key" 440 318
    $f = $d.Form
    $f.Controls.Add((New-Label "Paste your personal Everhour API token." 22 56 396 20 $FontUI $UI.Text))
    $f.Controls.Add((New-Label "Everhour: your name (bottom-left) > My Profile > Application Access" 22 78 396 20 $FontSmall $UI.Muted))

    $tb = New-TextBox 22 110 396 "" "API token"
    $tb.UseSystemPasswordChar = $true
    $f.Controls.Add($tb)

    $show = New-Object System.Windows.Forms.CheckBox
    $show.Text = "Show token"; $show.Font = $FontSmall; $show.ForeColor = $UI.Muted
    $show.Location = New-Object System.Drawing.Point((Px 22), (Px 144))
    $show.Size = New-Object System.Drawing.Size((Px 120), (Px 22))
    $show.Add_CheckedChanged({ $Script:KD.Tb.UseSystemPasswordChar = -not $this.Checked })
    $f.Controls.Add($show)

    $st = New-Label "" 22 172 396 40 $FontSmall $UI.Muted
    $f.Controls.Add($st)
    $f.Controls.Add((New-Label "Stored encrypted on this PC. Only ever sent to api.everhour.com." 22 216 396 20 $FontSmall $UI.Muted))

    $btnCancel = New-FlatButton -Text "Cancel" -X 220 -Y 262 -W 92 -H 34
    $btnGo = New-FlatButton -Text "Connect" -X 320 -Y 262 -W 98 -H 34 -Primary
    $f.Controls.Add($btnCancel); $f.Controls.Add($btnGo)
    $f.AcceptButton = $btnGo

    $Script:KD = @{ Result = $null; Tb = $tb; St = $st; Form = $f; Busy = $false }
    $btnCancel.Add_Click({ $Script:KD.Form.Close() })
    $btnGo.Add_Click({
        $kd = $Script:KD
        $k = $kd.Tb.Text.Trim()
        if (-not $k) { $kd.St.ForeColor = $UI.Danger; $kd.St.Text = "Paste your token first."; return }
        if ($kd.Busy) { return }
        $kd.Busy = $true
        $kd.St.ForeColor = $UI.Muted; $kd.St.Text = "Checking with Everhour..."
        Invoke-Api -Key $k -Requests @(@{ Name = "me"; Path = "/users/me" }) -OnDone {
            param($m)
            $kd = $Script:KD
            $kd.Busy = $false
            if ($kd.Form.IsDisposed) { return }
            $r = $m["me"]
            if ($r -and $r.Ok -and $r.Data) {
                $Script:UserId = $r.Data.id
                $Script:UserName = [string]$r.Data.name
                $kd.Result = $kd.Tb.Text.Trim()
                $kd.Form.Close()
            } elseif ($r -and ($r.Code -eq 401 -or $r.Code -eq 403)) {
                $kd.St.ForeColor = $UI.Danger
                $kd.St.Text = "Everhour rejected this token. Check you copied all of it."
            } else {
                # Can't verify while offline - accept it; the widget will say if it's wrong.
                $kd.Result = $kd.Tb.Text.Trim()
                $kd.Form.Close()
            }
        }
    })
    $f.Add_Shown({ $Script:KD.Tb.Focus() | Out-Null })
    [void]$f.ShowDialog()
    $f.Dispose()
    return $Script:KD.Result
}

function Change-ApiKey {
    $k = Show-KeyDialog
    if ($k) {
        Set-ApiKey $k
        After-KeyChanged
        return $true
    }
    return $false
}

function After-KeyChanged {
    $Script:LastError = ""
    $Script:RecordsLoaded = $false; $Script:WeekLoaded = $false
    $Script:RecordsAt = [DateTime]::MinValue
    Request-Poll -Force
    Render
}

# ===========================================================================
#  MAIN WIDGET  (custom drawn on a per-pixel-alpha window)
# ===========================================================================
$Script:IsExpanded   = $false
$Script:LastInteract = Get-Date
$Script:Hover        = ""
$Script:Hits         = @()
$Script:Ready        = $false
$Script:Layered      = $Script:HasWinApi
$Script:F            = @{}
$Script:C            = @{}
$Script:Frame        = $null
$Script:Mode         = "idle"
$Script:Pal          = $null
$Script:DotCache     = @{}

$form                 = New-Object System.Windows.Forms.Form
$form.Text            = "Everhour Widget"
$form.FormBorderStyle = "None"
$form.StartPosition   = "Manual"
$form.ShowInTaskbar   = $false
$form.TopMost         = [bool]$Script:Cfg.AlwaysOnTop
$form.Location        = New-Object System.Drawing.Point(-32000, -32000)
$form.Size            = New-Object System.Drawing.Size(10, 10)
Set-DoubleBuffered $form

$Script:SF = @{}
foreach ($align in @("Left", "Right", "Center")) {
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = switch ($align) { "Left" { "Near" } "Right" { "Far" } default { "Center" } }
    $fmt.LineAlignment = "Center"
    $fmt.Trimming = "EllipsisCharacter"
    $fmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
    $Script:SF[$align] = $fmt
}
$Script:MeasureBmp = New-Object System.Drawing.Bitmap(1, 1)
$Script:MeasureG = [System.Drawing.Graphics]::FromImage($Script:MeasureBmp)
$Script:MeasureG.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

function New-PxFont([string]$key, [double]$pt, $style = [System.Drawing.FontStyle]::Regular) {
    $px = [single]($pt * 96.0 / 72.0 * $Script:Scale)
    $fam = Get-FontFamilyObj $key
    if (-not $fam.IsStyleAvailable($style)) { $style = [System.Drawing.FontStyle]::Regular }
    try { return New-Object System.Drawing.Font($fam, $px, $style, [System.Drawing.GraphicsUnit]::Pixel) }
    catch { return New-Object System.Drawing.Font("Segoe UI", $px, $style, [System.Drawing.GraphicsUnit]::Pixel) }
}

function A($color, [int]$alpha) { return [System.Drawing.Color]::FromArgb([Math]::Max(0, [Math]::Min(255, $alpha)), $color) }

function Mix($c1, $c2, [double]$t) {
    return [System.Drawing.Color]::FromArgb(
        [int]($c1.R + ($c2.R - $c1.R) * $t), [int]($c1.G + ($c2.G - $c1.G) * $t), [int]($c1.B + ($c2.B - $c1.B) * $t))
}

function New-RoundPath([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($r -le 0.5) { $p.AddRectangle((New-Object System.Drawing.RectangleF($x, $y, $w, $h))); return $p }
    $r = [Math]::Min($r, [Math]::Min($w, $h) / 2)
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Fill-Round($g, $color, [single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    if ($w -le 0 -or $h -le 0) { return }
    $p = New-RoundPath $x $y $w $h $r
    $b = New-Object System.Drawing.SolidBrush($color)
    $g.FillPath($b, $p)
    $b.Dispose(); $p.Dispose()
}

function Fill-Circle($g, $color, [single]$cx, [single]$cy, [single]$r) {
    $b = New-Object System.Drawing.SolidBrush($color)
    $g.FillEllipse($b, ($cx - $r), ($cy - $r), (2 * $r), (2 * $r))
    $b.Dispose()
}

function Draw-Text($g, [string]$text, $font, $color, [single]$x, [single]$y, [single]$w, [single]$h, [string]$align = "Left") {
    if ($w -le 1 -or [string]::IsNullOrEmpty($text)) { return }
    $b = New-Object System.Drawing.SolidBrush($color)
    $g.DrawString($text, $font, $b, (New-Object System.Drawing.RectangleF($x, $y, $w, $h)), $Script:SF[$align])
    $b.Dispose()
}

function Measure-W([string]$text, $font) {
    if ([string]::IsNullOrEmpty($text)) { return 0 }
    return $Script:MeasureG.MeasureString($text, $font, (New-Object System.Drawing.SizeF(4000, 400)), $Script:SF["Left"]).Width
}

function Add-Hit([string]$name, [single]$x, [single]$y, [single]$w, [single]$h) {
    $Script:Hits += [pscustomobject]@{ Name = $name; Rect = (New-Object System.Drawing.RectangleF($x, $y, $w, $h)) }
}

# ---------------------------------------------------------------------------
#  MODES + PALETTES
#    work       timer running on a normal task       -> your theme
#    break      running a break task, within allowance -> calm teal gradient
#    overbreak  break allowance used up              -> fast red/orange gradient
#    stopped    no timer running                     -> red gradient, red dot circling
#    idle       connecting / offline / red turned off -> your theme
#  Colours glide from one palette to the next instead of jumping.
# ---------------------------------------------------------------------------
function Get-Mode {
    if ($Script:IsRunning) {
        if (Test-IsBreak $Script:TaskName) {
            $limit = [double]$Script:Cfg.BreakLimitMinutes * 60
            if ($limit -gt 0 -and (Get-BreakTotal) -gt $limit) { return "overbreak" }
            return "break"
        }
        return "work"
    }
    if (-not $Script:FirstPollDone -or $Script:LastError) { return "idle" }
    if ($Script:Cfg.RedWhenStopped) { return "stopped" }
    return "idle"
}

function Get-ModePalette([string]$mode) {
    $C = $Script:C
    switch ($mode) {
        "break" {
            return @{ Bg1 = ToColor "#0B3A40"; Bg2 = ToColor "#1B2B5E"; Accent = ToColor "#5EEAD4"; Glow = ToColor "#67E8F9"
                      Task = ToColor "#CCFBF1"; Time = ToColor "#FFFFFF"; Muted = ToColor "#6FB7B0"; Error = $C.Error; Dot = ToColor "#5EEAD4" }
        }
        "overbreak" {
            return @{ Bg1 = ToColor "#7F1D1D"; Bg2 = ToColor "#EA580C"; Accent = ToColor "#FFE4E6"; Glow = ToColor "#FB7185"
                      Task = ToColor "#FFE4E6"; Time = ToColor "#FFFFFF"; Muted = ToColor "#FDA4AF"; Error = ToColor "#FFF1F2"; Dot = ToColor "#FFE4E6" }
        }
        "stopped" {
            return @{ Bg1 = ToColor "#3A0A0F"; Bg2 = ToColor "#B4182C"; Accent = ToColor "#FECDD3"; Glow = ToColor "#F43F5E"
                      Task = ToColor "#FECDD3"; Time = ToColor "#FFFFFF"; Muted = ToColor "#FB7185"; Error = ToColor "#FFF1F2"; Dot = ToColor "#FF4D5E" }
        }
        default {
            return @{ Bg1 = $C.Back; Bg2 = (Mix $C.Back $C.Accent 0.10); Accent = $C.Accent; Glow = $C.Accent
                      Task = $C.Task; Time = $C.Time; Muted = $C.Idle; Error = $C.Error; Dot = $C.Accent }
        }
    }
}

function Step-Pal($pal, $target, [double]$k) {
    $done = $true
    foreach ($key in @($target.Keys)) {
        $a = $pal[$key]; $b = $target[$key]
        if (-not $a) { $pal[$key] = $b; continue }
        if ([Math]::Abs($a.R - $b.R) + [Math]::Abs($a.G - $b.G) + [Math]::Abs($a.B - $b.B) -le 6) { $pal[$key] = $b; continue }
        $pal[$key] = Mix $a $b $k
        $done = $false
    }
    return $done
}

function Update-ModeAndPalette([switch]$Snap) {
    $Script:Mode = Get-Mode
    $target = Get-ModePalette $Script:Mode
    if (-not $Script:Pal -or $Snap -or -not $Script:Cfg.Animations) {
        $Script:Pal = @{}; foreach ($k in $target.Keys) { $Script:Pal[$k] = $target[$k] }
        $Script:PalSettled = $true
    } else {
        $Script:PalSettled = Step-Pal $Script:Pal $target 0.14
    }
}

function Get-AnimTime {
    if (-not $Script:Cfg.Animations) { return 0.0 }
    if ($Script:FixedAnimT) { return $Script:FixedAnimT }
    return $Script:Clock.Elapsed.TotalSeconds
}

function Apply-Theme {
    $c = $Script:Cfg
    $Script:C = @{
        Back   = ToColor $c.BackColor
        Task   = ToColor $c.TaskColor
        Time   = ToColor $c.TimeColor
        Accent = ToColor $c.AccentColor
        Idle   = ToColor $c.IdleColor
        Error  = ToColor $c.ErrorColor
    }
    foreach ($old in $Script:F.Values) { try { $old.Dispose() } catch { } }
    $fam = [string]$c.FontFamily
    $tfam = if ([string]::IsNullOrWhiteSpace($c.TimerFontFamily)) { $fam } else { [string]$c.TimerFontFamily }
    $Script:F = @{
        Task      = New-PxFont $fam ([double]$c.TaskFontSize)
        TaskBold  = New-PxFont $fam ([double]$c.TaskFontSize) ([System.Drawing.FontStyle]::Bold)
        Time      = New-PxFont $tfam ([double]$c.TimeFontSize) ([System.Drawing.FontStyle]::Bold)
        TimeBig   = New-PxFont $tfam ([double]$c.TimeFontSize * 1.35) ([System.Drawing.FontStyle]::Bold)
        Small     = New-PxFont $fam ([Math]::Max(7, [double]$c.TaskFontSize - 1))
        SmallBold = New-PxFont $fam ([Math]::Max(7, [double]$c.TaskFontSize - 1.5)) ([System.Drawing.FontStyle]::Bold)
        Caps      = New-PxFont $fam ([Math]::Max(6.5, [double]$c.TaskFontSize - 2)) ([System.Drawing.FontStyle]::Bold)
    }
    $form.TopMost = [bool]$c.AlwaysOnTop
    if (-not $Script:Layered) {
        $form.BackColor = $Script:C.Back
        $form.Opacity = [double]$c.Opacity / 100.0
    }
    Set-CaptureHidden $form
    Update-ModeAndPalette
    Update-AnimTimer
    Render
}

function Get-FrameMargin { if ($Script:Layered) { return (Px 12) } else { return 0 } }

function Get-CollapsedFrameHeight {
    if ($Script:Cfg.Shape -eq "Square") { return (Px $Script:Cfg.SquareSize) + 2 * (Get-FrameMargin) }
    $P = Px 16
    $hT = $Script:F.Task.GetHeight(); $hB = $Script:F.Time.GetHeight()
    $topH = [Math]::Max((Px 38), $hT + $hB - (Px 1))
    $h = $P + $topH + $P + (Px 14)
    return [int][Math]::Ceiling($h) + 2 * (Get-FrameMargin)
}

function Render {
    if (-not $Script:Ready) { return }
    try { Render-Core } catch { Write-Log "Render failed: $($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)" }
}

function Render-Core {
    Push-Frame (Build-Frame $Script:Pal $Script:Mode)
}

# ---- edge lights: dots evenly spaced along the inside of the card edge,
#      starting at top-centre and running clockwise ----
function Get-EdgeDots([single]$x, [single]$y, [single]$w, [single]$h, [single]$r, [single]$spacing) {
    $key = "$x|$y|$w|$h|$r|$spacing"
    if ($Script:DotCache.ContainsKey($key)) { return $Script:DotCache[$key] }
    $p = New-RoundPath $x $y $w $h $r
    $p.Flatten($null, 0.2)
    $pts = $p.PathPoints
    $p.Dispose()
    $n = $pts.Length
    $cum = New-Object double[] ($n + 1)
    for ($i = 0; $i -lt $n; $i++) {
        $a = $pts[$i]; $b = $pts[($i + 1) % $n]
        $cum[$i + 1] = $cum[$i] + [Math]::Sqrt(($b.X - $a.X) * ($b.X - $a.X) + ($b.Y - $a.Y) * ($b.Y - $a.Y))
    }
    $total = $cum[$n]
    # arc position of top-centre
    $s0 = 0.0; $best = [double]::MaxValue
    for ($i = 0; $i -lt $n; $i++) {
        $d = [Math]::Abs($pts[$i].X - ($x + $w / 2)) + [Math]::Abs($pts[$i].Y - $y) * 4
        if ($d -lt $best) { $best = $d; $s0 = $cum[$i] }
    }
    $count = [Math]::Max(12, [int][Math]::Floor($total / $spacing))
    $step = $total / $count
    $out = New-Object 'System.Drawing.PointF[]' $count
    $seg = 0
    for ($k = 0; $k -lt $count; $k++) {
        $s = ($s0 + $k * $step) % $total
        $seg = 0
        while ($seg -lt $n - 1 -and $cum[$seg + 1] -lt $s) { $seg++ }
        $a = $pts[$seg]; $b = $pts[($seg + 1) % $n]
        $len = $cum[$seg + 1] - $cum[$seg]
        $t = if ($len -gt 0) { ($s - $cum[$seg]) / $len } else { 0 }
        $out[$k] = New-Object System.Drawing.PointF(($a.X + ($b.X - $a.X) * $t), ($a.Y + ($b.Y - $a.Y) * $t))
    }
    if ($Script:DotCache.Count -gt 24) { $Script:DotCache = @{} }
    $Script:DotCache[$key] = $out
    return $out
}

# Fills a run of dots as one path - far cheaper than one call per dot.
function Fill-DotRun($g, $color, $dots, [int]$from, [int]$to, [single]$rd) {
    if ($to -lt $from) { return }
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = 2 * $rd
    for ($i = $from; $i -le $to; $i++) { $p.AddEllipse(($dots[$i].X - $rd), ($dots[$i].Y - $rd), $d, $d) }
    $b = New-Object System.Drawing.SolidBrush($color)
    $g.FillPath($b, $p)
    $b.Dispose(); $p.Dispose()
}

function Draw-EdgeLights($g, $pal, [string]$mode, [single]$W, [single]$H, [single]$R, [double]$at) {
    $ins = [single](Px 6)
    $dots = Get-EdgeDots $ins $ins ($W - 2 * $ins) ($H - 2 * $ins) ([Math]::Max(2, $R - $ins + (Px 1))) ([single](Px 9))
    $n = $dots.Length
    $rd = [single][Math]::Max(1.2, (Px 1.5))
    $dim = A $pal.Muted 55
    switch ($mode) {
        "work" {
            # one lap per minute, like a seconds hand
            $lit = ((Get-LiveElapsed) % 60) / 60.0 * $n
            $full = [int][Math]::Floor($lit)
            Fill-DotRun $g (A $pal.Dot 235) $dots 0 ($full - 1) $rd
            Fill-DotRun $g $dim $dots ($full + 1) ($n - 1) $rd
            $hd = $dots[[Math]::Min($n - 1, $full)]
            Fill-Circle $g (A $pal.Dot ([int](60 + 175 * ($lit - $full)))) $hd.X $hd.Y $rd
            Fill-Circle $g (A $pal.Glow 70) $hd.X $hd.Y ($rd * 2.6)
        }
        "break" {
            $limit = [Math]::Max(1, [double]$Script:Cfg.BreakLimitMinutes * 60)
            $lit = [int][Math]::Ceiling([Math]::Min(1.0, (Get-BreakTotal) / $limit) * $n)
            $breath = 0.75 + 0.25 * [Math]::Sin($at * 2 * [Math]::PI / 4)
            Fill-DotRun $g (A $pal.Dot ([int](235 * $breath))) $dots 0 ($lit - 1) $rd
            Fill-DotRun $g $dim $dots $lit ($n - 1) $rd
        }
        "overbreak" {
            # a bright wave chasing round the edge, in 4 brightness bands
            $bands = @(@(), @(), @(), @())
            for ($i = 0; $i -lt $n; $i++) {
                $wv = 0.5 + 0.5 * [Math]::Sin(2 * [Math]::PI * ($i / $n * 3 - $at * 1.2))
                $bands[[Math]::Min(3, [int]($wv * 4))] += $i
            }
            for ($b = 0; $b -lt 4; $b++) {
                if ($bands[$b].Count -eq 0) { continue }
                $p = New-Object System.Drawing.Drawing2D.GraphicsPath
                $rr = $rd * (0.85 + 0.12 * $b); $d = 2 * $rr
                foreach ($i in $bands[$b]) { $p.AddEllipse(($dots[$i].X - $rr), ($dots[$i].Y - $rr), $d, $d) }
                $br = New-Object System.Drawing.SolidBrush((A $pal.Dot (70 + 60 * $b)))
                $g.FillPath($br, $p); $br.Dispose(); $p.Dispose()
            }
        }
        "stopped" {
            # a red comet running round the edge
            Fill-DotRun $g (A $pal.Dot 45) $dots 0 ($n - 1) $rd
            $head = ($at * 0.28 % 1.0) * $n
            $tail = 9
            for ($k = $tail; $k -ge 0; $k--) {
                $idx = [int]([Math]::Floor($head) - $k)
                $idx = (($idx % $n) + $n) % $n
                $fade = 1.0 - $k / ($tail + 1)
                Fill-Circle $g (A $pal.Dot ([int](255 * $fade))) $dots[$idx].X $dots[$idx].Y ($rd * (0.8 + 0.7 * $fade))
            }
            $hd = $dots[[int][Math]::Floor($head) % $n]
            Fill-Circle $g (A $pal.Glow 90) $hd.X $hd.Y ($rd * 3.2)
        }
        default {
            Fill-DotRun $g $dim $dots 0 ($n - 1) $rd
        }
    }
}

# Little coffee cup with rising steam, for breaks.
function Draw-Cup($g, $color, [single]$x, [single]$y, [single]$s, [double]$at) {
    $pen = New-Object System.Drawing.Pen($color, [single][Math]::Max(1.2, $s * 0.11))
    $pen.StartCap = "Round"; $pen.EndCap = "Round"
    $g.DrawArc($pen, $x, ($y + $s * 0.25), ($s * 0.72), ($s * 0.75), 0, 180)
    $g.DrawLine($pen, $x, ($y + $s * 0.62), ($x + $s * 0.72), ($y + $s * 0.62))
    $g.DrawLine($pen, $x, ($y + $s * 0.45), $x, ($y + $s * 0.62))
    $g.DrawLine($pen, ($x + $s * 0.72), ($y + $s * 0.45), ($x + $s * 0.72), ($y + $s * 0.62))
    $g.DrawArc($pen, ($x + $s * 0.62), ($y + $s * 0.45), ($s * 0.3), ($s * 0.28), -90, 180)
    for ($i = 0; $i -lt 2; $i++) {
        $ph = ($at * 0.8 + $i * 0.5) % 1.0
        $sx = $x + $s * (0.22 + $i * 0.28)
        $sy = $y + $s * 0.38 - $ph * $s * 0.35
        $sp = New-Object System.Drawing.Pen((A $color ([int](200 * (1 - $ph)))), [single][Math]::Max(1, $s * 0.08))
        $g.DrawBezier($sp, $sx, $sy, ($sx + $s * 0.08), ($sy - $s * 0.08), ($sx - $s * 0.08), ($sy - $s * 0.16), $sx, ($sy - $s * 0.24))
        $sp.Dispose()
    }
    $pen.Dispose()
}

# The soft shadow only changes with size and colour, so draw it once and reuse it.
$Script:ShadowCache = @{}
function Get-ShadowLayer([int]$bw, [int]$bh, [int]$M, [single]$W, [single]$H, [single]$R, $color) {
    $key = "$bw|$bh|$R|$($color.ToArgb())"
    if ($Script:ShadowCache.ContainsKey($key)) { return $Script:ShadowCache[$key] }
    if ($Script:ShadowCache.Count -gt 12) {
        foreach ($v in $Script:ShadowCache.Values) { $v.Dispose() }
        $Script:ShadowCache = @{}
    }
    $sb = New-Object System.Drawing.Bitmap($bw, $bh, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $sg = [System.Drawing.Graphics]::FromImage($sb)
    $sg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $card = New-RoundPath $M $M ($W - 1) ($H - 1) $R
    $sg.SetClip($card, [System.Drawing.Drawing2D.CombineMode]::Exclude)
    $shadow = New-Object System.Drawing.SolidBrush($color)
    for ($i = [int]$M; $i -ge 1; $i--) {
        $sp = New-RoundPath ($M - $i) ($M - $i + (Px 2)) ($W - 1 + 2 * $i) ($H - 1 + 2 * $i) ($R + $i)
        $sg.FillPath($shadow, $sp); $sp.Dispose()
    }
    $shadow.Dispose(); $card.Dispose(); $sg.Dispose()
    $Script:ShadowCache[$key] = $sb
    return $sb
}

function Build-Frame($Pal, [string]$Mode) {
    $F = $Script:F; $cfg = $Script:Cfg
    $at = Get-AnimTime
    $square = ($cfg.Shape -eq "Square")
    $M = Get-FrameMargin
    $P = [single](Px 16)
    $R = [single](Px $cfg.CornerRadius)
    $hT = [single]$F.Task.GetHeight(); $hB = [single]$F.Time.GetHeight(); $hS = [single]$F.Small.GetHeight()
    $hC = [single]$F.Caps.GetHeight()
    $target = [double]$cfg.DailyTargetHours
    $showToday = [bool]$cfg.ShowTodayTotal
    $now = Get-Date
    $today = Get-TodayTotal
    $hasToday = $Script:RecordsLoaded -or $Script:IsRunning
    $isBreak = ($Mode -eq "break" -or $Mode -eq "overbreak")
    $breakSec = if ($isBreak) { Get-BreakTotal } else { 0 }
    $limit = [double]$cfg.BreakLimitMinutes * 60
    $showBar = ($showToday -and $target -gt 0) -or ($isBreak -and $limit -gt 0)
    $stoppedShow = ($Mode -eq "stopped")

    # ---------- what goes where ----------
    if ($square) {
        $W = [single](Px $cfg.SquareSize)
        if ($Script:IsExpanded) { $W = [single][Math]::Max($W, (Px 260)) }
        $btnD = [single](Px 34)
        $btnX = $W - $P - $btnD; $btnY = $P - (Px 2)
        $capsRect = @(($P + (Px 2)), $P, ($btnX - $P - (Px 8)), ($btnD - (Px 4)))
        $timeFont = $F.TimeBig
        if ((Measure-W "00:00:00" $timeFont) -gt ($W - 2 * $P)) { $timeFont = $F.Time }
        $hTime = [single]$timeFont.GetHeight()
        $sqH = [single](Px $cfg.SquareSize)
        $barY = $sqH - $P - (Px 4)
        # task, timer and total sit as one block, centred between the top row and the bar
        $stackH = ($hT - (Px 2)) + ($hTime - (Px 4)) + $hS
        $top = $btnY + $btnD
        $taskY = $top + ($barY - (Px 6) - $top - $stackH) / 2
        $timeY = $taskY + $hT - (Px 2)
        $todayY = $timeY + $hTime - (Px 4)
        $line1 = @(($P + (Px 2)), $taskY, ($W - 2 * $P), $hT)
        $timeRect = @(($P - (Px 1)), $timeY, ($W - 2 * $P), $hTime)
        $y = $sqH - $P
        $collapsedBottom = $sqH
    } else {
        $W = [single](Px $cfg.Width)
        $btnD = [single](Px 40)
        $topH = [single][Math]::Max($btnD, $hT + $hB - (Px 1))
        $btnX = $P; $btnY = $P + ($topH - $btnD) / 2
        $x0 = $P + $btnD + (Px 12)
        $line1Y = $P + ($topH - ($hT + $hB - (Px 1))) / 2
        $line1 = @($x0, $line1Y, ($W - $P - $x0), $hT)
        $timeFont = $F.Time; $hTime = $hB
        $timeRect = @(($x0 - (Px 1)), ($line1Y + $hT - (Px 1)), ($W - $P - $x0), $hB)
        $y = $P + $topH
        $barY = $y + (Px 10)
        $y = $barY + (Px 4)
        $collapsedBottom = $y + $P
    }
    $expStart = $y

    $rows = @(); $more = 0
    $rowH = $hT + (Px 11)
    $btnH = [single](Px 30)
    if ($Script:IsExpanded) {
        $all = @(Get-BreakdownRows)
        $rows = @($all | Select-Object -First 6)
        $more = $all.Count - $rows.Count
        $y += (Px 12) + 1 + (Px 10) + $hS + (Px 8)
        if ($rows.Count -eq 0) { $y += $hT + (Px 8) } else { $y += $rows.Count * $rowH }
        if ($more -gt 0) { $y += $hS + (Px 4) }
        if ($cfg.ShowWeekTotal) { $y += $hS + (Px 10) }
        $y += (Px 6) + $btnH
        $H = [single][Math]::Ceiling($y + $P)
    } else {
        $H = [single][Math]::Ceiling($collapsedBottom)
    }

    $bw = [int]($W + 2 * $M); $bh = [int]($H + 2 * $M)
    $bmp = New-Object System.Drawing.Bitmap($bw, $bh, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.Clear([System.Drawing.Color]::Transparent)
    $Script:Hits = @()

    $pulse = 0.5 + 0.5 * [Math]::Sin($at * 2 * [Math]::PI / $(if ($Mode -eq "overbreak") { 1.1 } else { 3.2 }))

    # ---------- soft shadow ----------
    $card = New-RoundPath $M $M ($W - 1) ($H - 1) $R
    if ($M -gt 0) {
        $sc = [System.Drawing.Color]::FromArgb(7, 0, 0, 0)
        if ($Mode -eq "stopped" -or $Mode -eq "overbreak") { $sc = [System.Drawing.Color]::FromArgb(6 + 2 * [int]([Math]::Round(3 * $pulse)), 200, 20, 40) }
        $g.DrawImageUnscaled((Get-ShadowLayer $bw $bh $M $W $H $R $sc), 0, 0)
    }

    # ---------- gradient background (flows in break / red modes) ----------
    $bgAlpha = 255
    if ($Script:Layered) { $bgAlpha = [int](255 * [double]$cfg.Opacity / 100.0) }
    if ($Mode -ne "work" -and $Mode -ne "idle") { $bgAlpha = [Math]::Max($bgAlpha, 236) }
    $gr = New-Object System.Drawing.RectangleF($M, $M, ($W * 0.9), $H)
    $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($gr, (A $Pal.Bg1 $bgAlpha), (A $Pal.Bg2 $bgAlpha), [single]25)
    $lg.WrapMode = [System.Drawing.Drawing2D.WrapMode]::TileFlipXY
    if ($Mode -ne "work" -and $Mode -ne "idle") {
        $speed = if ($Mode -eq "overbreak") { 0.45 } elseif ($Mode -eq "stopped") { 0.12 } else { 0.08 }
        $lg.TranslateTransform([single](($at * $speed * $W * 1.8) % ($W * 1.8)), 0)
    }
    $g.FillPath($lg, $card); $lg.Dispose()

    # drifting glow
    $ga = switch ($Mode) { "work" { 30 } "break" { [int](30 + 30 * $pulse) } "overbreak" { [int](40 + 80 * $pulse) } "stopped" { [int](30 + 45 * $pulse) } default { 14 } }
    $gx = $M + $W * (0.5 + 0.42 * [Math]::Sin($at * 0.45)); $gy = $M + $H * (0.35 + 0.25 * [Math]::Cos($at * 0.6))
    $gr2 = [single]([Math]::Max($W, $H) * 0.62)
    $gpath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $gpath.AddEllipse(($gx - $gr2), ($gy - $gr2), (2 * $gr2), (2 * $gr2))
    $pg = New-Object System.Drawing.Drawing2D.PathGradientBrush($gpath)
    $pg.CenterColor = A $Pal.Glow $ga
    $pg.SurroundColors = [System.Drawing.Color[]]@((A $Pal.Glow 0))
    $g.SetClip($card)
    $g.FillPath($pg, $gpath)
    $g.ResetClip()
    $pg.Dispose(); $gpath.Dispose()

    $edge = if (IsLight $Pal.Bg1) { [System.Drawing.Color]::FromArgb(30, 0, 0, 0) } else { [System.Drawing.Color]::FromArgb(26, 255, 255, 255) }
    $ew = [single]1
    if ($Mode -eq "stopped" -or $Mode -eq "overbreak") { $edge = A $Pal.Glow ([int](70 + 110 * $pulse)); $ew = [single]1.5 }
    $pen = New-Object System.Drawing.Pen($edge, $ew); $g.DrawPath($pen, $card); $pen.Dispose()
    $card.Dispose()

    $g.TranslateTransform($M, $M)

    # ---------- edge lights ----------
    if ($cfg.EdgeLights) { Draw-EdgeLights $g $Pal $Mode $W $H $R $at }

    # ---------- start / stop button ----------
    $cx = $btnX + $btnD / 2; $cy = $btnY + $btnD / 2
    $hovBtn = ($Script:Hover -eq "toggle")
    if ($Script:LastError -eq "AUTH") {
        Fill-Circle $g (A $Pal.Error $(if ($hovBtn) { 90 } else { 55 })) $cx $cy ($btnD / 2)
        Draw-Text $g "!" $F.TaskBold $Pal.Error ($cx - $btnD / 2) ($cy - $btnD / 2) $btnD $btnD "Center"
    } elseif ($Script:IsRunning) {
        $fillC = $Pal.Accent; if ($hovBtn) { $fillC = Mix $Pal.Accent ([System.Drawing.Color]::White) 0.2 }
        Fill-Circle $g (A $Pal.Glow 50) $cx $cy ($btnD / 2 + (Px 3))
        Fill-Circle $g $fillC $cx $cy ($btnD / 2)
        $sq = $btnD * 0.30
        Fill-Round $g $Pal.Bg1 ($cx - $sq / 2) ($cy - $sq / 2) $sq $sq (Px 2)
    } else {
        $breathe = 1.0
        if ($Mode -eq "stopped") { $breathe = 1.0 + 0.06 * $pulse }
        $rr = $btnD / 2 * $breathe
        Fill-Circle $g (A $Pal.Accent $(if ($hovBtn) { 90 } else { 48 })) $cx $cy $rr
        $tri = $btnD * 0.17
        $pts = [System.Drawing.PointF[]]@(
            (New-Object System.Drawing.PointF(($cx - $tri * 0.8), ($cy - $tri * 1.15))),
            (New-Object System.Drawing.PointF(($cx - $tri * 0.8), ($cy + $tri * 1.15))),
            (New-Object System.Drawing.PointF(($cx + $tri * 1.25), $cy)))
        $tb = New-Object System.Drawing.SolidBrush($Pal.Accent); $g.FillPolygon($tb, $pts); $tb.Dispose()
    }
    Add-Hit "toggle" ($btnX + $M) ($btnY + $M) $btnD $btnD

    # ---------- status chip ----------
    $chip = ""; $chipC = $Pal.Error
    if ($Script:Toast -and $now -lt $Script:ToastUntil) {
        $chip = $Script:Toast
        $chipC = if ($Script:ToastIsError) { $Pal.Error } else { $Pal.Accent }
    } elseif ($Script:LastError -eq "OFFLINE") { $chip = "offline" }
    elseif ($Script:LastError -eq "RATE") { $chip = "slowing down" }
    elseif ($Script:LastError -eq "AUTH") { $chip = "key rejected" }

    # ---------- texts ----------
    $l1 = ""; $l1C = $Pal.Task; $l1F = $F.Task
    if ($hovBtn -and $Script:LastError -eq "AUTH") { $l1 = "Click to enter your API token"; $l1C = $Pal.Error }
    elseif ($hovBtn -and $Script:IsRunning) { $l1 = "Stop timer"; $l1C = $Pal.Accent }
    elseif ($hovBtn) {
        $l1C = $Pal.Accent
        $l1 = if ($cfg.LastTaskId) { "Resume  " + $cfg.LastTaskName } else { "Start a timer" }
    }
    elseif ($Mode -eq "overbreak") { $l1 = "Break over by " + (Format-Short ($breakSec - $limit)); $l1F = $F.TaskBold }
    elseif ($Script:IsRunning) { $l1 = $Script:TaskName }
    elseif (-not $Script:FirstPollDone -and -not $Script:LastError) { $l1 = "Connecting to Everhour..."; $l1C = $Pal.Muted }
    elseif ($stoppedShow) { $l1 = "Timer off since " + $Script:StoppedSince.ToString("h:mm tt"); $l1C = $Pal.Task }
    else { $l1 = "Not tracking"; $l1C = $Pal.Muted }

    $timeText = Format-HMS 0
    $timeC = A $Pal.Time 115
    if ($Script:IsRunning) { $timeText = Format-HMS (Get-LiveElapsed); $timeC = $Pal.Time }
    elseif ($stoppedShow) { $timeText = Format-HMS (($now - $Script:StoppedSince).TotalSeconds); $timeC = $Pal.Time }

    if ($square) {
        $caps = switch ($Mode) { "work" { "TRACKING" } "break" { "ON BREAK" } "overbreak" { "BREAK OVER" } "stopped" { "TIMER OFF" } default { "EVERHOUR" } }
        $cxp = $capsRect[0]
        if ($isBreak) { Draw-Cup $g $Pal.Accent $cxp ($capsRect[1] + (Px 6)) ([single](Px 15)) $at; $cxp += (Px 20) }
        elseif ($Mode -eq "work" -or $Mode -eq "stopped") {
            $da = if ($Mode -eq "work") { 255 } else { [int](120 + 135 * $pulse) }
            Fill-Circle $g (A $Pal.Dot $da) ($cxp + (Px 4)) ($capsRect[1] + $capsRect[3] / 2) ([single](Px 3.5)); $cxp += (Px 13)
        }
        if ($chip) {
            Draw-Text $g $chip $F.SmallBold $chipC $cxp $capsRect[1] ($capsRect[0] + $capsRect[2] - $cxp) $capsRect[3] "Left"
        } else {
            Draw-Text $g $caps $F.Caps $Pal.Muted $cxp $capsRect[1] ($capsRect[0] + $capsRect[2] - $cxp) $capsRect[3] "Left"
        }
        if ($stoppedShow -and -not $hovBtn) { $l1 = "Off since " + $Script:StoppedSince.ToString("h:mm tt") }
        Draw-Text $g $l1 $l1F $l1C $line1[0] $line1[1] $line1[2] $line1[3] "Left"
        Draw-Text $g $timeText $timeFont $timeC $timeRect[0] $timeRect[1] $timeRect[2] $timeRect[3] "Left"
        if ($showToday -or $isBreak) {
            $main = ""; $suffix = ""
            if ($Mode -eq "overbreak") { $main = "+" + (Format-Short ($breakSec - $limit)); $suffix = "  over break" }
            elseif ($isBreak) { $main = Format-Short $breakSec; $suffix = "  of " + (Format-Short $limit) + " break" }
            else {
                $main = if ($hasToday) { Format-Short $today } else { "--" }
                $suffix = if ($target -gt 0) { "  of " + (Format-Target $target) + " today" } else { "  today" }
            }
            $mw = Measure-W $main $F.SmallBold
            Draw-Text $g $main $F.SmallBold $Pal.Task $P $todayY ($mw + (Px 2)) $hS "Left"
            Draw-Text $g $suffix $F.Small $Pal.Muted ($P + $mw) $todayY ($W - 2 * $P - $mw) $hS "Left"
        }
    } else {
        $lineR = $line1[0] + $line1[2]
        if ($chip) {
            $cw = (Measure-W $chip $F.Small) + (Px 10)
            $ch = $hS + (Px 2)
            $chX = $lineR - $cw; $chY = $line1[1] + ($hT - $ch) / 2
            Fill-Round $g (A $chipC 38) $chX $chY $cw $ch ($ch / 2)
            Draw-Text $g $chip $F.Small $chipC $chX $chY $cw $ch "Center"
            $lineR = $chX - (Px 6)
        }
        $lx = $line1[0]
        if ($isBreak -and -not $hovBtn) { Draw-Cup $g $Pal.Accent $lx ($line1[1] + (Px 1)) ([single](Px 13)) $at; $lx += (Px 18) }
        Draw-Text $g $l1 $l1F $l1C $lx $line1[1] ($lineR - $lx) $hT "Left"

        $timeW = Measure-W $timeText $timeFont
        Draw-Text $g $timeText $timeFont $timeC $timeRect[0] $timeRect[1] ($timeW + (Px 4)) $hB "Left"

        if ($showToday -or $isBreak) {
            if ($Mode -eq "overbreak") { $main = "+" + (Format-Short ($breakSec - $limit)); $suffix = " over" }
            elseif ($isBreak) { $main = Format-Short $breakSec; $suffix = " / " + (Format-Short $limit) }
            else {
                $main = if ($hasToday) { Format-Short $today } else { "--" }
                $suffix = if ($target -gt 0) { " / " + (Format-Target $target) } else { " today" }
            }
            $sw = Measure-W $suffix $F.Small
            $mw = Measure-W $main $F.SmallBold
            $xr = $W - $P
            $avail = $xr - ($timeRect[0] + $timeW + (Px 10))
            if ($avail -ge ($sw + $mw)) {
                $ly = $timeRect[1] + $hB - $hS - (Px 6)
                Draw-Text $g $suffix $F.Small $Pal.Muted ($xr - $sw) $ly ($sw + (Px 1)) $hS "Right"
                Draw-Text $g $main $F.SmallBold $Pal.Task ($xr - $sw - $mw) $ly $mw $hS "Right"
            }
        }
    }

    # ---------- progress bar: day target, or break allowance ----------
    if ($showBar) {
        $bx = $P; $bwid = $W - 2 * $P; $bhgt = [single](Px 4)
        Fill-Round $g (A $Pal.Muted 60) $bx $barY $bwid $bhgt ($bhgt / 2)
        $frac = 0.0
        if ($isBreak) { $frac = [Math]::Min(1.0, $breakSec / [Math]::Max(1, $limit)) }
        elseif ($hasToday) { $frac = [Math]::Min(1.0, $today / ($target * 3600.0)) }
        if ($frac -gt 0) {
            $fw = [single][Math]::Max($bhgt, $bwid * $frac)
            Fill-Round $g $Pal.Accent $bx $barY $fw $bhgt ($bhgt / 2)
            if ($Mode -eq "overbreak") {
                # moving warning stripes
                $clipP = New-RoundPath $bx $barY $fw $bhgt ($bhgt / 2)
                $g.SetClip($clipP)
                $spen = New-Object System.Drawing.Pen((A $Pal.Bg1 170), [single](Px 2))
                $off = ($at * (Px 18)) % (Px 8)
                for ($sx = $bx - (Px 8) + $off; $sx -lt $bx + $fw; $sx += (Px 8)) { $g.DrawLine($spen, $sx, ($barY + $bhgt), ($sx + (Px 4)), $barY) }
                $spen.Dispose(); $g.ResetClip(); $clipP.Dispose()
            } elseif ($Script:Cfg.Animations -and ($Mode -eq "work" -or $Mode -eq "break")) {
                # shimmer sliding along the filled part
                $sh = ($at % 2.6) / 2.6
                $sx = $bx - (Px 40) + ($fw + (Px 80)) * $sh
                $clipP = New-RoundPath $bx $barY $fw $bhgt ($bhgt / 2)
                $g.SetClip($clipP)
                $srect = New-Object System.Drawing.RectangleF($sx, $barY, (Px 40), $bhgt)
                $slg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($srect, (A ([System.Drawing.Color]::White) 0), (A ([System.Drawing.Color]::White) 150), [single]0)
                $blend = New-Object System.Drawing.Drawing2D.Blend(3)
                $blend.Factors = [single[]]@(0, 1, 0); $blend.Positions = [single[]]@(0, 0.5, 1)
                $slg.Blend = $blend
                $g.FillRectangle($slg, $srect)
                $slg.Dispose(); $g.ResetClip(); $clipP.Dispose()
            }
        }
    }

    # ---------- expanded: today's breakdown, week, buttons ----------
    if ($Script:IsExpanded) {
        $ey = $expStart + (Px 12)
        $lp = New-Object System.Drawing.Pen((A $Pal.Muted 70), 1)
        $g.DrawLine($lp, $P, $ey, ($W - $P), $ey); $lp.Dispose()
        $ey += 1 + (Px 10)

        Draw-Text $g "TODAY" $F.Caps $Pal.Muted $P $ey ($W / 2) $hS "Left"
        $totText = if ($hasToday) { Format-Short $today } else { "--" }
        Draw-Text $g $totText $F.SmallBold $Pal.Task ($W / 2) $ey ($W / 2 - $P) $hS "Right"
        $ey += $hS + (Px 8)

        if ($rows.Count -eq 0) {
            $msg = if ($Script:RecordsLoaded) { "Nothing tracked yet today" } else { "Loading..." }
            Draw-Text $g $msg $F.Task $Pal.Muted $P $ey ($W - 2 * $P) $hT "Left"
            $ey += $hT + (Px 8)
        } else {
            $maxSec = [Math]::Max(1, $rows[0].Sec)
            $durW = [single](Px 66)
            foreach ($row in $rows) {
                $nc = if ($row.Running) { $Pal.Time } else { $Pal.Task }
                $nf = if ($row.Running) { $F.TaskBold } else { $F.Task }
                Draw-Text $g $row.Name $nf $nc $P $ey ($W - 2 * $P - $durW) $hT "Left"
                $dc = if ($row.Running) { $Pal.Accent } else { $Pal.Task }
                Draw-Text $g (Format-Short $row.Sec) $F.Task $dc ($W - $P - $durW) $ey $durW $hT "Right"
                $by = $ey + $hT + (Px 2); $bhh = [single][Math]::Max(2, (Px 3))
                Fill-Round $g (A $Pal.Muted 40) $P $by ($W - 2 * $P) $bhh ($bhh / 2)
                $fc = if ($row.Running) { $Pal.Accent } elseif (Test-IsBreak $row.Name) { A (ToColor "#5EEAD4") 190 } else { A $Pal.Muted 190 }
                Fill-Round $g $fc $P $by ([Math]::Max($bhh, ($W - 2 * $P) * $row.Sec / $maxSec)) $bhh ($bhh / 2)
                $ey += $rowH
            }
        }
        if ($more -gt 0) {
            Draw-Text $g "+$more more" $F.Small $Pal.Muted $P $ey ($W - 2 * $P) $hS "Left"
            $ey += $hS + (Px 4)
        }
        if ($cfg.ShowWeekTotal) {
            $ey += (Px 4)
            $wk = Get-WeekTotal
            $wkText = if ($wk -ge 0) { Format-Short $wk } else { "--" }
            Draw-Text $g "This week" $F.Small $Pal.Muted $P $ey ($W / 2) $hS "Left"
            Draw-Text $g $wkText $F.SmallBold $Pal.Task ($W / 2) $ey ($W / 2 - $P) $hS "Right"
            $ey += $hS + (Px 6)
        }
        $ey += (Px 6)

        $gap = [single](Px 6)
        $bW = ($W - 2 * $P - 2 * $gap) / 3
        $labels = @(
            @{ Name = "b_start"; Text = $(if ($Script:IsRunning) { if ($square) { "Switch" } else { "Switch task" } } elseif ($square) { "Start" } else { "Start task" }); Primary = $true },
            @{ Name = "b_stop"; Text = $(if ($Script:IsRunning) { "Stop" } else { "Resume" }); Primary = $false },
            @{ Name = "b_settings"; Text = "Settings"; Primary = $false })
        for ($i = 0; $i -lt 3; $i++) {
            $bx = $P + $i * ($bW + $gap)
            $hov = ($Script:Hover -eq $labels[$i].Name)
            if ($labels[$i].Primary) {
                Fill-Round $g (A $Pal.Accent $(if ($hov) { 140 } else { 95 })) $bx $ey $bW $btnH ($btnH / 2)
                Draw-Text $g $labels[$i].Text $F.TaskBold $Pal.Time $bx $ey $bW $btnH "Center"
            } else {
                Fill-Round $g (A $Pal.Muted $(if ($hov) { 90 } else { 48 })) $bx $ey $bW $btnH ($btnH / 2)
                Draw-Text $g $labels[$i].Text $F.Task $Pal.Task $bx $ey $bW $btnH "Center"
            }
            Add-Hit $labels[$i].Name ($bx + $M) ($ey + $M) $bW $btnH
        }
    }

    $g.Dispose()
    return $bmp
}

function Get-Anchor {
    if (-not $Script:Anchor) { Place-Form }
    return $Script:Anchor
}

function Push-Frame($bmp) {
    $an = Get-Anchor
    $wa = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point(($an.X + 40), ($an.Y + 20)))).WorkingArea
    $M = Get-FrameMargin
    # grow upwards instead of off the bottom of the screen
    $py = $an.Y
    if ($py + $bmp.Height - $M -gt $wa.Bottom) { $py = $wa.Bottom - $bmp.Height + $M }
    if ($py + $M -lt $wa.Top) { $py = $wa.Top - $M }
    if ($Script:Layered) {
        $ok = $false
        try { $ok = [EhWin]::PushLayered($form.Handle, $bmp, $an.X, $py) } catch { }
        $bmp.Dispose()
        if (-not $ok) { Switch-ToBasicWindow }
        return
    }
    if ($Script:Frame) { $Script:Frame.Dispose() }
    $Script:Frame = $bmp
    $form.SetBounds($an.X, $py, $bmp.Width, $bmp.Height)
    try {
        $p = New-RoundPath 0 0 $bmp.Width $bmp.Height (Px $Script:Cfg.CornerRadius)
        $form.Region = New-Object System.Drawing.Region($p); $p.Dispose()
    } catch { }
    $form.Invalidate()
}

# If per-pixel alpha isn't available, fall back to an ordinary window.
function Switch-ToBasicWindow {
    if (-not $Script:Layered) { return }
    Write-Log "Layered window unavailable; using basic window"
    $Script:Layered = $false
    if ($Script:HasWinApi) {
        try {
            $ex = [EhWin]::GetWindowLong($form.Handle, -20)
            [EhWin]::SetWindowLong($form.Handle, -20, ($ex -band (-bnot 0x00080000))) | Out-Null
        } catch { }
    }
    Apply-Theme
}
$form.Add_Paint({
    param($s, $e)
    if (-not $Script:Layered -and $Script:Frame) { $e.Graphics.DrawImageUnscaled($Script:Frame, 0, 0) }
})

function Test-OnScreen([int]$x, [int]$y) {
    $pt = New-Object System.Drawing.Point(($x + 40), ($y + 20))
    foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
        if ($scr.WorkingArea.Contains($pt)) { return $true }
    }
    return $false
}

function Place-Form {
    if ($null -ne $Script:Cfg.PosX -and $null -ne $Script:Cfg.PosY) {
        $x = [int]$Script:Cfg.PosX; $y = [int]$Script:Cfg.PosY
        if (Test-OnScreen $x $y) { $Script:Anchor = New-Object System.Drawing.Point($x, $y); return }
    }
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $M = Get-FrameMargin
    $cw = if ($Script:Cfg.Shape -eq "Square") { $Script:Cfg.SquareSize } else { $Script:Cfg.Width }
    $w = (Px $cw) + 2 * $M
    $h = Get-CollapsedFrameHeight
    $Script:Anchor = New-Object System.Drawing.Point(($wa.Right - $w - (Px 8) + $M), ($wa.Bottom - $h - (Px 8) + $M))
}

function Set-Expanded([bool]$on) {
    $Script:IsExpanded = $on
    $Script:LastInteract = Get-Date
    if ($on) {
        $stale = ((Get-Date) - $Script:RecordsAt).TotalSeconds -gt 45
        $weekStale = $Script:Cfg.ShowWeekTotal -and (((Get-Date) - $Script:WeekAt).TotalSeconds -gt 120)
        if ($stale -or $weekStale) { Request-Records -WithWeek:$weekStale }
    }
    Render
}

# ===========================================================================
#  ANIMATION CLOCK
#  20 fps while colours change, 15 fps for the red / break effects, 8 fps
#  for the calm "work" look,
#  nothing extra when animations are off (the 1-second clock redraws then).
# ===========================================================================
$animTimer = New-Object System.Windows.Forms.Timer
$animTimer.Interval = 50
$animTimer.Add_Tick({
    Update-ModeAndPalette
    if (-not $Script:Dragging) { Render }
    $want = if (-not $Script:PalSettled) { 50 } elseif ($Script:Mode -in @("stopped", "overbreak", "break")) { 66 } else { 125 }
    if ($animTimer.Interval -ne $want) { $animTimer.Interval = $want }
})
function Update-AnimTimer {
    if (-not $Script:Ready) { return }
    if ($Script:Cfg.Animations) { if (-not $animTimer.Enabled) { $animTimer.Start() } }
    else { $animTimer.Stop() }
}

# ===========================================================================
#  SETTINGS
# ===========================================================================
function New-Toggle([string]$text, [bool]$on, [int]$x, [int]$y, [int]$w) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point((Px $x), (Px $y))
    $p.Size = New-Object System.Drawing.Size((Px $w), (Px 30))
    $p.BackColor = $UI.Bg
    $p.Cursor = "Hand"
    $p.Tag = @{ On = $on; Text = $text }
    Set-DoubleBuffered $p
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $sw = [single](Px 36); $sh = [single](Px 20)
        $sx = $s.Width - $sw - 2; $sy = ($s.Height - $sh) / 2
        $col = if ($s.Tag.On) { $UI.Accent } else { $UI.Line }
        Fill-Round $g $col $sx $sy $sw $sh ($sh / 2)
        $kd = $sh - (Px 6)
        $kx = if ($s.Tag.On) { $sx + $sw - $kd - (Px 3) } else { $sx + (Px 3) }
        Fill-Round $g ([System.Drawing.Color]::White) $kx ($sy + (Px 3)) $kd $kd ($kd / 2)
        $r = New-Object System.Drawing.Rectangle(0, 0, [int]($sx - (Px 8)), $s.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($g, [string]$s.Tag.Text, $FontUI, $r, $UI.Text,
            ([System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis))
    })
    $p.Add_Click({ param($s, $e) $s.Tag.On = -not $s.Tag.On; $s.Invalidate(); Preview-Settings })
    return $p
}

function New-DayChip([string]$day, [bool]$on, [int]$x, [int]$y) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point((Px $x), (Px $y))
    $p.Size = New-Object System.Drawing.Size((Px 40), (Px 28))
    $p.BackColor = $UI.Bg
    $p.Cursor = "Hand"
    $p.Tag = @{ On = $on; Text = $day }
    Set-DoubleBuffered $p
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $col = if ($s.Tag.On) { $UI.Accent } else { $UI.Card }
        Fill-Round $g $col 0 0 ($s.Width - 1) ($s.Height - 1) (Px 7)
        $tc = if ($s.Tag.On) { [System.Drawing.Color]::White } else { $UI.Muted }
        $r = New-Object System.Drawing.Rectangle(0, 0, $s.Width, $s.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($g, [string]$s.Tag.Text, $FontSmall, $r, $tc,
            ([System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter))
    })
    $p.Add_Click({ param($s, $e) $s.Tag.On = -not $s.Tag.On; $s.Invalidate() })
    return $p
}

# Theme tile. In Settings it fills the colour swatches; in the setup guide it
# sets the colours directly.
function New-ThemeTile([string]$name, [int]$x, [int]$y, [int]$w, [int]$h = 52) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point((Px $x), (Px $y))
    $p.Size = New-Object System.Drawing.Size((Px $w), (Px $h))
    $p.BackColor = $UI.Bg
    $p.Cursor = "Hand"
    $p.Tag = $name
    Set-DoubleBuffered $p
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $t = $Script:Themes[[string]$s.Tag]
        $sel = $true
        foreach ($k in $t.Keys) {
            $cur = if ($Script:SettingsOpen -and $Script:SC.Swatch) { ToHex $Script:SC.Swatch[$k].BackColor } else { [string]$Script:Cfg[$k] }
            if ($cur -ne $t[$k]) { $sel = $false }
        }
        Fill-Round $g (ToColor $t.BackColor) 1 1 ($s.Width - 3) ($s.Height - 3) (Px 9)
        $pc = if ($sel) { $UI.Accent } else { $UI.Line }
        $pw = if ($sel) { 2 } else { 1 }
        $pen = New-Object System.Drawing.Pen($pc, $pw)
        $pp = New-RoundPath 1 1 ($s.Width - 3) ($s.Height - 3) (Px 9)
        $g.DrawPath($pen, $pp); $pp.Dispose(); $pen.Dispose()
        $d = [single](Px 10)
        Fill-Round $g (ToColor $t.AccentColor) (Px 9) (Px 9) $d $d ($d / 2)
        $r = New-Object System.Drawing.Rectangle((Px 8), (Px 24), ($s.Width - (Px 12)), (Px 22))
        [System.Windows.Forms.TextRenderer]::DrawText($g, [string]$s.Tag, $FontSmall, $r, (ToColor $t.TaskColor),
            ([System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter))
    })
    $p.Add_Click({
        param($s, $e)
        $t = $Script:Themes[[string]$s.Tag]
        if ($Script:SettingsOpen) {
            foreach ($k in $t.Keys) { Set-Swatch $Script:SC.Swatch[$k] (ToColor $t[$k]) }
            foreach ($tile in $Script:SC.Tiles) { $tile.Invalidate() }
            Preview-Settings
        } else {
            foreach ($k in $t.Keys) { $Script:Cfg[$k] = $t[$k] }
            Apply-Theme
            foreach ($c in $s.Parent.Controls) { $c.Invalidate() }
        }
    })
    return $p
}

function Set-Swatch($btn, $color) {
    $btn.BackColor = $color
    $btn.Text = ToHex $color
    $btn.ForeColor = if (IsLight $color) { [System.Drawing.Color]::Black } else { [System.Drawing.Color]::White }
    $btn.FlatAppearance.MouseOverBackColor = $color
}

function Read-SettingsControls {
    $sc = $Script:SC; $c = $Script:Cfg
    foreach ($k in $sc.Swatch.Keys) { $c[$k] = ToHex $sc.Swatch[$k].BackColor }
    $c.Opacity             = [int]$sc.Opacity.Value
    $c.FontFamily          = [string]$sc.Font.SelectedItem
    $tf = [string]$sc.TimerFont.SelectedItem
    $c.TimerFontFamily     = if ($tf -eq "Same as text") { "" } else { $tf }
    $c.Shape               = [string]$sc.Shape.SelectedItem
    $c.Width               = [int]$sc.Width.Value
    $c.SquareSize          = [int]$sc.Square.Value
    $c.TimeFontSize        = [int]$sc.TimeSize.Value
    $c.TaskFontSize        = [int]$sc.TaskSize.Value
    $c.CornerRadius        = [int]$sc.Radius.Value
    $c.Animations          = [bool]$sc.Anim.Tag.On
    $c.EdgeLights          = [bool]$sc.Edge.Tag.On
    $c.RedWhenStopped      = [bool]$sc.Red.Tag.On
    $c.BreakLimitMinutes   = [int]$sc.BreakMin.Value
    $c.BreakKeywords       = $sc.BreakWords.Text.Trim()
    $c.AlwaysOnTop         = [bool]$sc.Top.Tag.On
    $c.HideFromCapture     = [bool]$sc.Hide.Tag.On
    $c.ShowSeconds         = [bool]$sc.Seconds.Tag.On
    $c.ShowTodayTotal      = [bool]$sc.Today.Tag.On
    $c.ShowWeekTotal       = [bool]$sc.Week.Tag.On
    $c.ConfirmSwitch       = [bool]$sc.Confirm.Tag.On
    $c.DailyTargetHours    = [double]$sc.Target.Value
    $c.RefreshSeconds      = [int]$sc.Refresh.Value
    $c.AutoCollapseSeconds = [int]$sc.Collapse.Value
    $c.HotkeyEnabled       = [bool]$sc.HotOn.Tag.On
    $c.Hotkey              = $sc.Hot.Text.Trim()
    $c.IdleNudge           = [bool]$sc.Nudge.Tag.On
    $c.IdleNudgeMinutes    = [int]$sc.NudgeMin.Value
    $c.WorkStart           = [string]$sc.WStart.SelectedItem
    $c.WorkEnd             = [string]$sc.WEnd.SelectedItem
    $c.WorkDays            = (@($sc.Days | Where-Object { $_.Tag.On } | ForEach-Object { $_.Tag.Key })) -join ","
}

# Everything previews live on the widget; Cancel puts it all back.
function Preview-Settings {
    if (-not $Script:SettingsLive) { return }
    Read-SettingsControls
    $Script:Anchor = $null; Place-Form
    Apply-Theme
}

function Show-Settings {
    if ($Script:SettingsOpen) { return }
    $Script:SettingsOpen = $true
    $Script:SettingsLive = $false
    $Script:SettingsSaved = $false
    $Script:RunGuideAfter = $false
    $Script:CfgSnap = Copy-Config
    $Script:SC = @{ Swatch = @{}; Tiles = @(); Days = @() }

    $d = New-Dialog "Settings" 500 720
    $f = $d.Form
    $d.Title.Text = "Widget settings"

    $footH = Px 66
    $foot = New-Object System.Windows.Forms.Panel
    $foot.Size = New-Object System.Drawing.Size($f.Width, $footH)
    $foot.Location = New-Object System.Drawing.Point(0, ($f.Height - $footH))
    $foot.BackColor = $UI.Bg
    $f.Controls.Add($foot)
    $fl = New-Object System.Windows.Forms.Panel
    $fl.Size = New-Object System.Drawing.Size($f.Width, 1); $fl.BackColor = $UI.Line
    $foot.Controls.Add($fl)

    $btnReset  = New-FlatButton -Text "Reset" -X 20 -Y 16 -W 80 -H 34 -Ghost
    $btnCancel = New-FlatButton -Text "Cancel" -X 286 -Y 16 -W 90 -H 34
    $btnSave   = New-FlatButton -Text "Save" -X 384 -Y 16 -W 96 -H 34 -Primary
    $Script:SC.Status = New-Label "" 108 16 172 34 $FontSmall $UI.Muted
    $Script:SC.Status.TextAlign = "MiddleLeft"
    foreach ($b in @($btnReset, $Script:SC.Status, $btnCancel, $btnSave)) { $foot.Controls.Add($b) }

    $body = New-Object System.Windows.Forms.Panel
    $body.Location = New-Object System.Drawing.Point(0, (Px 54))
    $body.Size = New-Object System.Drawing.Size($f.Width, ($f.Height - (Px 54) - $footH))
    $body.BackColor = $UI.Bg
    $body.AutoScroll = $true
    $f.Controls.Add($body)
    $Script:SBody = $body

    # layout cursor in logical (96 DPI) pixels
    $Script:SY = 2
    $LX = 24; $CX = 236; $CW = 216; $RowH = 40; $FullW = 428

    function Add-Section([string]$title) {
        $Script:SBody.Controls.Add((New-Label $title.ToUpper() $LX ($Script:SY + 12) 300 16 $FontCaps $UI.Muted))
        $Script:SY += 34
    }
    function Add-RowLabel([string]$text) {
        $Script:SBody.Controls.Add((New-Label $text $LX ($Script:SY + 5) 200 22 $FontUI $UI.Text))
    }
    function Add-Numeric([string]$label, [double]$min, [double]$max, [double]$val, [int]$decimals = 0, [double]$step = 1) {
        Add-RowLabel $label
        $n = New-NumBox $min $max $val $CX $Script:SY $decimals $step
        $n.Add_ValueChanged({ Preview-Settings })
        $Script:SBody.Controls.Add($n)
        $Script:SY += $RowH
        return $n
    }
    function Add-Toggle([string]$label, [bool]$on) {
        $t = New-Toggle $label $on $LX $Script:SY $FullW
        $Script:SBody.Controls.Add($t)
        $Script:SY += 34
        return $t
    }
    function Add-Note([string]$text) {
        $Script:SBody.Controls.Add((New-Label $text $LX ($Script:SY - 6) 420 18 $FontSmall $UI.Muted))
        $Script:SY += 16
    }

    $cfg = $Script:Cfg

    # ================= APPEARANCE =================
    Add-Section "Theme"
    $tileW = 66; $i = 0
    foreach ($name in $Script:Themes.Keys) {
        $tile = New-ThemeTile $name ($LX + $i * ($tileW + 6.4)) $Script:SY $tileW
        $body.Controls.Add($tile)
        $Script:SC.Tiles += $tile
        $i++
    }
    $Script:SY += 62

    Add-Section "Shape"
    Add-RowLabel "Layout"
    $Script:SC.Shape = New-DarkCombo @("Wide", "Square") ([string]$cfg.Shape) $CX $Script:SY 120
    $Script:SC.Shape.Add_SelectedIndexChanged({ Preview-Settings })
    $body.Controls.Add($Script:SC.Shape)
    $Script:SY += $RowH
    $Script:SC.Width  = Add-Numeric "Wide: width (px)"   240 600 $cfg.Width
    $Script:SC.Square = Add-Numeric "Square: size (px)"  150 280 $cfg.SquareSize
    $Script:SC.Radius = Add-Numeric "Corner roundness"   0   40  $cfg.CornerRadius

    Add-Section "Colours"
    $colorFields = @(
        @{ Key = "BackColor";   Label = "Background" },
        @{ Key = "TaskColor";   Label = "Task text" },
        @{ Key = "TimeColor";   Label = "Timer text" },
        @{ Key = "AccentColor"; Label = "Accent" },
        @{ Key = "IdleColor";   Label = "Muted" },
        @{ Key = "ErrorColor";  Label = "Errors" }
    )
    $col = 0
    foreach ($cf in $colorFields) {
        # two swatches per row
        $sx = if ($col -eq 0) { $LX } else { $LX + 218 }
        $body.Controls.Add((New-Label $cf.Label $sx ($Script:SY + 6) 92 20 $FontUI $UI.Text))
        $btn = New-Object System.Windows.Forms.Button
        $btn.Location = New-Object System.Drawing.Point((Px ($sx + 96)), (Px $Script:SY))
        $btn.Size = New-Object System.Drawing.Size((Px 108), (Px 30))
        $btn.FlatStyle = "Flat"
        $btn.UseVisualStyleBackColor = $false
        $btn.FlatAppearance.BorderSize = 1
        $btn.FlatAppearance.BorderColor = $UI.Line
        $btn.Font = $FontSmall
        $btn.Cursor = "Hand"
        Set-Swatch $btn (ToColor $cfg[$cf.Key])
        $btn.Add_Click({
            param($s, $e)
            $dlg = New-Object System.Windows.Forms.ColorDialog
            $dlg.Color = $s.BackColor; $dlg.FullOpen = $true
            if ($dlg.ShowDialog() -eq "OK") {
                Set-Swatch $s $dlg.Color
                foreach ($tile in $Script:SC.Tiles) { $tile.Invalidate() }
                Preview-Settings
            }
            $dlg.Dispose()
        })
        $body.Controls.Add($btn)
        $Script:SC.Swatch[$cf.Key] = $btn
        if ($col -eq 1) { $Script:SY += $RowH; $col = 0 } else { $col = 1 }
    }
    if ($col -eq 1) { $Script:SY += $RowH }

    Add-RowLabel "Background opacity"
    $trk = New-Object System.Windows.Forms.TrackBar
    $trk.Minimum = 30; $trk.Maximum = 100; $trk.TickStyle = "None"
    $trk.Value = [int]$cfg.Opacity
    $trk.Location = New-Object System.Drawing.Point((Px ($CX - 6)), (Px ($Script:SY + 2)))
    $trk.Size = New-Object System.Drawing.Size((Px 170), (Px 30))
    $trk.BackColor = $UI.Bg
    $body.Controls.Add($trk)
    $lblOp = New-Label "$($trk.Value)%" ($CX + 168) ($Script:SY + 5) 50 20 $FontUI $UI.Muted
    $body.Controls.Add($lblOp)
    $Script:SC.OpLabel = $lblOp
    $trk.Add_ValueChanged({ $Script:SC.OpLabel.Text = "$($this.Value)%"; Preview-Settings })
    $Script:SC.Opacity = $trk
    $Script:SY += $RowH

    Add-Section "Fonts"
    $fonts = Get-AvailableFonts
    Add-RowLabel "Text font"
    $Script:SC.Font = New-DarkCombo $fonts ([string]$cfg.FontFamily) $CX $Script:SY $CW -FontPreview
    $Script:SC.Font.Add_SelectedIndexChanged({ Preview-Settings })
    $body.Controls.Add($Script:SC.Font)
    $Script:SY += $RowH
    Add-RowLabel "Timer font"
    $tsel = if ([string]::IsNullOrWhiteSpace($cfg.TimerFontFamily)) { "Same as text" } else { [string]$cfg.TimerFontFamily }
    $Script:SC.TimerFont = New-DarkCombo (@("Same as text") + $fonts) $tsel $CX $Script:SY $CW -FontPreview
    $Script:SC.TimerFont.Add_SelectedIndexChanged({ Preview-Settings })
    $body.Controls.Add($Script:SC.TimerFont)
    $Script:SY += $RowH
    $Script:SC.TimeSize = Add-Numeric "Timer text size"   10  40  $cfg.TimeFontSize
    $Script:SC.TaskSize = Add-Numeric "Task text size"    7   18  $cfg.TaskFontSize
    Add-Note "Try Doto for a Nothing-style dot timer, or Inter for an iPhone look."

    # ================= FOCUS =================
    Add-Section "Focus and breaks"
    $Script:SC.Anim  = Add-Toggle "Smooth animations" ([bool]$cfg.Animations)
    $Script:SC.Edge  = Add-Toggle "Edge lights (dots round the border)" ([bool]$cfg.EdgeLights)
    $Script:SC.Red   = Add-Toggle "Turn red when no timer is running" ([bool]$cfg.RedWhenStopped)
    $Script:SY += 4
    $Script:SC.BreakMin = Add-Numeric "Break allowance (min/day)" 0 600 $cfg.BreakLimitMinutes
    Add-RowLabel "Break tasks contain"
    $Script:SC.BreakWords = New-TextBox $CX $Script:SY $CW ([string]$cfg.BreakKeywords) "break, lunch"
    $Script:SC.BreakWords.Add_Leave({ Preview-Settings })
    $body.Controls.Add($Script:SC.BreakWords)
    $Script:SY += $RowH
    Add-Note "Tasks with these words count as a break. Over the allowance, the widget turns red."

    # ================= WIDGET =================
    Add-Section "Widget"
    $Script:SC.Top     = Add-Toggle "Always on top of other windows" ([bool]$cfg.AlwaysOnTop)
    $Script:SC.Hide    = Add-Toggle "Hide from screen sharing and screenshots" ([bool]$cfg.HideFromCapture)
    $Script:SC.Seconds = Add-Toggle "Show seconds on the timer" ([bool]$cfg.ShowSeconds)
    $Script:SC.Today   = Add-Toggle "Show today's total and progress bar" ([bool]$cfg.ShowTodayTotal)
    $Script:SC.Week    = Add-Toggle "Show this week's total when expanded" ([bool]$cfg.ShowWeekTotal)
    $Script:SC.Confirm = Add-Toggle "Ask before switching to another task" ([bool]$cfg.ConfirmSwitch)
    $Script:SC.Auto    = Add-Toggle "Start automatically when Windows starts" (Test-Autostart)
    $Script:SY += 6
    $Script:SC.Target   = Add-Numeric "Daily target (hours)"       0  24  $cfg.DailyTargetHours 1 0.5
    $Script:SC.Refresh  = Add-Numeric "Refresh every (seconds)"    10 300 $cfg.RefreshSeconds
    $Script:SC.Collapse = Add-Numeric "Auto-collapse after (sec)"  0  300 $cfg.AutoCollapseSeconds
    Add-Note "0 = never collapse. Target 0 hides the progress bar."

    # ================= SHORTCUT =================
    Add-Section "Keyboard shortcut"
    $Script:SC.HotOn = Add-Toggle "Start / stop the timer from anywhere" ([bool]$cfg.HotkeyEnabled)
    Add-RowLabel "Shortcut"
    $hot = New-TextBox $CX $Script:SY $CW ([string]$cfg.Hotkey) "Click, then press keys"
    $hot.ReadOnly = $true
    $hot.BackColor = $UI.Card
    $hot.Cursor = "Hand"
    $hot.Add_KeyDown({
        param($s, $e)
        $e.SuppressKeyPress = $true; $e.Handled = $true
        $k = $e.KeyCode.ToString()
        if ($k -in @("ControlKey", "ShiftKey", "Menu", "LWin", "RWin")) { return }
        if ($k -eq "Back" -or $k -eq "Delete" -or $k -eq "Escape") { return }
        $parts = @()
        if ($e.Control) { $parts += "Ctrl" }
        if ($e.Alt) { $parts += "Alt" }
        if ($e.Shift) { $parts += "Shift" }
        if ($parts.Count -eq 0) { $Script:SC.Status.ForeColor = $UI.Muted; $Script:SC.Status.Text = "Add Ctrl, Alt or Shift"; return }
        $s.Text = (($parts + $k) -join "+")
    })
    $body.Controls.Add($hot)
    $Script:SC.Hot = $hot
    $Script:SY += $RowH
    $hk = if ($Script:HotkeyStatus) { $Script:HotkeyStatus } else { "Click the box and press the keys you want." }
    Add-Note $hk

    # ================= REMINDERS =================
    Add-Section "Reminders"
    $Script:SC.Nudge = Add-Toggle "Remind me when no timer is running in work hours" ([bool]$cfg.IdleNudge)
    $Script:SY += 4
    $Script:SC.NudgeMin = Add-Numeric "Remind after (minutes idle)" 5 240 $cfg.IdleNudgeMinutes

    $slots = @()
    for ($m = 0; $m -lt 24 * 60; $m += 15) { $slots += ("{0:D2}:{1:D2}" -f [int][Math]::Floor($m / 60), ($m % 60)) }
    function Get-Slot([string]$v) {
        $ts = Parse-HHmm $v
        if (-not $ts) { return "09:30" }
        $mins = [int]([Math]::Round($ts.TotalMinutes / 15) * 15) % (24 * 60)
        return ("{0:D2}:{1:D2}" -f [int][Math]::Floor($mins / 60), ($mins % 60))
    }
    Add-RowLabel "Work hours"
    $Script:SC.WStart = New-DarkCombo $slots (Get-Slot $cfg.WorkStart) $CX $Script:SY 90
    $body.Controls.Add($Script:SC.WStart)
    $body.Controls.Add((New-Label "to" ($CX + 96) ($Script:SY + 5) 22 20 $FontUI $UI.Muted))
    $Script:SC.WEnd = New-DarkCombo $slots (Get-Slot $cfg.WorkEnd) ($CX + 122) $Script:SY 90
    $body.Controls.Add($Script:SC.WEnd)
    $Script:SY += $RowH

    Add-RowLabel "Work days"
    $Script:SY += 30
    $dayKeys = @("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
    $on = @(([string]$cfg.WorkDays) -split "," | ForEach-Object { $_.Trim() })
    for ($i = 0; $i -lt 7; $i++) {
        $chipD = New-DayChip $dayKeys[$i] ($on -contains $dayKeys[$i]) ($LX + $i * 46) $Script:SY
        $chipD.Tag.Key = $dayKeys[$i]
        $body.Controls.Add($chipD)
        $Script:SC.Days += $chipD
    }
    $Script:SY += 42

    # ================= ACCOUNT =================
    Add-Section "Account"
    $acct = if ($Script:UserName) { "Connected as $($Script:UserName)" } else { "Connected" }
    if ($Script:LastError -eq "AUTH") { $acct = "Your API token was rejected" }
    $Script:SC.Account = New-Label $acct $LX $Script:SY 420 22 $FontUI $(if ($Script:LastError -eq "AUTH") { $UI.Danger } else { $UI.Text })
    $body.Controls.Add($Script:SC.Account)
    $Script:SY += 28
    $btnKey = New-FlatButton -Text "Change API token" -X $LX -Y $Script:SY -W 140 -H 32
    $btnTest = New-FlatButton -Text "Test connection" -X ($LX + 148) -Y $Script:SY -W 140 -H 32
    $btnGuide = New-FlatButton -Text "Setup guide" -X ($LX + 296) -Y $Script:SY -W 132 -H 32 -Ghost
    foreach ($b in @($btnKey, $btnTest, $btnGuide)) { $body.Controls.Add($b) }
    $btnKey.Add_Click({
        if (Change-ApiKey) {
            $Script:SC.Account.ForeColor = $UI.Text
            $Script:SC.Account.Text = if ($Script:UserName) { "Connected as $($Script:UserName)" } else { "Token saved" }
        }
    })
    $btnTest.Add_Click({
        $Script:SC.Account.ForeColor = $UI.Muted
        $Script:SC.Account.Text = "Checking..."
        Invoke-Api -Requests @(@{ Name = "me"; Path = "/users/me" }) -OnDone {
            param($m)
            $lbl = $Script:SC.Account
            if (-not $lbl -or $lbl.IsDisposed) { return }
            $r = $m["me"]
            if ($r -and $r.Ok) {
                $Script:UserName = [string]$r.Data.name
                $lbl.ForeColor = $UI.Good; $lbl.Text = "Working - connected as $($Script:UserName)"
            } elseif ($r -and ($r.Code -eq 401 -or $r.Code -eq 403)) {
                $lbl.ForeColor = $UI.Danger; $lbl.Text = "Everhour rejected the token"
            } else {
                $lbl.ForeColor = $UI.Danger; $lbl.Text = "Can't reach Everhour - check your internet"
            }
        }
    })
    $btnGuide.Add_Click({ $Script:RunGuideAfter = $true; $this.FindForm().Close() })
    $Script:SY += 44
    $btnLog = New-FlatButton -Text "Open log folder" -X $LX -Y $Script:SY -W 140 -H 30 -Ghost
    $btnLog.Add_Click({ Start-Process explorer.exe $ConfigDir })
    $body.Controls.Add($btnLog)
    $Script:SY += 40
    $body.Controls.Add((New-Label "Everhour Widget v$($Script:Version) - your token is stored encrypted for your Windows user." $LX $Script:SY 428 18 $FontSmall $UI.Muted))
    $Script:SY += 30
    $spacer = New-Object System.Windows.Forms.Panel
    $spacer.Location = New-Object System.Drawing.Point(0, (Px $Script:SY)); $spacer.Size = New-Object System.Drawing.Size(1, 1)
    $body.Controls.Add($spacer)

    # ---- actions ----
    $btnSave.Add_Click({
        Read-SettingsControls
        if ($Script:Cfg.HotkeyEnabled -and -not (Parse-Hotkey $Script:Cfg.Hotkey)) {
            $Script:SC.Status.ForeColor = $UI.Danger
            $Script:SC.Status.Text = "That shortcut isn't valid"
            return
        }
        Save-Config
        if ($Script:SC.Auto.Tag.On) { Install-Autostart | Out-Null } else { Remove-Autostart }
        Register-Hotkey
        Apply-Theme
        $Script:SettingsSaved = $true
        $this.FindForm().Close()
    })
    $btnCancel.Add_Click({ $this.FindForm().Close() })
    $btnReset.Add_Click({
        if (-not (Show-Message "Reset settings?" "Colours, sizes and behaviour go back to the defaults. Your API token and the widget's position are kept." "Reset" "Cancel")) { return }
        foreach ($k in $Script:Defaults.Keys) {
            if ($k -notin @("ApiKey", "ApiKeyProtected", "PosX", "PosY", "LastTaskId", "LastTaskName", "LastStopAt", "OnboardingDone")) { $Script:Cfg[$k] = $Script:Defaults[$k] }
        }
        Save-Config
        Register-Hotkey
        Apply-Theme
        $Script:SettingsSaved = $true
        $this.FindForm().Close()
    })
    $f.Add_FormClosing({
        if (-not $Script:SettingsSaved) {
            # put the preview back, but keep a key changed while the dialog was open
            foreach ($k in $Script:CfgSnap.Keys) {
                if ($k -notin @("ApiKey", "ApiKeyProtected", "PosX", "PosY", "LastTaskId", "LastTaskName", "LastStopAt")) { $Script:Cfg[$k] = $Script:CfgSnap[$k] }
            }
            Save-Config
            $Script:Anchor = $null; Place-Form
            Apply-Theme
        }
    })

    $Script:SettingsLive = $true
    try { [void]$f.ShowDialog() } finally {
        $Script:SettingsLive = $false
        $Script:SettingsOpen = $false
        $f.Dispose()
    }
    if ($Script:RunGuideAfter) { Show-Onboarding | Out-Null }
}

# ===========================================================================
#  TASK PICKER
# ===========================================================================
function Fill-Picker($items, [string]$note) {
    $pk = $Script:PK
    if (-not $pk -or $pk.Form.IsDisposed) { return }
    $pk.Items.Clear()
    $pk.Lb.BeginUpdate()
    $pk.Lb.Items.Clear()
    foreach ($it in @($items)) { if ($it) { [void]$pk.Items.Add($it); [void]$pk.Lb.Items.Add($it.Name) } }
    $pk.Lb.EndUpdate()
    if ($pk.Lb.Items.Count -gt 0) { $pk.Lb.SelectedIndex = 0 }
    $pk.Hint.Text = $note
}

function Load-PickerRecent {
    if (-not $Script:UserId) {
        Invoke-Api -Requests @(@{ Name = "me"; Path = "/users/me" }) -OnDone {
            param($m)
            $r = $m["me"]
            if ($r -and $r.Ok -and $r.Data.id) { $Script:UserId = $r.Data.id; Load-PickerRecent }
            elseif ($Script:PK -and -not $Script:PK.Form.IsDisposed) { $Script:PK.Hint.Text = "Can't reach Everhour - try searching" }
        }
        return
    }
    $from = (Get-Date).AddDays(-21).ToString("yyyy-MM-dd")
    $to = (Get-Date).ToString("yyyy-MM-dd")
    Invoke-Api -Requests @(@{ Name = "recent"; Path = "/users/$($Script:UserId)/time?from=$from&to=$to&limit=500" }) -OnDone {
        param($m)
        $pk = $Script:PK
        if (-not $pk -or $pk.Form.IsDisposed) { return }
        $r = $m["recent"]
        $map = @{}
        if ($r -and $r.Ok) {
            foreach ($rec in @($r.Data)) {
                if (-not $rec -or -not $rec.task -or -not $rec.task.id) { continue }
                $id = [string]$rec.task.id
                $date = [string]$rec.date
                if (-not $map.ContainsKey($id)) { $map[$id] = [pscustomobject]@{ Id = $id; Name = [string]$rec.task.name; Last = $date; Sec = 0; Sub = "" } }
                $e = $map[$id]
                if ($date -gt $e.Last) { $e.Last = $date }
                try { $e.Sec += [int]$rec.time } catch { }
            }
        }
        $last = [string]$Script:Cfg.LastTaskId
        if ($last -and -not $map.ContainsKey($last)) {
            $map[$last] = [pscustomobject]@{ Id = $last; Name = [string]$Script:Cfg.LastTaskName; Last = "9999"; Sec = 0; Sub = "" }
        }
        $items = @($map.Values | Sort-Object @{ Expression = { $_.Id -eq $last }; Descending = $true }, @{ Expression = "Last"; Descending = $true }, @{ Expression = "Sec"; Descending = $true })
        foreach ($it in $items) {
            $parts = @()
            if ($it.Id -eq $last) { $parts += "Last used" }
            if ($it.Last -ne "9999") { $parts += (Format-Day $it.Last) }
            if ($it.Sec -gt 0) { $parts += ((Format-Short $it.Sec) + " in 3 weeks") }
            if (Test-IsBreak $it.Name) { $parts += "break" }
            $it.Sub = $parts -join "  |  "
        }
        $pk.Recent = $items
        if ($pk.Tb.Text.Trim().Length -lt 2) {
            if ($items.Count -gt 0) { Fill-Picker $items "Tasks you've tracked recently" }
            elseif ($r -and $r.Ok) { Fill-Picker @() "No recent tasks - search for one above" }
            else { Fill-Picker @() "Can't reach Everhour - try again in a moment" }
        }
    }
}

function Run-PickerSearch {
    $pk = $Script:PK
    if (-not $pk -or $pk.Form.IsDisposed) { return }
    $q = $pk.Tb.Text.Trim()
    if ($q.Length -lt 2) { Fill-Picker $pk.Recent "Tasks you've tracked recently"; return }
    $pk.Hint.Text = "Searching..."
    $enc = [System.Uri]::EscapeDataString($q)
    $pk.Query = $q
    Invoke-Api -Requests @(@{ Name = "search"; Path = "/tasks/search?query=$enc&limit=50" }) -OnDone {
        param($m)
        $pk = $Script:PK
        if (-not $pk -or $pk.Form.IsDisposed) { return }
        if ($pk.Tb.Text.Trim() -ne $pk.Query) { return }   # user kept typing
        $r = $m["search"]
        if (-not $r -or -not $r.Ok) { Fill-Picker $pk.Recent "Search unavailable - showing recent tasks"; return }
        $items = @()
        foreach ($t in @($r.Data)) {
            if (-not $t -or -not $t.id) { continue }
            $sub = ""
            try { if ($t.time -and $t.time.total) { $sub = "Total " + (Format-Short ([int]$t.time.total)) } } catch { }
            $items += [pscustomobject]@{ Id = [string]$t.id; Name = [string]$t.name; Sub = $sub }
        }
        if ($items.Count -gt 0) { Fill-Picker $items "$($items.Count) result(s) for '$($pk.Query)'" }
        else { Fill-Picker @() "No tasks match '$($pk.Query)'" }
    }
}

function Show-TaskPicker {
    if ($Script:PickerOpen) { return }
    $Script:PickerOpen = $true
    $d = New-Dialog "Start a timer" 500 540
    $f = $d.Form

    $tb = New-TextBox 22 60 456 "" "Search all tasks..."
    $f.Controls.Add($tb)

    $lb = New-Object System.Windows.Forms.ListBox
    $lb.DrawMode = "OwnerDrawFixed"
    $lb.ItemHeight = Px 42
    $lb.IntegralHeight = $false
    $lb.Font = $FontUI
    $lb.BorderStyle = "None"
    $lb.BackColor = $UI.Card; $lb.ForeColor = $UI.Text
    $lb.Location = New-Object System.Drawing.Point((Px 22), (Px 100))
    $lb.Size = New-Object System.Drawing.Size((Px 456), (Px 290))
    $f.Controls.Add($lb)
    $lb.Add_DrawItem({
        param($s, $e)
        if ($e.Index -lt 0 -or $e.Index -ge $Script:PK.Items.Count) { return }
        $it = $Script:PK.Items[$e.Index]
        $g = $e.Graphics
        $sel = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
        $bg = if ($sel) { $UI.Sel } else { $UI.Card }
        $br = New-Object System.Drawing.SolidBrush($bg); $g.FillRectangle($br, $e.Bounds); $br.Dispose()
        if ($sel) {
            $ab = New-Object System.Drawing.SolidBrush($UI.Accent)
            $g.FillRectangle($ab, $e.Bounds.X, ($e.Bounds.Y + (Px 8)), (Px 3), ($e.Bounds.Height - (Px 16))); $ab.Dispose()
        }
        $flags = [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor
                 [System.Windows.Forms.TextFormatFlags]::EndEllipsis -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix
        $x = $e.Bounds.X + (Px 14); $w = $e.Bounds.Width - (Px 24)
        if ($it.Sub) {
            $r1 = New-Object System.Drawing.Rectangle($x, ($e.Bounds.Y + (Px 3)), $w, (Px 20))
            $r2 = New-Object System.Drawing.Rectangle($x, ($e.Bounds.Y + (Px 21)), $w, (Px 18))
            [System.Windows.Forms.TextRenderer]::DrawText($g, $it.Name, $FontUI, $r1, $UI.Text, $flags)
            [System.Windows.Forms.TextRenderer]::DrawText($g, $it.Sub, $FontSmall, $r2, $UI.Muted, $flags)
        } else {
            $r1 = New-Object System.Drawing.Rectangle($x, $e.Bounds.Y, $w, $e.Bounds.Height)
            [System.Windows.Forms.TextRenderer]::DrawText($g, $it.Name, $FontUI, $r1, $UI.Text, $flags)
        }
    })

    $note = New-TextBox 22 402 456 "" "Note for this entry (optional)"
    $f.Controls.Add($note)

    $hint = New-Label "Loading recent tasks..." 22 446 250 40 $FontSmall $UI.Muted
    if ($Script:IsRunning) { $hint.Text = "Now tracking: $($Script:TaskName)" }
    $f.Controls.Add($hint)

    $btnCancel = New-FlatButton -Text "Cancel" -X 280 -Y 482 -W 92 -H 36
    $btnGo = New-FlatButton -Text "Start" -X 380 -Y 482 -W 98 -H 36 -Primary
    $f.Controls.Add($btnCancel); $f.Controls.Add($btnGo)

    $deb = New-Object System.Windows.Forms.Timer
    $deb.Interval = 350
    $deb.Add_Tick({ $this.Stop(); Run-PickerSearch })

    $Script:PK = @{ Form = $f; Tb = $tb; Lb = $lb; Note = $note; Hint = $hint; Items = (New-Object System.Collections.ArrayList); Recent = @(); Query = ""; Deb = $deb }

    $tb.Add_TextChanged({ $Script:PK.Deb.Stop(); $Script:PK.Deb.Start() })
    $tb.Add_KeyDown({
        param($s, $e)
        $lb = $Script:PK.Lb
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Down -and $lb.Items.Count -gt 0) {
            $lb.SelectedIndex = [Math]::Min($lb.Items.Count - 1, $lb.SelectedIndex + 1); $e.Handled = $true
        } elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Up -and $lb.Items.Count -gt 0) {
            $lb.SelectedIndex = [Math]::Max(0, $lb.SelectedIndex - 1); $e.Handled = $true
        } elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $e.SuppressKeyPress = $true; Start-PickedTask
        }
    })
    $lb.Add_DoubleClick({ Start-PickedTask })
    $lb.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { $e.SuppressKeyPress = $true; Start-PickedTask } })
    $note.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { $e.SuppressKeyPress = $true; Start-PickedTask } })
    $btnGo.Add_Click({ Start-PickedTask })
    $btnCancel.Add_Click({ $Script:PK.Form.Close() })

    Load-PickerRecent
    $f.Add_Shown({ $Script:PK.Tb.Focus() | Out-Null })
    try { [void]$f.ShowDialog() } finally {
        $deb.Stop(); $deb.Dispose()
        $f.Dispose()
        $Script:PickerOpen = $false
    }
}

function Start-PickedTask {
    $pk = $Script:PK
    if ($pk.Lb.SelectedIndex -lt 0 -or $pk.Lb.SelectedIndex -ge $pk.Items.Count) { $pk.Hint.Text = "Pick a task first."; return }
    $sel = $pk.Items[$pk.Lb.SelectedIndex]
    if ($Script:IsRunning -and $sel.Id -eq $Script:TaskId) { $pk.Hint.Text = "That task is already running."; return }
    if ($Script:IsRunning -and $Script:Cfg.ConfirmSwitch) {
        $ok = Show-Message "Switch task?" "Stop '$($Script:TaskName)' and start '$($sel.Name)'?" "Switch" "Cancel"
        if (-not $ok) { return }
    }
    Start-Timer $sel.Id $sel.Name $pk.Note.Text
    $pk.Form.Close()
}

# ===========================================================================
#  SETUP GUIDE  (first run, and again from Settings / the menu)
#  Animated walkthrough of where the API token lives in Everhour, then a
#  few questions to make the widget yours.
# ===========================================================================
function Ease([double]$x) { if ($x -le 0) { return 0.0 }; if ($x -ge 1) { return 1.0 }; return $x * $x * (3 - 2 * $x) }
function Seg([double]$t, [double]$a, [double]$b) { return Ease (($t - $a) / ($b - $a)) }
function Lerp([double]$a, [double]$b, [double]$p) { return $a + ($b - $a) * $p }

$Script:SceneF = @{}
function Get-SceneFont([double]$px, [switch]$Bold) {
    $key = "$px|$Bold"
    if (-not $Script:SceneF.ContainsKey($key)) {
        $st = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
        $fam = Get-FontFamilyObj "Inter"
        if (-not $fam.IsStyleAvailable($st)) { $st = [System.Drawing.FontStyle]::Regular }
        $Script:SceneF[$key] = New-Object System.Drawing.Font($fam, [single]$px, $st, [System.Drawing.GraphicsUnit]::Pixel)
    }
    return $Script:SceneF[$key]
}

function Draw-Cursor($g, [single]$x, [single]$y) {
    $pts = [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF($x, $y)), (New-Object System.Drawing.PointF($x, ($y + 17))),
        (New-Object System.Drawing.PointF(($x + 4), ($y + 13))), (New-Object System.Drawing.PointF(($x + 7.5), ($y + 20))),
        (New-Object System.Drawing.PointF(($x + 10), ($y + 19))), (New-Object System.Drawing.PointF(($x + 6.5), ($y + 12))),
        (New-Object System.Drawing.PointF(($x + 12), ($y + 12))))
    $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White); $g.FillPolygon($b, $pts); $b.Dispose()
    $p = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, 1.2); $g.DrawPolygon($p, $pts); $p.Dispose()
}
function Draw-Ripple($g, [single]$x, [single]$y, [double]$p) {
    if ($p -le 0 -or $p -ge 1) { return }
    $r = 5 + 20 * $p
    $pen = New-Object System.Drawing.Pen((A ([System.Drawing.Color]::White) ([int](200 * (1 - $p)))), 2)
    $g.DrawEllipse($pen, ($x - $r), ($y - $r), (2 * $r), (2 * $r)); $pen.Dispose()
}
function Draw-Pill($g, [string]$text, $bg, $fg, [single]$x, [single]$y, [double]$alpha = 1) {
    $f = Get-SceneFont 11 -Bold
    $w = (Measure-W $text $f) + 16
    Fill-Round $g (A $bg ([int](255 * $alpha))) $x $y $w 24 12
    Draw-Text $g $text $f (A $fg ([int](255 * $alpha))) $x $y $w 24 "Center"
}
function Draw-Check($g, $color, [single]$x, [single]$y, [single]$s) {
    $p = New-Object System.Drawing.Pen($color, [single]2.2); $p.StartCap = "Round"; $p.EndCap = "Round"
    $g.DrawLines($p, [System.Drawing.PointF[]]@((New-Object System.Drawing.PointF($x, ($y + $s * 0.5))),
        (New-Object System.Drawing.PointF(($x + $s * 0.38), ($y + $s * 0.85))), (New-Object System.Drawing.PointF(($x + $s), $y))))
    $p.Dispose()
}

# Scene 1: click your name at the bottom-left, then "My Profile".
function Draw-SceneProfile($g, [double]$t) {
    $W = 512; $H = 236
    $t = $t % 6.4
    Fill-Round $g (ToColor "#1A1A1C") 0 0 $W $H 12
    Fill-Round $g (ToColor "#222224") 0 0 200 $H 12
    $bar = ToColor "#303034"
    for ($i = 0; $i -lt 4; $i++) {
        Fill-Circle $g $bar 22 (22 + $i * 28) 6
        Fill-Round $g $bar 36 (18 + $i * 28) (70 + ($i * 23) % 50) 8 4
    }
    for ($i = 0; $i -lt 5; $i++) { Fill-Round $g (ToColor "#262629") 220 (22 + $i * 38) (260 - ($i * 37) % 90) 22 6 }
    $sep = New-Object System.Drawing.Pen((ToColor "#333337"), 1); $g.DrawLine($sep, 0, ($H - 44), 200, ($H - 44)); $sep.Dispose()
    Fill-Circle $g (ToColor "#5A6B7D") 28 ($H - 22) 12
    Draw-Text $g "Your name" (Get-SceneFont 12.5) (ToColor "#E6E6E6") 48 ($H - 32) 140 20 "Left"

    $mp = Seg $t 1.45 1.9
    if ($mp -gt 0) {
        $my = 8 + (1 - $mp) * 18
        $aa = [int](255 * $mp)
        Fill-Round $g (A (ToColor "#2A2A2D") $aa) 8 $my 186 172 8
        Fill-Round $g (A (ToColor "#E5A82E") $aa) 22 ($my + 10) 158 28 4
        Draw-Text $g "Clock-Out" (Get-SceneFont 12 -Bold) (A (ToColor "#FFFFFF") $aa) 22 ($my + 10) 158 28 "Center"
        Draw-Text $g "You've clocked in at 10:32 am" (Get-SceneFont 10) (A (ToColor "#BDBDBD") $aa) 8 ($my + 42) 186 16 "Center"
        $items = @("My Profile", "Integrations", "Request a Demo", "Help Docs", "Sign Out")
        $hov = Seg $t 2.6 2.8
        for ($i = 0; $i -lt $items.Count; $i++) {
            $iy = $my + 64 + $i * 21
            if ($i -eq 0 -and $hov -gt 0) { Fill-Round $g (A (ToColor "#3A3A3F") ([int]($aa * $hov))) 12 $iy 178 21 4 }
            $c = if ($i -eq 4) { ToColor "#E5534B" } else { ToColor "#ECECEC" }
            Draw-Text $g $items[$i] (Get-SceneFont 12) (A $c $aa) 20 $iy 170 21 "Left"
        }
    }
    # cursor path: in from the right -> your name -> My Profile
    $p1 = Seg $t 0.2 1.2; $p2 = Seg $t 1.95 2.7
    $cx = Lerp (Lerp 440 70 $p1) 72 $p2
    $cy = Lerp (Lerp 70 ($H - 24) $p1) 82 $p2
    Draw-Ripple $g 70 ($H - 24) (($t - 1.25) / 0.45)
    Draw-Ripple $g 72 82 (($t - 2.95) / 0.45)
    if ($t -gt 3.1 -and $t -lt 5.8) { Draw-Pill $g "Open My Profile" $UI.Accent ([System.Drawing.Color]::White) 210 70 (Seg $t 3.1 3.4) }
    Draw-Cursor $g $cx $cy
    if ($t -gt 5.9) { $fb = New-Object System.Drawing.SolidBrush((A (ToColor "#17171B") ([int](255 * (Seg $t 5.9 6.4))))); $g.FillRectangle($fb, 0, 0, $W, $H); $fb.Dispose() }
}

# Scene 2: scroll down to Application Access and copy the API Token.
function Draw-SceneToken($g, [double]$t) {
    $W = 512; $H = 236
    $t = $t % 7.2
    Fill-Round $g (ToColor "#1A1A1C") 0 0 $W $H 12
    $g.SetClip((New-Object System.Drawing.RectangleF(0, 0, $W, $H)))
    $scroll = (Seg $t 0.7 2.4) * 250
    $g.TranslateTransform(0, [single](-$scroll))
    Draw-Text $g "My Profile" (Get-SceneFont 17 -Bold) (ToColor "#F0F0F0") 24 14 300 28 "Left"
    $fields = @("Full name", "Email", "Time zone", "Week starts on")
    for ($i = 0; $i -lt $fields.Count; $i++) {
        $fy = 56 + $i * 58
        Draw-Text $g $fields[$i] (Get-SceneFont 10.5) (ToColor "#9A9A9A") 24 $fy 200 16 "Left"
        Fill-Round $g (ToColor "#262629") 24 ($fy + 18) 300 28 4
        Fill-Round $g (ToColor "#3A3A3E") 34 ($fy + 29) (80 + ($i * 41) % 90) 7 3
    }
    Draw-Text $g "Application Access" (Get-SceneFont 17 -Bold) (ToColor "#F0F0F0") 24 300 300 28 "Left"
    $sp = New-Object System.Drawing.Pen((ToColor "#333337"), 1); $g.DrawLine($sp, 24, 332, 488, 332); $sp.Dispose()
    Draw-Text $g "API Token" (Get-SceneFont 11) (ToColor "#BDBDBD") 24 344 120 18 "Left"
    Fill-Round $g (ToColor "#3A3A3E") 24 366 300 36 4
    Fill-Round $g (ToColor "#7CCBFF") 34 377 230 14 2
    Fill-Round $g (ToColor "#2E2E31") 324 366 36 36 4
    $ip = New-Object System.Drawing.Pen((ToColor "#D0D0D0"), 1.4)
    $g.DrawRectangle($ip, 335, 375, 11, 13); $g.DrawRectangle($ip, 339, 379, 11, 13); $ip.Dispose()
    Draw-Text $g "Reset Token" (Get-SceneFont 12) (ToColor "#CFCFCF") 372 366 120 36 "Left"
    for ($i = 0; $i -lt 3; $i++) { Fill-Round $g (ToColor "#262629") 24 (430 + $i * 34) 380 22 6 }
    $g.ResetTransform()
    $g.ResetClip()
    # scrollbar
    Fill-Round $g (ToColor "#2A2A2D") ($W - 10) 8 4 ($H - 16) 2
    Fill-Round $g (ToColor "#5A5A60") ($W - 10) (8 + ($scroll / 250) * ($H - 16 - 70)) 4 70 2

    $btnY = 384 - $scroll
    $p = Seg $t 2.6 3.5
    $cx = Lerp 300 342 $p; $cy = Lerp 120 $btnY $p
    if ($t -gt 0.6 -and $t -lt 2.5) {
        # mouse-wheel hint while scrolling
        $wf = Get-SceneFont 14 -Bold
        Draw-Text $g ([string][char]0x2193) $wf (A ([System.Drawing.Color]::White) ([int](120 + 120 * [Math]::Sin($t * 9)))) 316 112 20 24 "Center"
    }
    Draw-Ripple $g 342 $btnY (($t - 3.6) / 0.45)
    if ($t -gt 3.7 -and $t -lt 6.6) {
        $ap = Seg $t 3.7 3.95
        Draw-Pill $g "Copied!" $UI.Good ([System.Drawing.Color]::Black) 318 ($btnY - 52) $ap
    }
    if ($t -gt 1.6 -and $t -lt 6.6) { Draw-Pill $g "Copy the API Token" $UI.Accent ([System.Drawing.Color]::White) 24 ($btnY + 26) (Seg $t 1.6 1.9) }
    Draw-Cursor $g $cx $cy
    if ($t -gt 6.7) { $fb = New-Object System.Drawing.SolidBrush((A (ToColor "#17171B") ([int](255 * (Seg $t 6.7 7.2))))); $g.FillRectangle($fb, 0, 0, $W, $H); $fb.Dispose() }
}

# Scene 3: Ctrl+V into the box, Connect, connected.
function Draw-ScenePaste($g, [double]$t) {
    $W = 512; $H = 236
    $t = $t % 5.6
    Fill-Round $g (ToColor "#1A1A1C") 0 0 $W $H 12
    Draw-Text $g "API token" (Get-SceneFont 11) (ToColor "#9A9A9A") 24 40 200 18 "Left"
    $focus = Seg $t 0.2 0.5
    Fill-Round $g (ToColor "#222228") 24 62 464 40 6
    $bp = New-Object System.Drawing.Pen((Mix (ToColor "#33333B") $UI.Accent $focus), 1.5)
    $pp = New-RoundPath 24 62 464 40 6; $g.DrawPath($bp, $pp); $pp.Dispose(); $bp.Dispose()
    $press = if ($t -gt 0.9 -and $t -lt 1.3) { 1 } else { 0 }
    $keys = @(@{ T = "Ctrl"; X = 196; W = 60 }, @{ T = "V"; X = 266; W = 44 })
    foreach ($k in $keys) {
        $ky = 128 + 3 * $press
        Fill-Round $g (ToColor "#0E0E11") $k.X (128 + 4) $k.W 38 7
        Fill-Round $g $(if ($press) { $UI.Accent } else { ToColor "#2C2C34" }) $k.X $ky $k.W 38 7
        Draw-Text $g $k.T (Get-SceneFont 13 -Bold) ([System.Drawing.Color]::White) $k.X $ky $k.W 38 "Center"
    }
    Draw-Text $g "+" (Get-SceneFont 14 -Bold) (ToColor "#8B8B96") 256 128 10 38 "Center"
    $dots = [int][Math]::Min(26, [Math]::Max(0, ($t - 1.25) * 70))
    if ($dots -gt 0) { Draw-Text $g ([string]([char]0x2022) * $dots) (Get-SceneFont 14) (ToColor "#E8E8ED") 36 62 440 40 "Left" }
    elseif ($t -lt 1.25 -and ([int]($t * 3) % 2 -eq 0)) {
        $cp = New-Object System.Drawing.Pen((ToColor "#E8E8ED"), 1.5); $g.DrawLine($cp, 37, 72, 37, 92); $cp.Dispose()
    }
    $pressC = if ($t -gt 2.5 -and $t -lt 2.8) { $UI.AccentH } else { $UI.Accent }
    Fill-Round $g $pressC 380 186 108 34 7
    Draw-Text $g "Connect" (Get-SceneFont 12.5 -Bold) ([System.Drawing.Color]::White) 380 186 108 34 "Center"
    if ($t -gt 2.9) {
        $ap = [int](255 * (Seg $t 2.9 3.2))
        Draw-Check $g (A $UI.Good $ap) 26 196 14
        Draw-Text $g "Connected - you're good to go" (Get-SceneFont 12.5 -Bold) (A $UI.Good $ap) 48 186 300 34 "Left"
    }
    $p = Seg $t 1.6 2.4
    Draw-Cursor $g (Lerp 330 432 $p) (Lerp 150 203 $p)
    Draw-Ripple $g 432 203 (($t - 2.55) / 0.45)
    if ($t -gt 5.1) { $fb = New-Object System.Drawing.SolidBrush((A (ToColor "#17171B") ([int](255 * (Seg $t 5.1 5.6))))); $g.FillRectangle($fb, 0, 0, $W, $H); $fb.Dispose() }
}

# A widget frame drawn with sample data, for the guide.
$Script:DemoVars = @("IsRunning", "TaskId", "TaskName", "BaseDuration", "TimerToday", "LastPollAt", "RecordsLoaded", "WeekLoaded",
                     "TodayByTask", "TodayRecordsTotal", "WeekRecordsTotal", "FirstPollDone", "LastError", "IsExpanded", "Hover",
                     "Toast", "Hits", "StoppedSince")
$Script:DemoPal = $null
function Build-DemoFrame([string]$mode, [double]$t) {
    $saved = @{}
    foreach ($n in $Script:DemoVars) { $saved[$n] = (Get-Variable -Scope Script -Name $n).Value }
    try {
        $Script:FirstPollDone = $true; $Script:LastError = ""; $Script:IsExpanded = $false; $Script:Hover = ""; $Script:Toast = ""
        $Script:RecordsLoaded = $true; $Script:LastPollAt = Get-Date
        $Script:TodayByTask = @{ "d1" = @{ Name = "Website redesign"; Sec = 7800 }; "d2" = @{ Name = "Break Time"; Sec = 1200 } }
        $Script:TodayRecordsTotal = 9000
        switch ($mode) {
            "work"      { $Script:IsRunning = $true; $Script:TaskId = "d1"; $Script:TaskName = "Website redesign"; $Script:BaseDuration = 2722 + [int]$t; $Script:TimerToday = 7800 + [int]$t }
            "break"     { $Script:IsRunning = $true; $Script:TaskId = "d2"; $Script:TaskName = "Break Time"; $Script:BaseDuration = 600 + [int]$t; $Script:TimerToday = 1200 + [int]$t }
            "overbreak" { $Script:IsRunning = $true; $Script:TaskId = "d2"; $Script:TaskName = "Break Time"; $Script:BaseDuration = 1500 + [int]$t; $Script:TimerToday = 4100 + [int]$t
                          $Script:TodayByTask["d2"].Sec = 4100 }
            default     { $Script:IsRunning = $false; $Script:TaskId = ""; $Script:TaskName = ""; $Script:StoppedSince = (Get-Date).AddSeconds(-1380 - $t) }
        }
        $target = Get-ModePalette $mode
        if (-not $Script:DemoPal) { $Script:DemoPal = @{}; foreach ($k in $target.Keys) { $Script:DemoPal[$k] = $target[$k] } }
        else { Step-Pal $Script:DemoPal $target 0.12 | Out-Null }
        return Build-Frame $Script:DemoPal $mode
    } finally {
        foreach ($n in $Script:DemoVars) { Set-Variable -Scope Script -Name $n -Value $saved[$n] }
    }
}

function Get-GuideTime {
    if ($RenderPreview) { return @(0, 3.6, 4.3, 3.6, 0, 0, 0)[$Script:OB.Step] + 0.0 }
    return $Script:OB.Clock.Elapsed.TotalSeconds
}

function Draw-GuideStage($g, [int]$step) {
    $t = Get-GuideTime
    switch ($step) {
        1 { Draw-SceneProfile $g $t }
        2 { Draw-SceneToken $g $t }
        3 { Draw-ScenePaste $g $t }
        default {
            Fill-Round $g (ToColor "#121215") 0 0 512 236 12
            $modes = @("work", "break", "overbreak", "stopped")
            $names = @("Working", "On a break", "Break over the limit", "Timer off")
            $idx = if ($step -eq 4) { 0 } else { [int][Math]::Floor($t / 3.5) % 4 }
            if ($RenderPreview -and $step -eq 0) { $idx = 0 }
            if ($RenderPreview -and $step -eq 5) { $idx = 1 }
            if ($RenderPreview -and $step -eq 6) { $idx = 3 }
            if ($step -eq 5 -and -not $RenderPreview) { $idx = 1 + [int][Math]::Floor($t / 3.5) % 3 }
            $bmp = Build-DemoFrame $modes[$idx] $t
            $state = $g.Save()
            $g.ResetTransform()
            $sx = [int]((Px 512) - $bmp.Width) / 2; $sy = [int]((Px 206) - $bmp.Height) / 2
            $g.DrawImage($bmp, $sx, $sy, $bmp.Width, $bmp.Height)
            $g.Restore($state)
            $bmp.Dispose()
            Draw-Text $g $names[$idx] (Get-SceneFont 11 -Bold) (ToColor "#8B8B96") 0 206 512 24 "Center"
        }
    }
}

function Show-Onboarding {
    if ($Script:GuideOpen) { return $false }
    $Script:GuideOpen = $true
    $hadKey = -not [string]::IsNullOrWhiteSpace((Get-ApiKey))
    $Script:OB = @{ Step = 0; Clock = [Diagnostics.Stopwatch]::StartNew(); Done = $false; Busy = $false; Groups = @{}; HadKey = $hadKey }
    $d = New-Dialog "Set up your widget" 560 652
    $f = $d.Form
    $ob = $Script:OB
    $ob.Form = $f

    $stage = New-Object System.Windows.Forms.Panel
    $stage.Location = New-Object System.Drawing.Point((Px 24), (Px 56))
    $stage.Size = New-Object System.Drawing.Size((Px 512), (Px 236))
    $stage.BackColor = $UI.Bg
    Set-DoubleBuffered $stage
    $stage.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $g.ScaleTransform([single]$Script:Scale, [single]$Script:Scale)
        try { Draw-GuideStage $g $Script:OB.Step } catch { Write-Log "Guide draw failed: $($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)" }
    })
    $f.Controls.Add($stage)
    $ob.Stage = $stage

    $ob.Title = New-Label "" 24 304 512 30 $FontHero $UI.Text
    $ob.Body = New-Label "" 24 338 512 46 $FontUI $UI.Muted
    $f.Controls.Add($ob.Title); $f.Controls.Add($ob.Body)

    $content = New-Object System.Windows.Forms.Panel
    $content.Location = New-Object System.Drawing.Point((Px 24), (Px 390))
    $content.Size = New-Object System.Drawing.Size((Px 512), (Px 186))
    $content.BackColor = $UI.Bg
    $f.Controls.Add($content)
    $ob.Content = $content

    function Add-To([int]$step, $ctrl) {
        if (-not $Script:OB.Groups.ContainsKey($step)) { $Script:OB.Groups[$step] = @() }
        $Script:OB.Groups[$step] += $ctrl
        $Script:OB.Content.Controls.Add($ctrl)
    }

    # step 1: open Everhour
    $bOpen = New-FlatButton -Text "Open Everhour in my browser" -X 0 -Y 0 -W 240 -H 36
    $bOpen.Add_Click({ Start-Process "https://app.everhour.com/" })
    Add-To 1 $bOpen
    Add-To 1 (New-Label "Already open? Just follow the animation above." 0 46 500 20 $FontSmall $UI.Muted)

    # step 2: nothing to fill in
    Add-To 2 (New-Label "Tip: the token is personal - treat it like a password." 0 0 500 20 $FontSmall $UI.Muted)

    # step 3: paste + connect
    $kb = New-TextBox 0 2 392 "" "Paste your API token here"
    $kb.UseSystemPasswordChar = $true
    Add-To 3 $kb
    $ob.KeyBox = $kb
    $bPaste = New-FlatButton -Text "Paste" -X 400 -Y 0 -W 112 -H 30
    $bPaste.Add_Click({
        try { $clip = [System.Windows.Forms.Clipboard]::GetText().Trim(); if ($clip) { $Script:OB.KeyBox.Text = $clip } } catch { }
    })
    Add-To 3 $bPaste
    $show = New-Object System.Windows.Forms.CheckBox
    $show.Text = "Show token"; $show.Font = $FontSmall; $show.ForeColor = $UI.Muted
    $show.Location = New-Object System.Drawing.Point(0, (Px 38))
    $show.Size = New-Object System.Drawing.Size((Px 140), (Px 22))
    $show.Add_CheckedChanged({ $Script:OB.KeyBox.UseSystemPasswordChar = -not $this.Checked })
    Add-To 3 $show
    $ob.KeyStatus = New-Label "" 0 64 512 44 $FontUI $UI.Muted
    Add-To 3 $ob.KeyStatus
    Add-To 3 (New-Label "Stored encrypted on this PC. Only ever sent to api.everhour.com." 0 112 512 20 $FontSmall $UI.Muted)

    # step 4: look
    $i = 0
    $tilePanel = New-Object System.Windows.Forms.Panel
    $tilePanel.Location = New-Object System.Drawing.Point(0, 0)
    $tilePanel.Size = New-Object System.Drawing.Size((Px 512), (Px 52))
    $tilePanel.BackColor = $UI.Bg
    foreach ($name in $Script:Themes.Keys) { $tilePanel.Controls.Add((New-ThemeTile $name ($i * 86) 0 80 50)); $i++ }
    Add-To 4 $tilePanel
    Add-To 4 (New-Label "Font" 0 70 120 22 $FontUI $UI.Text)
    $fonts = Get-AvailableFonts
    $ob.FontBox = New-DarkCombo $fonts ([string]$Script:Cfg.FontFamily) 130 66 250 -FontPreview
    $ob.FontBox.Add_SelectedIndexChanged({ $Script:Cfg.FontFamily = [string]$this.SelectedItem; Apply-Theme })
    Add-To 4 $ob.FontBox
    Add-To 4 (New-Label "Shape" 0 110 120 22 $FontUI $UI.Text)
    $ob.ShapeBox = New-DarkCombo @("Wide", "Square") ([string]$Script:Cfg.Shape) 130 106 120
    $ob.ShapeBox.Add_SelectedIndexChanged({ $Script:Cfg.Shape = [string]$this.SelectedItem; $Script:Anchor = $null; Place-Form; Apply-Theme })
    Add-To 4 $ob.ShapeBox
    Add-To 4 (New-Label "Everything can be changed later in Settings." 0 150 500 20 $FontSmall $UI.Muted)

    # step 5: workday
    Add-To 5 (New-Label "Daily target (hours)" 0 4 200 22 $FontUI $UI.Text)
    $ob.Target = New-NumBox 0 24 ([double]$Script:Cfg.DailyTargetHours) 220 0 1 0.5
    Add-To 5 $ob.Target
    Add-To 5 (New-Label "Break allowance (min/day)" 0 40 200 22 $FontUI $UI.Text)
    $ob.Break = New-NumBox 0 600 ([double]$Script:Cfg.BreakLimitMinutes) 220 36
    Add-To 5 $ob.Break
    Add-To 5 (New-Label "Break tasks contain" 0 76 200 22 $FontUI $UI.Text)
    $ob.Words = New-TextBox 220 72 220 ([string]$Script:Cfg.BreakKeywords) "break, lunch"
    Add-To 5 $ob.Words
    $ob.Red = New-Toggle "Turn red when no timer is running" ([bool]$Script:Cfg.RedWhenStopped) 0 112 512
    Add-To 5 $ob.Red
    $ob.Auto = New-Toggle "Start automatically when Windows starts" $true 0 146 512
    Add-To 5 $ob.Auto

    # step 6: tips
    $tips = "Round button - start / stop (resumes your last task)`r`nClick the widget - today's time, task by task`r`nRight-click - start a task, settings, exit`r`n$($Script:Cfg.Hotkey) - start / stop from anywhere"
    Add-To 6 (New-Label $tips 0 0 512 92 $FontUI $UI.Text)

    # footer
    $dots = New-Object System.Windows.Forms.Panel
    $dots.Location = New-Object System.Drawing.Point((Px 24), (Px 606))
    $dots.Size = New-Object System.Drawing.Size((Px 160), (Px 16))
    $dots.BackColor = $UI.Bg
    Set-DoubleBuffered $dots
    $dots.Add_Paint({
        param($s, $e)
        $g = $e.Graphics; $g.SmoothingMode = "AntiAlias"
        for ($i = 0; $i -lt 7; $i++) {
            $w = if ($i -eq $Script:OB.Step) { Px 18 } else { Px 6 }
            $x = 0; for ($j = 0; $j -lt $i; $j++) { $x += $(if ($j -eq $Script:OB.Step) { Px 18 } else { Px 6 }) + (Px 6) }
            $c = if ($i -le $Script:OB.Step) { $UI.Accent } else { $UI.Line }
            Fill-Round $g $c $x (Px 5) $w (Px 6) (Px 3)
        }
    })
    $f.Controls.Add($dots)
    $ob.Dots = $dots
    $ob.Back = New-FlatButton -Text "Back" -X 320 -Y 596 -W 92 -H 38 -Ghost
    $ob.Next = New-FlatButton -Text "Next" -X 420 -Y 596 -W 116 -H 38 -Primary
    $f.Controls.Add($ob.Back); $f.Controls.Add($ob.Next)
    $ob.Back.Add_Click({ Show-GuideStep ($Script:OB.Step - 1) })
    $ob.Next.Add_Click({ Guide-Next })
    $f.AcceptButton = $ob.Next

    $anim = New-Object System.Windows.Forms.Timer
    $anim.Interval = 40
    $anim.Add_Tick({ $Script:OB.Stage.Invalidate() })
    $ob.Anim = $anim

    Show-GuideStep 0
    $f.Add_Shown({ $Script:OB.Anim.Start() })
    try { [void]$f.ShowDialog() } finally {
        $anim.Stop(); $anim.Dispose()
        $f.Dispose()
        $Script:GuideOpen = $false
    }
    $haveKey = -not [string]::IsNullOrWhiteSpace((Get-ApiKey))
    if ($haveKey) {
        $Script:Cfg.OnboardingDone = $true
        Save-Config
    }
    return $haveKey
}

function Show-GuideStep([int]$step) {
    $ob = $Script:OB
    if ($step -lt 0) { return }
    $ob.Step = $step
    $ob.Clock.Restart()
    foreach ($k in $ob.Groups.Keys) { foreach ($c in $ob.Groups[$k]) { $c.Visible = ($k -eq $step) } }
    $texts = @(
        @("Your Everhour timer, always on screen", "This widget shows what you're tracking, turns red when nothing is running, and warns you when a break runs long. Setup takes about a minute."),
        @("1.  Open your Everhour profile", "In Everhour, click your name at the bottom-left, then choose My Profile."),
        @("2.  Copy your API token", "Scroll down to Application Access and click the copy button next to API Token."),
        @("3.  Paste it here", "Press Paste (or Ctrl+V), then Connect. We check it with Everhour straight away."),
        @("4.  Make it yours", "Pick a theme, a font and a shape. The preview above updates as you choose."),
        @("5.  Your workday", "Set your daily target and how long your breaks can be. Over the limit, the widget turns red."),
        @("You're all set", "The widget lives in the bottom-right corner. Drag it anywhere you like."))
    $ob.Title.Text = $texts[$step][0]
    $ob.Body.Text = $texts[$step][1]
    $ob.Back.Visible = ($step -gt 0)
    $ob.Next.Text = switch ($step) { 0 { "Let's go" } 3 { "Connect" } 6 { "Start using it" } default { "Next" } }
    if ($step -eq 3) {
        if ($ob.HadKey -or $ob.KeyOk) {
            $ob.KeyStatus.ForeColor = $UI.Good
            $who = if ($Script:UserName) { " as $($Script:UserName)" } else { "" }
            $ob.KeyStatus.Text = "You're already connected$who. Paste a new token only if you want to change it."
        } elseif (-not $RenderPreview -and -not $ob.KeyBox.Text) {
            try {
                $clip = [System.Windows.Forms.Clipboard]::GetText().Trim()
                if ($clip -match '^[A-Za-z0-9\-_:.]{20,100}$') {
                    $ob.KeyBox.Text = $clip
                    $ob.KeyStatus.ForeColor = $UI.Good
                    $ob.KeyStatus.Text = "Found a token on your clipboard - press Connect."
                }
            } catch { }
        }
        $ob.KeyBox.Focus() | Out-Null
    }
    $ob.Dots.Invalidate()
    $ob.Stage.Invalidate()
}

function Guide-Next {
    $ob = $Script:OB
    switch ($ob.Step) {
        3 {
            $k = $ob.KeyBox.Text.Trim()
            if (-not $k) {
                if ($ob.HadKey -or $ob.KeyOk) { Show-GuideStep 4; return }
                $ob.KeyStatus.ForeColor = $UI.Danger; $ob.KeyStatus.Text = "Paste your API token first."
                return
            }
            if ($ob.Busy) { return }
            $ob.Busy = $true
            $ob.KeyStatus.ForeColor = $UI.Muted; $ob.KeyStatus.Text = "Checking with Everhour..."
            Invoke-Api -Key $k -Requests @(@{ Name = "me"; Path = "/users/me" }) -OnDone {
                param($m)
                $ob = $Script:OB
                $ob.Busy = $false
                if ($ob.Form.IsDisposed) { return }
                $r = $m["me"]
                $k = $ob.KeyBox.Text.Trim()
                if ($r -and $r.Ok -and $r.Data) {
                    $Script:UserId = $r.Data.id
                    $Script:UserName = [string]$r.Data.name
                    Set-ApiKey $k; $ob.KeyOk = $true
                    if ($Script:Ready) { After-KeyChanged }
                    $ob.KeyBox.Text = ""
                    Show-GuideStep 4
                } elseif ($r -and ($r.Code -eq 401 -or $r.Code -eq 403)) {
                    $ob.KeyStatus.ForeColor = $UI.Danger
                    $ob.KeyStatus.Text = "Everhour didn't accept that token. Copy it again and make sure you got all of it."
                } else {
                    # offline: keep it; the widget will say if it's wrong
                    Set-ApiKey $k; $ob.KeyOk = $true
                    if ($Script:Ready) { After-KeyChanged }
                    $ob.KeyBox.Text = ""
                    $ob.KeyStatus.ForeColor = $UI.Muted
                    Show-GuideStep 4
                }
            }
        }
        5 {
            $c = $Script:Cfg
            $c.DailyTargetHours = [double]$ob.Target.Value
            $c.BreakLimitMinutes = [int]$ob.Break.Value
            $c.BreakKeywords = $ob.Words.Text.Trim()
            $c.RedWhenStopped = [bool]$ob.Red.Tag.On
            if ($ob.Auto.Tag.On) { Install-Autostart | Out-Null } else { Remove-Autostart }
            Save-Config
            Apply-Theme
            Show-GuideStep 6
        }
        6 {
            $ob.Done = $true
            Save-Config
            $ob.Form.Close()
        }
        default { Show-GuideStep ($ob.Step + 1) }
    }
}

# ===========================================================================
#  HOTKEY
# ===========================================================================
$Script:Hot = $null
$Script:HotkeyStatus = ""
function Parse-Hotkey([string]$str) {
    if ([string]::IsNullOrWhiteSpace($str)) { return $null }
    $mod = 0; $vk = 0
    foreach ($p in $str.Split("+")) {
        switch ($p.Trim()) {
            "Ctrl"  { $mod = $mod -bor 2 }
            "Alt"   { $mod = $mod -bor 1 }
            "Shift" { $mod = $mod -bor 4 }
            "Win"   { $mod = $mod -bor 8 }
            default {
                try { $vk = [int]([System.Windows.Forms.Keys]$p.Trim()) } catch { return $null }
            }
        }
    }
    if ($mod -eq 0 -or $vk -eq 0) { return $null }
    return @{ Mod = $mod; Vk = $vk }
}
function Register-Hotkey {
    if (-not $Script:HasWinApi) { return }
    try {
        if (-not $Script:Hot) {
            $Script:Hot = New-Object EhHotkey
            $Script:Hot.add_Pressed({
                if ($Script:IsRunning) { Set-Toast "Stopping..." 3 } else { Set-Toast "Starting..." 3 }
                Toggle-Timer
            })
        }
        $Script:Hot.Unregister()
        $Script:HotkeyStatus = ""
        if (-not $Script:Cfg.HotkeyEnabled) { return }
        $hk = Parse-Hotkey $Script:Cfg.Hotkey
        if (-not $hk) { $Script:HotkeyStatus = "Shortcut not valid"; return }
        if (-not $Script:Hot.Register([uint32]$hk.Mod, [uint32]$hk.Vk)) {
            $Script:HotkeyStatus = "$($Script:Cfg.Hotkey) is already used by another app - pick another."
            Write-Log "Hotkey $($Script:Cfg.Hotkey) could not be registered"
        }
    } catch { Write-Log "Hotkey setup failed: $($_.Exception.Message)" }
}

# ===========================================================================
#  CONTEXT MENU
# ===========================================================================
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.ShowImageMargin = $false
$menu.Font = $FontUI
if ($Script:HasWinApi) { try { $menu.Renderer = New-Object EhMenuRenderer } catch { } }
$menu.BackColor = $UI.Card
$menu.ForeColor = $UI.Text
$miStart    = $menu.Items.Add("Start a timer...")
$miResume   = $menu.Items.Add("Resume last task")
$miStop     = $menu.Items.Add("Stop timer")
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$miRefresh  = $menu.Items.Add("Refresh now")
$miOpen     = $menu.Items.Add("Open Everhour")
$miShape    = $menu.Items.Add("Switch to square")
$miSettings = $menu.Items.Add("Settings...")
$miGuide    = $menu.Items.Add("Setup guide...")
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$miExit     = $menu.Items.Add("Exit")
foreach ($mi in $menu.Items) { $mi.Padding = New-Object System.Windows.Forms.Padding(4, 3, 4, 3) }

$menu.Add_Opening({
    $miStop.Enabled = $Script:IsRunning
    $last = [string]$Script:Cfg.LastTaskName
    $miResume.Visible = (-not $Script:IsRunning) -and [bool]$Script:Cfg.LastTaskId
    if ($last.Length -gt 34) { $last = $last.Substring(0, 33) + "..." }
    $miResume.Text = "Resume  $last"
    $miStart.Text = if ($Script:IsRunning) { "Switch task..." } else { "Start a timer..." }
    $miShape.Text = if ($Script:Cfg.Shape -eq "Square") { "Switch to wide" } else { "Switch to square" }
})
$miStart.Add_Click({ Show-TaskPicker })
$miResume.Add_Click({ Resume-LastTask })
$miStop.Add_Click({ Stop-Timer })
$miRefresh.Add_Click({ $Script:RecordsAt = [DateTime]::MinValue; $Script:WeekAt = [DateTime]::MinValue; Request-Poll -Force })
$miOpen.Add_Click({ Start-Process "https://app.everhour.com/" })
$miShape.Add_Click({
    $Script:Cfg.Shape = if ($Script:Cfg.Shape -eq "Square") { "Wide" } else { "Square" }
    Save-Config
    Apply-Theme
})
$miSettings.Add_Click({ Show-Settings })
$miGuide.Add_Click({ Show-Onboarding | Out-Null })
$miExit.Add_Click({ $form.Close() })
$form.ContextMenuStrip = $menu

# ===========================================================================
#  MOUSE: drag vs click, hover, hit areas
# ===========================================================================
$Script:Dragging  = $false
$Script:DragStart = New-Object System.Drawing.Point(0, 0)
$Script:FormStart = New-Object System.Drawing.Point(0, 0)
$Script:DidMove   = $false

function Get-HitAt($pt) {
    foreach ($h in $Script:Hits) { if ($h.Rect.Contains([single]$pt.X, [single]$pt.Y)) { return $h.Name } }
    return ""
}

$form.Add_MouseDown({
    param($s, $e)
    $Script:LastInteract = Get-Date
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $Script:Dragging  = $true
        $Script:DidMove   = $false
        $Script:DragStart = [System.Windows.Forms.Cursor]::Position
        $Script:FormStart = $form.Location
    }
})
$form.Add_MouseMove({
    param($s, $e)
    $Script:LastInteract = Get-Date
    if ($Script:Dragging) {
        $now = [System.Windows.Forms.Cursor]::Position
        $dx = $now.X - $Script:DragStart.X
        $dy = $now.Y - $Script:DragStart.Y
        if ([Math]::Abs($dx) -gt 4 -or [Math]::Abs($dy) -gt 4) { $Script:DidMove = $true }
        if ($Script:DidMove) {
            $form.Location = New-Object System.Drawing.Point(($Script:FormStart.X + $dx), ($Script:FormStart.Y + $dy))
        }
        return
    }
    $h = Get-HitAt $e.Location
    $form.Cursor = if ($h) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::Default }
    if ($h -ne $Script:Hover) { $Script:Hover = $h; Render }
})
$form.Add_MouseLeave({ if ($Script:Hover) { $Script:Hover = ""; Render } })
$form.Add_MouseUp({
    param($s, $e)
    $Script:LastInteract = Get-Date
    if (-not $Script:Dragging) { return }
    $Script:Dragging = $false
    if ($Script:DidMove) {
        $Script:Anchor = $form.Location
        $Script:Cfg.PosX = $form.Location.X
        $Script:Cfg.PosY = $form.Location.Y
        Save-Config
        return
    }
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    switch (Get-HitAt $e.Location) {
        "toggle"     { Toggle-Timer }
        "b_start"    { Show-TaskPicker }
        "b_stop"     { if ($Script:IsRunning) { Stop-Timer } else { Resume-LastTask } }
        "b_settings" { Show-Settings }
        default      { Set-Expanded (-not $Script:IsExpanded) }
    }
})

# ===========================================================================
#  REMINDERS (tray balloon; the tray icon only shows while a balloon is up)
# ===========================================================================
$notify = New-Object System.Windows.Forms.NotifyIcon
try {
    $ib = New-Object System.Drawing.Bitmap(32, 32)
    $ig = [System.Drawing.Graphics]::FromImage($ib)
    $ig.SmoothingMode = "AntiAlias"
    Fill-Round $ig (ToColor "#22C55E") 2 2 28 28 14
    $ig.Dispose()
    $notify.Icon = [System.Drawing.Icon]::FromHandle($ib.GetHicon())
} catch { $notify.Icon = [System.Drawing.SystemIcons]::Information }
$notify.Text = "Everhour Widget"
$notify.Visible = $false
$Script:BalloonAction = ""
$Script:NotifyHideAt = [DateTime]::MaxValue

function Show-Balloon([string]$title, [string]$text, [string]$action) {
    $Script:BalloonAction = $action
    $notify.Visible = $true
    $notify.ShowBalloonTip(8000, $title, $text, [System.Windows.Forms.ToolTipIcon]::Info)
    $Script:NotifyHideAt = (Get-Date).AddSeconds(20)
}
$notify.Add_BalloonTipClicked({
    $notify.Visible = $false
    switch ($Script:BalloonAction) {
        "picker" { Show-TaskPicker }
        "key"    { Change-ApiKey | Out-Null }
    }
})
$notify.Add_BalloonTipClosed({ $notify.Visible = $false })

function Test-WorkTime($now) {
    $days = @(([string]$Script:Cfg.WorkDays) -split "," | ForEach-Object { $_.Trim() })
    if ($days -notcontains $now.DayOfWeek.ToString().Substring(0, 3)) { return $false }
    $ws = Parse-HHmm $Script:Cfg.WorkStart; $we = Parse-HHmm $Script:Cfg.WorkEnd
    if (-not $ws -or -not $we) { return $false }
    $t = $now.TimeOfDay
    if ($ws -le $we) { return ($t -ge $ws -and $t -le $we) }
    return ($t -ge $ws -or $t -le $we)    # overnight shift
}

function Check-IdleNudge {
    if (-not $Script:Cfg.IdleNudge -or $Script:IsRunning -or $Script:LastError) { return }
    try {
        $now = Get-Date
        if (-not (Test-WorkTime $now)) { return }
        $idleMin = ($now - $Script:LastRunAt).TotalMinutes
        if ($idleMin -lt [int]$Script:Cfg.IdleNudgeMinutes) { return }
        if (($now - $Script:NudgedAt).TotalMinutes -lt [int]$Script:Cfg.IdleNudgeMinutes) { return }
        $Script:NudgedAt = $now
        Show-Balloon "No timer running" "You haven't tracked time for $([int]$idleMin) minutes. Click here to start one." "picker"
    } catch { }
}

# ===========================================================================
#  CLOCK: polling schedule, auto-collapse, redraw when animations are off
# ===========================================================================
$uiTimer = New-Object System.Windows.Forms.Timer
$uiTimer.Interval = 1000
$uiTimer.Add_Tick({
    $now = Get-Date

    $interval = [int]$Script:Cfg.RefreshSeconds
    if ($now -lt $Script:SlowUntil) { $interval = [Math]::Max($interval, 60) }
    if (($now - $Script:LastPollReq).TotalSeconds -ge $interval) { Request-Poll }

    # today's entries: refresh after changes, every few minutes, and at midnight
    if ($Script:UserId) {
        $todayStr = $now.ToString("yyyy-MM-dd")
        $maxAge = if ($Script:IsExpanded) { 60 } else { 180 }
        $weekDue = $Script:IsExpanded -and $Script:Cfg.ShowWeekTotal -and
                   ((($now - $Script:WeekAt).TotalSeconds -gt 300) -or $Script:WeekDate -ne $todayStr)
        if ($Script:RecordsDate -ne $todayStr -and $Script:RecordsLoaded) {
            $Script:RecordsLoaded = $false; $Script:TodayByTask = @{}; $Script:TodayRecordsTotal = 0
            $Script:RecordsAt = [DateTime]::MinValue
        }
        if ((($now - $Script:RecordsAt).TotalSeconds -gt $maxAge) -or $weekDue) { Request-Records -WithWeek:$weekDue }
    }

    if ($Script:IsExpanded -and [int]$Script:Cfg.AutoCollapseSeconds -gt 0 -and -not $Script:Dragging) {
        $overIt = $false
        try { $overIt = $form.Bounds.Contains([System.Windows.Forms.Cursor]::Position) } catch { }
        if ($overIt -or $menu.Visible) { $Script:LastInteract = $now }
        elseif (($now - $Script:LastInteract).TotalSeconds -ge [int]$Script:Cfg.AutoCollapseSeconds) {
            Set-Expanded $false
        }
    }

    if ($notify.Visible -and $now -gt $Script:NotifyHideAt) { $notify.Visible = $false }
    if (-not $Script:Cfg.Animations) {
        Update-ModeAndPalette
        if (-not $Script:Dragging) { Render }
    }
})

$form.Add_Shown({
    if ($Script:HasWinApi) {
        try {
            $GWL_EXSTYLE      = -20
            $WS_EX_TOOLWINDOW = 0x00000080
            $WS_EX_NOACTIVATE = 0x08000000
            $WS_EX_LAYERED    = 0x00080000
            $ex = [EhWin]::GetWindowLong($form.Handle, $GWL_EXSTYLE) -bor $WS_EX_TOOLWINDOW -bor $WS_EX_NOACTIVATE
            if ($Script:Layered) { $ex = $ex -bor $WS_EX_LAYERED }
            [EhWin]::SetWindowLong($form.Handle, $GWL_EXSTYLE, $ex) | Out-Null
        } catch { $Script:Layered = $false }
    }
    $Script:Ready = $true
    Apply-Theme
    Place-Form
    Render
    if (-not $NoAutoInstall) {
        if (Test-Autostart) { Repair-Autostart } elseif (-not $Script:Cfg.OnboardingDone) { Install-Autostart | Out-Null }
    }
    Register-Hotkey
    Request-Poll -Force
    $uiTimer.Start()
    Update-AnimTimer
})

$form.Add_FormClosing({
    $uiTimer.Stop(); $animTimer.Stop(); $Script:JobTimer.Stop()
    try { if ($Script:Hot) { $Script:Hot.Dispose() } } catch { }
    $notify.Visible = $false; $notify.Dispose()
})

# Sample images of the widget, its dialogs and the guide (design checks, README).
if ($RenderPreview) {
    if (-not (Test-Path $RenderPreview)) { New-Item -ItemType Directory -Path $RenderPreview -Force | Out-Null }
    $Script:Layered = $true
    $Script:FirstPollDone = $true
    $Script:RecordsLoaded = $true; $Script:WeekLoaded = $true
    $Script:TodayByTask = @{
        "ev:1" = @{ Name = "Q4 dashboard redesign"; Sec = 3000 }
        "ev:2" = @{ Name = "Client sync call"; Sec = 2700 }
        "ev:3" = @{ Name = "Break Time"; Sec = 1500 }
        "ev:4" = @{ Name = "Email and planning"; Sec = 900 }
    }
    $Script:TodayRecordsTotal = 8100
    $Script:WeekRecordsTotal = 19 * 3600 + 1500
    $Script:Cfg.LastTaskId = "ev:1"; $Script:Cfg.LastTaskName = "Q4 dashboard redesign"
    $Script:Cfg.Animations = $true
    $Script:FixedAnimT = 2.3
    function Save-Preview([string]$name) {
        Update-ModeAndPalette -Snap
        $fr = Build-Frame $Script:Pal $Script:Mode
        $pad = Px 24
        $canvas = New-Object System.Drawing.Bitmap(($fr.Width + 2 * $pad), ($fr.Height + 2 * $pad))
        $cg = [System.Drawing.Graphics]::FromImage($canvas)
        $rect = New-Object System.Drawing.Rectangle(0, 0, $canvas.Width, $canvas.Height)
        $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, (ToColor "#6E9A3C"), (ToColor "#2E4A22"), 60)
        $cg.FillRectangle($lg, $rect); $lg.Dispose()
        $cg.DrawImage($fr, $pad, $pad, $fr.Width, $fr.Height)
        $cg.Dispose(); $fr.Dispose()
        $canvas.Save((Join-Path $RenderPreview "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        $canvas.Dispose()
    }
    function Set-Run([string]$id, [string]$name, [int]$dur, [int]$today) {
        $Script:IsRunning = $true; $Script:TaskId = $id; $Script:TaskName = $name
        $Script:BaseDuration = $dur; $Script:TimerToday = $today; $Script:LastPollAt = Get-Date
    }
    $Script:Ready = $false; Apply-Theme
    foreach ($shape in @("Wide", "Square")) {
        $Script:Cfg.Shape = $shape; Apply-Theme
        $sfx = $shape.ToLower()
        Set-Run "ev:1" "Q4 dashboard redesign" 4935 6120
        Save-Preview "$sfx-running"
        $Script:IsExpanded = $true; Save-Preview "$sfx-running-expanded"; $Script:IsExpanded = $false
        Set-Run "ev:3" "Break Time" 900 1500
        Save-Preview "$sfx-break"
        $Script:TodayByTask["ev:3"].Sec = 4300; Set-Run "ev:3" "Break Time" 2100 4300
        Save-Preview "$sfx-overbreak"
        $Script:TodayByTask["ev:3"].Sec = 1500
        $Script:IsRunning = $false; $Script:TaskId = ""; $Script:StoppedSince = (Get-Date).AddMinutes(-23)
        Save-Preview "$sfx-stopped"
        $Script:Hover = "toggle"; Save-Preview "$sfx-stopped-hover"; $Script:Hover = ""
    }
    $Script:Cfg.Shape = "Wide"
    # animation cost
    Set-Run "ev:1" "Q4 dashboard redesign" 4935 6120
    $Script:FixedAnimT = 0
    foreach ($mode in @("work", "stopped")) {
        if ($mode -eq "stopped") { $Script:IsRunning = $false }
        Update-ModeAndPalette -Snap
        for ($i = 0; $i -lt 5; $i++) { (Build-Frame $Script:Pal $Script:Mode).Dispose() }   # warm-up
        $sw = [Diagnostics.Stopwatch]::StartNew()
        for ($i = 0; $i -lt 30; $i++) { (Build-Frame $Script:Pal $Script:Mode).Dispose() }
        Write-Host ("Frame cost ({0}): {1:N1} ms" -f $mode, ($sw.Elapsed.TotalMilliseconds / 30))
    }
    $Script:FixedAnimT = 2.3
    $Script:IsRunning = $false; $Script:TaskId = ""

    # dialogs: open each one briefly, snapshot it, close it
    function Capture-NextDialog([string]$name, [int]$delayMs, [switch]$ScrollEnd, [switch]$Guide) {
        $Script:CapName = $name; $Script:CapScroll = [bool]$ScrollEnd; $Script:CapGuide = [bool]$Guide
        $ct = New-Object System.Windows.Forms.Timer
        $ct.Interval = $delayMs
        $ct.Add_Tick({
            $fm = @([System.Windows.Forms.Application]::OpenForms) | Where-Object { $_.Visible } | Select-Object -Last 1
            if (-not $fm) { $this.Stop(); return }
            if ($Script:CapScroll -and $Script:SBody) {
                $Script:SBody.AutoScrollPosition = New-Object System.Drawing.Point(0, 99999); $fm.Refresh()
            }
            $nm = $Script:CapName
            if ($Script:CapGuide) { $nm = "guide-$($Script:OB.Step)" }
            $cb = New-Object System.Drawing.Bitmap($fm.Width, $fm.Height)
            $fm.DrawToBitmap($cb, (New-Object System.Drawing.Rectangle(0, 0, $fm.Width, $fm.Height)))
            $cb.Save((Join-Path $RenderPreview "$nm.png"), [System.Drawing.Imaging.ImageFormat]::Png)
            $cb.Dispose()
            if ($Script:CapGuide -and $Script:OB.Step -lt 6) { Show-GuideStep ($Script:OB.Step + 1); return }
            $this.Stop()
            $fm.Close()
        })
        $ct.Start()
    }
    Capture-NextDialog "settings-top" 900; Show-Settings
    Capture-NextDialog "settings-bottom" 900 -ScrollEnd; Show-Settings
    $Script:OB = $null
    Capture-NextDialog "guide" 900 -Guide; Show-Onboarding | Out-Null
    Write-Host "Preview images written to $RenderPreview"
    exit
}

# First run (or first run of v5): the setup guide. Without a token, there's
# nothing to show, so quit if it's closed early.
if (-not $Script:Cfg.OnboardingDone -or [string]::IsNullOrWhiteSpace((Get-ApiKey))) {
    Apply-Theme
    $okGuide = Show-Onboarding
    if (-not $okGuide -and [string]::IsNullOrWhiteSpace((Get-ApiKey))) { exit }
}

[System.Windows.Forms.Application]::Run($form)
