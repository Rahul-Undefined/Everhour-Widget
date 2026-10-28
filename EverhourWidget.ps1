<#
    EverhourWidget.ps1  -  v8.6
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
    [switch]$AtLogon,          # started at sign-in: if already running, stay quiet
    [switch]$BuildShare,       # make the "Share" folder + zip for other laptops
    [string]$RenderPreview     # folder: draws sample widget images there and exits
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security

$Script:Version = "8.9"

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
    // A soft chime: a few sine notes with a quick fade, as a WAV in memory.
    public static byte[] Tone(double[] freqs, double noteSec, double vol) {
        int rate = 22050, per = (int)(rate * noteSec);
        int n = per * freqs.Length + rate / 3;
        short[] pcm = new short[n];
        for (int k = 0; k < freqs.Length; k++) {
            int off = k * per;
            for (int i = 0; off + i < n; i++) {
                double t = (double)i / rate;
                double env = Math.Min(1.0, t / 0.006) * Math.Exp(-t * 7.0);
                if (env < 0.001 && t > 0.05) { break; }
                double s = Math.Sin(2 * Math.PI * freqs[k] * t) * 0.85 + Math.Sin(4 * Math.PI * freqs[k] * t) * 0.15;
                int v = pcm[off + i] + (int)(s * env * vol * 32767);
                pcm[off + i] = (short)Math.Max(-32767, Math.Min(32767, v));
            }
        }
        System.IO.MemoryStream ms = new System.IO.MemoryStream();
        System.IO.BinaryWriter w = new System.IO.BinaryWriter(ms);
        w.Write(System.Text.Encoding.ASCII.GetBytes("RIFF")); w.Write(36 + n * 2);
        w.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt ")); w.Write(16); w.Write((short)1); w.Write((short)1);
        w.Write(rate); w.Write(rate * 2); w.Write((short)2); w.Write((short)16);
        w.Write(System.Text.Encoding.ASCII.GetBytes("data")); w.Write(n * 2);
        foreach (short s in pcm) { w.Write(s); }
        w.Flush();
        return ms.ToArray();
    }

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
    public static Color Text = Color.FromArgb(232, 232, 237), Muted = Color.FromArgb(110, 110, 120);
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
        e.TextColor = e.Item.Enabled ? EhMenuColors.Text : EhMenuColors.Muted;
        base.OnRenderItemText(e);
    }
    protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e) {
        e.ArrowColor = EhMenuColors.Text;
        base.OnRenderArrow(e);
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
    $dir = Join-Path $ScriptDir "assets\fonts"
    if (-not (Test-Path $dir)) { $dir = Join-Path $ScriptDir "fonts" }
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

# launch.vbs   - used at sign-in (passes -AtLogon, so a duplicate start stays quiet)
# everhour.vbs - used by Win+R "Everhour" (brings a running widget to the front)
$OpenLauncher = Join-Path $ConfigDir "everhour.vbs"
$RunKey       = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$AppPathKey   = "HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\Everhour.exe"
$AutoName     = "EverhourWidget"

function Write-VbsLauncher {
    try {
        if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
        (Get-LauncherVbs $ScriptPath "-AtLogon") | Set-Content -Path $VbsLauncher -Encoding ASCII
        (Get-LauncherVbs $ScriptPath) | Set-Content -Path $OpenLauncher -Encoding ASCII
        return $true
    } catch { Write-Log "VBS launcher write failed: $($_.Exception.Message)"; return $false }
}

# Win+R -> "Everhour" starts the widget (or shows it if it's running).
function Register-RunCommand {
    try {
        New-Item $AppPathKey -Force | Out-Null
        Set-ItemProperty $AppPathKey -Name "(default)" -Value $OpenLauncher
    } catch { Write-Log "Win+R command not registered: $($_.Exception.Message)" }
}

# Start at sign-in two ways: a logon task in Task Scheduler (runs right away)
# and the registry Run key (works even where tasks are locked down). If both
# fire, the second start just exits. The old Startup-folder shortcut was slow
# and on some PCs never ran, so it is removed.
function Install-Autostart {
    try {
        Write-VbsLauncher | Out-Null
        $wscript = Join-Path $env:WINDIR "System32\wscript.exe"
        $cmd = "`"$wscript`" `"$VbsLauncher`""
        if (-not (Test-Path $RunKey)) { New-Item $RunKey -Force | Out-Null }
        Set-ItemProperty $RunKey -Name $AutoName -Value $cmd
        try {
            $existing = Get-ScheduledTask -TaskName $AutoName -ErrorAction SilentlyContinue
            if (-not $existing -or $existing.Actions[0].Arguments -ne "`"$VbsLauncher`"") {
                $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
                $a = New-ScheduledTaskAction -Execute $wscript -Argument "`"$VbsLauncher`""
                $tr = New-ScheduledTaskTrigger -AtLogOn -User $me
                $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
                $pr = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
                Register-ScheduledTask -TaskName $AutoName -Description "Starts the Everhour widget when you sign in" -Action $a -Trigger $tr -Settings $set -Principal $pr -Force | Out-Null
            }
        } catch { Write-Log "Logon task not created ($($_.Exception.Message)); the Run key still starts the widget" }
        if (Test-Path $ShortcutPath) { Remove-Item $ShortcutPath -Force -ErrorAction SilentlyContinue }
        Register-RunCommand
        return $true
    } catch {
        Write-Log "Autostart install failed: $($_.Exception.Message)"
        return $false
    }
}

function Remove-Autostart {
    Remove-ItemProperty $RunKey -Name $AutoName -ErrorAction SilentlyContinue
    try { Unregister-ScheduledTask -TaskName $AutoName -Confirm:$false -ErrorAction Stop } catch { }
    if (Test-Path $ShortcutPath) { Remove-Item $ShortcutPath -Force -ErrorAction SilentlyContinue }
}
function Test-Autostart {
    if (Test-Path $ShortcutPath) { return $true }     # older versions
    return [bool](Get-ItemProperty $RunKey -Name $AutoName -ErrorAction SilentlyContinue)
}

# Autostart records an absolute path to this script. If the folder is moved or
# renamed the entry goes stale, so it is rewritten on every start. A git
# checkout used for development never takes over from the installed copy.
function Repair-Autostart {
    if (-not (Test-Autostart)) { Write-VbsLauncher | Out-Null; Register-RunCommand; return }
    if ((Test-Path (Join-Path $ScriptDir ".git")) -and (Test-Path (Join-Path $InstallDir "EverhourWidget.ps1")) -and $ScriptDir -ne $InstallDir) { return }
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

# Fonts live in assets\fonts. (Up to v8.0 they were in .\fonts; older
# updaters copy that folder over fonts the running widget has locked, and
# fail - so the folder moved, and those updaters now skip it.)
function Get-FontDir([string]$root) {
    $a = Join-Path $root "assets\fonts"
    if (Test-Path $a) { return $a }
    return (Join-Path $root "fonts")
}

# Copy one file, skipping it when the target already has the same content.
# Returns $false only when it really couldn't be written.
function Copy-IfChanged([string]$src, [string]$dst) {
    if (Test-Path $dst) {
        try {
            if ((Get-Item $src).Length -eq (Get-Item $dst).Length -and
                (Get-FileHash $src -Algorithm SHA1).Hash -eq (Get-FileHash $dst -Algorithm SHA1).Hash) { return $true }
        } catch { }
    }
    try { Copy-Item $src $dst -Force -ErrorAction Stop; return $true }
    catch { Write-Log "Couldn't replace $(Split-Path $dst -Leaf): $($_.Exception.Message)"; return $false }
}

# Copies the widget; returns $true when the script itself is in place. A
# font file the running widget holds open is left alone - it never changes.
function Copy-AppFiles([string]$from, [string]$to) {
    New-Item -ItemType Directory -Force -Path $to | Out-Null
    $ok = $true
    foreach ($f in $Script:AppFiles) {
        $src = Join-Path $from $f
        if (Test-Path $src) {
            $copied = Copy-IfChanged $src (Join-Path $to $f)
            if (-not $copied -and $f -eq "EverhourWidget.ps1") { $ok = $false }
        }
    }
    # everything under assets (fonts, the tour and its pictures), whatever is added later
    $as = Join-Path $from "assets"
    if (Test-Path $as) {
        foreach ($ff in Get-ChildItem $as -Recurse -File) {
            $dst = Join-Path (Join-Path $to "assets") $ff.FullName.Substring($as.Length + 1)
            New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
            [void](Copy-IfChanged $ff.FullName $dst)
        }
    } elseif (Test-Path (Join-Path $from "fonts")) {
        # packages from before v8.1 kept the fonts in .\fonts
        $fd = Join-Path $to "assets\fonts"
        New-Item -ItemType Directory -Force -Path $fd | Out-Null
        foreach ($ff in Get-ChildItem (Join-Path $from "fonts") -File) { [void](Copy-IfChanged $ff.FullName (Join-Path $fd $ff.Name)) }
    }
    return $ok
}

if ($BuildShare) {
    $shareRoot = Join-Path $ScriptDir "Share"
    $out = Join-Path $shareRoot "Everhour Widget"
    if (Test-Path $out) { Remove-Item $out -Recurse -Force }
    [void](Copy-AppFiles $ScriptDir $out)
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
            [void](Copy-AppFiles $ScriptDir $InstallDir)
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
    ConfigVersion       = 7
    ApiKey              = ""      # legacy plain-text key; migrated to ApiKeyProtected
    ApiKeyProtected     = ""
    OnboardingDone      = $false
    RefreshSeconds      = 10
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
    Shape               = "Large" # Large, Square or Wide
    TextSize            = "M"     # S, M or L
    AutoHide            = $false  # slide into the screen edge when not in use
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
    Favorites           = @()     # pinned tasks: @{ Id; Name }, up to 5
    Sounds              = $true
    FocusMinutes        = 25
    FocusBreakMinutes   = 5
    FocusAutoBreak      = $true   # switch to your break task and back
    BreakTaskId         = ""      # learned from the last break task you ran
    BreakTaskName       = ""
    AutoUpdate          = $true
    PrivacyMode         = $false  # eye on the widget: hide task names and times
    ClockInOut          = $true   # Everhour timecards: clock in / out from the widget
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
    $ver = 7
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
    if ($ver -lt 6) {
        # v6: the always-open Large shape is the default; sizes become S / M / L
        if ([string]$cfg.Shape -eq "Wide") { $cfg.Shape = "Large" }
        $tf = [int]$cfg.TimeFontSize
        $cfg.TextSize = if ($tf -le 16) { "S" } elseif ($tf -le 19) { "M" } else { "L" }
        $cfg.OnboardingDone = $false     # show the new setup flow once
    }
    if ($ver -lt 7) {
        # v8.7: closer to real time - the old 20 s default refresh becomes 10 s
        if ([int]$cfg.RefreshSeconds -eq 20) { $cfg.RefreshSeconds = 10 }
    }
    $cfg.ConfigVersion = 7
    return $cfg
}

function Limit([double]$v, [double]$lo, [double]$hi) { return [Math]::Max($lo, [Math]::Min($hi, $v)) }

function Normalize-Config {
    $c = $Script:Cfg
    try { $c.RefreshSeconds      = [int](Limit $c.RefreshSeconds 5 300) }        catch { $c.RefreshSeconds = 10 }
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
    if ($c.Shape -notin @("Wide", "Square", "Large")) { $c.Shape = "Large" }
    if ($c.TextSize -notin @("S", "M", "L")) { $c.TextSize = "M" }
    if (-not (Parse-HHmm $c.WorkStart)) { $c.WorkStart = "09:30" }
    if (-not (Parse-HHmm $c.WorkEnd))   { $c.WorkEnd   = "18:30" }
    if ($null -eq $c.WorkDays) { $c.WorkDays = "Mon,Tue,Wed,Thu,Fri" }
    if ($null -eq $c.BreakKeywords) { $c.BreakKeywords = "break, lunch" }
    try { $c.FocusMinutes      = [int](Limit $c.FocusMinutes 5 180) }      catch { $c.FocusMinutes = 25 }
    try { $c.FocusBreakMinutes = [int](Limit $c.FocusBreakMinutes 0 60) }  catch { $c.FocusBreakMinutes = 5 }
    $c.Favorites = @(@($c.Favorites) | Where-Object { $_ -and $_.Id } | Select-Object -First 5 |
        ForEach-Object { [pscustomobject]@{ Id = [string]$_.Id; Name = [string]$_.Name } })
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
    $runVal = (Get-ItemProperty $RunKey -Name $AutoName -ErrorAction SilentlyContinue).$AutoName
    $task = Get-ScheduledTask -TaskName $AutoName -ErrorAction SilentlyContinue
    if (-not $runVal -and -not $task) {
        Write-Host "    NO - no startup entry found." -ForegroundColor Red
        Write-Host "    Fix: start the widget once, or turn it on in Settings."
        $ok = $false
    } else {
        Write-Host "    Run key      : $(if ($runVal) { 'FOUND - ' + $runVal } else { 'missing' })"
        Write-Host "    Logon task   : $(if ($task) { 'FOUND (' + $task.State + ')' } else { 'missing (the Run key is enough)' })"
        $ap = (Get-ItemProperty $AppPathKey -ErrorAction SilentlyContinue).'(default)'
        Write-Host "    Win+R Everhour: $(if ($ap) { 'registered' } else { 'not registered' })"

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

    $runVal = (Get-ItemProperty $RunKey -Name $AutoName -ErrorAction SilentlyContinue).$AutoName
    if (-not $runVal) {
        Write-Host "FAIL: there is no startup entry to test." -ForegroundColor Red
        Write-Host "Start the widget once first." ; Write-Host ""
        exit
    }
    $tgt = Join-Path $env:WINDIR "System32\wscript.exe"; $arg = "`"$VbsLauncher`""
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

# Only one widget at a time. Starting it again (Win+R "Everhour", the Start
# shortcut) asks the running one to come to the front instead.
$Script:Mutex = New-Object System.Threading.Mutex($false, "Local\EverhourWidgetSingleInstance")
$Script:ShowSignal = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, "Local\EverhourWidgetShow")
if (-not $RenderPreview) {
    $mine = $true
    try { $mine = $Script:Mutex.WaitOne(0, $false) }
    catch [System.Threading.AbandonedMutexException] { $mine = $true } catch { }
    if (-not $mine) {
        if (-not $AtLogon) { try { [void]$Script:ShowSignal.Set() } catch { } }
        exit
    }
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
        $res = [pscustomobject]@{ Name = $rq.Name; Ok = $false; Code = 0; Data = $null; Error = ""; At = $null }
        $t0 = [DateTime]::Now
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
        # the server read its clock about half-way through the round trip
        $res.At = $t0.AddTicks([long](([DateTime]::Now - $t0).Ticks / 2))
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
$Script:OpenGroup     = "today"     # which list is open: today, week or none
$Script:ListScroll    = 0

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
        $rows[$k] = [pscustomobject]@{ Id = $k; Name = $v.Name; Sec = [double]$v.Sec; Running = $false }
    }
    if ($Script:IsRunning) {
        $live = Get-LiveTaskToday
        if ($rows.ContainsKey($Script:TaskId)) {
            $rows[$Script:TaskId].Sec = [Math]::Max($rows[$Script:TaskId].Sec, $live)
            $rows[$Script:TaskId].Running = $true
        } else {
            $rows[$Script:TaskId] = [pscustomobject]@{ Id = $Script:TaskId; Name = $Script:TaskName; Sec = $live; Running = $true }
        }
    }
    return @($rows.Values | Where-Object { $_.Sec -gt 0 } | Sort-Object -Property Sec -Descending)
}

# This week, task by task (the running task counts its live time).
$Script:WeekByTask = @{}
function Get-WeekRows {
    $rows = @{}
    foreach ($k in $Script:WeekByTask.Keys) {
        $v = $Script:WeekByTask[$k]
        $rows[$k] = [pscustomobject]@{ Id = $k; Name = $v.Name; Sec = [double]$v.Sec; Running = $false }
    }
    if ($Script:IsRunning) {
        $extra = [Math]::Max(0, (Get-LiveTaskToday) - (Get-RecordedForTask $Script:TaskId))
        if ($rows.ContainsKey($Script:TaskId)) { $rows[$Script:TaskId].Sec += $extra; $rows[$Script:TaskId].Running = $true }
        else { $rows[$Script:TaskId] = [pscustomobject]@{ Id = $Script:TaskId; Name = $Script:TaskName; Sec = (Get-LiveTaskToday); Running = $true } }
    }
    return @($rows.Values | Where-Object { $_.Sec -gt 0 } | Sort-Object -Property Sec -Descending)
}

# Double-click a task in the list to start it again.
function Start-TaskById([string]$id, [string]$name) {
    if (-not $id -or $id -eq "none") { return }
    if ($Script:IsRunning -and $Script:TaskId -eq $id) { Set-Toast "Already running" 2; return }
    if ($Script:IsRunning -and $Script:Cfg.ConfirmSwitch) {
        if (-not (Show-Message "Switch task?" "Stop '$($Script:TaskName)' and start '$name'?" "Switch" "Cancel")) { return }
    }
    Start-Timer $id $name ""
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
    if ($Script:WeekLoaded) {
        $Script:WeekRecordsTotal += $diff
        if (-not $Script:WeekByTask.ContainsKey($Script:TaskId)) { $Script:WeekByTask[$Script:TaskId] = @{ Name = $Script:TaskName; Sec = 0 } }
        $Script:WeekByTask[$Script:TaskId].Sec += $diff
    }
}

# ===========================================================================
#  POLLING
# ===========================================================================
function Apply-TimerData($d, $at) {
    $wasRunning = $Script:IsRunning
    $wasTask = $Script:TaskId
    if ($d -and $d.status -eq "active" -and $d.task) {
        $prevLive = if ($wasRunning) { Get-LiveElapsed } else { -1 }
        $Script:IsRunning    = $true
        $Script:TaskId       = [string]$d.task.id
        $Script:TaskName     = [string]$d.task.name
        $Script:BaseDuration = 0; try { $Script:BaseDuration = [int]$d.duration } catch { }
        $Script:TimerToday   = 0; try { $Script:TimerToday = [int]$d.today } catch { }
        $Script:TimerComment = [string]$d.comment
        # Real time: Everhour counted whole seconds at the moment it answered
        # (mid round trip), so anchor there plus half a second - not when the
        # answer reached us, which made the clock run a second or two behind.
        if ($at -is [DateTime]) { $Script:LastPollAt = $at.AddMilliseconds(-500) } else { $Script:LastPollAt = Get-Date }
        # never tick backwards by a hair after a refresh of the same timer
        if ($wasRunning -and $wasTask -eq $Script:TaskId -and $prevLive -ge 0) {
            $back = $prevLive - (Get-LiveElapsed)
            if ($back -gt 0 -and $back -lt 2) { $Script:LastPollAt = $Script:LastPollAt.AddSeconds(-$back) }
        }
        $Script:LastRunAt    = Get-Date
        if ($Script:Cfg.LastTaskId -ne $Script:TaskId -or $Script:Cfg.LastTaskName -ne $Script:TaskName) {
            $Script:Cfg.LastTaskId = $Script:TaskId
            $Script:Cfg.LastTaskName = $Script:TaskName
            Save-Config
        }
        # remember the break task, so focus sessions can switch to it for you
        if ((Test-IsBreak $Script:TaskName) -and $Script:Cfg.BreakTaskId -ne $Script:TaskId) {
            $Script:Cfg.BreakTaskId = $Script:TaskId
            $Script:Cfg.BreakTaskName = $Script:TaskName
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
    $cr = Get-ClockRequest
    if ($cr) { $reqs += $cr }
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
            Apply-TimerData $t.Data $t.At
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
    if ($m["clock"]) { On-Clock $m["clock"] }
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
            $ws = Sum-Records $w.Data
            $Script:WeekRecordsTotal = $ws.Sum
            $Script:WeekByTask = $ws.By
            $Script:WeekLoaded = $true
            $Script:WeekDate = $Script:RecReqDate
        }
    }
    Render
}

# ===========================================================================
#  TIMER ACTIONS
# ===========================================================================
function Start-Timer([string]$TaskId, [string]$TaskName, [string]$Comment, [string]$DoneText = "Started") {
    if ($Script:ActionBusy -or -not $TaskId) { return }
    $Script:ActionBusy = $true
    $body = @{ task = $TaskId; userDate = (Get-Date).ToString("yyyy-MM-dd") }
    if (-not [string]::IsNullOrWhiteSpace($Comment)) { $body.comment = $Comment.Trim() }
    $Script:StartDoneText = $DoneText
    Set-Toast "Starting..." 20
    Invoke-Api -Requests @(@{ Name = "start"; Path = "/timers"; Method = "Post"; Body = $body }) -OnDone {
        param($m)
        $Script:ActionBusy = $false
        $r = $m["start"]
        if ($r -and $r.Ok) {
            if ($r.Data -and $r.Data.status -eq "active") { Apply-TimerData $r.Data $r.At }
            $Script:LastError = ""
            $Script:ClockAt = [DateTime]::MinValue    # Everhour may clock you in with the timer
            Play-Sound "start"
            Set-Toast $Script:StartDoneText 2
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
            if ($Script:FocusPhase -eq "focus") { $Script:FocusPhase = "" }    # stopping ends the focus session
            Play-Sound "stop"
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
    if ($Script:IsRunning) { Stop-Timer }
    elseif ((Get-Mode) -eq "clockedout") { Clock-In }
    else { Resume-LastTask }
}

# ===========================================================================
#  CLOCK IN / CLOCK OUT  (Everhour timecards)
#  Clocked out, the widget rests: nothing counts and nothing turns red. It
#  starts counting again from the moment you clock in - from the widget or
#  in Everhour itself (the state is re-read with every refresh).
#  ClockState: "" not known yet, "in", "out", "na" (not available to you)
# ===========================================================================
$Script:ClockState = ""
$Script:ClockUsed  = $false       # this account keeps timecards at all
$Script:ClockInAt  = $null
$Script:ClockOutAt = $null
$Script:ClockAt    = [DateTime]::MinValue
$Script:ClockBusy  = $false
$Script:ClockLogged = $false

function Test-ClockOn { return ([bool]$Script:Cfg.ClockInOut -and $Script:ClockState -in @("in", "out")) }

function Get-ClockRequest {
    if (-not $Script:Cfg.ClockInOut -or -not $Script:UserId) { return $null }
    $age = ((Get-Date) - $Script:ClockAt).TotalSeconds
    $due = if ($Script:ClockState -eq "na") { 1800 } else { 15 }
    if ($age -lt $due) { return $null }
    $Script:ClockAt = Get-Date
    # a week back, to learn whether this account uses timecards at all
    $from = (Get-Date).AddDays(-7).ToString("yyyy-MM-dd"); $to = (Get-Date).ToString("yyyy-MM-dd")
    return @{ Name = "clock"; Path = "/users/$($Script:UserId)/timecards?from=$from&to=$to" }
}

function Read-ClockTime([string]$s, [DateTime]$day) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $ts = Parse-HHmm $s
    if ($ts) { return $day.Date.Add($ts) }
    try { return [DateTime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}

# One timecard -> in/out, when you clocked in (the latest time) and out.
function Apply-Timecard($tc) {
    $today = (Get-Date).Date
    $state = "out"; $inAt = $null; $outAt = $null
    if ($tc) {
        $inAt  = Read-ClockTime ([string]$tc.clockIn) $today
        $outAt = Read-ClockTime ([string]$tc.clockOut) $today
        if ($inAt -and -not $outAt) { $state = "in" }
        # clocking in again later in the day: the history has the latest one
        foreach ($h in @($tc.history)) {
            if (-not $h -or $h.previousTime) { continue }      # skips edits of a time
            $hAt = Read-ClockTime ([string]$h.time) $today
            if ([string]$h.action -eq "clock-in") { $state = "in"; if ($hAt) { $inAt = $hAt } }
            elseif ([string]$h.action -eq "clock-out") { $state = "out"; if ($hAt) { $outAt = $hAt } }
        }
        if ($state -eq "in" -and $outAt -and $inAt -and $outAt -gt $inAt) { $state = "out" }
    }
    $was = $Script:ClockState
    $Script:ClockState = $state
    $Script:ClockInAt = $inAt; $Script:ClockOutAt = $outAt
    if ($was -eq "out" -and $state -eq "in" -and -not $Script:IsRunning) {
        # clocked in somewhere else: count the time off from now, not from yesterday
        $Script:StoppedSince = Get-Date
    }
}

function On-Clock($r) {
    if (-not $r) { return }
    if (-not $r.Ok) {
        if ($r.Code -in @(402, 403, 404)) { $Script:ClockState = "na" }
        return
    }
    $cards = @($r.Data | Where-Object { $_ })
    if (-not $Script:ClockLogged -and $cards.Count) {
        $Script:ClockLogged = $true
        try { Write-Log ("Timecard sample: " + ($cards[-1] | ConvertTo-Json -Depth 4 -Compress)) } catch { }
    }
    if (@($cards | Where-Object { $_.clockIn -or $_.history }).Count -gt 0) { $Script:ClockUsed = $true }
    $todayStr = (Get-Date).ToString("yyyy-MM-dd")
    $tc = $cards | Where-Object { [string]$_.date -eq $todayStr } | Select-Object -Last 1
    Apply-Timecard $tc
    Render
}

function Clock-In {
    if ($Script:ClockBusy -or -not $Script:UserId) { return }
    $Script:ClockBusy = $true
    Set-Toast "Clocking in..." 20
    Invoke-Api -Requests @(@{ Name = "cin"; Path = "/users/$($Script:UserId)/timecards/clock-in"; Method = "Post"; Body = @{ userDate = (Get-Date).ToString("yyyy-MM-dd") } }) -OnDone {
        param($m)
        $Script:ClockBusy = $false
        $r = $m["cin"]
        if ($r -and $r.Ok) {
            $Script:ClockUsed = $true
            if ($r.Data -and ($r.Data.clockIn -or $r.Data.history)) { Apply-Timecard $r.Data }
            if ($Script:ClockState -ne "in") { $Script:ClockState = "in"; $Script:ClockInAt = Get-Date }
            if (-not $Script:IsRunning) { $Script:StoppedSince = Get-Date }
            Play-Sound "start"
            Set-Toast "Clocked in" 3
        } else {
            Set-Toast "Couldn't clock in" 5 -IsError
        }
        $Script:ClockAt = [DateTime]::MinValue
        Request-Poll -Force
    }
}

function Clock-Out {
    if ($Script:ClockBusy -or -not $Script:UserId) { return }
    if ($Script:IsRunning) {
        if (-not (Show-Message "Clock out?" "This stops '$($Script:TaskName)' and clocks you out for the day." "Clock out" "Cancel")) { return }
    }
    $Script:ClockBusy = $true
    Set-Toast "Clocking out..." 20
    $reqs = @()
    if ($Script:IsRunning) { $reqs += @{ Name = "stop"; Path = "/timers/current"; Method = "Delete" } }
    $reqs += @{ Name = "cout"; Path = "/users/$($Script:UserId)/timecards/clock-out"; Method = "Post" }
    Invoke-Api -Requests $reqs -OnDone {
        param($m)
        $Script:ClockBusy = $false
        if ($m["stop"] -and $m["stop"].Ok) { Apply-TimerData $null; $Script:FocusPhase = "" }
        $r = $m["cout"]
        if ($r -and $r.Ok) {
            if ($r.Data -and ($r.Data.clockIn -or $r.Data.history)) { Apply-Timecard $r.Data }
            if ($Script:ClockState -ne "out") { $Script:ClockState = "out"; $Script:ClockOutAt = Get-Date }
            Play-Sound "stop"
            Set-Toast "Clocked out" 3
        } else {
            Set-Toast "Couldn't clock out" 5 -IsError
        }
        $Script:ClockAt = [DateTime]::MinValue
        Request-Poll -Force
    }
}

function Toggle-Clock { if ($Script:ClockState -eq "in") { Clock-Out } else { Clock-In } }

# The time off counts from the later of: the timer stopping, clocking in.
function Get-OffSince {
    $s = $Script:StoppedSince
    if ((Test-ClockOn) -and $Script:ClockState -eq "in" -and $Script:ClockInAt -and $Script:ClockInAt -gt $s -and $Script:ClockInAt -le (Get-Date)) { $s = $Script:ClockInAt }
    return $s
}

# ===========================================================================
#  SOUNDS  (short chimes made on the fly - no sound files)
# ===========================================================================
$Script:SoundDefs = @{
    start = @(@(659.25, 987.77), 0.10)
    stop  = @(@(783.99, 523.25), 0.11)
    soft  = @(@(587.33, 783.99), 0.12)
    chime = @(@(523.25, 659.25, 783.99, 1046.5), 0.10)
    alert = @(@(880.0, 0.0, 880.0, 0.0, 880.0), 0.09)
}
$Script:SoundCache = @{}
function Play-Sound([string]$name) {
    if (-not $Script:Cfg.Sounds -or -not $Script:HasWinApi -or $RenderPreview) { return }
    try {
        if (-not $Script:SoundCache.ContainsKey($name)) {
            $def = $Script:SoundDefs[$name]
            $Script:SoundCache[$name] = [EhWin]::Tone([double[]]$def[0], [double]$def[1], 0.22)
        }
        $Script:Player = New-Object System.Media.SoundPlayer((New-Object System.IO.MemoryStream(, $Script:SoundCache[$name])))
        $Script:Player.Play()
    } catch { }
}

# ===========================================================================
#  FAVOURITE TASKS  (one-click chips on the widget)
# ===========================================================================
function Get-Favs { return @(@($Script:Cfg.Favorites) | Where-Object { $_ -and $_.Id }) }
function Test-Fav([string]$id) { return [bool](Get-Favs | Where-Object { $_.Id -eq $id }) }
function Toggle-Fav([string]$id, [string]$name) {
    if (Test-Fav $id) {
        $Script:Cfg.Favorites = @(Get-Favs | Where-Object { $_.Id -ne $id })
        Set-Toast "Removed from favourites" 2
    } else {
        if ((Get-Favs).Count -ge 5) { Set-Toast "Up to 5 favourites" 3 -IsError; return }
        $Script:Cfg.Favorites = @(Get-Favs) + [pscustomobject]@{ Id = $id; Name = $name }
        Set-Toast "Added to favourites" 2
    }
    Save-Config
    Render
}
function Start-Fav([int]$i) {
    $favs = Get-Favs
    if ($i -lt 0 -or $i -ge $favs.Count) { return }
    $f = $favs[$i]
    if ($Script:IsRunning -and $Script:TaskId -eq $f.Id) { return }
    if ($Script:IsRunning -and $Script:Cfg.ConfirmSwitch) {
        if (-not (Show-Message "Switch task?" "Stop '$($Script:TaskName)' and start '$($f.Name)'?" "Switch" "Cancel")) { return }
    }
    Start-Timer $f.Id $f.Name ""
}

# ===========================================================================
#  FOCUS SESSIONS  (e.g. 25 min work, 5 min break, switching tasks for you)
# ===========================================================================
$Script:FocusPhase = ""          # "", focus, rest
$Script:FocusEnd = [DateTime]::MinValue
$Script:FocusLen = 1
$Script:FocusWork = $null

function Start-Focus([int]$min = 0) {
    if ($min -le 0) { $min = [int]$Script:Cfg.FocusMinutes }
    $Script:FocusPhase = "focus"
    $Script:FocusLen = $min * 60
    $Script:FocusEnd = (Get-Date).AddMinutes($min)
    $Script:FocusWork = $null
    if (-not $Script:IsRunning) { Resume-LastTask } else { Play-Sound "start" }
    Set-Toast "Focus $min min" 3
}
function Stop-Focus { $Script:FocusPhase = ""; Set-Toast "Focus ended" 2 }

function Get-FocusLeft { return [Math]::Max(0, ($Script:FocusEnd - (Get-Date)).TotalSeconds) }
function Get-FocusLabel {
    if (-not $Script:FocusPhase) { return "" }
    $left = Get-FocusLeft
    $txt = if ($left -ge 60) { "{0}m left" -f [int][Math]::Ceiling($left / 60) } else { "{0}s left" -f [int]$left }
    if ($Script:FocusPhase -eq "focus") { return "Focus  $txt" }
    return "Break  $txt"
}

function Check-Focus {
    if (-not $Script:FocusPhase -or (Get-Date) -lt $Script:FocusEnd) { return }
    $auto = [bool]$Script:Cfg.FocusAutoBreak
    if ($Script:FocusPhase -eq "focus") {
        Play-Sound "chime"
        $rest = [int]$Script:Cfg.FocusBreakMinutes
        if ($rest -le 0) { $Script:FocusPhase = ""; Show-Balloon "Focus session done" "Nice work - keep going or take a breather." ""; return }
        $Script:FocusPhase = "rest"
        $Script:FocusLen = $rest * 60
        $Script:FocusEnd = (Get-Date).AddMinutes($rest)
        $Script:FocusWork = @{ Id = $Script:TaskId; Name = $Script:TaskName }
        if ($auto -and $Script:Cfg.BreakTaskId -and $Script:IsRunning -and -not (Test-IsBreak $Script:TaskName)) {
            Start-Timer $Script:Cfg.BreakTaskId $Script:Cfg.BreakTaskName "" "Break started"
            Show-Balloon "Focus session done" "Break started for $rest min. I'll tell you when it's over." ""
        } else {
            Show-Balloon "Focus session done" "Time for a $rest-minute break." ""
        }
    } else {
        $Script:FocusPhase = ""
        Play-Sound "chime"
        $w = $Script:FocusWork
        if ($auto -and $w -and $w.Id -and $Script:IsRunning -and (Test-IsBreak $Script:TaskName)) {
            Start-Timer $w.Id $w.Name "" "Back to work"
            Show-Balloon "Break over" "Back to $($w.Name)." ""
        } else {
            Show-Balloon "Break over" "Ready for the next focus session?" "focus"
        }
    }
}

# ===========================================================================
#  NOTE ON THE RUNNING TIMER, and ADDING MISSED TIME
# ===========================================================================
function Show-NoteDialog {
    if (-not $Script:IsRunning) { return }
    $d = New-Dialog "Note for this entry" 440 236
    $f = $d.Form
    $f.Controls.Add((New-Label "What are you working on in '$($Script:TaskName)'?" 22 56 396 40 $FontUI $UI.Muted))
    $tb = New-TextBox 22 100 396 ([string]$Script:TimerComment) "Add a note"
    $f.Controls.Add($tb)
    $f.Controls.Add((New-Label "Saved on today's entry. The timer keeps running." 22 136 396 20 $FontSmall $UI.Muted))
    $Script:NoteBox = $tb; $Script:NoteOk = $false
    $bc = New-FlatButton -Text "Cancel" -X 220 -Y 178 -W 92 -H 36
    $bs = New-FlatButton -Text "Save note" -X 320 -Y 178 -W 98 -H 36 -Primary
    $bc.Add_Click({ $this.FindForm().Close() })
    $bs.Add_Click({ $Script:NoteOk = $true; $this.FindForm().Close() })
    $f.Controls.Add($bc); $f.Controls.Add($bs); $f.AcceptButton = $bs
    $f.Add_Shown({ $Script:NoteBox.Focus() | Out-Null; $Script:NoteBox.SelectAll() })
    [void]$f.ShowDialog()
    $note = $Script:NoteBox.Text.Trim()
    $f.Dispose()
    if ($Script:NoteOk -and $Script:IsRunning) {
        # Everhour keeps the note with the timer it was started with, so restart
        # the same task with the new note; the time carries on in the same entry.
        Start-Timer $Script:TaskId $Script:TaskName $note "Note saved"
    }
}

function Add-PickedTime {
    $pk = $Script:PK
    if ($pk.Lb.SelectedIndex -lt 0 -or $pk.Lb.SelectedIndex -ge $pk.Items.Count) { $pk.Hint.Text = "Pick a task first."; return }
    $sel = $pk.Items[$pk.Lb.SelectedIndex]
    $min = [double]$pk.Minutes
    if ($min -le 0) { $pk.Hint.Text = "Choose how long."; return }
    if (-not $Script:UserId) { $pk.Hint.Text = "Still connecting to Everhour - try again in a moment."; Request-Poll -Force; return }
    if ($pk.Busy) { return }
    $pk.Busy = $true
    $pk.Hint.Text = "Adding..."
    $body = @{ time = [int]($min * 60); date = $pk.Date.ToString("yyyy-MM-dd"); user = $Script:UserId }
    if ($pk.Note.Text.Trim()) { $body.comment = $pk.Note.Text.Trim() }
    $Script:AddInfo = "Added $(Format-Short ($min * 60)) to $($sel.Name)"
    Invoke-Api -Requests @(@{ Name = "add"; Path = "/tasks/$($sel.Id)/time"; Method = "Post"; Body = $body }) -OnDone {
        param($m)
        $pk = $Script:PK
        $r = $m["add"]
        $Script:RecordsAt = [DateTime]::MinValue; $Script:WeekAt = [DateTime]::MinValue
        if ($r -and $r.Ok) {
            Play-Sound "soft"
            Set-Toast "Time added" 3
            if ($pk -and -not $pk.Form.IsDisposed) { $pk.Form.Close() }
            Show-Balloon "Time added" $Script:AddInfo ""
        } elseif ($pk -and -not $pk.Form.IsDisposed) {
            $pk.Busy = $false
            $pk.Hint.ForeColor = $UI.Danger
            $pk.Hint.Text = "Everhour said no ($($r.Code)). Check the date isn't locked."
        }
    }
}

# ===========================================================================
#  AUTO-UPDATE  (checks GitHub; installs with one click and restarts)
# ===========================================================================
$Script:UpdateVersionUrl = "https://raw.githubusercontent.com/Rahul-Undefined/Everhour-Widget/main/version.json"
$Script:UpdateZipUrl     = "https://github.com/Rahul-Undefined/Everhour-Widget/archive/refs/heads/main.zip"
$Script:UpdateAvail = $null
$Script:UpdCheckedAt = [DateTime]::MinValue
$Script:StartedAt = Get-Date

$Script:UpdWorker = {
    param($Kind, $VersionUrl, $ZipUrl)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $res = [pscustomobject]@{ Name = $Kind; Ok = $false; Code = 0; Data = $null; Error = "" }
    try {
        if ($Kind -eq "updcheck") {
            # raw.githubusercontent.com is IPv6-first; on networks where IPv6
            # half-works .NET hangs there while everything else is fine. So:
            # .NET with a short wait, then curl over IPv4, then the GitHub API.
            $errs = @()
            try { $res.Data = Invoke-RestMethod -Uri ($VersionUrl + "?t=" + [DateTime]::UtcNow.Ticks) -TimeoutSec 8 -UseBasicParsing } catch { $errs += $_.Exception.Message }
            if (-not ($res.Data -and $res.Data.version)) {
                $curl = Join-Path $env:WINDIR "System32\curl.exe"
                if (Test-Path $curl) {
                    try {
                        $txt = (& $curl -4 -s -f -m 15 ($VersionUrl + "?t=" + [DateTime]::UtcNow.Ticks)) -join "`n"
                        if ($txt) { $res.Data = $txt | ConvertFrom-Json }
                    } catch { $errs += "curl: " + $_.Exception.Message }
                }
            }
            if (-not ($res.Data -and $res.Data.version)) {
                try {
                    $api = $VersionUrl -replace '^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.+)$', 'https://api.github.com/repos/$1/$2/contents/$4?ref=$3'
                    $res.Data = Invoke-RestMethod -Uri $api -Headers @{ Accept = "application/vnd.github.raw" } -TimeoutSec 15 -UseBasicParsing
                } catch { $errs += "api: " + $_.Exception.Message }
            }
            if (-not ($res.Data -and $res.Data.version)) { throw ($errs -join " | ") }
        } else {
            $dir = Join-Path $env:TEMP ("everhour-widget-update-" + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $dir | Out-Null
            $zip = Join-Path $dir "update.zip"
            Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 180
            $out = Join-Path $dir "files"
            Expand-Archive -Path $zip -DestinationPath $out -Force
            $ps1 = Get-ChildItem $out -Recurse -Filter "EverhourWidget.ps1" | Select-Object -First 1
            if (-not $ps1) { throw "the download has no EverhourWidget.ps1" }
            $res.Data = $ps1.DirectoryName
        }
        $res.Ok = $true
    } catch { $res.Error = $_.Exception.Message }
    $res
}.ToString()

function Start-UpdateJob([string]$kind, [scriptblock]$OnDone) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $Script:Pool
    [void]$ps.AddScript($Script:UpdWorker).AddArgument($kind).AddArgument($Script:UpdateVersionUrl).AddArgument($Script:UpdateZipUrl)
    $h = $ps.BeginInvoke()
    [void]$Script:Jobs.Add([pscustomobject]@{ PS = $ps; Handle = $h; OnDone = $OnDone })
}

function Check-Update([switch]$Manual) {
    $Script:UpdCheckedAt = Get-Date
    if ($Script:UpdBusy) { return }
    $Script:UpdBusy = $true
    $Script:UpdManual = [bool]$Manual
    Start-UpdateJob "updcheck" { param($m) On-UpdateCheck $m["updcheck"] }
}
function On-UpdateCheck($r) {
    $Script:UpdBusy = $false
    $msg = "Couldn't check for updates right now"
    if ($r -and $r.Ok -and $r.Data -and $r.Data.version) {
        $remote = $null; try { $remote = [version]([string]$r.Data.version) } catch { }
        if ($remote -and $remote -gt [version]$Script:Version) {
            $Script:UpdateAvail = @{ Version = [string]$r.Data.version; Notes = [string]$r.Data.notes }
            $msg = "Version $remote is ready to install"
            if (-not $Script:UpdManual) {
                if ($Script:Cfg.AutoUpdate -and -not (Test-Path (Join-Path $ScriptDir ".git"))) {
                    $Script:AutoInstallPending = $true      # installs itself, no click needed
                } elseif ($Script:UpdNotified -ne [string]$remote) {
                    $Script:UpdNotified = [string]$remote
                    Show-Balloon "Widget update: v$remote" "$($r.Data.notes) Click the Update pill on the widget to install." "update"
                }
            }
            Render
        } else {
            $Script:UpdateAvail = $null
            $msg = "You have the latest version ($($Script:Version))"
        }
    }
    if ($Script:HubOpen -and $Script:Hub.UpdLabel -and -not $Script:Hub.UpdLabel.IsDisposed) { $Script:Hub.UpdLabel.Text = $msg }
}

function Install-Update {
    if (Test-Path (Join-Path $ScriptDir ".git")) {
        Show-Message "Update" "This copy of the widget is a git checkout. Update it with 'git pull' instead, then restart the widget." | Out-Null
        return
    }
    Set-Toast "Downloading update..." 180
    Start-UpdateJob "updget" { param($m) On-UpdateDownloaded $m["updget"] }
}
function On-UpdateDownloaded($r) {
    if (-not ($r -and $r.Ok)) { Set-Toast "Update failed" 6 -IsError; Write-Log "Update download failed: $($r.Error)"; return }
    $src = [string]$r.Data
    $errs = $null; $tok = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $src "EverhourWidget.ps1"), [ref]$tok, [ref]$errs)
    if ($errs.Count -gt 0) { Set-Toast "Update looks broken - skipped" 6 -IsError; Write-Log "Update skipped: downloaded script has $($errs.Count) parse errors"; return }
    try {
        $ok = Copy-AppFiles $src $ScriptDir
        Get-ChildItem $ScriptDir -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
        if (-not $ok) { throw "the widget script couldn't be replaced" }
    } catch { Set-Toast "Update failed" 6 -IsError; Write-Log "Update copy failed: $($_.Exception.Message)"; return }
    Write-Log "Updated from $($Script:Version) to $($Script:UpdateAvail.Version)"
    Restart-Widget
}
function Restart-Widget {
    $tmp = Join-Path $env:TEMP "everhour-widget-restart.vbs"
    (Get-LauncherVbs $ScriptPath) | Set-Content -Path $tmp -Encoding ASCII
    try { $Script:Mutex.ReleaseMutex() } catch { }
    Start-Process wscript.exe -ArgumentList "`"$tmp`""
    $form.Close()
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
    OnAccent = [System.Drawing.Color]::White
    IsLight = $false
}

# Settings, the task picker and every dialog take their colours from the
# widget's theme, so the whole app looks like one piece.
function Update-UiPalette {
    $c = $Script:Cfg
    $back = ToColor $c.BackColor; $acc = ToColor $c.AccentColor
    $text = ToColor $c.TimeColor; $task = ToColor $c.TaskColor; $idle = ToColor $c.IdleColor
    $light = IsLight $back
    $toward = if ($light) { [System.Drawing.Color]::Black } else { [System.Drawing.Color]::White }
    $UI.IsLight = $light
    $UI.Bg      = $back
    $UI.Card    = Mix $back $toward $(if ($light) { 0.05 } else { 0.06 })
    $UI.Sel     = Mix (Mix $back $toward 0.10) $acc 0.14
    $UI.Line    = Mix $back $toward $(if ($light) { 0.13 } else { 0.15 })
    $UI.Text    = $text
    $UI.Muted   = Mix $idle $task 0.6
    $UI.Accent  = $acc
    $UI.AccentH = Mix $acc $toward 0.15
    $UI.Danger  = ToColor $c.ErrorColor
    $UI.Good    = if ($light) { ToColor "#16A34A" } else { ToColor "#4ADE80" }
    $UI.OnAccent = if (IsLight $acc) { ToColor "#111114" } else { [System.Drawing.Color]::White }
    if ($Script:HasWinApi) {
        try {
            [EhMenuColors]::Bg = $UI.Card; [EhMenuColors]::Hover = $UI.Sel; [EhMenuColors]::Line = $UI.Line
            [EhMenuColors]::Text = $UI.Text; [EhMenuColors]::Muted = $UI.Muted
        } catch { }
    }
    if ($menu) { $menu.BackColor = $UI.Card; $menu.ForeColor = $UI.Text }
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
function Set-CaptureHidden($f, [switch]$Always) {
    if (-not $Script:HasWinApi -or -not $f.IsHandleCreated) { return }
    try {
        $aff = if ($Script:Cfg.HideFromCapture -or $Always) { 0x11 } else { 0 }
        if (-not [EhWin]::SetWindowDisplayAffinity($f.Handle, $aff) -and $aff -ne 0) {
            Write-Log "Hide-from-screen-share not supported on this Windows version"
        }
    } catch { }
}

# Settings and dialogs see-through like the widget, but never so faint the
# text gets hard to read.
function Get-DialogOpacity { return [Math]::Max(0.9, [Math]::Min(1.0, [double]$Script:Cfg.Opacity / 100.0)) }

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
        $b.BackColor = $UI.Accent; $b.ForeColor = $UI.OnAccent
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
    $f.Add_Shown({ param($s, $e) Set-DwmLook $s; Set-CaptureHidden $s; $s.Opacity = Get-DialogOpacity; $s.Activate(); $s.BringToFront() })
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

function Change-ApiKey {
    return (Show-Hub "settings" "connect")
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
    if ((Test-ClockOn) -and $Script:ClockState -eq "out" -and $Script:ClockUsed) { return "clockedout" }
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
        "clockedout" {
            # off for the day: a calm night-blue, nothing counting
            return @{ Bg1 = ToColor "#11131C"; Bg2 = ToColor "#262B45"; Accent = ToColor "#A5B4FC"; Glow = ToColor "#818CF8"
                      Task = ToColor "#C7D2FE"; Time = ToColor "#E0E7FF"; Muted = ToColor "#6E76A0"; Error = $C.Error; Dot = ToColor "#A5B4FC" }
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
    $prev = $Script:Mode
    $Script:Mode = Get-Mode
    if ($Script:Ready -and $Script:Mode -eq "overbreak" -and $prev -and $prev -ne "overbreak") { Play-Sound "alert" }
    $target = Get-ModePalette $Script:Mode
    if (-not $Script:Pal -or $Snap -or -not $Script:Cfg.Animations) {
        $Script:Pal = @{}; foreach ($k in $target.Keys) { $Script:Pal[$k] = $target[$k] }
        $Script:PalSettled = $true
    } else {
        # time-based easing: the same glide whatever the frame rate
        $now = $Script:Clock.Elapsed.TotalSeconds
        $dt = [Math]::Min(0.2, [Math]::Max(0.001, $now - $Script:PalAt))
        $Script:PalSettled = Step-Pal $Script:Pal $target (1 - [Math]::Exp(-$dt / 0.22))
    }
    $Script:PalAt = $Script:Clock.Elapsed.TotalSeconds
}

function Get-AnimTime {
    if (-not $Script:Cfg.Animations) { return 0.0 }
    if ($Script:FixedAnimT) { return $Script:FixedAnimT }
    return $Script:Clock.Elapsed.TotalSeconds
}

function Apply-Theme {
    $c = $Script:Cfg
    Update-UiPalette
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
    $sz = $Script:TextSizes[[string]$c.TextSize]
    if (-not $sz) { $sz = $Script:TextSizes["M"] }
    $tm = [double]$sz.Time; $tk = [double]$sz.Task
    $Script:F = @{
        Task      = New-PxFont $fam $tk
        TaskBold  = New-PxFont $fam $tk ([System.Drawing.FontStyle]::Bold)
        Time      = New-PxFont $tfam $tm ([System.Drawing.FontStyle]::Bold)
        TimeBig   = New-PxFont $tfam ($tm * 1.35) ([System.Drawing.FontStyle]::Bold)
        Small     = New-PxFont $fam ([Math]::Max(7, $tk - 1))
        SmallBold = New-PxFont $fam ([Math]::Max(7, $tk - 1.5)) ([System.Drawing.FontStyle]::Bold)
        Caps      = New-PxFont $fam ([Math]::Max(6.5, $tk - 2)) ([System.Drawing.FontStyle]::Bold)
    }
    $form.TopMost = [bool]$c.AlwaysOnTop
    if (-not $Script:Layered) {
        $form.BackColor = $Script:C.Back
        $form.Opacity = [double]$c.Opacity / 100.0
    }
    Set-CaptureHidden $form -Always:($Script:HideTarget -eq 1)
    if ($Script:HideTarget -eq 1) { $form.TopMost = $true }
    Update-ModeAndPalette
    Update-AnimTimer
    Render
}

function Get-FrameMargin { if ($Script:Layered) { return (Px 12) } else { return 0 } }

function Get-ShapeWidth {
    switch ([string]$Script:Cfg.Shape) { "Square" { return (Px $Script:Cfg.SquareSize) } "Large" { return (Px 300) } default { return (Px $Script:Cfg.Width) } }
}

function Get-CollapsedFrameHeight {
    if ($Script:Cfg.Shape -eq "Square") { return (Px $Script:Cfg.SquareSize) + 2 * (Get-FrameMargin) }
    if ($Script:Cfg.Shape -eq "Large") { return (Px 400) + 2 * (Get-FrameMargin) }
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
    if ($Script:HideP -ge 0.999) {
        $pk = Build-Peek $Script:Pal $Script:Mode
        Push-Peek $pk
        Push-ExtraPeeks $pk
        $pk.Dispose()
        return
    }
    $slide = 0.0
    if ($Script:HideP -gt 0.001) { $slide = Ease $Script:HideP }
    Push-Frame (Build-Frame $Script:Pal $Script:Mode) $slide
}

# ---------------------------------------------------------------------------
#  AUTO-HIDE: the widget slides into the nearest side edge; a slim pill of
#  dots stays visible and keeps showing the status. Hover it to bring the
#  widget back.
# ---------------------------------------------------------------------------
$Script:HideP = 0.0
$Script:HideTarget = 0
$Script:HideSide = "right"

function Get-AnchorScreen {
    $an = Get-Anchor
    return [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point(($an.X + 40), ($an.Y + 20)))).WorkingArea
}

function Start-AutoHide {
    if ($Script:HideTarget -eq 1) { return }
    $wa = Get-AnchorScreen
    $cxw = $form.Left + $form.Width / 2
    $Script:HideSide = if ($cxw -gt ($wa.Left + $wa.Width / 2)) { "right" } else { "left" }
    $Script:HideTarget = 1
    # the edge strip stays above every window, and never shows in a screen share
    $form.TopMost = $true
    Set-CaptureHidden $form -Always
    if (-not $Script:Cfg.Animations) { $Script:HideP = 1.0; Render }
    Update-AnimTimer
}

function Show-FromHide {
    if ($Script:HideTarget -eq 0) { return }
    $Script:HideTarget = 0
    Hide-ExtraPeeks
    $form.TopMost = [bool]$Script:Cfg.AlwaysOnTop
    Set-CaptureHidden $form
    $Script:PeekY = $null
    $Script:LastInteract = Get-Date
    if (-not $Script:Cfg.Animations) { $Script:HideP = 0.0; Render }
    Update-AnimTimer
}

# Opened again while it is already running: slide out of the edge, sit above
# other windows for a few seconds and open the list so it is easy to spot.
$Script:ForwardUntil = $null
function Bring-Forward {
    Show-FromHide
    Place-Form
    $form.TopMost = $true
    $Script:ForwardUntil = (Get-Date).AddSeconds(6)
    $Script:LastInteract = Get-Date
    if (-not $Script:IsExpanded -and $Script:Cfg.Shape -ne "Large") { Set-Expanded $true }
    Render
}

# The strip on every other monitor too: hover any of them and the widget
# slides out on that screen.
$Script:PeekForms = @{}
function Get-PeekForm([string]$dev) {
    $pf = $Script:PeekForms[$dev]
    if ($pf -and -not $pf.IsDisposed) { return $pf }
    $pf = New-Object System.Windows.Forms.Form
    $pf.Text = "Everhour Widget edge"
    $pf.FormBorderStyle = "None"; $pf.ShowInTaskbar = $false; $pf.StartPosition = "Manual"
    $pf.Location = New-Object System.Drawing.Point(-32000, -32000); $pf.Size = New-Object System.Drawing.Size(10, 10)
    $pf.TopMost = $true
    $pf.Tag = $dev
    $pf.Add_MouseMove({ param($s, $e) Reveal-OnScreen ([string]$s.Tag) })
    $pf.Add_MouseDown({ param($s, $e) Reveal-OnScreen ([string]$s.Tag) })
    $null = $pf.Handle
    $ex = [EhWin]::GetWindowLong($pf.Handle, -20) -bor 0x80 -bor 0x08000000 -bor 0x00080000   # tool window, no-activate, layered
    [EhWin]::SetWindowLong($pf.Handle, -20, $ex) | Out-Null
    Set-CaptureHidden $pf -Always
    $Script:PeekForms[$dev] = $pf
    return $pf
}
function Push-ExtraPeeks($bmp) {
    if (-not $Script:Layered -or -not $Script:HasWinApi) { return }
    $an = Get-Anchor
    $mainScr = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point(($an.X + 40), ($an.Y + 20))))
    $mwa = $mainScr.WorkingArea
    $py = if ($Script:PeekY) { $Script:PeekY } else { $mwa.Top + $mwa.Height / 2 }
    $rel = [Math]::Max(0.0, [Math]::Min(1.0, ($py - $mwa.Top) / [Math]::Max(1, $mwa.Height)))
    $seen = @{}
    foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
        if ($scr.DeviceName -eq $mainScr.DeviceName) { continue }
        $seen[$scr.DeviceName] = $true
        try {
            $pf = Get-PeekForm $scr.DeviceName
            $wa = $scr.WorkingArea
            $x = if ($Script:HideSide -eq "right") { $wa.Right - $bmp.Width + (Px 4) } else { $wa.Left - (Px 4) }
            $y = [int]($wa.Top + $rel * $wa.Height)
            $y = [Math]::Max($wa.Top, [Math]::Min($y, $wa.Bottom - $bmp.Height))
            [EhWin]::PushLayered($pf.Handle, $bmp, $x, $y) | Out-Null
            [EhWin]::ShowWindow($pf.Handle, 4) | Out-Null    # SW_SHOWNOACTIVATE
        } catch { }
    }
    foreach ($k in @($Script:PeekForms.Keys)) {
        if (-not $seen.ContainsKey($k)) { try { $Script:PeekForms[$k].Dispose() } catch { }; $Script:PeekForms.Remove($k) }
    }
}
function Hide-ExtraPeeks {
    foreach ($pf in $Script:PeekForms.Values) { if ($pf -and -not $pf.IsDisposed) { try { [EhWin]::ShowWindow($pf.Handle, 0) | Out-Null } catch { } } }
}
function Reveal-OnScreen([string]$dev) {
    if ($Script:HideTarget -ne 1) { return }
    $scr = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -eq $dev } | Select-Object -First 1
    if ($scr) {
        $mwa = Get-AnchorScreen
        $an = Get-Anchor
        $rel = [Math]::Max(0.0, [Math]::Min(1.0, ($an.Y - $mwa.Top) / [Math]::Max(1, $mwa.Height)))
        $wa = $scr.WorkingArea
        $M = Get-FrameMargin
        $w = (Get-ShapeWidth) + 2 * $M
        $x = if ($Script:HideSide -eq "right") { $wa.Right - $w - (Px 8) + $M } else { $wa.Left + (Px 8) - $M }
        $Script:Anchor = New-Object System.Drawing.Point($x, [int]($wa.Top + $rel * $wa.Height))
        $Script:Cfg.PosX = $Script:Anchor.X; $Script:Cfg.PosY = $Script:Anchor.Y
        Save-Config
    }
    Show-FromHide
}

function Build-Peek($Pal, [string]$Mode) {
    $M = [single](Px 6)
    $w = [single](Px 16); $h = [single](Px 84)
    $at = Get-AnimTime
    $bmp = New-Object System.Drawing.Bitmap([int]($w + 2 * $M), [int]($h + 2 * $M), [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $pulse = 0.5 + 0.5 * [Math]::Sin($at * 2 * [Math]::PI / $(if ($Mode -eq "overbreak") { 1.1 } else { 2.8 }))
    $glowA = if ($Mode -in @("stopped", "overbreak")) { [int](40 + 70 * $pulse) } else { 30 }
    Fill-Round $g (A $Pal.Glow $glowA) 0 0 ($w + 2 * $M) ($h + 2 * $M) (($w + 2 * $M) / 2)
    $rect = New-Object System.Drawing.RectangleF($M, $M, $w, $h)
    $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, (A $Pal.Bg1 245), (A $Pal.Bg2 245), [single]90)
    $pp = New-RoundPath $M $M $w $h ($w / 2)
    $g.FillPath($lg, $pp); $lg.Dispose(); $pp.Dispose()
    $n = 7; $rd = [single](Px 2.4); $cx = $M + $w / 2
    for ($i = 0; $i -lt $n; $i++) {
        $cy = $M + (Px 12) + $i * (($h - (Px 24)) / ($n - 1))
        $a = 60
        switch ($Mode) {
            { $_ -eq "work" -or $_ -eq "break" } {
                $el = Get-LiveElapsed
                $on = ($i -lt [Math]::Ceiling(($el % 60) / 60.0 * $n))
                if ([int][Math]::Floor($el / 60) % 2 -eq 1) { $on = -not $on }     # alternate laps, no jump at :00
                if ($on) { $a = 240 }
            }
            "overbreak" { $a = [int](80 + 175 * (0.5 + 0.5 * [Math]::Sin($at * 6 - $i * 0.9))) }
            "stopped"   { $head = ($at * 3.0) % $n; $d = [Math]::Abs($i - $head); $a = [int]([Math]::Max(50, 255 - $d * 70)) }
        }
        Fill-Circle $g (A $Pal.Dot $a) $cx $cy $rd
    }
    $g.Dispose()
    return $bmp
}

function Push-Peek($bmp) {
    $wa = Get-AnchorScreen
    $an = Get-Anchor
    $x = if ($Script:HideSide -eq "right") { $wa.Right - $bmp.Width + (Px 4) } else { $wa.Left - (Px 4) }
    $y = [int]($form.Top + $form.Height / 2 - $bmp.Height / 2)
    if ($Script:PeekY) { $y = $Script:PeekY } else { $Script:PeekY = $y }
    $y = [Math]::Max($wa.Top, [Math]::Min($y, $wa.Bottom - $bmp.Height))
    $Script:Hits = @([pscustomobject]@{ Name = "peek"; Rect = (New-Object System.Drawing.RectangleF(0, 0, $bmp.Width, $bmp.Height)) })
    if ($Script:Layered) {
        try { [EhWin]::PushLayered($form.Handle, $bmp, $x, $y) | Out-Null } catch { }
    } else {
        if ($Script:Frame) { $Script:Frame.Dispose() }
        $Script:Frame = $bmp.Clone()
        $form.SetBounds($x, $y, $bmp.Width, $bmp.Height)
        $form.Invalidate()
    }
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
        { $_ -eq "work" -or $_ -eq "break" } {
            # One lap per minute, like a seconds hand - while working and on a
            # break alike (the break's allowance is on the bar below). Laps
            # alternate: one lap lights the ring up, the next switches it off
            # behind the head, so the motion never jumps back to empty at :00.
            # In a focus session (or its break) the ring shows the time left
            # draining away instead.
            $el = Get-LiveElapsed
            $lit = ($el % 60) / 60.0 * $n
            $fillLap = ([int][Math]::Floor($el / 60) % 2 -eq 0)
            if (($mode -eq "work" -and $Script:FocusPhase -eq "focus") -or ($mode -eq "break" -and $Script:FocusPhase -eq "rest")) {
                $lit = (Get-FocusLeft) / [Math]::Max(1, $Script:FocusLen) * ($n - 1); $fillLap = $true
            }
            $full = [int][Math]::Min($n - 1, [Math]::Floor($lit))
            $onA = 235
            if ($mode -eq "break") { $onA = [int](200 + 55 * [Math]::Sin($at * 2 * [Math]::PI / 4)) }    # gentle breathing on a break
            $on = A $pal.Dot $onA
            if ($fillLap) {
                Fill-DotRun $g $on $dots 0 ($full - 1) $rd
                Fill-DotRun $g $dim $dots ($full + 1) ($n - 1) $rd
            } else {
                Fill-DotRun $g $dim $dots 0 ($full - 1) $rd
                Fill-DotRun $g $on $dots ($full + 1) ($n - 1) $rd
            }
            $hd = $dots[$full]
            Fill-Circle $g (A $pal.Dot ([int](110 + 145 * ($lit - [Math]::Floor($lit))))) $hd.X $hd.Y ($rd * 1.15)
            Fill-Circle $g (A $pal.Glow 75) $hd.X $hd.Y ($rd * 2.8)
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
        "clockedout" {
            # resting: the whole ring breathes slowly, nothing runs
            $ba = if ($Script:Cfg.Animations) { [int](40 + 45 * (0.5 + 0.5 * [Math]::Sin($at * 2 * [Math]::PI / 6))) } else { 60 }
            Fill-DotRun $g (A $pal.Dot $ba) $dots 0 ($n - 1) $rd
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
    $isLarge = ($cfg.Shape -eq "Large")
    $square = ($cfg.Shape -eq "Square" -or $isLarge)
    $expanded = $Script:IsExpanded -or $isLarge
    $M = Get-FrameMargin
    $P = [single](Px 16)
    $R = [single]$(if ($square) { Px 24 } else { Px 16 })
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
    $offSince = Get-OffSince
    $clockBtn = Test-ClockOn

    # ---------- what goes where ----------
    if ($square) {
        $W = if ($isLarge) { [single](Px 300) } else { [single](Px $cfg.SquareSize) }
        if ($expanded) { $W = [single][Math]::Max($W, (Px 290)) }
        $btnD = [single](Px 34)
        $btnX = $W - $P - $btnD; $btnY = $P - (Px 2)
        $capsRect = @(($P + (Px 2)), $P, ($btnX - $P - (Px 8)), ($btnD - (Px 4)))
        $timeFont = $F.TimeBig
        if ((Measure-W "00:00:00" $timeFont) -gt ($W - 2 * $P)) { $timeFont = $F.Time }
        $hTime = [single]$timeFont.GetHeight()
        $stackH = ($hT - (Px 2)) + ($hTime - (Px 4)) + $hS
        $top = $btnY + $btnD
        if ($expanded) {
            # open: the block sits right under the top row, list follows
            $taskY = $top + (Px 8)
            $timeY = $taskY + $hT - (Px 2)
            $todayY = $timeY + $hTime - (Px 4)
            $barY = $todayY + $hS + (Px 10)
            $y = $barY + (Px 4)
            $collapsedBottom = $y + $P
        } else {
            # closed square: the block is centred between the top row and the bar
            $sqH = [single](Px $cfg.SquareSize)
            $barY = $sqH - $P - (Px 4)
            $taskY = $top + ($barY - (Px 6) - $top - $stackH) / 2
            $timeY = $taskY + $hT - (Px 2)
            $todayY = $timeY + $hTime - (Px 4)
            $y = $sqH - $P
            $collapsedBottom = $sqH
        }
        $line1 = @(($P + (Px 2)), $taskY, ($W - 2 * $P), $hT)
        $timeRect = @(($P - (Px 1)), $timeY, ($W - 2 * $P), $hTime)
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
    $grpH = $hS + (Px 14)
    if ($expanded) {
        # TODAY and THIS WEEK are groups; at most one is open, showing 5 rows
        # that scroll, so the widget never grows past one open group
        $open = [string]$Script:OpenGroup
        $listAll = @()
        if ($open -eq "today") { $listAll = @(Get-BreakdownRows) } elseif ($open -eq "week") { $listAll = @(Get-WeekRows) }
        $vis = [Math]::Min(5, $listAll.Count)
        $maxScroll = [Math]::Max(0, $listAll.Count - 5)
        $scroll = [int][Math]::Max(0, [Math]::Min($Script:ListScroll, $maxScroll))
        $Script:ListScroll = $scroll
        $listH = if ($vis -eq 0) { $hT + (Px 8) } else { $vis * $rowH }
        $y += (Px 12) + 1 + (Px 6) + 2 * $grpH
        if ($open) { $y += $listH + (Px 4) }
        $favL = Get-FavLayout $W $P
        if ($favL) { $y += $hS + (Px 6) + $favL.H + (Px 10) }
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
    } elseif ($Mode -eq "clockedout") {
        # clock face: click to clock in
        Fill-Circle $g (A $Pal.Accent $(if ($hovBtn) { 90 } else { 48 })) $cx $cy ($btnD / 2)
        $cr = $btnD * 0.24
        $cpen = New-Object System.Drawing.Pen($Pal.Accent, [single][Math]::Max(1.5, (Px 1.8)))
        $cpen.StartCap = "Round"; $cpen.EndCap = "Round"
        $g.DrawEllipse($cpen, ($cx - $cr), ($cy - $cr), (2 * $cr), (2 * $cr))
        $g.DrawLine($cpen, $cx, $cy, $cx, ($cy - $cr * 0.62))
        $g.DrawLine($cpen, $cx, $cy, ($cx + $cr * 0.5), ($cy + $cr * 0.18))
        $cpen.Dispose()
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

    # ---------- privacy eye ----------
    $es = [single](Px 9)
    if ($square) { $ex = $btnX - (Px 18); $eyc = $btnY + $btnD / 2; $capsRect[2] -= (Px 26) }
    else { $ex = $W - (Px 20); $eyc = (Px 10) }
    $hovE = ($Script:Hover -eq "eye")
    if ($hovE) { Fill-Circle $g (A $Pal.Muted 60) $ex $eyc ($es * 1.25) }
    Draw-Eye $g $(if ($cfg.PrivacyMode) { $Pal.Accent } elseif ($hovE) { $Pal.Task } else { $Pal.Muted }) $ex $eyc $es ([bool]$cfg.PrivacyMode)
    Add-Hit "eye" ($ex - $es * 1.3 + $M) ($eyc - $es * 1.3 + $M) ($es * 2.6) ($es * 2.6)

    # ---------- status chip ----------
    $chip = ""; $chipC = $Pal.Error; $chipHit = ""
    if ($Script:Toast -and $now -lt $Script:ToastUntil) {
        $chip = $Script:Toast
        $chipC = if ($Script:ToastIsError) { $Pal.Error } else { $Pal.Accent }
    } elseif ($Script:LastError -eq "OFFLINE") { $chip = "offline" }
    elseif ($Script:LastError -eq "RATE") { $chip = "slowing down" }
    elseif ($Script:LastError -eq "AUTH") { $chip = "key rejected" }
    elseif ($Script:UpdateAvail) { $chip = "Update to v$($Script:UpdateAvail.Version)"; $chipC = $Pal.Accent; $chipHit = "update" }
    elseif ($Script:FocusPhase -and -not $square) { $chip = (Get-FocusLabel).ToLower(); $chipC = $Pal.Accent }

    # ---------- texts ----------
    $l1 = ""; $l1C = $Pal.Task; $l1F = $F.Task
    if ($hovBtn -and $Script:LastError -eq "AUTH") { $l1 = "Click to enter your API token"; $l1C = $Pal.Error }
    elseif ($hovBtn -and $Script:IsRunning) { $l1 = "Stop timer"; $l1C = $Pal.Accent }
    elseif ($hovBtn -and $Mode -eq "clockedout") { $l1 = "Clock in"; $l1C = $Pal.Accent }
    elseif ($hovBtn) {
        $l1C = $Pal.Accent
        $l1 = if ($cfg.LastTaskId) { "Resume  " + $cfg.LastTaskName } else { "Start a timer" }
    }
    elseif ($Mode -eq "overbreak") { $l1 = "Break over by " + (Format-Short ($breakSec - $limit)); $l1F = $F.TaskBold }
    elseif ($Script:IsRunning) { $l1 = $Script:TaskName }
    elseif (-not $Script:FirstPollDone -and -not $Script:LastError) { $l1 = "Connecting to Everhour..."; $l1C = $Pal.Muted }
    elseif ($stoppedShow) { $l1 = "Timer off since " + $offSince.ToString("h:mm tt"); $l1C = $Pal.Task }
    elseif ($Mode -eq "clockedout") {
        $l1 = if ($Script:ClockOutAt) { "Clocked out at " + $Script:ClockOutAt.ToString("h:mm tt") } else { "Not clocked in yet" }
        $l1C = $Pal.Task
    }
    else { $l1 = "Not tracking"; $l1C = $Pal.Muted }

    $timeText = Format-HMS 0
    $timeC = A $Pal.Time 115
    if ($Script:IsRunning) { $timeText = Format-HMS (Get-LiveElapsed); $timeC = $Pal.Time }
    elseif ($stoppedShow) { $timeText = Format-HMS (($now - $offSince).TotalSeconds); $timeC = $Pal.Time }
    if ($cfg.PrivacyMode) {
        if ($Script:TaskName -and $l1 -eq $Script:TaskName) { $l1 = Hide-Name $l1 }
        elseif ($l1 -like "Resume  *") { $l1 = "Resume  " + (Hide-Name $cfg.LastTaskName) }
        $l1 = Hide-Num $l1
        $timeText = Hide-Num $timeText
    }

    if ($square) {
        $caps = switch ($Mode) { "work" { "TRACKING" } "break" { "ON BREAK" } "overbreak" { "BREAK OVER" } "stopped" { "TIMER OFF" } "clockedout" { "CLOCKED OUT" } default { "EVERHOUR" } }
        if ($Script:FocusPhase) { $caps = (Get-FocusLabel).ToUpper() }
        $cxp = $capsRect[0]
        if ($isBreak) { Draw-Cup $g $Pal.Accent $cxp ($capsRect[1] + (Px 6)) ([single](Px 15)) $at; $cxp += (Px 20) }
        elseif ($Mode -eq "work" -or $Mode -eq "stopped") {
            $da = if ($Mode -eq "work") { 255 } else { [int](120 + 135 * $pulse) }
            Fill-Circle $g (A $Pal.Dot $da) ($cxp + (Px 4)) ($capsRect[1] + $capsRect[3] / 2) ([single](Px 3.5)); $cxp += (Px 13)
        }
        if ($chip) {
            if ($chipHit) {
                $pw = [Math]::Min((Measure-W $chip $F.SmallBold) + (Px 14), $capsRect[0] + $capsRect[2] - $cxp)
                $ph = $hS + (Px 6); $py0 = $capsRect[1] + ($capsRect[3] - $ph) / 2
                Fill-Round $g (A $chipC $(if ($Script:Hover -eq $chipHit) { 90 } else { 50 })) ($cxp - (Px 4)) $py0 $pw $ph ($ph / 2)
                Draw-Text $g $chip $F.SmallBold $Pal.Time ($cxp - (Px 4)) $py0 $pw $ph "Center"
                Add-Hit $chipHit ($cxp - (Px 4) + $M) ($py0 + $M) $pw $ph
            } else {
                Draw-Text $g $chip $F.SmallBold $chipC $cxp $capsRect[1] ($capsRect[0] + $capsRect[2] - $cxp) $capsRect[3] "Left"
            }
        } else {
            Draw-Text $g $caps $F.Caps $Pal.Muted $cxp $capsRect[1] ($capsRect[0] + $capsRect[2] - $cxp) $capsRect[3] "Left"
        }
        if ($stoppedShow -and -not $hovBtn) { $l1 = Hide-Num ("Off since " + $offSince.ToString("h:mm tt")) }
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
            $main = Hide-Num $main; $suffix = Hide-Num $suffix
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
            if ($chipHit) { Add-Hit $chipHit ($chX + $M) ($chY + $M) $cw $ch }
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
            $main = Hide-Num $main; $suffix = Hide-Num $suffix
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
    if ($expanded) {
        $ey = $expStart + (Px 12)
        $lp = New-Object System.Drawing.Pen((A $Pal.Muted 70), 1)
        $g.DrawLine($lp, $P, $ey, ($W - $P), $ey); $lp.Dispose()
        $ey += 1 + (Px 6)
        $Script:RowNames = @{}
        foreach ($grp in @("today", "week")) {
            $isOpen = ($open -eq $grp)
            $hovG = ($Script:Hover -eq "grp:$grp")
            if ($hovG) { Fill-Round $g (A $Pal.Muted 32) ($P - (Px 6)) $ey ($W - 2 * $P + (Px 12)) $grpH (Px 8) }
            # caret: down when open, right when closed
            $cy = $ey + $grpH / 2; $cx = $P + (Px 4); $cs = [single](Px 3.5)
            $tri = if ($isOpen) {
                [System.Drawing.PointF[]]@((New-Object System.Drawing.PointF(($cx - $cs), ($cy - $cs * 0.6))), (New-Object System.Drawing.PointF(($cx + $cs), ($cy - $cs * 0.6))), (New-Object System.Drawing.PointF($cx, ($cy + $cs * 0.8))))
            } else {
                [System.Drawing.PointF[]]@((New-Object System.Drawing.PointF(($cx - $cs * 0.6), ($cy - $cs))), (New-Object System.Drawing.PointF(($cx - $cs * 0.6), ($cy + $cs))), (New-Object System.Drawing.PointF(($cx + $cs * 0.8), $cy)))
            }
            $tb = New-Object System.Drawing.SolidBrush($(if ($isOpen) { $Pal.Task } else { $Pal.Muted })); $g.FillPolygon($tb, $tri); $tb.Dispose()
            $label = if ($grp -eq "today") { "TODAY" } else { "THIS WEEK" }
            Draw-Text $g $label $F.Caps $(if ($isOpen) { $Pal.Task } else { $Pal.Muted }) ($P + (Px 14)) $ey ($W / 2) $grpH "Left"
            $tot = if ($grp -eq "today") { if ($hasToday) { Format-Short $today } else { "--" } } else { $wk = Get-WeekTotal; if ($wk -ge 0) { Format-Short $wk } else { "--" } }
            Draw-Text $g (Hide-Num $tot) $F.SmallBold $Pal.Task ($W / 2) $ey ($W / 2 - $P) $grpH "Right"
            Add-Hit "grp:$grp" ($P - (Px 6) + $M) ($ey + $M) ($W - 2 * $P + (Px 12)) $grpH
            $ey += $grpH
            if (-not $isOpen) { continue }
            if ($vis -eq 0) {
                $msg = if ($grp -eq "today") { if ($Script:RecordsLoaded) { "Nothing tracked yet today" } else { "Loading..." } } else { if ($Script:WeekLoaded) { "Nothing tracked this week" } else { "Loading..." } }
                Draw-Text $g $msg $F.Task $Pal.Muted $P $ey ($W - 2 * $P) $hT "Left"
                $ey += $hT + (Px 8) + (Px 4)
                continue
            }
            $listTop = $ey
            $maxSec = [Math]::Max(1, $listAll[0].Sec)
            $durW = [single](Px 66)
            for ($r = $scroll; $r -lt $scroll + $vis; $r++) {
                $row = $listAll[$r]
                $Script:RowNames[[string]$row.Id] = [string]$row.Name
                $hovR = ($Script:Hover -eq "row:$($row.Id)")
                if ($hovR) { Fill-Round $g (A $Pal.Muted 34) ($P - (Px 6)) ($ey - (Px 3)) ($W - 2 * $P + (Px 12)) ($rowH - (Px 1)) (Px 7) }
                $nc = if ($row.Running) { $Pal.Time } else { $Pal.Task }
                $nf = if ($row.Running) { $F.TaskBold } else { $F.Task }
                Draw-Text $g (Hide-Name $row.Name) $nf $nc $P $ey ($W - 2 * $P - $durW) $hT "Left"
                $dc = if ($row.Running) { $Pal.Accent } else { $Pal.Task }
                $durText = if ($hovR -and -not $row.Running) { "start" } else { Hide-Num (Format-Short $row.Sec) }
                if ($hovR -and -not $row.Running) { $dc = $Pal.Accent }
                Draw-Text $g $durText $F.Task $dc ($W - $P - $durW) $ey $durW $hT "Right"
                $by = $ey + $hT + (Px 2); $bhh = [single][Math]::Max(2, (Px 3))
                Fill-Round $g (A $Pal.Muted 40) $P $by ($W - 2 * $P) $bhh ($bhh / 2)
                $fc = if ($row.Running) { $Pal.Accent } elseif (Test-IsBreak $row.Name) { A (ToColor "#5EEAD4") 190 } else { A $Pal.Muted 190 }
                Fill-Round $g $fc $P $by ([Math]::Max($bhh, ($W - 2 * $P) * $row.Sec / $maxSec)) $bhh ($bhh / 2)
                Add-Hit "row:$($row.Id)" ($P - (Px 6) + $M) ($ey - (Px 3) + $M) ($W - 2 * $P + (Px 12)) $rowH
                $ey += $rowH
            }
            if ($maxScroll -gt 0) {
                # thin scrollbar on the right of the list
                $trackH = $vis * $rowH - (Px 6)
                $sx = $W - (Px 9)
                Fill-Round $g (A $Pal.Muted 40) $sx $listTop (Px 3) $trackH (Px 1.5)
                $thH = [Math]::Max((Px 14), $trackH * $vis / $listAll.Count)
                $thY = $listTop + ($trackH - $thH) * $scroll / $maxScroll
                Fill-Round $g (A $Pal.Task 150) $sx $thY (Px 3) $thH (Px 1.5)
            }
            Add-Hit "list" $M ($listTop + $M) $W ($vis * $rowH)
            $ey += (Px 4)
        }
        if ($favL) {            # favourite tasks as one-click chips
            $ey += (Px 4)
            Draw-Text $g "QUICK SWITCH" $F.Caps $Pal.Muted $P $ey ($W - 2 * $P) $hS "Left"
            $ey += $hS + (Px 6)
            foreach ($it in $favL.Items) {
                $cx0 = $P + $it.X; $cy0 = $ey + $it.Y
                $on = ($Script:IsRunning -and $Script:TaskId -eq $it.Id)
                $hov = ($Script:Hover -eq "fav:$($it.I)")
                $bg = if ($on) { A $Pal.Accent 150 } elseif ($hov) { A $Pal.Muted 95 } else { A $Pal.Muted 45 }
                Fill-Round $g $bg $cx0 $cy0 $it.W $favL.Ch ($favL.Ch / 2)
                Draw-Text $g (Hide-Name $it.Name) $F.Small $(if ($on) { $Pal.Time } else { $Pal.Task }) ($cx0 + (Px 8)) $cy0 ($it.W - (Px 16)) $favL.Ch "Center"
                Add-Hit "fav:$($it.I)" ($cx0 + $M) ($cy0 + $M) $it.W $favL.Ch
            }
            $ey += $favL.H + (Px 10)
        }
        $ey += (Px 6)

        $gap = [single](Px 6)
        $labels = @(
            @{ Name = "b_start"; Text = $(if ($Script:IsRunning) { if ($square) { "Switch" } else { "Switch task" } } elseif ($square) { "Start" } else { "Start task" }); Primary = $true },
            @{ Name = "b_stop"; Text = $(if ($Script:IsRunning) { "Stop" } else { "Resume" }); Primary = $false })
        $rowW = $W - 2 * $P
        if ($clockBtn) {
            # clock in / out takes the third place; Settings shrinks to a gear
            $clockIn = ($Script:ClockState -eq "in")
            $labels += @{ Name = "b_clock"; Text = $(if ($clockIn) { "Clock out" } else { "Clock in" }); Primary = (-not $clockIn) }
            if ($Mode -eq "clockedout") { $labels[0].Primary = $false }
            $gx = $W - $P - $btnH
            $hovS = ($Script:Hover -eq "b_settings")
            Fill-Round $g (A $Pal.Muted $(if ($hovS) { 90 } else { 48 })) $gx $ey $btnH $btnH ($btnH / 2)
            Draw-Gear $g $Pal.Task ($gx + $btnH / 2) ($ey + $btnH / 2) ([single]($btnH * 0.22))
            Add-Hit "b_settings" ($gx + $M) ($ey + $M) $btnH $btnH
            $rowW -= $btnH + $gap
        } else {
            $labels += @{ Name = "b_settings"; Text = "Settings"; Primary = $false }
        }
        # Each button is as wide as its word plus padding; the spare room is
        # shared equally. Too tight? Smaller text first, then squeeze evenly.
        $avail = $rowW - 2 * $gap
        $pad = [single](Px 14)
        $fonts = @(); $need = @()
        foreach ($small in @($false, $true)) {
            $fonts = @(foreach ($lb in $labels) {
                if ($small) { if ($lb.Primary) { $F.SmallBold } else { $F.Small } } else { if ($lb.Primary) { $F.TaskBold } else { $F.Task } }
            })
            $need = @(for ($i = 0; $i -lt 3; $i++) { (Measure-W $labels[$i].Text $fonts[$i]) + $pad })
            if (($need | Measure-Object -Sum).Sum -le $avail) { break }
        }
        $sum = ($need | Measure-Object -Sum).Sum
        $widths = if ($sum -le $avail) { @($need | ForEach-Object { [single]($_ + ($avail - $sum) / 3) }) }
                  else { @($need | ForEach-Object { [single]($_ * $avail / $sum) }) }
        $bx = $P - $gap; $bW = 0
        for ($i = 0; $i -lt 3; $i++) {
            $bx += $bW + $gap
            $bW = $widths[$i]
            $hov = ($Script:Hover -eq $labels[$i].Name)
            $bf = $fonts[$i]
            if ($labels[$i].Primary) {
                Fill-Round $g (A $Pal.Accent $(if ($hov) { 140 } else { 95 })) $bx $ey $bW $btnH ($btnH / 2)
                Draw-Text $g $labels[$i].Text $bf $Pal.Time $bx $ey $bW $btnH "Center"
            } else {
                Fill-Round $g (A $Pal.Muted $(if ($hov) { 90 } else { 48 })) $bx $ey $bW $btnH ($btnH / 2)
                Draw-Text $g $labels[$i].Text $bf $Pal.Task $bx $ey $bW $btnH "Center"
            }
            Add-Hit $labels[$i].Name ($bx + $M) ($ey + $M) $bW $btnH
        }
    }

    $g.Dispose()
    return $bmp
}

# ---- privacy: the eye on the widget hides task names and every number ----
function Hide-Name([string]$s) {
    if (-not $Script:Cfg.PrivacyMode -or [string]::IsNullOrEmpty($s)) { return $s }
    return ([string][char]0x2022) * 8
}
function Hide-Num([string]$s) {
    if (-not $Script:Cfg.PrivacyMode -or [string]::IsNullOrEmpty($s)) { return $s }
    return ($s -replace '\d', [string][char]0x2022)
}
function Draw-Gear($g, $color, [single]$cx, [single]$cy, [single]$s) {
    $pen = New-Object System.Drawing.Pen($color, [single][Math]::Max(1.4, $s * 0.42))
    $pen.StartCap = "Round"; $pen.EndCap = "Round"
    for ($k = 0; $k -lt 8; $k++) {
        $a = $k * [Math]::PI / 4
        $g.DrawLine($pen, ($cx + [Math]::Cos($a) * $s * 0.9), ($cy + [Math]::Sin($a) * $s * 0.9), ($cx + [Math]::Cos($a) * $s * 1.25), ($cy + [Math]::Sin($a) * $s * 1.25))
    }
    $pen.Width = [single][Math]::Max(1.3, $s * 0.3)
    $g.DrawEllipse($pen, ($cx - $s * 0.78), ($cy - $s * 0.78), ($s * 1.56), ($s * 1.56))
    $pen.Dispose()
}
function Draw-Eye($g, $color, [single]$cx, [single]$cy, [single]$s, [bool]$closed) {
    $pen = New-Object System.Drawing.Pen($color, [single][Math]::Max(1.3, $s * 0.16))
    $pen.StartCap = "Round"; $pen.EndCap = "Round"
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddBezier(($cx - $s), $cy, ($cx - $s * 0.45), ($cy - $s * 0.75), ($cx + $s * 0.45), ($cy - $s * 0.75), ($cx + $s), $cy)
    $p.AddBezier(($cx + $s), $cy, ($cx + $s * 0.45), ($cy + $s * 0.75), ($cx - $s * 0.45), ($cy + $s * 0.75), ($cx - $s), $cy)
    $g.DrawPath($pen, $p); $p.Dispose()
    Fill-Circle $g $color $cx $cy ($s * 0.3)
    if ($closed) { $g.DrawLine($pen, ($cx - $s * 0.85), ($cy + $s * 0.75), ($cx + $s * 0.85), ($cy - $s * 0.75)) }
    $pen.Dispose()
}
function Get-FavLayout([single]$W, [single]$P) {
    $favs = @(Get-Favs)
    if ($favs.Count -eq 0) { return $null }
    $ch = [single](Px 26); $gap = [single](Px 6); $maxW = $W - 2 * $P
    $x = [single]0; $y = [single]0; $items = @()
    for ($i = 0; $i -lt $favs.Count; $i++) {
        $nm = Hide-Name ([string]$favs[$i].Name)
        $tw =[single][Math]::Min($maxW * 0.62, (Measure-W $nm $Script:F.Small) + (Px 22))
        if ($x -gt 0 -and $x + $tw -gt $maxW) { $x = 0; $y += $ch + $gap }
        $items += [pscustomobject]@{ I = $i; Id = [string]$favs[$i].Id; Name = $nm; X = $x; Y = $y; W = $tw }
        $x += $tw + $gap
    }
    return @{ Items = $items; H = $y + $ch; Ch = $ch }
}

function Get-Anchor {
    if (-not $Script:Anchor) { Place-Form }
    return $Script:Anchor
}

function Push-Frame($bmp, [double]$slide = 0) {
    $an = Get-Anchor
    $wa = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point(($an.X + 40), ($an.Y + 20)))).WorkingArea
    $M = Get-FrameMargin
    # always keep the whole card on screen: grow up / left instead of off an edge
    $px = $an.X; $py = $an.Y
    if ($px + $bmp.Width - $M -gt $wa.Right) { $px = $wa.Right - $bmp.Width + $M }
    if ($px + $M -lt $wa.Left) { $px = $wa.Left - $M }
    if ($py + $bmp.Height - $M -gt $wa.Bottom) { $py = $wa.Bottom - $bmp.Height + $M }
    if ($py + $M -lt $wa.Top) { $py = $wa.Top - $M }
    if ($slide -gt 0) {
        # sliding into the side edge (auto-hide)
        $tx = if ($Script:HideSide -eq "right") { $wa.Right - $M } else { $wa.Left - $bmp.Width + $M }
        $px = [int]($px + ($tx - $px) * $slide)
    }
    if ($Script:Layered) {
        $ok = $false
        try { $ok = [EhWin]::PushLayered($form.Handle, $bmp, $px, $py) } catch { }
        $bmp.Dispose()
        if (-not $ok) { Switch-ToBasicWindow }
        return
    }
    if ($Script:Frame) { $Script:Frame.Dispose() }
    $Script:Frame = $bmp
    $form.SetBounds($px, $py, $bmp.Width, $bmp.Height)
    try {
        $p = New-RoundPath 0 0 $bmp.Width $bmp.Height (Px $(if ($Script:Cfg.Shape -eq "Wide") { 16 } else { 24 }))
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
    $w = (Get-ShapeWidth) + 2 * $M
    $h = Get-CollapsedFrameHeight
    $Script:Anchor = New-Object System.Drawing.Point(($wa.Right - $w - (Px 8) + $M), ($wa.Bottom - $h - (Px 8) + $M))
}

function Test-ShowsList { return ($Script:IsExpanded -or $Script:Cfg.Shape -eq "Large") }

function Set-Expanded([bool]$on) {
    if ($Script:Cfg.Shape -eq "Large") { $on = $false }    # Large is always open
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
#  30 fps while sliding or changing colour, 20 fps for the red / break
#  effects, 10 fps for the calm "work" look. Everything is time-based, so
#  motion stays even if a frame is late. Nothing extra when animations are
#  off (the 1-second clock redraws then).
# ===========================================================================
$Script:LastAnimAt = 0.0
$animTimer = New-Object System.Windows.Forms.Timer
$animTimer.Interval = 50
$animTimer.Add_Tick({
    $now = $Script:Clock.Elapsed.TotalSeconds
    $dt = [Math]::Min(0.1, [Math]::Max(0.0, $now - $Script:LastAnimAt))
    $Script:LastAnimAt = $now
    if ($Script:HideP -ne $Script:HideTarget) {
        $step = $dt / 0.32
        if ($Script:HideTarget -eq 1) { $Script:HideP = [Math]::Min(1.0, $Script:HideP + $step) }
        else { $Script:HideP = [Math]::Max(0.0, $Script:HideP - $step) }
    }
    Update-ModeAndPalette
    if (-not $Script:Dragging) { Render }
    $sliding = ($Script:HideP -gt 0 -and $Script:HideP -lt 1)
    $want = if ($sliding -or -not $Script:PalSettled) { 33 }
            elseif ($Script:HideP -ge 1) { 80 }
            elseif ($Script:Mode -in @("stopped", "overbreak", "break")) { 50 }
            else { 100 }
    if ($animTimer.Interval -ne $want) { $animTimer.Interval = $want }
})
function Update-AnimTimer {
    if (-not $Script:Ready) { return }
    if ($Script:Cfg.Animations) { if (-not $animTimer.Enabled) { $Script:LastAnimAt = $Script:Clock.Elapsed.TotalSeconds; $animTimer.Start() } }
    else { $animTimer.Stop() }
}

# ===========================================================================
#  SETTINGS + SETUP HUB
#  One widget-style card for both the first-run questions and Settings.
#  Pages slide in and out, one question at a time; every answer is saved and
#  shown on the widget straight away - there is no Save button.
# ===========================================================================
$Script:TextSizes = [ordered]@{ "S" = @{ Time = 15; Task = 8.5 }; "M" = @{ Time = 18; Task = 9 }; "L" = @{ Time = 22; Task = 10.5 } }
$Script:SetupPages = @("welcome", "connect", "theme", "shape", "font", "size", "workday", "breaks", "target", "finish")
$Script:HubW = 400

function Set-Cfg([string]$key, $value) {
    $Script:Cfg[$key] = $value
    Save-Config
    Apply-Theme
}

function Toggle-Cfg([string]$key) {
    if ($key -eq "_autostart") {
        if (Test-Autostart) { Remove-Autostart } else { Install-Autostart | Out-Null }
        return
    }
    Set-Cfg $key (-not [bool]$Script:Cfg[$key])
    if ($key -eq "HotkeyEnabled") { Register-Hotkey }
    if ($key -eq "AutoHide" -and -not $Script:Cfg.AutoHide) { Show-FromHide }
    if ($key -eq "ClockInOut") { $Script:ClockAt = [DateTime]::MinValue; if ($Script:Cfg.ClockInOut) { Request-Poll -Force } else { Render } }
}

function Get-CurrentThemeName {
    foreach ($name in $Script:Themes.Keys) {
        $t = $Script:Themes[$name]; $same = $true
        foreach ($k in $t.Keys) { if ([string]$Script:Cfg[$k] -ne $t[$k]) { $same = $false } }
        if ($same) { return $name }
    }
    return "Custom"
}

function Format-Days([string]$days) {
    $d = @(([string]$days) -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (($d -join ",") -eq "Mon,Tue,Wed,Thu,Fri") { return "Mon-Fri" }
    if (($d -join ",") -eq "Mon,Tue,Wed,Thu,Fri,Sat") { return "Mon-Sat" }
    if ($d.Count -eq 7) { return "Every day" }
    if ($d.Count -eq 0) { return "No days" }
    return ($d -join ", ")
}

# ---------------------------------------------------------------------------
#  Hub building blocks (logical 96-DPI coordinates; scaled inside)
# ---------------------------------------------------------------------------
function Add-HubCtrl($p, $c) { $p.Controls.Add($c); return $c }

function New-PaintPanel([int]$x, [int]$y, [int]$w, [int]$h) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point((Px $x), (Px $y))
    $p.Size = New-Object System.Drawing.Size((Px $w), (Px $h))
    $p.BackColor = $UI.Bg
    Set-DoubleBuffered $p
    return $p
}

function Start-Paint($e) {
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    return $g
}

function Draw-UiText($g, [string]$text, $font, $color, $rect, [string]$align = "Left") {
    $flags = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix
    $flags = $flags -bor $(switch ($align) { "Right" { [System.Windows.Forms.TextFormatFlags]::Right } "Center" { [System.Windows.Forms.TextFormatFlags]::HorizontalCenter } default { [System.Windows.Forms.TextFormatFlags]::Left } })
    [System.Windows.Forms.TextRenderer]::DrawText($g, $text, $font, $rect, $color, $flags)
}

# A switch bound straight to a config key (or "_autostart").
function New-HubToggle([string]$label, [string]$key, [int]$x, [int]$y, [int]$w = 352, [string]$sub = "") {
    $h = if ($sub) { 48 } else { 36 }
    $p = New-PaintPanel $x $y $w $h
    $p.Cursor = "Hand"
    $p.Tag = @{ Key = $key; Text = $label; Sub = $sub }
    $p.Add_Paint({
        param($s, $e)
        $g = Start-Paint $e
        $on = if ($s.Tag.Key -eq "_autostart") { Test-Autostart } else { [bool]$Script:Cfg[$s.Tag.Key] }
        $sw = [single](Px 38); $sh = [single](Px 22)
        $sx = $s.Width - $sw - 2; $sy = ($s.Height - $sh) / 2
        Fill-Round $g $(if ($on) { $UI.Accent } else { $UI.Line }) $sx $sy $sw $sh ($sh / 2)
        $kd = $sh - (Px 6)
        $kx = if ($on) { $sx + $sw - $kd - (Px 3) } else { $sx + (Px 3) }
        Fill-Round $g ([System.Drawing.Color]::White) $kx ($sy + (Px 3)) $kd $kd ($kd / 2)
        if ($s.Tag.Sub) {
            Draw-UiText $g $s.Tag.Text $FontUI $UI.Text (New-Object System.Drawing.Rectangle(0, (Px 3), [int]($sx - (Px 8)), (Px 22)))
            Draw-UiText $g $s.Tag.Sub $FontSmall $UI.Muted (New-Object System.Drawing.Rectangle(0, (Px 24), [int]($sx - (Px 8)), (Px 20)))
        } else {
            Draw-UiText $g $s.Tag.Text $FontUI $UI.Text (New-Object System.Drawing.Rectangle(0, 0, [int]($sx - (Px 8)), $s.Height))
        }
    })
    $p.Add_Click({ param($s, $e) Toggle-Cfg $s.Tag.Key; $s.Invalidate() })
    return $p
}

# Pill chips. $Get returns the current value; $Set receives the picked value.
# -Unit adds a "Custom" chip that turns into a small number box.
function New-Chips($opts, [int]$x, [int]$y, [int]$w, [scriptblock]$Get, [scriptblock]$Set, [string]$Unit = "", [switch]$Multi) {
    $all = @($opts)
    if ($Unit) { $all += @{ L = "Custom"; V = "__custom" } }
    # lay the chips out once, wrapping onto new rows
    $rects = @(); $cx = 0; $cy = 0; $ch = Px 34; $gap = Px 8
    foreach ($o in $all) {
        $tw = [System.Windows.Forms.TextRenderer]::MeasureText([string]$o.L, $FontUIBold).Width + (Px 26)
        if ($o.V -eq "__custom") { $tw += Px 34 }
        if ($cx -gt 0 -and $cx + $tw -gt (Px $w)) { $cx = 0; $cy += $ch + $gap }
        $rects += [pscustomobject]@{ Opt = $o; Rect = (New-Object System.Drawing.Rectangle($cx, $cy, $tw, $ch)) }
        $cx += $tw + $gap
    }
    $p = New-PaintPanel $x $y $w 10
    $p.Height = $cy + $ch + 2
    $p.Cursor = "Hand"
    $p.Tag = @{ Rects = $rects; Get = $Get; Set = $Set; Unit = $Unit; Multi = [bool]$Multi; Box = $null; Vals = @($opts | ForEach-Object { $_.V }) }
    $p.Add_Paint({
        param($s, $e)
        $g = Start-Paint $e
        $t = $s.Tag
        $cur = & $t.Get
        foreach ($r in $t.Rects) {
            $v = $r.Opt.V
            $sel = if ($t.Multi) { @($cur) -contains $v } elseif ($v -eq "__custom") { $null -ne $cur -and -not ($t.Vals -contains $cur) } else { $cur -eq $v }
            $rc = $r.Rect
            Fill-Round $g $(if ($sel) { $UI.Accent } else { $UI.Card }) $rc.X $rc.Y ($rc.Width - 1) ($rc.Height - 1) ($rc.Height / 2)
            $lbl = [string]$r.Opt.L
            if ($v -eq "__custom" -and $sel) { $lbl = "$cur $($t.Unit)" }
            $fc = if ($sel) { $UI.OnAccent } else { $UI.Text }
            Draw-UiText $g $lbl $FontUIBold $fc $rc "Center"
        }
    })
    $p.Add_MouseClick({
        param($s, $e)
        $t = $s.Tag
        foreach ($r in $t.Rects) {
            if (-not $r.Rect.Contains($e.Location)) { continue }
            $v = $r.Opt.V
            if ($v -eq "__custom") {
                if (-not $t.Box) {
                    $tb = New-Object System.Windows.Forms.TextBox
                    $tb.Font = $FontUIBold; $tb.BorderStyle = "None"; $tb.TextAlign = "Center"
                    $tb.BackColor = $UI.Accent; $tb.ForeColor = [System.Drawing.Color]::White
                    $tb.Tag = $s
                    $tb.Add_KeyDown({ param($b, $ev) if ($ev.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { $ev.SuppressKeyPress = $true; Commit-ChipBox $b } })
                    $tb.Add_Leave({ Commit-ChipBox $this })
                    $s.Controls.Add($tb)
                    $t.Box = $tb
                }
                $rc = $r.Rect
                $t.Box.SetBounds(($rc.X + (Px 12)), ($rc.Y + (Px 8)), ($rc.Width - (Px 24)), (Px 18))
                $cur = & $t.Get
                $t.Box.Text = if ($null -ne $cur -and -not ($t.Vals -contains $cur)) { [string]$cur } else { "" }
                $t.Box.Visible = $true
                $t.Box.Focus() | Out-Null
            } elseif ($t.Multi) {
                $cur = @(& $t.Get)
                $new = if ($cur -contains $v) { @($cur | Where-Object { $_ -ne $v }) } else { @($cur + $v) }
                & $t.Set $new
            } else {
                & $t.Set $v
            }
            $s.Invalidate()
            return
        }
    })
    return $p
}

function Commit-ChipBox($tb) {
    if (-not $tb.Visible) { return }
    $tb.Visible = $false
    $chips = $tb.Tag
    $n = 0.0
    if ([double]::TryParse($tb.Text.Trim(), [ref]$n) -and $n -gt 0) { & $chips.Tag.Set $n }
    $chips.Invalidate()
}

# A row you tap to open another page.
function New-NavRow([string]$label, [scriptblock]$Value, [string]$page, [int]$x, [int]$y, [int]$w = 352) {
    $p = New-PaintPanel $x $y $w 46
    $p.Cursor = "Hand"
    $p.Tag = @{ Text = $label; Value = $Value; Page = $page; Hover = $false; Action = $null }
    $p.Add_Paint({
        param($s, $e)
        $g = Start-Paint $e
        $bg = if ($s.Tag.Hover) { $UI.Sel } else { $UI.Card }
        Fill-Round $g $bg 0 0 ($s.Width - 1) ($s.Height - 1) (Px 10)
        $vw = [int]($s.Width * 0.5)
        Draw-UiText $g $s.Tag.Text $FontUI $(if ($s.Tag.Danger) { $UI.Danger } else { $UI.Text }) (New-Object System.Drawing.Rectangle((Px 14), 0, ($s.Width - $vw), $s.Height))
        $val = if ($s.Tag.Value) { [string](& $s.Tag.Value) } else { "" }
        Draw-UiText $g $val $FontUI $UI.Muted (New-Object System.Drawing.Rectangle(($s.Width - $vw - (Px 30)), 0, $vw, $s.Height)) "Right"
        if ($s.Tag.Page) { Draw-UiText $g ([string][char]0x203A) $FontTitle $UI.Muted (New-Object System.Drawing.Rectangle(($s.Width - (Px 26)), 0, (Px 18), $s.Height)) "Center" }
    })
    $p.Add_MouseEnter({ $this.Tag.Hover = $true; $this.Invalidate() })
    $p.Add_MouseLeave({ $this.Tag.Hover = $false; $this.Invalidate() })
    $p.Add_Click({
        param($s, $e)
        if ($s.Tag.Action) { & $s.Tag.Action $s } elseif ($s.Tag.Page) { Hub-Go $s.Tag.Page 1 -Push }
    })
    return $p
}
function New-ActionRow([string]$label, [scriptblock]$Action, [int]$x, [int]$y, [switch]$Danger) {
    $p = New-NavRow $label $null "" $x $y
    $p.Tag.Action = $Action
    $p.Tag.Danger = [bool]$Danger
    return $p
}

function New-Caps([string]$text, [int]$x, [int]$y) { return New-Label $text.ToUpper() $x $y 352 18 $FontCaps $UI.Muted }

# iOS-style scrolling wheel (hours / minutes). Drag, scroll or click above /
# below the middle; it glides to the nearest value.
function New-Wheel($values, [int]$index, [int]$x, [int]$y, [int]$w, [int]$h, [scriptblock]$OnChange) {
    $p = New-PaintPanel $x $y $w $h
    $p.Cursor = "SizeNS"
    $p.Tag = @{ Vals = @($values); Idx = $index; Off = [double]$index; Drag = $false; Moved = $false; Y0 = 0; Off0 = 0.0; OnChange = $OnChange }
    $p.Add_Paint({
        param($s, $e)
        $g = Start-Paint $e
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $t = $s.Tag; $n = $t.Vals.Count
        Fill-Round $g $UI.Card 0 0 ($s.Width - 1) ($s.Height - 1) (Px 12)
        $rh = [single](Px 34); $mid = $s.Height / 2
        Fill-Round $g $UI.Sel (Px 4) ($mid - $rh / 2) ($s.Width - (Px 8)) $rh (Px 8)
        $base = [int][Math]::Floor($t.Off)
        for ($k = $base - 3; $k -le $base + 4; $k++) {
            $d = $k - $t.Off
            $cy = $mid + $d * $rh
            $ad = [Math]::Abs($d)
            if ($ad -gt 2.6) { continue }
            $a = [int](255 * [Math]::Max(0.12, 1 - $ad / 2.6))
            $font = if ($ad -lt 0.5) { Get-SceneFont ([single](Px 22)) -Bold } else { Get-SceneFont ([single](Px 17)) }
            $v = $t.Vals[(($k % $n) + $n) % $n]
            Draw-Text $g ([string]$v) $font (A $UI.Text $a) 0 ($cy - $rh / 2) $s.Width $rh "Center"
        }
    })
    $p.Add_MouseDown({ param($s, $e) $s.Tag.Drag = $true; $s.Tag.Moved = $false; $s.Tag.Y0 = $e.Y; $s.Tag.Off0 = $s.Tag.Off })
    $p.Add_MouseMove({
        param($s, $e)
        if (-not $s.Tag.Drag) { return }
        $dy = $e.Y - $s.Tag.Y0
        if ([Math]::Abs($dy) -gt 3) { $s.Tag.Moved = $true }
        if ($s.Tag.Moved) { $s.Tag.Off = $s.Tag.Off0 - $dy / (Px 34); $s.Tag.Idx = [int][Math]::Round($s.Tag.Off); $s.Invalidate() }
    })
    $p.Add_MouseUp({
        param($s, $e)
        $t = $s.Tag
        if (-not $t.Drag) { return }
        $t.Drag = $false
        if (-not $t.Moved) {
            if ($e.Y -lt $s.Height / 2 - (Px 17)) { $t.Idx-- } elseif ($e.Y -gt $s.Height / 2 + (Px 17)) { $t.Idx++ }
        }
        Fire-Wheel $s
    })
    $p.Add_MouseWheel({ param($s, $e) if ($e.Delta -gt 0) { $s.Tag.Idx-- } else { $s.Tag.Idx++ }; Fire-Wheel $s })
    $p.Add_MouseEnter({ $this.Focus() | Out-Null })
    $Script:Hub.Wheels += $p
    return $p
}
function Get-WheelValue($wh) { $n = $wh.Tag.Vals.Count; return $wh.Tag.Vals[((($wh.Tag.Idx) % $n) + $n) % $n] }
function Fire-Wheel($wh) { if ($wh.Tag.OnChange) { & $wh.Tag.OnChange } }

# Live widget preview inside the hub (sample data, current look).
function New-PreviewStage([int]$x, [int]$y, [int]$w, [int]$h, [string[]]$modes) {
    $p = New-PaintPanel $x $y $w $h
    $p.Tag = @{ Modes = $modes }
    $p.Add_Paint({
        param($s, $e)
        $g = Start-Paint $e
        Fill-Round $g $UI.Card 0 0 ($s.Width - 1) ($s.Height - 1) (Px 14)
        $t = Get-HubTime
        $ms = $s.Tag.Modes
        $i = [int][Math]::Floor($t / 3.5) % $ms.Count
        try {
            $bmp = Build-DemoFrame $ms[$i] $t
            $sc = [Math]::Min(1.0, [Math]::Min(($s.Width - (Px 16)) / $bmp.Width, ($s.Height - (Px 26)) / $bmp.Height))
            $bw = [int]($bmp.Width * $sc); $bh = [int]($bmp.Height * $sc)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.DrawImage($bmp, [int](($s.Width - $bw) / 2), [int](($s.Height - (Px 18) - $bh) / 2), $bw, $bh)
            $bmp.Dispose()
        } catch { }
        if ($ms.Count -gt 1) {
            $names = @{ work = "Working"; break = "On a break"; overbreak = "Break over the limit"; stopped = "Timer off" }
            Draw-UiText $g $names[$ms[$i]] $FontSmall $UI.Muted (New-Object System.Drawing.Rectangle(0, ($s.Height - (Px 22)), $s.Width, (Px 20))) "Center"
        }
    })
    $Script:Hub.Stages += $p
    return $p
}

# The three tutorial scenes, playing one after another, shrunk to fit.
function New-TutorialStage([int]$x, [int]$y, [int]$w, [int]$h) {
    $p = New-PaintPanel $x $y $w $h
    $p.Add_Paint({
        param($s, $e)
        $g = Start-Paint $e
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $t = (Get-HubTime) % 19.2
        $sc = [single]($s.Width / 512.0)
        $g.ScaleTransform($sc, $sc)
        try {
            if ($t -lt 6.4) { Draw-SceneProfile $g $t; $cap = "1  Open My Profile" }
            elseif ($t -lt 13.6) { Draw-SceneToken $g ($t - 6.4); $cap = "2  Copy the API Token" }
            else { Draw-ScenePaste $g ($t - 13.6); $cap = "3  Paste it below" }
            Draw-Pill $g $cap ([System.Drawing.Color]::FromArgb(230, 20, 20, 24)) ([System.Drawing.Color]::White) 10 200
        } catch { }
    })
    $Script:Hub.Stages += $p
    return $p
}

function New-ThemeTile([string]$name, [int]$x, [int]$y, [int]$w, [int]$h = 64) {
    $p = New-PaintPanel $x $y $w $h
    $p.Cursor = "Hand"
    $p.Tag = $name
    $p.Add_Paint({
        param($s, $e)
        $g = Start-Paint $e
        $t = $Script:Themes[[string]$s.Tag]
        $sel = ((Get-CurrentThemeName) -eq [string]$s.Tag)
        $bg = ToColor $t.BackColor
        $rect = New-Object System.Drawing.RectangleF(1, 1, ($s.Width - 3), ($s.Height - 3))
        $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $bg, (Mix $bg (ToColor $t.AccentColor) 0.18), [single]30)
        $pp = New-RoundPath 1 1 ($s.Width - 3) ($s.Height - 3) (Px 12)
        $g.FillPath($lg, $pp); $lg.Dispose()
        $pen = New-Object System.Drawing.Pen($(if ($sel) { $UI.Accent } else { $UI.Line }), $(if ($sel) { 2.5 } else { 1 }))
        $g.DrawPath($pen, $pp); $pp.Dispose(); $pen.Dispose()
        for ($i = 0; $i -lt 6; $i++) { Fill-Circle $g (A (ToColor $t.AccentColor) $(if ($i -lt 4) { 230 } else { 60 })) ((Px 12) + $i * (Px 7)) (Px 13) ([single](Px 2)) }
        Draw-UiText $g ([string]$s.Tag) $FontUIBold (ToColor $t.TaskColor) (New-Object System.Drawing.Rectangle((Px 10), ($s.Height - (Px 30)), ($s.Width - (Px 14)), (Px 24)))
    })
    $p.Add_Click({
        param($s, $e)
        $t = $Script:Themes[[string]$s.Tag]
        foreach ($k in $t.Keys) { $Script:Cfg[$k] = $t[$k] }
        Save-Config; Apply-Theme
        foreach ($c in $s.Parent.Controls) { $c.Invalidate() }
        if ($Script:HubOpen) { Queue-HubRetheme }
    })
    return $p
}

# Repaint the open Settings / setup window in the new theme. Runs a moment
# later, because the page holding the clicked tile gets rebuilt.
function Queue-HubRetheme {
    $Script:RethemeKick = New-Object System.Windows.Forms.Timer
    $Script:RethemeKick.Interval = 30
    $Script:RethemeKick.Add_Tick({ $Script:RethemeKick.Stop(); $Script:RethemeKick.Dispose(); Hub-Retheme })
    $Script:RethemeKick.Start()
}
function Hub-Retheme {
    $H = $Script:Hub
    if (-not $H -or -not $H.Form -or $H.Form.IsDisposed) { return }
    $H.Form.BackColor = $UI.Bg; $H.View.BackColor = $UI.Bg; $H.Bar.BackColor = $UI.Bg
    $H.BackBtn.ForeColor = $UI.Text; $H.TitleLbl.ForeColor = $UI.Text; $H.CloseBtn.ForeColor = $UI.Muted
    if ($H.Next) {
        $H.Next.BackColor = $UI.Accent; $H.Next.ForeColor = $UI.OnAccent
        $H.Next.FlatAppearance.MouseOverBackColor = $UI.AccentH
        $H.Dots.BackColor = $UI.Bg
    }
    Set-DwmLook $H.Form
    $scroll = 0
    if ($H.Current) { $scroll = -$H.Current.AutoScrollPosition.Y }
    Hub-Go $H.PageName 1 -NoAnim
    if ($scroll -gt 0) { $H.Current.AutoScrollPosition = New-Object System.Drawing.Point(0, $scroll) }
    $H.Form.Invalidate($true)
}

function New-ShapeTile([string]$name, [string]$desc, [int]$x, [int]$y, [int]$w, [int]$h) {
    $p = New-PaintPanel $x $y $w $h
    $p.Cursor = "Hand"
    $p.Tag = @{ Name = $name; Desc = $desc }
    $p.Add_Paint({
        param($s, $e)
        $g = Start-Paint $e
        $nm = $s.Tag.Name
        $sel = ([string]$Script:Cfg.Shape -eq $nm)
        Fill-Round $g $(if ($sel) { $UI.Sel } else { $UI.Card }) 1 1 ($s.Width - 3) ($s.Height - 3) (Px 12)
        if ($sel) { $pen = New-Object System.Drawing.Pen($UI.Accent, 2.5); $pp = New-RoundPath 1 1 ($s.Width - 3) ($s.Height - 3) (Px 12); $g.DrawPath($pen, $pp); $pp.Dispose(); $pen.Dispose() }
        $acc = ToColor $Script:Cfg.AccentColor
        $cx = $s.Width / 2; $top = Px 16
        switch ($nm) {
            "Wide"   { $rw = Px 80; $rh = Px 30 }
            "Square" { $rw = Px 52; $rh = Px 52 }
            default  { $rw = Px 56; $rh = Px 76 }
        }
        $rx = $cx - $rw / 2
        Fill-Round $g (ToColor "#2E2E36") $rx $top $rw $rh (Px 8)
        Fill-Circle $g $acc ($rx + $rw - (Px 9)) ($top + (Px 9)) ([single](Px 5))
        Fill-Round $g (ToColor "#8B8B96") ($rx + (Px 6)) ($top + $rh / 2 - (Px 3)) ($rw * 0.45) (Px 5) (Px 2)
        Fill-Round $g $acc ($rx + (Px 6)) ($top + $rh - (Px 9)) ($rw * 0.5) (Px 3) (Px 1)
        if ($nm -eq "Large") { for ($i = 0; $i -lt 3; $i++) { Fill-Round $g (ToColor "#45454F") ($rx + (Px 6)) ($top + $rh * 0.6 + $i * (Px 6) - (Px 20)) ($rw - (Px 12)) (Px 2) (Px 1) } }
        Draw-UiText $g $nm $FontUIBold $UI.Text (New-Object System.Drawing.Rectangle(0, ($s.Height - (Px 46)), $s.Width, (Px 22))) "Center"
        Draw-UiText $g $s.Tag.Desc $FontSmall $UI.Muted (New-Object System.Drawing.Rectangle((Px 4), ($s.Height - (Px 26)), ($s.Width - (Px 8)), (Px 20))) "Center"
    })
    $p.Add_Click({
        param($s, $e)
        $Script:IsExpanded = $false
        Set-Cfg "Shape" $s.Tag.Name
        foreach ($c in $s.Parent.Controls) { $c.Invalidate() }
    })
    return $p
}

# Scrolling list of fonts, each shown in its own typeface.
function New-FontList([int]$x, [int]$y, [int]$w, [int]$h) {
    $box = New-Object System.Windows.Forms.Panel
    $box.Location = New-Object System.Drawing.Point((Px $x), (Px $y))
    $box.Size = New-Object System.Drawing.Size((Px $w), (Px $h))
    $box.BackColor = $UI.Bg
    $box.AutoScroll = $true
    $i = 0
    foreach ($key in (Get-AvailableFonts)) {
        $t = New-PaintPanel 0 ($i * 54) ($w - 20) 48
        $t.Cursor = "Hand"
        $t.Tag = $key
        $t.Add_Paint({
            param($s, $e)
            $g = Start-Paint $e
            $k = [string]$s.Tag
            $sel = ([string]$Script:Cfg.FontFamily -eq $k)
            Fill-Round $g $(if ($sel) { $UI.Sel } else { $UI.Card }) 0 0 ($s.Width - 1) ($s.Height - 1) (Px 10)
            if ($sel) { Fill-Round $g $UI.Accent 0 (Px 10) (Px 3) ($s.Height - (Px 20)) (Px 1) }
            if (-not $Script:TileFonts) { $Script:TileFonts = @{} }
            if (-not $Script:TileFonts.ContainsKey($k)) {
                $fam = Get-FontFamilyObj $k
                $bst = if ($fam.IsStyleAvailable([System.Drawing.FontStyle]::Bold)) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
                $Script:TileFonts[$k] = @((New-Object System.Drawing.Font($fam, [single]11)), (New-Object System.Drawing.Font($fam, [single]14, $bst)))
            }
            $fs = $Script:TileFonts[$k]
            Draw-UiText $g $k $fs[0] $UI.Text (New-Object System.Drawing.Rectangle((Px 14), (Px 2), ($s.Width / 2), (Px 26)))
            $hint = if ($Script:FontCatalog.Contains($k)) { [string]$Script:FontCatalog[$k].Hint } else { "" }
            Draw-UiText $g $hint $FontSmall $UI.Muted (New-Object System.Drawing.Rectangle((Px 14), (Px 26), ($s.Width / 2), (Px 18)))
            Draw-UiText $g "01:23:45" $fs[1] $(if ($sel) { $UI.Accent } else { $UI.Text }) (New-Object System.Drawing.Rectangle(($s.Width / 2), 0, ($s.Width / 2 - (Px 12)), $s.Height)) "Right"
        })
        $t.Add_Click({
            param($s, $e)
            Set-Cfg "FontFamily" ([string]$s.Tag)
            foreach ($c in $s.Parent.Controls) { $c.Invalidate() }
        })
        $box.Controls.Add($t)
        $i++
    }
    return $box
}

# ---------------------------------------------------------------------------
#  Pages. Each returns its title and fills the panel it is given.
# ---------------------------------------------------------------------------
function Below($c, [int]$gap = 14) { return [int][Math]::Ceiling($c.Bottom / $Script:Scale) + $gap }

function Add-Hero($p, [string]$title, [string]$sub, [int]$y = 4) {
    $sz = [System.Windows.Forms.TextRenderer]::MeasureText($title, $FontHero, (New-Object System.Drawing.Size((Px 352), 0)), [System.Windows.Forms.TextFormatFlags]::WordBreak)
    $th = [int][Math]::Ceiling($sz.Height / $Script:Scale) + 4
    [void](Add-HubCtrl $p (New-Label $title 24 $y 352 $th $FontHero $UI.Text))
    $y += $th + 2
    if ($sub) {
        $sz2 = [System.Windows.Forms.TextRenderer]::MeasureText($sub, $FontUI, (New-Object System.Drawing.Size((Px 352), 0)), [System.Windows.Forms.TextFormatFlags]::WordBreak)
        $sh = [int][Math]::Ceiling($sz2.Height / $Script:Scale) + 4
        [void](Add-HubCtrl $p (New-Label $sub 24 $y 352 $sh $FontUI $UI.Muted))
        $y += $sh
    }
    return $y + 12
}

function Build-Page-welcome($p) {
    $y = Add-Hero $p "Let's set up your Everhour widget" "A few quick questions - each answer saves on its own, and you can change anything later."
    [void](Add-HubCtrl $p (New-PreviewStage 24 $y 352 210 @("work", "break", "overbreak", "stopped")))
    $y += 222
    $pts = @("Turns red the moment no timer is running", "Warns you when breaks run past your limit", "Hidden from screen sharing, so only you see it")
    foreach ($t in $pts) {
        $dot = New-PaintPanel 26 ($y + 7) 8 8
        $dot.Add_Paint({ param($s, $e) $g = Start-Paint $e; Fill-Circle $g $UI.Accent ($s.Width / 2) ($s.Height / 2) ($s.Width / 2) })
        [void](Add-HubCtrl $p $dot)
        [void](Add-HubCtrl $p (New-Label $t 42 $y 330 22 $FontUI $UI.Text))
        $y += 26
    }
    return "Welcome"
}

function Build-Page-connect($p) {
    $H = $Script:Hub
    $y = Add-Hero $p "Connect Everhour" "Copy your personal API token from Everhour and paste it here."
    [void](Add-HubCtrl $p (New-TutorialStage 24 $y 352 162))
    $y += 172
    $kb = New-TextBox 24 ($y + 2) 256 "" "Paste your API token"
    $kb.UseSystemPasswordChar = $true
    [void](Add-HubCtrl $p $kb)
    $H.KeyBox = $kb
    $bp = New-FlatButton -Text "Paste" -X 288 -Y $y -W 88 -H 30
    $bp.Add_Click({ try { $c = [System.Windows.Forms.Clipboard]::GetText().Trim(); if ($c) { $Script:Hub.KeyBox.Text = $c } } catch { } })
    [void](Add-HubCtrl $p $bp)
    $kb.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { $e.SuppressKeyPress = $true; Hub-Connect } })
    $y += 38
    $H.KeyStatus = New-Label "" 24 $y 352 40 $FontUI $UI.Muted
    [void](Add-HubCtrl $p $H.KeyStatus)
    $y += 42
    if ($H.Mode -ne "setup") {
        $bc = New-FlatButton -Text "Connect" -X 24 -Y $y -W 352 -H 38 -Primary
        $bc.Add_Click({ Hub-Connect })
        [void](Add-HubCtrl $p $bc)
        $y += 46
    }
    [void](Add-HubCtrl $p (New-Label "Stored encrypted on this PC. Only ever sent to api.everhour.com." 24 $y 352 20 $FontSmall $UI.Muted))
    if ($H.HadKey -or $H.KeyOk) {
        $who = if ($Script:UserName) { " as $($Script:UserName)" } else { "" }
        $H.KeyStatus.ForeColor = $UI.Good
        $H.KeyStatus.Text = "Connected$who. Paste a new token only if you want to change it."
    } elseif (-not $RenderPreview) {
        try {
            $clip = [System.Windows.Forms.Clipboard]::GetText().Trim()
            if ($clip -match '^[A-Za-z0-9\-_:.]{20,100}$') {
                $kb.Text = $clip
                $H.KeyStatus.ForeColor = $UI.Good
                $H.KeyStatus.Text = "Found a token on your clipboard - press Connect."
            }
        } catch { }
    }
    return "Connect"
}

function Build-Page-theme($p) {
    $y = Add-Hero $p "Pick a theme" "The widget behind changes as you tap."
    $i = 0
    foreach ($name in $Script:Themes.Keys) {
        [void](Add-HubCtrl $p (New-ThemeTile $name (24 + ($i % 3) * 120) ($y + [Math]::Floor($i / 3) * 76) 112 68))
        $i++
    }
    $y += 160
    [void](Add-HubCtrl $p (New-PreviewStage 24 $y 352 180 @("work")))
    return "Theme"
}

function Build-Page-shape($p) {
    $y = Add-Hero $p "Choose a shape" "Large shows today's tasks all the time. Wide and Square open them with a click."
    [void](Add-HubCtrl $p (New-ShapeTile "Large" "Always open" 24 $y 112 150))
    [void](Add-HubCtrl $p (New-ShapeTile "Square" "Compact" 144 $y 112 150))
    [void](Add-HubCtrl $p (New-ShapeTile "Wide" "Slim bar" 264 $y 112 150))
    $y += 166
    [void](Add-HubCtrl $p (New-HubToggle "Auto-hide into the screen edge" "AutoHide" 24 $y 352 "Slides away when you're not using it; a dot strip shows the status"))
    return "Shape"
}

function Build-Page-font($p) {
    $y = Add-Hero $p "Pick a font" "Inter looks like an iPhone; Doto is the Nothing-phone dot style."
    [void](Add-HubCtrl $p (New-FontList 24 $y 352 372))
    return "Font"
}

function Build-Page-size($p) {
    $y = Add-Hero $p "Text size" ""
    $ch = Add-HubCtrl $p (New-Chips @(@{ L = "Small"; V = "S" }, @{ L = "Medium"; V = "M" }, @{ L = "Large"; V = "L" }) 24 $y 352 { [string]$Script:Cfg.TextSize } { param($v) Set-Cfg "TextSize" $v })
    $y = Below $ch
    [void](Add-HubCtrl $p (New-Caps "Background" 24 $y)); $y += 22
    $ch = Add-HubCtrl $p (New-Chips @(@{ L = "Glass"; V = 60 }, @{ L = "75%"; V = 75 }, @{ L = "90%"; V = 90 }, @{ L = "Solid"; V = 100 }) 24 $y 352 { [int]$Script:Cfg.Opacity } { param($v) Set-Cfg "Opacity" ([int]$v) })
    $y = Below $ch
    [void](Add-HubCtrl $p (New-PreviewStage 24 $y 352 200 @("work")))
    return "Size"
}

function Build-Page-workday($p) {
    $H = $Script:Hub
    $y = Add-Hero $p "Your work hours" "Scroll or drag the wheels. Used for reminders."
    $hours = 0..23 | ForEach-Object { "{0:D2}" -f $_ }
    $mins = 0..11 | ForEach-Object { "{0:D2}" -f ($_ * 5) }
    $ws = Parse-HHmm $Script:Cfg.WorkStart; $we = Parse-HHmm $Script:Cfg.WorkEnd
    if (-not $ws) { $ws = New-Object TimeSpan(9, 30, 0) }
    if (-not $we) { $we = New-Object TimeSpan(18, 30, 0) }
    [void](Add-HubCtrl $p (New-Label "Start" 24 $y 160 20 $FontCaps $UI.Muted))
    [void](Add-HubCtrl $p (New-Label "End" 216 $y 160 20 $FontCaps $UI.Muted))
    $y += 22
    $upd = { Update-WorkHoursFromWheels }
    $H.WSH = New-Wheel $hours $ws.Hours 24 $y 72 150 $upd;  [void](Add-HubCtrl $p $H.WSH)
    [void](Add-HubCtrl $p (New-Label ":" 98 ($y + 60) 14 30 $FontHero $UI.Muted))
    $H.WSM = New-Wheel $mins ([int][Math]::Round($ws.Minutes / 5)) 112 $y 72 150 $upd; [void](Add-HubCtrl $p $H.WSM)
    $H.WEH = New-Wheel $hours $we.Hours 216 $y 72 150 $upd; [void](Add-HubCtrl $p $H.WEH)
    [void](Add-HubCtrl $p (New-Label ":" 290 ($y + 60) 14 30 $FontHero $UI.Muted))
    $H.WEM = New-Wheel $mins ([int][Math]::Round($we.Minutes / 5)) 304 $y 72 150 $upd; [void](Add-HubCtrl $p $H.WEM)
    $y += 166
    [void](Add-HubCtrl $p (New-Caps "Work days" 24 $y)); $y += 22
    $days = @("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun") | ForEach-Object { @{ L = $_; V = $_ } }
    $ch = Add-HubCtrl $p (New-Chips $days 24 $y 352 { @(([string]$Script:Cfg.WorkDays) -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } {
        param($v)
        $order = @("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
        Set-Cfg "WorkDays" ((@($order | Where-Object { @($v) -contains $_ })) -join ",")
    } -Multi)
    $y = Below $ch 18
    [void](Add-HubCtrl $p (New-HubToggle "Remind me when no timer is running" "IdleNudge" 24 $y))
    $y += 40
    [void](Add-HubCtrl $p (New-Chips @(@{ L = "5 min"; V = 5 }, @{ L = "10 min"; V = 10 }, @{ L = "15 min"; V = 15 }) 24 $y 352 { [int]$Script:Cfg.IdleNudgeMinutes } { param($v) Set-Cfg "IdleNudgeMinutes" ([int][Math]::Max(1, [Math]::Min(240, $v))) } "min"))
    return "Work hours"
}

function Update-WorkHoursFromWheels {
    $H = $Script:Hub
    $s = "{0}:{1}" -f (Get-WheelValue $H.WSH), (Get-WheelValue $H.WSM)
    $e = "{0}:{1}" -f (Get-WheelValue $H.WEH), (Get-WheelValue $H.WEM)
    $Script:Cfg.WorkStart = $s; $Script:Cfg.WorkEnd = $e
    Save-Config
}

function Build-Page-breaks($p) {
    $y = Add-Hero $p "Breaks" "Tasks whose name contains these words count as a break. Past your daily allowance, the widget turns red."
    [void](Add-HubCtrl $p (New-Caps "Break tasks contain" 24 $y)); $y += 22
    $tb = New-TextBox 24 $y 352 ([string]$Script:Cfg.BreakKeywords) "break, lunch"
    $tb.Add_Leave({ $Script:Cfg.BreakKeywords = $this.Text.Trim(); Save-Config; Apply-Theme })
    $tb.Add_TextChanged({ $Script:Cfg.BreakKeywords = $this.Text.Trim() })
    [void](Add-HubCtrl $p $tb)
    $y += 40
    [void](Add-HubCtrl $p (New-Caps "Daily break allowance" 24 $y)); $y += 22
    $ch = Add-HubCtrl $p (New-Chips @(@{ L = "30 min"; V = 30 }, @{ L = "45 min"; V = 45 }, @{ L = "1 hour"; V = 60 }, @{ L = "90 min"; V = 90 }) 24 $y 352 { [int]$Script:Cfg.BreakLimitMinutes } { param($v) Set-Cfg "BreakLimitMinutes" ([int][Math]::Min(600, $v)) } "min")
    $y = Below $ch
    [void](Add-HubCtrl $p (New-PreviewStage 24 $y 352 170 @("break", "overbreak")))
    return "Breaks"
}

function Build-Page-target($p) {
    $y = Add-Hero $p "Daily target" "The bar under the timer fills up towards it."
    $ch = Add-HubCtrl $p (New-Chips @(@{ L = "6 h"; V = 6 }, @{ L = "7 h"; V = 7 }, @{ L = "8 h"; V = 8 }, @{ L = "9 h"; V = 9 }) 24 $y 352 { [double]$Script:Cfg.DailyTargetHours } { param($v) Set-Cfg "DailyTargetHours" ([double][Math]::Min(24, $v)) } "h")
    $y = Below $ch
    [void](Add-HubCtrl $p (New-HubToggle "Start automatically when Windows starts" "_autostart" 24 $y)); $y += 40
    [void](Add-HubCtrl $p (New-HubToggle "Hide from screen sharing and screenshots" "HideFromCapture" 24 $y)); $y += 40
    [void](Add-HubCtrl $p (New-HubToggle "Turn red when no timer is running" "RedWhenStopped" 24 $y)); $y += 40
    return "Daily target"
}

function Build-Page-finish($p) {
    $y = Add-Hero $p "You're all set" "Here's how it works:"
    $tips = @(
        @("Round button", "start / stop (resumes last task)"),
        @("Click the widget", "today's time, task by task"),
        @("Right-click", "start a task, settings, exit"),
        @($Script:Cfg.Hotkey, "start or stop from anywhere"))
    foreach ($t in $tips) {
        [void](Add-HubCtrl $p (New-Label $t[0] 24 $y 126 22 $FontUIBold $UI.Text))
        [void](Add-HubCtrl $p (New-Label $t[1] 152 $y 228 22 $FontUI $UI.Muted))
        $y += 28
    }
    $y += 14
    $b = New-FlatButton -Text "Start tracking" -X 24 -Y $y -W 352 -H 48 -Primary
    $b.Font = $FontTitle
    $b.Add_Click({ $Script:Hub.Done = $true; $Script:Hub.Form.Close() })
    [void](Add-HubCtrl $p $b)
    $y += 60
    [void](Add-HubCtrl $p (New-PreviewStage 24 $y 352 150 @("work")))
    return "Done"
}

# Settings home: a live preview and a short list of categories, each its own
# small page.
function Build-Page-home($p) {
    $y = 4
    [void](Add-HubCtrl $p (New-PreviewStage 24 $y 352 124 @("work")))
    $y += 134
    $rows = @(
        @("How to use", { "3-minute tour" }, "tour"),
        @("Appearance", { "{0}  |  {1}" -f (Get-CurrentThemeName), $Script:Cfg.Shape }, "appearance"),
        @("Widget", { $n = @("AlwaysOnTop", "HideFromCapture", "AutoHide", "Sounds") | Where-Object { $Script:Cfg[$_] }; "{0} on" -f @($n).Count }, "behaviour"),
        @("Focus and breaks", { "{0} min focus  |  {1} min breaks" -f $Script:Cfg.FocusMinutes, $Script:Cfg.BreakLimitMinutes }, "focusbreaks"),
        @("Work hours and reminders", { "{0}-{1}" -f $Script:Cfg.WorkStart, $Script:Cfg.WorkEnd }, "workday"),
        @("Favourite tasks", { "{0} pinned" -f @(Get-Favs).Count }, "favourites"),
        @("Advanced", { "{0:0.#} h target" -f [double]$Script:Cfg.DailyTargetHours }, "advanced"),
        @("Account and updates", { if ($Script:UpdateAvail) { "Update ready" } else { "v$($Script:Version)" } }, "account"))
    foreach ($r in $rows) {
        [void](Add-HubCtrl $p (New-NavRow $r[0] $r[1] $r[2] 24 $y)); $y += 52
    }
    [void](Add-HubCtrl $p (New-Label "Changes save automatically." 24 ($y + 6) 352 20 $FontSmall $UI.Muted))
    return "Settings"
}

function Build-Page-appearance($p) {
    $y = 4
    [void](Add-HubCtrl $p (New-Caps "Theme" 24 $y)); $y += 22
    $i = 0
    foreach ($name in $Script:Themes.Keys) {
        [void](Add-HubCtrl $p (New-ThemeTile $name (24 + ($i % 3) * 120) ($y + [Math]::Floor($i / 3) * 62) 112 56))
        $i++
    }
    $y += 132
    [void](Add-HubCtrl $p (New-Caps "Shape" 24 $y)); $y += 22
    $ch = Add-HubCtrl $p (New-Chips @(@{ L = "Large"; V = "Large" }, @{ L = "Square"; V = "Square" }, @{ L = "Wide"; V = "Wide" }) 24 $y 352 { [string]$Script:Cfg.Shape } { param($v) $Script:IsExpanded = $false; Set-Cfg "Shape" $v })
    $y = Below $ch 12
    [void](Add-HubCtrl $p (New-NavRow "Font" { [string]$Script:Cfg.FontFamily } "font" 24 $y)); $y += 58
    [void](Add-HubCtrl $p (New-Caps "Text size" 24 $y)); $y += 22
    $ch = Add-HubCtrl $p (New-Chips @(@{ L = "Small"; V = "S" }, @{ L = "Medium"; V = "M" }, @{ L = "Large"; V = "L" }) 24 $y 352 { [string]$Script:Cfg.TextSize } { param($v) Set-Cfg "TextSize" $v })
    $y = Below $ch 12
    [void](Add-HubCtrl $p (New-Caps "Background" 24 $y)); $y += 22
    $ch = Add-HubCtrl $p (New-Chips @(@{ L = "Glass"; V = 60 }, @{ L = "75%"; V = 75 }, @{ L = "90%"; V = 90 }, @{ L = "Solid"; V = 100 }) 24 $y 352 { [int]$Script:Cfg.Opacity } { param($v) Set-Cfg "Opacity" ([int]$v) })
    $y = Below $ch 8
    $sp = New-PaintPanel 0 $y 1 1; [void](Add-HubCtrl $p $sp)
    return "Appearance"
}

function Build-Page-behaviour($p) {
    $y = 4
    foreach ($t in @(@("Always on top of other windows", "AlwaysOnTop", ""),
                     @("Hide from screen sharing", "HideFromCapture", "Teams, Zoom and screenshots won't see it"),
                     @("Auto-hide into the screen edge", "AutoHide", "A dot strip stays; hover it to bring the widget back"),
                     @("Privacy mode", "PrivacyMode", "Hide task names and times - or tap the eye on the widget"),
                     @("Show seconds", "ShowSeconds", ""),
                     @("Show today's progress", "ShowTodayTotal", ""),
                     @("Ask before switching tasks", "ConfirmSwitch", ""),
                     @("Clock in / clock out", "ClockInOut", "Everhour timecards; clocked out, nothing counts"),
                     @("Sounds", "Sounds", ""),
                     @("Start with Windows", "_autostart", ""))) {
        [void](Add-HubCtrl $p (New-HubToggle $t[0] $t[1] 24 $y 352 $t[2]))
        $y += $(if ($t[2]) { 54 } else { 40 })
    }
    return "Widget"
}

function Build-Page-focusbreaks($p) {
    $y = 4
    foreach ($t in @(@("Smooth animations", "Animations"), @("Edge lights", "EdgeLights"), @("Turn red when no timer runs", "RedWhenStopped"))) {
        [void](Add-HubCtrl $p (New-HubToggle $t[0] $t[1] 24 $y)); $y += 40
    }
    $y += 8
    [void](Add-HubCtrl $p (New-NavRow "Focus sessions" { "{0} min  |  {1} min break" -f $Script:Cfg.FocusMinutes, $Script:Cfg.FocusBreakMinutes } "focus" 24 $y)); $y += 52
    [void](Add-HubCtrl $p (New-NavRow "Breaks" { "{0} min a day" -f $Script:Cfg.BreakLimitMinutes } "breaks" 24 $y)); $y += 52
    return "Focus and breaks"
}

# ---------------------------------------------------------------------------
#  HOW TO USE: a guided tour that plays inside Settings, over real screenshots
#  (assets\tour). r = the highlighted area [x, y, w, h] in the picture's pixels.
# ---------------------------------------------------------------------------
$Script:TourScenes = @(
    @{ ch = "Get started"; img = "hub-setup-welcome"; r = @(325, 752, 145, 50); t = "Install it"; d = "Double-click Install Everhour Widget.vbs. A short setup opens; press Get started." }
    @{ ch = "Get started"; img = "hub-setup-connect"; r = @(30, 188, 440, 205); t = "Find your API token"; d = "In Everhour: your name (bottom-left), My Profile, Application Access, then copy the API Token." }
    @{ ch = "Get started"; img = "hub-setup-connect"; r = @(30, 398, 440, 48); t = "Paste and connect"; d = "Paste the token and press Connect. If it's on your clipboard, it fills in by itself." }
    @{ ch = "Get started"; img = "hub-setup-theme"; r = @(30, 160, 440, 190); t = "Make it yours"; d = "Pick a theme, shape, font, text size, work hours, breaks and daily target. Each answer saves at once." }
    @{ ch = "Get started"; img = "hub-setup-finish"; r = @(30, 318, 440, 66); t = "Start tracking"; d = "Press Start tracking. From now on the widget starts with Windows by itself." }
    @{ ch = "The widget"; img = "large-running"; r = @(316, 57, 56, 56); t = "Start and stop"; d = "The round button starts or stops the timer. When nothing runs, it resumes your last task." }
    @{ ch = "The widget"; img = "large-running"; r = @(56, 108, 262, 100); t = "What you're tracking"; d = "The running task and its timer." }
    @{ ch = "The widget"; img = "large-running"; r = @(56, 184, 316, 48); t = "Today's progress"; d = "Time tracked today, filling up towards your daily target." }
    @{ ch = "The widget"; img = "large-running"; r = @(44, 44, 342, 606); t = "Edge lights"; d = "The dots round the border complete one lap every minute, on tasks and on breaks." }
    @{ ch = "Today and This week"; img = "large-running"; r = @(56, 254, 320, 178); t = "Today"; d = "Every task you tracked today. Double-click one to start it again; scroll for more." }
    @{ ch = "Today and This week"; img = "large-week-scrolled"; r = @(56, 286, 330, 214); t = "This week"; d = "Click This week for the whole week. Only one list is open at a time." }
    @{ ch = "Today and This week"; img = "large-groups-closed"; r = @(56, 252, 320, 72); t = "Close both"; d = "Click a heading to close its list; the widget gets shorter." }
    @{ ch = "Start, stop, switch"; img = "large-running"; r = @(56, 474, 320, 112); t = "Quick switch"; d = "Your favourite tasks, one click to start. Pin up to five with the star in the task picker." }
    @{ ch = "Start, stop, switch"; img = "large-running"; r = @(56, 594, 320, 46); t = "Switch, Stop, Settings"; d = "Switch opens the task picker: recent tasks, live search and a note." }
    @{ ch = "Start, stop, switch"; mock = "keys"; t = "From anywhere"; d = "Press Ctrl + Alt + E in any app to start or stop, even when the widget is hidden." }
    @{ ch = "Start, stop, switch"; mock = "menu"; t = "Right-click for more"; d = "Favourites, focus, edit note, add missed time, hide names, shape, settings and this tour." }
    @{ ch = "Colours"; img = "large-break"; r = @(44, 44, 342, 606); t = "On a break"; d = "Teal with a steaming cup. The bar shows how much of today's break allowance you've used." }
    @{ ch = "Colours"; img = "large-overbreak"; r = @(44, 44, 342, 606); t = "Break over the limit"; d = "Red-orange with chasing lights and an alert. Time to get back." }
    @{ ch = "Colours"; img = "large-stopped"; r = @(56, 108, 300, 104); t = "No timer running"; d = "The widget turns red and counts how long the timer has been off." }
    @{ ch = "Focus"; img = "large-focus"; r = @(56, 64, 232, 40); t = "Focus sessions"; d = "Right-click, Focus, 25 or 50 min. The lights count down, then a chime and a break." }
    @{ ch = "Privacy"; img = "large-privacy"; r = @(282, 68, 36, 34); t = "Hide names and times"; d = "Click the eye and everything turns into dots. Also hidden from screen sharing." }
    @{ ch = "Shapes"; img = "square-running"; r = $null; t = "Square"; d = "A compact square. Click it to open the lists." }
    @{ ch = "Shapes"; img = "wide-running"; r = $null; t = "Wide"; d = "A slim bar for the top or bottom of the screen." }
    @{ ch = "Shapes"; img = "peek-stopped"; r = $null; t = "Auto-hide"; d = "The widget slides into the screen edge; this strip keeps showing the status. Hover it to bring it back." }
    @{ ch = "Settings"; img = "hub-settings-home"; r = @(30, 272, 440, 456); t = "Settings"; d = "Short pages; every change saves and shows on the widget at once." }
    @{ ch = "Settings"; img = "hub-settings-appearance"; r = @(30, 92, 440, 170); t = "Appearance"; d = "Six themes, three shapes, twelve fonts, text size and background." }
    @{ ch = "Settings"; img = "hub-settings-workday"; r = @(30, 166, 440, 190); t = "Work hours"; d = "Scroll the wheels to set your hours, then pick your days and reminders." }
    @{ ch = "Updates"; img = "large-update-pill"; r = @(62, 68, 154, 32); t = "Always up to date"; d = "New versions install themselves. If you turned that off, click the Update pill." }
)
foreach ($sc in $Script:TourScenes) { $sc.Ms = [Math]::Max(5200, [Math]::Min(9500, 3200 + $sc.d.Length * 38)) }

# Every file the widget needs besides the script; missing ones are fetched.
$Script:AssetFiles = @("assets/guide.html") + @($Script:TourScenes | Where-Object { $_.img } | ForEach-Object { "assets/tour/$($_.img).png" } | Select-Object -Unique)

$Script:TourImages = @{}
function Get-TourImage([string]$name) {
    if ($Script:TourImages.ContainsKey($name)) { return $Script:TourImages[$name] }
    $f = Join-Path $ScriptDir "assets\tour\$name.png"
    if (-not (Test-Path $f)) { return $null }
    try {
        # read into memory so the file isn't kept locked (updates replace it)
        $ms = New-Object System.IO.MemoryStream(, [IO.File]::ReadAllBytes($f))
        $tmp = [System.Drawing.Image]::FromStream($ms)
        $bmp = New-Object System.Drawing.Bitmap($tmp)
        $tmp.Dispose(); $ms.Dispose()
        $Script:TourImages[$name] = $bmp
        return $bmp
    } catch { return $null }
}

function Build-Page-tour($p) {
    $H = $Script:Hub
    $H.Tour = @{ Idx = 0; T0 = $H.Clock.Elapsed.TotalSeconds; Playing = $true; Paused = 0.0; From = $null; Pt = $null }
    $stage = New-PaintPanel 24 4 352 330
    $stage.Add_Paint({ param($s, $e) $g = Start-Paint $e; try { Draw-TourStage $g $s.Width $s.Height } catch { } })
    $stage.Cursor = "Hand"
    $stage.Add_Click({ Tour-Toggle })
    [void](Add-HubCtrl $p $stage)
    $Script:Hub.Stages += $stage
    $H.TourStage = $stage
    $H.TourChap = New-Label "" 24 344 352 18 $FontCaps $UI.Accent
    $H.TourTitle = New-Label "" 24 362 352 28 $FontTitle $UI.Text
    $H.TourText = New-Label "" 24 392 352 62 $FontUI $UI.Muted
    foreach ($c in @($H.TourChap, $H.TourTitle, $H.TourText)) { [void](Add-HubCtrl $p $c) }
    $bPrev = New-FlatButton -Text ([string][char]0x2039) -X 24 -Y 462 -W 52 -H 36
    $bPrev.Font = $FontTitle
    $bPrev.Add_Click({ Tour-Go ($Script:Hub.Tour.Idx - 1) })
    $H.TourPlay = New-FlatButton -Text "Pause" -X 82 -Y 462 -W 96 -H 36 -Primary
    $H.TourPlay.Add_Click({ Tour-Toggle })
    $bNext = New-FlatButton -Text ([string][char]0x203A) -X 184 -Y 462 -W 52 -H 36
    $bNext.Font = $FontTitle
    $bNext.Add_Click({ Tour-Go ($Script:Hub.Tour.Idx + 1) })
    $H.TourCount = New-Label "" 244 470 132 22 $FontSmall $UI.Muted
    $H.TourCount.TextAlign = "MiddleRight"
    foreach ($c in @($bPrev, $H.TourPlay, $bNext, $H.TourCount)) { [void](Add-HubCtrl $p $c) }
    # scrub bar: one segment per step, click to jump
    $bar = New-PaintPanel 24 508 352 14
    $bar.Cursor = "Hand"
    $bar.Add_Paint({
        param($s, $e)
        $g = Start-Paint $e
        $n = $Script:TourScenes.Count; $gap = [single](Px 2)
        $w = ($s.Width - ($n - 1) * $gap) / $n; $h = [single](Px 5); $y = ($s.Height - $h) / 2
        $T = $Script:Hub.Tour
        for ($i = 0; $i -lt $n; $i++) {
            $x = $i * ($w + $gap)
            Fill-Round $g $UI.Line $x $y $w $h ($h / 2)
            $frac = if ($i -lt $T.Idx) { 1.0 } elseif ($i -gt $T.Idx) { 0.0 } else { [Math]::Min(1.0, (Get-TourElapsed) / ($Script:TourScenes[$i].Ms / 1000.0)) }
            if ($frac -gt 0) { Fill-Round $g $UI.Accent $x $y ([Math]::Max($h, $w * $frac)) $h ($h / 2) }
        }
    })
    $bar.Add_MouseClick({ param($s, $e) Tour-Go ([int][Math]::Floor($e.X / $s.Width * $Script:TourScenes.Count)) })
    [void](Add-HubCtrl $p $bar)
    $Script:Hub.Stages += $bar
    if (Test-Path (Join-Path $ScriptDir "assets\guide.html")) {
        $big = New-FlatButton -Text "Watch it full size in your browser" -X 24 -Y 532 -W 352 -H 32 -Ghost
        $big.Add_Click({ Open-Guide })
        [void](Add-HubCtrl $p $big)
    }
    Ensure-Assets
    Tour-Go 0
    return "How to use"
}

function Get-TourElapsed {
    $T = $Script:Hub.Tour
    if (-not $T.Playing) { return $T.Paused }
    return $Script:Hub.Clock.Elapsed.TotalSeconds - $T.T0
}

function Tour-Go([int]$i) {
    $H = $Script:Hub; $T = $H.Tour
    if (-not $T) { return }
    $n = $Script:TourScenes.Count
    $i = [Math]::Max(0, [Math]::Min($n - 1, $i))
    $T.From = $T.Pt
    $T.Idx = $i
    $T.T0 = $H.Clock.Elapsed.TotalSeconds; $T.Paused = 0.0
    $sc = $Script:TourScenes[$i]
    $H.TourChap.Text = $sc.ch.ToUpper()
    $H.TourTitle.Text = $sc.t
    $H.TourText.Text = $sc.d
    $H.TourCount.Text = "Step $($i + 1) of $n"
    $H.TourStage.Invalidate()
}

function Tour-Toggle {
    $T = $Script:Hub.Tour
    if (-not $T) { return }
    if ($T.Playing) { $T.Paused = Get-TourElapsed; $T.Playing = $false; $Script:Hub.TourPlay.Text = "Play" }
    else {
        if ($T.Idx -eq $Script:TourScenes.Count - 1 -and $T.Paused -ge $Script:TourScenes[$T.Idx].Ms / 1000.0) { Tour-Go 0 }
        $T.T0 = $Script:Hub.Clock.Elapsed.TotalSeconds - $T.Paused; $T.Playing = $true; $Script:Hub.TourPlay.Text = "Pause"
    }
}

# called from the hub clock: move on when a step's time is up
function Tour-Tick {
    $H = $Script:Hub; $T = $H.Tour
    if (-not $T -or $H.PageName -ne "tour" -or -not $T.Playing) { return }
    if ((Get-TourElapsed) -ge $Script:TourScenes[$T.Idx].Ms / 1000.0) {
        if ($T.Idx -lt $Script:TourScenes.Count - 1) { Tour-Go ($T.Idx + 1) }
        else { $T.Paused = $Script:TourScenes[$T.Idx].Ms / 1000.0; $T.Playing = $false; $H.TourPlay.Text = "Replay" }
    }
}

function Draw-TourStage($g, [int]$w, [int]$h) {
    $T = $Script:Hub.Tour
    $sc = $Script:TourScenes[$T.Idx]
    $el = Get-TourElapsed
    Fill-Round $g (ToColor "#14110F") 0 0 ($w - 1) ($h - 1) (Px 14)
    $acc = $UI.Accent
    if ($sc.mock -eq "keys") {
        $keys = @("Ctrl", "Alt", "E"); $kw = @((Px 70), (Px 60), (Px 50)); $kh = [single](Px 52)
        $total = ($kw | Measure-Object -Sum).Sum + 2 * (Px 36)
        $x = ($w - $total) / 2; $y = ($h - $kh) / 2 - (Px 10)
        for ($i = 0; $i -lt 3; $i++) {
            $down = ($el -ge 0.6 + $i * 0.35 -and $el -lt 2.4)
            $dy = if ($down) { Px 4 } else { 0 }
            Fill-Round $g (ToColor "#0A0807") $x ($y + (Px 6)) $kw[$i] $kh (Px 10)
            Fill-Round $g $(if ($down) { $acc } else { ToColor "#2B2420" }) $x ($y + $dy) $kw[$i] $kh (Px 10)
            Draw-Text $g $keys[$i] (Get-SceneFont ([single](Px 18)) -Bold) $(if ($down) { ToColor "#1A1410" } else { ToColor "#F3EEE8" }) $x ($y + $dy) $kw[$i] $kh "Center"
            $x += $kw[$i]
            if ($i -lt 2) { Draw-Text $g "+" (Get-SceneFont ([single](Px 18)) -Bold) (ToColor "#8D8178") $x $y (Px 36) $kh "Center"; $x += Px 36 }
        }
        Draw-Text $g "Works in any app" (Get-SceneFont ([single](Px 13))) (ToColor "#C9BFB5") 0 ($y + $kh + (Px 16)) $w (Px 22) "Center"
        $T.Pt = $null
        return
    }
    if ($sc.mock -eq "menu") {
        $items = @("Start a timer...", "Stop timer", "Favourites", "Focus", "-", "Edit note...", "Add missed time...", "Hide names and times", "-", "Shape: switch to square", "Settings...", "How to use...")
        $mw = [single](Px 220); $ih = [single](Px 22)
        $mh = ($items | ForEach-Object { if ($_ -eq "-") { Px 9 } else { $ih } } | Measure-Object -Sum).Sum + (Px 12)
        $mx = ($w - $mw) / 2; $my = ($h - $mh) / 2
        Fill-Round $g (ToColor "#26201D") $mx $my $mw $mh (Px 8)
        $real = @($items | Where-Object { $_ -ne "-" })
        $hi = $real[[int][Math]::Floor([Math]::Max(0, $el - 0.5) / 0.52) % $real.Count]
        $yy = $my + (Px 6)
        foreach ($it in $items) {
            if ($it -eq "-") { Fill-Round $g (ToColor "#3A322D") ($mx + (Px 8)) ($yy + (Px 4)) ($mw - (Px 16)) 1 0; $yy += Px 9; continue }
            if ($it -eq $hi) { Fill-Round $g (ToColor "#3D342E") ($mx + (Px 4)) $yy ($mw - (Px 8)) $ih (Px 5) }
            Draw-Text $g $it (Get-SceneFont ([single](Px 12.5))) (ToColor "#ECE6DF") ($mx + (Px 14)) $yy ($mw - (Px 20)) $ih "Left"
            $yy += $ih
        }
        $T.Pt = $null
        return
    }
    $img = Get-TourImage $sc.img
    if (-not $img) {
        Draw-Text $g "Getting the tour pictures..." (Get-SceneFont ([single](Px 13))) (ToColor "#C9BFB5") 0 0 $w $h "Center"
        return
    }
    $pad = [single](Px 12)
    $k = [Math]::Min(($w - 2 * $pad) / $img.Width, ($h - 2 * $pad) / $img.Height)
    $iw = [single]($img.Width * $k); $ih2 = [single]($img.Height * $k)
    $dx = [single](($w - $iw) / 2); $dy = [single](($h - $ih2) / 2)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($img, $dx, $dy, $iw, $ih2)
    $target = New-Object System.Drawing.PointF(($dx + $iw * 0.62), ($dy + $ih2 * 0.55))
    if ($sc.r) {
        $r = $sc.r; $sp = [single](Px 4)
        $rx = $dx + $r[0] * $k - $sp; $ry = $dy + $r[1] * $k - $sp; $rw = $r[2] * $k + 2 * $sp; $rh = $r[3] * $k + 2 * $sp
        # dim everything but the highlighted part
        $hole = New-RoundPath $rx $ry $rw $rh (Px 8)
        $region = New-Object System.Drawing.Region((New-Object System.Drawing.RectangleF($dx, $dy, $iw, $ih2)))
        $region.Exclude($hole)
        $dim = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(160, 8, 6, 5))
        $g.FillRegion($dim, $region); $dim.Dispose(); $region.Dispose()
        $pen = New-Object System.Drawing.Pen($acc, [single](Px 2)); $g.DrawPath($pen, $hole); $pen.Dispose(); $hole.Dispose()
        $target = New-Object System.Drawing.PointF(($dx + ($r[0] + [Math]::Min($r[2] * 0.5, 60)) * $k), ($dy + ($r[1] + $r[3] * 0.5) * $k))
    }
    # the cursor glides to the highlight, then clicks
    $from = if ($T.From) { $T.From } else { New-Object System.Drawing.PointF(($w * 0.85), ($h * 0.9)) }
    $p = Ease (($el - 0.25) / 0.9)
    $cx = $from.X + ($target.X - $from.X) * $p; $cy = $from.Y + ($target.Y - $from.Y) * $p
    $T.Pt = New-Object System.Drawing.PointF($cx, $cy)
    $rp = ($el - 1.25) / 0.7
    if ($rp -gt 0 -and $rp -lt 1) {
        $rr = (Px 5) + (Px 22) * $rp
        $rpen = New-Object System.Drawing.Pen((A ([System.Drawing.Color]::White) ([int](220 * (1 - $rp)))), [single](Px 2.5))
        $g.DrawEllipse($rpen, ($target.X - $rr), ($target.Y - $rr), (2 * $rr), (2 * $rr)); $rpen.Dispose()
    }
    $state = $g.Save()
    $g.TranslateTransform($cx, $cy); $g.ScaleTransform([single]$Script:Scale, [single]$Script:Scale)
    Draw-Cursor $g 0 0
    $g.Restore($state)
}

# Fetch any shipped file that's missing (e.g. the tour pictures, when an older
# updater installed this version without them).
$Script:AssetWorker = {
    param($Base, $Root, $Files)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $got = 0; $err = ""
    foreach ($f in $Files) {
        try {
            $dst = Join-Path $Root ($f -replace "/", "\")
            New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
            try { Invoke-WebRequest -Uri ($Base + $f) -OutFile "$dst.part" -UseBasicParsing -TimeoutSec 20 }
            catch {
                # same IPv6 trouble as the update check: retry with curl over IPv4
                $curl = Join-Path $env:WINDIR "System32\curl.exe"
                if (-not (Test-Path $curl)) { throw }
                & $curl -4 -s -f -L -m 120 -o "$dst.part" ($Base + $f)
                if ($LASTEXITCODE -ne 0) { throw "curl exit $LASTEXITCODE" }
            }
            Move-Item "$dst.part" $dst -Force
            $got++
        } catch { $err = $_.Exception.Message }
    }
    [pscustomobject]@{ Name = "assets"; Ok = ($err -eq ""); Code = 0; Data = $got; Error = $err }
}.ToString()

function Ensure-Assets([switch]$Force) {
    if ($Script:AssetsBusy -or $RenderPreview) { return }
    if (-not $Force -and $Script:AssetsChecked) { return }
    $Script:AssetsChecked = $true
    if (Test-Path (Join-Path $ScriptDir ".git")) { return }
    $missing = @($Script:AssetFiles | Where-Object { -not (Test-Path (Join-Path $ScriptDir ($_ -replace "/", "\"))) })
    if ($missing.Count -eq 0) { return }
    $Script:AssetsBusy = $true
    $ps = [powershell]::Create()
    $ps.RunspacePool = $Script:Pool
    [void]$ps.AddScript($Script:AssetWorker).AddArgument("https://raw.githubusercontent.com/Rahul-Undefined/Everhour-Widget/main/").AddArgument($ScriptDir).AddArgument($missing)
    $h = $ps.BeginInvoke()
    [void]$Script:Jobs.Add([pscustomobject]@{ PS = $ps; Handle = $h; OnDone = {
        param($m)
        $Script:AssetsBusy = $false
        $r = $m["assets"]
        if ($r) { Write-Log "Fetched $($r.Data) missing file(s)$(if ($r.Error) { ': ' + $r.Error })" }
        if ($Script:HubOpen -and $Script:Hub.TourStage -and -not $Script:Hub.TourStage.IsDisposed) { $Script:Hub.TourStage.Invalidate() }
    } })
}

function Build-Page-account($p) {
    $H = $Script:Hub
    $y = 4
    $who = if ($Script:LastError -eq "AUTH") { "Your API token was rejected" } elseif ($Script:UserName) { "Connected as $($Script:UserName)" } else { "Connected to Everhour" }
    $H.AcctLabel = New-Label $who 24 $y 352 22 $FontUIBold $(if ($Script:LastError -eq "AUTH") { $UI.Danger } else { $UI.Text })
    [void](Add-HubCtrl $p $H.AcctLabel); $y += 30
    [void](Add-HubCtrl $p (New-NavRow "Change API token" $null "connect" 24 $y)); $y += 52
    [void](Add-HubCtrl $p (New-ActionRow "Test connection" { Hub-TestConnection } 24 $y)); $y += 52
    [void](Add-HubCtrl $p (New-NavRow "How to use the widget" { "3-minute tour" } "tour" 24 $y)); $y += 52
    [void](Add-HubCtrl $p (New-ActionRow "Run the setup guide again" { $Script:Hub.RunSetup = $true; $Script:Hub.Form.Close() } 24 $y)); $y += 52
    [void](Add-HubCtrl $p (New-ActionRow "Open log folder" { Start-Process explorer.exe $ConfigDir } 24 $y)); $y += 62
    [void](Add-HubCtrl $p (New-Caps "Updates" 24 $y)); $y += 22
    $upd = if ($Script:UpdateAvail) { "Version $($Script:UpdateAvail.Version) is ready to install" } else { "You have version $($Script:Version)" }
    $H.UpdLabel = New-Label $upd 24 $y 352 22 $FontUI $UI.Text
    [void](Add-HubCtrl $p $H.UpdLabel); $y += 28
    if ($Script:UpdateAvail) {
        [void](Add-HubCtrl $p (New-ActionRow "Install the update now" { $Script:Hub.After = { Install-Update }; $Script:Hub.Form.Close() } 24 $y)); $y += 52
    }
    [void](Add-HubCtrl $p (New-ActionRow "Check for updates" { $Script:Hub.UpdLabel.Text = "Checking..."; Check-Update -Manual } 24 $y)); $y += 52
    [void](Add-HubCtrl $p (New-HubToggle "Install updates automatically" "AutoUpdate" 24 $y)); $y += 44
    $sp = New-PaintPanel 0 $y 1 1; [void](Add-HubCtrl $p $sp)
    return "Account"
}
function Build-Page-focus($p) {
    $H = $Script:Hub
    $y = Add-Hero $p "Focus sessions" "Work in focused blocks. The edge lights count down; when time's up you get a chime and a break."
    [void](Add-HubCtrl $p (New-Caps "Focus for" 24 $y)); $y += 22
    $ch = Add-HubCtrl $p (New-Chips @(@{ L = "25 min"; V = 25 }, @{ L = "45 min"; V = 45 }, @{ L = "50 min"; V = 50 }) 24 $y 352 { [int]$Script:Cfg.FocusMinutes } { param($v) Set-Cfg "FocusMinutes" ([int][Math]::Max(5, [Math]::Min(180, $v))) } "min")
    $y = Below $ch
    [void](Add-HubCtrl $p (New-Caps "Then a break of" 24 $y)); $y += 22
    $ch = Add-HubCtrl $p (New-Chips @(@{ L = "None"; V = 0 }, @{ L = "5 min"; V = 5 }, @{ L = "10 min"; V = 10 }, @{ L = "15 min"; V = 15 }) 24 $y 352 { [int]$Script:Cfg.FocusBreakMinutes } { param($v) Set-Cfg "FocusBreakMinutes" ([int][Math]::Min(60, $v)) } "min")
    $y = Below $ch
    $bt = if ($Script:Cfg.BreakTaskName) { "Uses '$($Script:Cfg.BreakTaskName)'" } else { "Start your break task once and it's remembered" }
    [void](Add-HubCtrl $p (New-HubToggle "Switch to my break task and back" "FocusAutoBreak" 24 $y 352 $bt)); $y += 62
    $b = New-FlatButton -Text "Start a focus session now" -X 24 -Y $y -W 352 -H 42 -Primary
    $b.Add_Click({ $Script:Hub.After = { Start-Focus 0 }; $Script:Hub.Form.Close() })
    [void](Add-HubCtrl $p $b)
    return "Focus"
}

function Build-Page-favourites($p) {
    $y = Add-Hero $p "Favourite tasks" "Up to 5. They show as one-click chips on the widget and in the right-click menu. Pin tasks with the star in the task picker."
    $favs = @(Get-Favs)
    if ($favs.Count -eq 0) {
        [void](Add-HubCtrl $p (New-Label "Nothing pinned yet." 24 $y 352 22 $FontUI $UI.Muted)); $y += 34
    }
    foreach ($fv in $favs) {
        $row = New-ActionRow ([string]$fv.Name) { param($row) Toggle-Fav $row.Tag.FavId ""; Hub-Go "favourites" 1 -NoAnim } 24 $y
        $row.Tag.FavId = [string]$fv.Id
        $row.Tag.Value = { "Remove" }
        [void](Add-HubCtrl $p $row); $y += 52
    }
    $y += 6
    $b = New-FlatButton -Text "Open the task picker" -X 24 -Y $y -W 352 -H 40
    $b.Add_Click({ $Script:Hub.After = { Show-TaskPicker }; $Script:Hub.Form.Close() })
    [void](Add-HubCtrl $p $b)
    return "Favourites"
}

function Build-Page-advanced($p) {
    $y = 4
    [void](Add-HubCtrl $p (New-Caps "Daily target" 24 $y)); $y += 22
    $ch = Add-HubCtrl $p (New-Chips @(@{ L = "6 h"; V = 6 }, @{ L = "7 h"; V = 7 }, @{ L = "8 h"; V = 8 }, @{ L = "9 h"; V = 9 }) 24 $y 352 { [double]$Script:Cfg.DailyTargetHours } { param($v) Set-Cfg "DailyTargetHours" ([double][Math]::Min(24, $v)) } "h")
    $y = Below $ch
    [void](Add-HubCtrl $p (New-Caps "Check Everhour every" 24 $y)); $y += 22
    $ch = Add-HubCtrl $p (New-Chips @(@{ L = "5 s"; V = 5 }, @{ L = "10 s"; V = 10 }, @{ L = "20 s"; V = 20 }, @{ L = "30 s"; V = 30 }) 24 $y 352 { [int]$Script:Cfg.RefreshSeconds } { param($v) Set-Cfg "RefreshSeconds" ([int]$v) })
    $y = Below $ch
    [void](Add-HubCtrl $p (New-Caps "Close the expanded view after" 24 $y)); $y += 22
    $ch = Add-HubCtrl $p (New-Chips @(@{ L = "Never"; V = 0 }, @{ L = "10 s"; V = 10 }, @{ L = "15 s"; V = 15 }, @{ L = "30 s"; V = 30 }) 24 $y 352 { [int]$Script:Cfg.AutoCollapseSeconds } { param($v) Set-Cfg "AutoCollapseSeconds" ([int]$v) })
    $y = Below $ch
    [void](Add-HubCtrl $p (New-Caps "Keyboard shortcut" 24 $y)); $y += 22
    [void](Add-HubCtrl $p (New-HubToggle "Start / stop from anywhere" "HotkeyEnabled" 24 $y 352 "Press it in any app - even when the widget is hidden")); $y += 54
    $hot = New-TextBox 24 $y 352 ([string]$Script:Cfg.Hotkey) "Click here, then press your keys"
    $hot.ReadOnly = $true; $hot.BackColor = $UI.Card; $hot.Cursor = "Hand"
    $hot.Add_KeyDown({
        param($s, $e)
        $e.SuppressKeyPress = $true; $e.Handled = $true
        $k = $e.KeyCode.ToString()
        if ($k -in @("ControlKey", "ShiftKey", "Menu", "LWin", "RWin", "Back", "Delete", "Escape")) { return }
        $parts = @()
        if ($e.Control) { $parts += "Ctrl" }
        if ($e.Alt) { $parts += "Alt" }
        if ($e.Shift) { $parts += "Shift" }
        if ($parts.Count -eq 0) { return }
        $s.Text = (($parts + $k) -join "+")
        $Script:Cfg.Hotkey = $s.Text; Save-Config; Register-Hotkey
        $Script:Hub.HotNote.Text = if ($Script:HotkeyStatus) { $Script:HotkeyStatus } else { "Saved - try it now." }
    })
    [void](Add-HubCtrl $p $hot); $y += 34
    $msg = if ($Script:HotkeyStatus) { $Script:HotkeyStatus } else { "Click the box and press the keys you want, e.g. Ctrl+Alt+E." }
    $Script:Hub.HotNote = New-Label $msg 24 $y 352 36 $FontSmall $UI.Muted
    [void](Add-HubCtrl $p $Script:Hub.HotNote)
    return "Advanced"
}

# ---------------------------------------------------------------------------
#  Hub window and navigation
# ---------------------------------------------------------------------------
function Get-HubTime {
    if ($RenderPreview) { return 3.6 }
    return $Script:Hub.Clock.Elapsed.TotalSeconds
}

function Show-Hub([string]$Mode = "settings", [string]$Page = "") {
    if ($Script:HubOpen) { return $false }
    $Script:HubOpen = $true
    $setup = ($Mode -eq "setup")
    $H = @{ Mode = $Mode; Stack = (New-Object System.Collections.ArrayList); Clock = [Diagnostics.Stopwatch]::StartNew()
            Wheels = @(); Stages = @(); HadKey = -not [string]::IsNullOrWhiteSpace((Get-ApiKey)); KeyOk = $false; Busy = $false
            Done = $false; RunSetup = $false; Current = $null; Old = $null; Slide = $null; PageName = "" }
    if ($RenderPreview) { $H.HadKey = $true }
    $Script:Hub = $H

    $W = $Script:HubW; $Hh = 660
    $footH = if ($setup) { 72 } else { 0 }
    $f = New-Object System.Windows.Forms.Form
    $f.Text = "Everhour Widget"
    $f.FormBorderStyle = "None"; $f.StartPosition = "Manual"
    $f.BackColor = $UI.Bg; $f.ShowInTaskbar = $setup; $f.TopMost = $true; $f.KeyPreview = $true
    $an = if ($Script:Anchor) { $Script:Anchor } else { [System.Windows.Forms.Cursor]::Position }
    $wa = [System.Windows.Forms.Screen]::FromPoint($an).WorkingArea
    $fw = Px $W; $fh = [Math]::Min((Px $Hh), $wa.Height - (Px 20))
    $f.Size = New-Object System.Drawing.Size($fw, $fh)
    if ($setup -or -not $Script:Anchor) {
        $fx = $wa.Left + [int](($wa.Width - $fw) / 2); $fy = $wa.Top + [int](($wa.Height - $fh) / 2)
    } else {
        # open beside the widget, on whichever side has room
        $fx = $form.Left - $fw - (Px 4)
        if ($fx -lt $wa.Left) { $fx = $form.Right + (Px 4) }
        $fx = [Math]::Max($wa.Left, [Math]::Min($fx, $wa.Right - $fw))
        $fy = [Math]::Max($wa.Top, [Math]::Min($form.Top, $wa.Bottom - $fh))
    }
    $f.Location = New-Object System.Drawing.Point($fx, $fy)
    $H.Form = $f

    # header: back, title, close
    # header in the widget's style: theme gradient with a strip of edge-light dots
    $bar = New-PaintPanel 0 0 $W 58
    $bar.Add_Paint({
        param($s, $e)
        $g = Start-Paint $e
        $rect = New-Object System.Drawing.Rectangle(0, 0, $s.Width, $s.Height)
        $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $UI.Bg, (Mix $UI.Bg $UI.Accent 0.22), [single]0)
        $g.FillRectangle($lg, $rect); $lg.Dispose()
        $n = [int]($s.Width / (Px 9))
        $lit = [int]($n * 0.35)
        for ($i = 0; $i -lt $n; $i++) {
            $a = if ($i -lt $lit) { 230 - $i * 3 } else { 45 }
            Fill-Circle $g (A $UI.Accent $a) ((Px 6) + $i * (Px 9)) ($s.Height - (Px 4)) ([single](Px 1.5))
        }
    })
    $f.Controls.Add($bar)
    $H.Bar = $bar
    $back = New-Label ([string][char]0x2039) 10 6 34 40 (New-Object System.Drawing.Font("Segoe UI", 20)) $UI.Text
    $back.TextAlign = "MiddleCenter"; $back.Cursor = "Hand"
    $back.Add_Click({ Hub-Back })
    $bar.Controls.Add($back); $H.BackBtn = $back
    $H.TitleLbl = New-Label "" 46 14 260 28 $FontTitle $UI.Text
    $bar.Controls.Add($H.TitleLbl)
    $x = New-Label ([string][char]0x2715) ($W - 46) 11 32 30 (New-Object System.Drawing.Font("Segoe UI", 10.5)) $UI.Muted
    $x.TextAlign = "MiddleCenter"; $x.Cursor = "Hand"
    $x.Add_Click({ $Script:Hub.Form.Close() })
    $bar.Controls.Add($x); $H.CloseBtn = $x
    Enable-Drag $bar; Enable-Drag $H.TitleLbl

    $vp = New-Object System.Windows.Forms.Panel
    $vp.Location = New-Object System.Drawing.Point(0, (Px 58))
    $vp.Size = New-Object System.Drawing.Size($fw, ($fh - (Px 58) - (Px $footH)))
    $vp.BackColor = $UI.Bg
    $f.Controls.Add($vp)
    $H.View = $vp

    if ($setup) {
        $dots = New-PaintPanel 24 0 160 16
        $dots.Top = $fh - (Px 46)
        $dots.Add_Paint({
            param($s, $e)
            $g = Start-Paint $e
            $n = $Script:SetupPages.Count
            $cur = [array]::IndexOf($Script:SetupPages, $Script:Hub.PageName)
            $x = 0.0
            for ($i = 0; $i -lt $n; $i++) {
                $w = if ($i -eq $cur) { Px 18 } else { Px 6 }
                Fill-Round $g $(if ($i -le $cur) { $UI.Accent } else { $UI.Line }) $x (Px 5) $w (Px 6) (Px 3)
                $x += $w + (Px 5)
            }
        })
        $f.Controls.Add($dots); $H.Dots = $dots
        $H.Next = New-FlatButton -Text "Next" -X ($W - 140) -Y 0 -W 116 -H 40 -Primary
        $H.Next.Top = $fh - (Px 58)
        $H.Next.Add_Click({ Hub-Next })
        $f.Controls.Add($H.Next)
    }

    # one clock for slides, wheels, previews and the fade-in
    $tick = New-Object System.Windows.Forms.Timer
    $tick.Interval = 16
    $tick.Add_Tick({ Hub-Tick })
    $H.Tick = $tick
    $H.Frame = 0

    $f.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $s.Close() } })
    $f.Add_Shown({
        param($s, $e)
        Set-DwmLook $s; Set-CaptureHidden $s
        $s.Activate()
        $Script:Hub.Tick.Start()
    })
    $f.Add_Paint({ param($s, $e) if (-not $Script:DwmRounded) { $pn = New-Object System.Drawing.Pen($UI.Line); $e.Graphics.DrawRectangle($pn, 0, 0, $s.Width - 1, $s.Height - 1); $pn.Dispose() } })

    $first = if ($setup) { "welcome" } elseif ($Page) { $Page } else { "home" }
    if (-not $setup -and $Page -and $Page -ne "home") { [void]$H.Stack.Add("home") }
    Hub-Go $first 1 -NoAnim
    if (-not $RenderPreview) { $f.Opacity = 0 }
    try { [void]$f.ShowDialog() } finally {
        $tick.Stop(); $tick.Dispose()
        $f.Dispose()
        $Script:HubOpen = $false
    }

    $haveKey = -not [string]::IsNullOrWhiteSpace((Get-ApiKey))
    if ($setup -and $haveKey) { $Script:Cfg.OnboardingDone = $true; Save-Config }
    if ($H.RunSetup) { return (Show-Hub "setup") }
    if ($H.After) { & $H.After }
    if ($setup -and $H.Done -and -not $Script:IsRunning -and $Script:Ready) { Show-TaskPicker }
    return $haveKey
}

function Hub-Go([string]$page, [int]$dir = 1, [switch]$NoAnim, [switch]$Push) {
    $H = $Script:Hub
    if ($H.Slide) { Finish-Slide }
    if ($Push -and $H.PageName) { [void]$H.Stack.Add($H.PageName) }
    $vp = $H.View
    $p = New-Object System.Windows.Forms.Panel
    $p.Size = $vp.ClientSize
    $p.BackColor = $UI.Bg
    $p.AutoScroll = $true
    Set-DoubleBuffered $p
    $title = & "Build-Page-$page" $p
    $H.PageName = $page
    $H.TitleLbl.Text = $(if ($H.Mode -eq "setup" -and $page -ne "home") { "Set up" } else { [string]$title })
    $setupIdx = [array]::IndexOf($Script:SetupPages, $page)
    $H.BackBtn.Visible = $(if ($H.Mode -eq "setup") { $setupIdx -gt 0 } else { $H.Stack.Count -gt 0 })
    if ($H.Next) {
        $H.Next.Visible = ($page -ne "finish")
        $H.Next.Text = switch ($page) { "welcome" { "Get started" } "connect" { if ($H.HadKey -or $H.KeyOk) { "Next" } else { "Connect" } } default { "Next" } }
        $H.Dots.Invalidate()
    }
    if ($NoAnim -or -not $H.Current) {
        if ($H.Current) { $vp.Controls.Remove($H.Current); $H.Current.Dispose() }
        $p.Location = New-Object System.Drawing.Point(0, 0)
        $vp.Controls.Add($p)
        $H.Current = $p
    } else {
        $p.Location = New-Object System.Drawing.Point(($dir * $vp.Width), 0)
        $vp.Controls.Add($p)
        $H.Slide = @{ Old = $H.Current; New = $p; Dir = $dir; T0 = $H.Clock.Elapsed.TotalSeconds }
        $H.Current = $p
    }
    if ($page -eq "connect" -and $H.KeyBox) { $H.KeyBox.Focus() | Out-Null }
}

function Finish-Slide {
    $H = $Script:Hub; $sl = $H.Slide
    if (-not $sl) { return }
    $sl.New.Left = 0
    $H.View.Controls.Remove($sl.Old); $sl.Old.Dispose()
    $H.Slide = $null
    $H.Wheels = @($H.Wheels | Where-Object { -not $_.IsDisposed })
    $H.Stages = @($H.Stages | Where-Object { -not $_.IsDisposed })
}

function Hub-Tick {
    $H = $Script:Hub
    if (-not $H -or $H.Form.IsDisposed) { return }
    $tgt = Get-DialogOpacity
    if ($H.Form.Opacity -lt $tgt - 0.005) { $H.Form.Opacity = [Math]::Min($tgt, $H.Form.Opacity + 0.12) }
    elseif ($H.Form.Opacity -gt $tgt + 0.005) { $H.Form.Opacity = $tgt }
    if ($H.Slide) {
        $p = ($H.Clock.Elapsed.TotalSeconds - $H.Slide.T0) / 0.26
        if ($p -ge 1) { Finish-Slide }
        else {
            $e = 1 - [Math]::Pow(1 - $p, 3)      # ease-out
            $w = $H.View.Width
            $H.Slide.New.Left = [int]($H.Slide.Dir * $w * (1 - $e))
            $H.Slide.Old.Left = [int](-$H.Slide.Dir * $w * $e)
        }
    }
    foreach ($wh in $H.Wheels) {
        if ($wh.IsDisposed -or $wh.Tag.Drag) { continue }
        $d = $wh.Tag.Idx - $wh.Tag.Off
        if ([Math]::Abs($d) -gt 0.002) { $wh.Tag.Off += $d * 0.28; $wh.Invalidate() }
    }
    Tour-Tick
    $H.Frame++
    if ($H.Frame % 3 -eq 0) { foreach ($st in $H.Stages) { if (-not $st.IsDisposed -and $st.Visible) { $st.Invalidate() } } }
}

function Hub-Back {
    $H = $Script:Hub
    if ($H.Mode -eq "setup") {
        $i = [array]::IndexOf($Script:SetupPages, $H.PageName)
        if ($i -gt 0) { Hub-Go $Script:SetupPages[$i - 1] -1 }
    } elseif ($H.Stack.Count -gt 0) {
        $prev = $H.Stack[$H.Stack.Count - 1]
        $H.Stack.RemoveAt($H.Stack.Count - 1)
        Hub-Go $prev -1
    }
}

function Hub-Next {
    $H = $Script:Hub
    $i = [array]::IndexOf($Script:SetupPages, $H.PageName)
    if ($H.PageName -eq "connect" -and -not ($H.HadKey -or $H.KeyOk)) { Hub-Connect; return }
    if ($H.PageName -eq "connect" -and $H.KeyBox -and $H.KeyBox.Text.Trim()) { Hub-Connect; return }
    if ($i -ge 0 -and $i -lt $Script:SetupPages.Count - 1) { Hub-Go $Script:SetupPages[$i + 1] 1 }
}

function Hub-Connect {
    $H = $Script:Hub
    $k = $H.KeyBox.Text.Trim()
    if (-not $k) {
        if ($H.HadKey -or $H.KeyOk) { if ($H.Mode -eq "setup") { Hub-Go "theme" 1 }; return }
        $H.KeyStatus.ForeColor = $UI.Danger; $H.KeyStatus.Text = "Paste your API token first."
        return
    }
    if ($H.Busy) { return }
    $H.Busy = $true
    $H.KeyStatus.ForeColor = $UI.Muted; $H.KeyStatus.Text = "Checking with Everhour..."
    Invoke-Api -Key $k -Requests @(@{ Name = "me"; Path = "/users/me" }) -OnDone {
        param($m)
        $H = $Script:Hub
        $H.Busy = $false
        if ($H.Form.IsDisposed -or -not $H.KeyBox -or $H.KeyBox.IsDisposed) { return }
        $r = $m["me"]
        $k = $H.KeyBox.Text.Trim()
        $ok = $false
        if ($r -and $r.Ok -and $r.Data) {
            $Script:UserId = $r.Data.id
            $Script:UserName = [string]$r.Data.name
            $ok = $true
        } elseif ($r -and ($r.Code -eq 401 -or $r.Code -eq 403)) {
            $H.KeyStatus.ForeColor = $UI.Danger
            $H.KeyStatus.Text = "Everhour didn't accept that token. Copy it again and make sure you got all of it."
        } else {
            $ok = $true     # offline: keep it; the widget will say if it's wrong
        }
        if ($ok) {
            Set-ApiKey $k; $H.KeyOk = $true
            if ($Script:Ready) { After-KeyChanged }
            $H.KeyBox.Text = ""
            $who = if ($Script:UserName) { " as $($Script:UserName)" } else { "" }
            $H.KeyStatus.ForeColor = $UI.Good; $H.KeyStatus.Text = "Connected$who."
            if ($H.Mode -eq "setup") { Hub-Go "theme" 1 }
        }
    }
}

function Hub-TestConnection {
    $Script:Hub.AcctLabel.ForeColor = $UI.Muted
    $Script:Hub.AcctLabel.Text = "Checking..."
    Invoke-Api -Requests @(@{ Name = "me"; Path = "/users/me" }) -OnDone {
        param($m)
        $lbl = $Script:Hub.AcctLabel
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
}

function Show-Settings { Show-Hub "settings" | Out-Null }

# The same tour as a full-size page in the browser (shipped with the widget).
function Open-Guide {
    $g = Join-Path $ScriptDir "assets\guide.html"
    if (Test-Path $g) { Start-Process $g } else { Ensure-Assets -Force }
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
        foreach ($fv in (Get-Favs)) {
            if (-not $map.ContainsKey([string]$fv.Id)) { $map[[string]$fv.Id] = [pscustomobject]@{ Id = [string]$fv.Id; Name = [string]$fv.Name; Last = "9999"; Sec = 0; Sub = "" } }
        }
        $items = @($map.Values | Sort-Object @{ Expression = { Test-Fav $_.Id }; Descending = $true }, @{ Expression = { $_.Id -eq $last }; Descending = $true }, @{ Expression = "Last"; Descending = $true }, @{ Expression = "Sec"; Descending = $true })
        foreach ($it in $items) {
            $parts = @()
            if (Test-Fav $it.Id) { $parts += "Favourite" }
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

function Draw-Star($g, $color, [single]$cx, [single]$cy, [single]$r, [bool]$filled) {
    $pts = New-Object 'System.Drawing.PointF[]' 10
    for ($i = 0; $i -lt 10; $i++) {
        $rr = if ($i % 2 -eq 0) { $r } else { $r * 0.45 }
        $ang = -[Math]::PI / 2 + $i * [Math]::PI / 5
        $pts[$i] = New-Object System.Drawing.PointF(($cx + $rr * [Math]::Cos($ang)), ($cy + $rr * [Math]::Sin($ang)))
    }
    if ($filled) { $b = New-Object System.Drawing.SolidBrush($color); $g.FillPolygon($b, $pts); $b.Dispose() }
    else { $pen = New-Object System.Drawing.Pen($color, 1.4); $g.DrawPolygon($pen, $pts); $pen.Dispose() }
}

# Task picker. -AddTime turns it into "add missed time": pick a task, a day
# and how long, and it's added to Everhour without starting a timer.
function Show-TaskPicker([switch]$AddTime) {
    if ($Script:PickerOpen) { return }
    $Script:PickerOpen = $true
    $title = if ($AddTime) { "Add missed time" } else { "Start a timer" }
    $d = New-Dialog $title 500 $(if ($AddTime) { 700 } else { 540 })
    $f = $d.Form

    $tb = New-TextBox 22 60 456 "" "Search all tasks..."
    $f.Controls.Add($tb)

    $listH = if ($AddTime) { 210 } else { 290 }
    $lb = New-Object System.Windows.Forms.ListBox
    $lb.DrawMode = "OwnerDrawFixed"
    $lb.ItemHeight = Px 42
    $lb.IntegralHeight = $false
    $lb.Font = $FontUI
    $lb.BorderStyle = "None"
    $lb.BackColor = $UI.Card; $lb.ForeColor = $UI.Text
    $lb.Location = New-Object System.Drawing.Point((Px 22), (Px 100))
    $lb.Size = New-Object System.Drawing.Size((Px 456), (Px $listH))
    $f.Controls.Add($lb)
    $lb.Add_DrawItem({
        param($s, $e)
        if ($e.Index -lt 0 -or $e.Index -ge $Script:PK.Items.Count) { return }
        $it = $Script:PK.Items[$e.Index]
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $sel = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
        $bg = if ($sel) { $UI.Sel } else { $UI.Card }
        $br = New-Object System.Drawing.SolidBrush($bg); $g.FillRectangle($br, $e.Bounds); $br.Dispose()
        if ($sel) {
            $ab = New-Object System.Drawing.SolidBrush($UI.Accent)
            $g.FillRectangle($ab, $e.Bounds.X, ($e.Bounds.Y + (Px 8)), (Px 3), ($e.Bounds.Height - (Px 16))); $ab.Dispose()
        }
        # star: pin as a favourite
        $fav = Test-Fav $it.Id
        Draw-Star $g $(if ($fav) { [System.Drawing.ColorTranslator]::FromHtml("#FBBF24") } else { $UI.Muted }) ($e.Bounds.Right - (Px 20)) ($e.Bounds.Y + $e.Bounds.Height / 2) ([single](Px 8)) $fav
        $flags = [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor
                 [System.Windows.Forms.TextFormatFlags]::EndEllipsis -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix
        $x = $e.Bounds.X + (Px 14); $w = $e.Bounds.Width - (Px 52)
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
    $lb.Add_MouseClick({
        param($s, $e)
        if ($e.X -lt $s.ClientSize.Width - (Px 40)) { return }
        $i = $s.IndexFromPoint($e.Location)
        if ($i -lt 0 -or $i -ge $Script:PK.Items.Count) { return }
        $it = $Script:PK.Items[$i]
        Toggle-Fav $it.Id $it.Name
        $s.Invalidate()
    })

    $y = 100 + $listH + 12
    $Script:PK = @{ Form = $f; Tb = $tb; Lb = $lb; Items = (New-Object System.Collections.ArrayList); Recent = @(); Query = ""
                    AddTime = [bool]$AddTime; Date = (Get-Date).Date; Minutes = 30; Busy = $false }
    if ($AddTime) {
        $f.Controls.Add((New-Caps "When" 22 $y)); $y += 22
        $dc = New-Chips @(@{ L = "Today"; V = 0 }, @{ L = "Yesterday"; V = 1 }) 22 $y 200 {
            [int]((Get-Date).Date - $Script:PK.Date).TotalDays } { param($v) $Script:PK.Date = (Get-Date).Date.AddDays(-[int]$v); $Script:PK.Dtp.Value = $Script:PK.Date }
        $f.Controls.Add($dc)
        $dtp = New-Object System.Windows.Forms.DateTimePicker
        $dtp.Format = "Custom"; $dtp.CustomFormat = "ddd d MMM yyyy"; $dtp.Font = $FontUI
        $dtp.MaxDate = (Get-Date).Date
        $dtp.Value = (Get-Date).Date
        $dtp.Location = New-Object System.Drawing.Point((Px 250), (Px ($y + 4)))
        $dtp.Width = Px 228
        $dtp.Add_ValueChanged({ $Script:PK.Date = $this.Value.Date; $Script:PK.DateChips.Invalidate() })
        $f.Controls.Add($dtp)
        $Script:PK.Dtp = $dtp; $Script:PK.DateChips = $dc
        $y = Below $dc 10
        $f.Controls.Add((New-Caps "How long" 22 $y)); $y += 22
        $hc = New-Chips @(@{ L = "15 min"; V = 15 }, @{ L = "30 min"; V = 30 }, @{ L = "45 min"; V = 45 }, @{ L = "1 h"; V = 60 }, @{ L = "2 h"; V = 120 }) 22 $y 456 {
            [double]$Script:PK.Minutes } { param($v) $Script:PK.Minutes = [double]$v } "min"
        $f.Controls.Add($hc)
        $y = Below $hc 10
    }
    $note = New-TextBox 22 $y 456 "" $(if ($AddTime) { "What was it? (optional)" } else { "Note for this entry (optional)" })
    $f.Controls.Add($note)
    $y += 42
    $hint = New-Label "Loading recent tasks..." 22 $y 250 40 $FontSmall $UI.Muted
    if ($Script:IsRunning -and -not $AddTime) { $hint.Text = "Now tracking: $($Script:TaskName)" }
    $f.Controls.Add($hint)
    $btnCancel = New-FlatButton -Text "Cancel" -X 280 -Y ($y + 2) -W 92 -H 36
    $btnGo = New-FlatButton -Text $(if ($AddTime) { "Add time" } else { "Start" }) -X 380 -Y ($y + 2) -W 98 -H 36 -Primary
    $f.Controls.Add($btnCancel); $f.Controls.Add($btnGo)
    $f.Height = [Math]::Min($f.Height, (Px ($y + 58)))
    $Script:PK.Note = $note; $Script:PK.Hint = $hint

    $deb = New-Object System.Windows.Forms.Timer
    $deb.Interval = 350
    $deb.Add_Tick({ $this.Stop(); Run-PickerSearch })
    $Script:PK.Deb = $deb

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
    $lb.Add_DoubleClick({ param($s, $e) if ($s.PointToClient([System.Windows.Forms.Cursor]::Position).X -lt $s.ClientSize.Width - (Px 40)) { Start-PickedTask } })
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
    if ($pk.AddTime) { Add-PickedTime; return }
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
                     "Toast", "Hits", "StoppedSince", "FocusPhase")
$Script:DemoPal = $null
function Build-DemoFrame([string]$mode, [double]$t) {
    $saved = @{}
    foreach ($n in $Script:DemoVars) { $saved[$n] = (Get-Variable -Scope Script -Name $n).Value }
    try {
        $Script:FirstPollDone = $true; $Script:LastError = ""; $Script:IsExpanded = $false; $Script:Hover = ""; $Script:Toast = ""; $Script:FocusPhase = ""
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
$miClock    = $menu.Items.Add("Clock in")
$miFavs     = New-Object System.Windows.Forms.ToolStripMenuItem("Favourites")
$miFocus    = New-Object System.Windows.Forms.ToolStripMenuItem("Focus")
[void]$menu.Items.Add($miFavs); [void]$menu.Items.Add($miFocus)
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$miNote     = $menu.Items.Add("Edit note...")
$miAddTime  = $menu.Items.Add("Add missed time...")
$miPrivacy  = $menu.Items.Add("Hide names and times")
$miPrivacy.Add_Click({ Toggle-Cfg "PrivacyMode" })
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$miRefresh  = $menu.Items.Add("Refresh now")
$miOpen     = $menu.Items.Add("Open Everhour")
$miShape    = $menu.Items.Add("Shape")
function Get-NextShape { switch ([string]$Script:Cfg.Shape) { "Large" { return "Square" } "Square" { return "Wide" } default { return "Large" } } }
$miSettings = $menu.Items.Add("Settings...")
$miGuide    = $menu.Items.Add("Setup guide...")
$miHowTo    = $menu.Items.Add("How to use...")
$miHowTo.Add_Click({ Show-Hub "settings" "tour" | Out-Null })
$miUpdate   = $menu.Items.Add("Install update")
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$miExit     = $menu.Items.Add("Exit")
foreach ($mi in $menu.Items) { $mi.Padding = New-Object System.Windows.Forms.Padding(4, 3, 4, 3) }
foreach ($sub in @($miFavs, $miFocus)) {
    $sub.DropDown.BackColor = $UI.Card; $sub.DropDown.ForeColor = $UI.Text
    if ($menu.Renderer) { $sub.DropDown.Renderer = $menu.Renderer }
    $sub.DropDown.ShowImageMargin = $false
}

function New-SubItem($parent, [string]$text, [scriptblock]$onClick, $tag = $null, [bool]$enabled = $true) {
    $it = New-Object System.Windows.Forms.ToolStripMenuItem($text)
    $it.Tag = $tag; $it.Enabled = $enabled
    $it.Padding = New-Object System.Windows.Forms.Padding(4, 3, 4, 3)
    if ($onClick) { $it.Add_Click($onClick) }
    [void]$parent.DropDownItems.Add($it)
}

$menu.Add_Opening({
    $miStop.Enabled = $Script:IsRunning
    $miClock.Visible = Test-ClockOn
    $miClock.Text = if ($Script:ClockState -eq "in") { "Clock out" } else { "Clock in" }
    $last = [string]$Script:Cfg.LastTaskName
    $miResume.Visible = (-not $Script:IsRunning) -and [bool]$Script:Cfg.LastTaskId
    if ($last.Length -gt 34) { $last = $last.Substring(0, 33) + "..." }
    $miResume.Text = "Resume  $last"
    $miStart.Text = if ($Script:IsRunning) { "Switch task..." } else { "Start a timer..." }
    $miShape.Text = "Shape: switch to " + (Get-NextShape).ToLower()
    $miNote.Enabled = $Script:IsRunning
    $miPrivacy.Text = if ($Script:Cfg.PrivacyMode) { "Show names and times" } else { "Hide names and times" }
    $miUpdate.Visible = [bool]$Script:UpdateAvail
    if ($Script:UpdateAvail) { $miUpdate.Text = "Install update (v$($Script:UpdateAvail.Version))" }

    $miFavs.DropDownItems.Clear()
    $favs = @(Get-Favs)
    for ($i = 0; $i -lt $favs.Count; $i++) {
        $nm = [string]$favs[$i].Name; if ($nm.Length -gt 40) { $nm = $nm.Substring(0, 39) + "..." }
        if ($Script:IsRunning -and $Script:TaskId -eq $favs[$i].Id) { $nm = "$nm   (running)" }
        New-SubItem $miFavs $nm { Start-Fav ([int]$this.Tag) } $i
    }
    if ($favs.Count -eq 0) { New-SubItem $miFavs "Pin tasks with the star in the task picker" $null $null $false }
    if ($Script:IsRunning) {
        $pinned = Test-Fav $Script:TaskId
        New-SubItem $miFavs $(if ($pinned) { "Unpin the running task" } else { "Pin the running task" }) { Toggle-Fav $Script:TaskId $Script:TaskName }
    }

    $miFocus.DropDownItems.Clear()
    if ($Script:FocusPhase) {
        New-SubItem $miFocus (Get-FocusLabel) $null $null $false
        New-SubItem $miFocus "End focus session" { Stop-Focus }
    } else {
        $fm = [int]$Script:Cfg.FocusMinutes
        foreach ($m in @($fm, 50) | Select-Object -Unique) { New-SubItem $miFocus "Focus for $m min" { Start-Focus ([int]$this.Tag) } $m }
        New-SubItem $miFocus "Focus settings..." { Show-Hub "settings" "focus" | Out-Null }
    }
})
$miStart.Add_Click({ Show-TaskPicker })
$miResume.Add_Click({ Resume-LastTask })
$miStop.Add_Click({ Stop-Timer })
$miClock.Add_Click({ Toggle-Clock })
$miNote.Add_Click({ Show-NoteDialog })
$miAddTime.Add_Click({ Show-TaskPicker -AddTime })
$miRefresh.Add_Click({ $Script:RecordsAt = [DateTime]::MinValue; $Script:WeekAt = [DateTime]::MinValue; Request-Poll -Force })
$miOpen.Add_Click({ Start-Process "https://app.everhour.com/" })
$miShape.Add_Click({
    $Script:IsExpanded = $false
    Set-Cfg "Shape" (Get-NextShape)
})
$miSettings.Add_Click({ Show-Settings })
$miGuide.Add_Click({ Show-Hub "setup" | Out-Null })
$miUpdate.Add_Click({ Install-Update })
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
    if ($Script:HideTarget -eq 1) { Show-FromHide; return }
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
    if ($Script:HideTarget -eq 1) { Show-FromHide; return }     # hovering the edge strip brings it back
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
$form.Add_MouseDoubleClick({
    param($s, $e)
    $h = Get-HitAt $e.Location
    if ($h -like "row:*") {
        $id = $h.Substring(4)
        Start-TaskById $id ([string]$Script:RowNames[$id])
    }
})
$form.Add_MouseWheel({
    param($s, $e)
    $h = Get-HitAt $e.Location
    if ($h -like "row:*" -or $h -eq "list") {
        $Script:ListScroll += $(if ($e.Delta -gt 0) { -1 } else { 1 })
        $Script:LastInteract = Get-Date
        Render
    }
})
function Toggle-Group([string]$grp) {
    $Script:OpenGroup = if ($Script:OpenGroup -eq $grp) { "" } else { $grp }
    $Script:ListScroll = 0
    $Script:LastInteract = Get-Date
    if ($Script:OpenGroup -eq "week" -and -not $Script:WeekLoaded) { Request-Records -WithWeek }
    Render
}
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
    switch -Wildcard (Get-HitAt $e.Location) {
        "toggle"     { Toggle-Timer }
        "fav:*"      { Start-Fav ([int]((Get-HitAt $e.Location).Substring(4))) }
        "grp:*"      { Toggle-Group ((Get-HitAt $e.Location).Substring(4)) }
        "row:*"      { }    # double-click starts it
        "list"       { }
        "update"     { Install-Update }
        "eye"        { Toggle-Cfg "PrivacyMode"; Set-Toast $(if ($Script:Cfg.PrivacyMode) { "Hidden" } else { "Visible" }) 2 }
        "b_start"    { Show-TaskPicker }
        "b_stop"     { if ($Script:IsRunning) { Stop-Timer } else { Resume-LastTask } }
        "b_settings" { Show-Settings }
        "b_clock"    { Toggle-Clock }
        default      { if ($Script:Cfg.Shape -ne "Large") { Set-Expanded (-not $Script:IsExpanded) } }
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
        "update" { Install-Update }
        "focus"  { Start-Focus 0 }
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
    if ($Script:Mode -eq "clockedout") { return }      # off for the day: no reminders
    try {
        $now = Get-Date
        if (-not (Test-WorkTime $now)) { return }
        $idleMin = ($now - $Script:LastRunAt).TotalMinutes
        if ($idleMin -lt [int]$Script:Cfg.IdleNudgeMinutes) { return }
        if (($now - $Script:NudgedAt).TotalMinutes -lt [int]$Script:Cfg.IdleNudgeMinutes) { return }
        $Script:NudgedAt = $now
        Play-Sound "soft"
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
        $maxAge = if (Test-ShowsList) { 60 } else { 180 }
        $weekDue = (Test-ShowsList) -and
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

    # auto-hide: slide into the edge after a few seconds without the pointer
    if ($Script:Cfg.AutoHide -and $Script:HideTarget -eq 0 -and -not $Script:Dragging -and -not $Script:HubOpen -and -not $Script:PickerOpen -and -not $menu.Visible) {
        $overIt = $false
        try { $overIt = $form.Bounds.Contains([System.Windows.Forms.Cursor]::Position) } catch { }
        if ($overIt) { $Script:LastInteract = $now }
        elseif (($now - $Script:LastInteract).TotalSeconds -ge 4) { Start-AutoHide }
    }
    if (-not $Script:Cfg.AutoHide -and $Script:HideTarget -eq 1) { Show-FromHide }

    # Win+R "Everhour" (or the Start shortcut) while already running: come forward
    try { if ($Script:ShowSignal -and $Script:ShowSignal.WaitOne(0)) { Bring-Forward } } catch { }
    if ($Script:ForwardUntil -and $now -gt $Script:ForwardUntil) {
        $Script:ForwardUntil = $null
        if ($Script:HideTarget -eq 0) { $form.TopMost = [bool]$Script:Cfg.AlwaysOnTop }
    }

    Check-Focus
    if (($now - $Script:StartedAt).TotalSeconds -gt 20) { Ensure-Assets }
    # look for a new version 30 s after start, then every 6 hours
    if (($now - $Script:StartedAt).TotalSeconds -gt 30 -and ($now - $Script:UpdCheckedAt).TotalHours -ge 6) { Check-Update }
    if ($Script:AutoInstallPending -and -not $Script:HubOpen -and -not $Script:PickerOpen -and -not $Script:ActionBusy) { $Script:AutoInstallPending = $false; Install-Update }

    if ($notify.Visible -and $now -gt $Script:NotifyHideAt) { $notify.Visible = $false }
    if (-not $Script:Cfg.Animations) {
        Update-ModeAndPalette
        if (-not $Script:Dragging) { Render }
    }
})

# Animations off: redraw the moment the shown second changes, not on a
# 1-second clock that drifts against it (which made seconds skip or lag).
$Script:LastSecShown = -1
$secTimer = New-Object System.Windows.Forms.Timer
$secTimer.Interval = 100
$secTimer.Add_Tick({
    if ($Script:Cfg.Animations -or $Script:Dragging) { return }
    $s = if ($Script:IsRunning) { [long][Math]::Floor((Get-LiveElapsed)) } else { [long][Math]::Floor(((Get-Date) - (Get-OffSince)).TotalSeconds) }
    if ($s -ne $Script:LastSecShown) { $Script:LastSecShown = $s; Render }
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
        if (-not (Test-Autostart) -and -not $Script:Cfg.OnboardingDone) { Install-Autostart | Out-Null }
        else { Repair-Autostart }
    }
    Register-Hotkey
    Request-Poll -Force
    $uiTimer.Start()
    $secTimer.Start()
    Update-AnimTimer
    # First run (or first run of a new version): the setup questions. They
    # open just after the widget appears, so every answer shows on it live.
    if (-not $Script:Cfg.OnboardingDone -or [string]::IsNullOrWhiteSpace((Get-ApiKey))) {
        $Script:SetupKick = New-Object System.Windows.Forms.Timer
        $Script:SetupKick.Interval = 400
        $Script:SetupKick.Add_Tick({
            $Script:SetupKick.Stop()
            $ok = Show-Hub "setup"
            if (-not $ok -and [string]::IsNullOrWhiteSpace((Get-ApiKey))) { $form.Close() }
        })
        $Script:SetupKick.Start()
    }
})

$form.Add_FormClosing({
    $uiTimer.Stop(); $secTimer.Stop(); $animTimer.Stop(); $Script:JobTimer.Stop()
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
    $Script:Cfg.Favorites = @([pscustomobject]@{ Id = "ev:1"; Name = "Q4 dashboard redesign" }, [pscustomobject]@{ Id = "ev:2"; Name = "Client sync call" }, [pscustomobject]@{ Id = "ev:3"; Name = "Break Time" })
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
    foreach ($shape in @("Wide", "Square", "Large")) {
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

    # auto-hide edge strip
    foreach ($mode in @("work", "stopped")) {
        $Script:IsRunning = ($mode -eq "work"); if ($Script:IsRunning) { Set-Run "ev:1" "Q4 dashboard redesign" 4935 6120 }
        Update-ModeAndPalette -Snap
        $pk = Build-Peek $Script:Pal $Script:Mode
        $canvas = New-Object System.Drawing.Bitmap(($pk.Width + 60), ($pk.Height + 40))
        $cg = [System.Drawing.Graphics]::FromImage($canvas); $cg.Clear((ToColor "#4E7A2C")); $cg.DrawImage($pk, 30, 20, $pk.Width, $pk.Height); $cg.Dispose()
        $canvas.Save((Join-Path $RenderPreview "peek-$mode.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        $canvas.Dispose(); $pk.Dispose()
    }
    $Script:IsRunning = $false; $Script:TaskId = ""

    # hub: walk through every setup page, then Settings and its sub-pages
    $Script:CapQueue = New-Object System.Collections.Queue
    foreach ($pg in $Script:SetupPages) { $Script:CapQueue.Enqueue("setup:$pg") }
    $ct = New-Object System.Windows.Forms.Timer
    $ct.Interval = 900
    $ct.Add_Tick({
        $H = $Script:Hub
        if (-not $H -or $H.Form.IsDisposed -or -not $H.Form.Visible) { return }
        if ($H.Slide) { Finish-Slide }
        $f = $H.Form
        $nm = "$($H.Mode)-$($H.PageName)$($Script:CapSuffix)"
        if ($Script:CapScrollNext) { $H.Current.AutoScrollPosition = New-Object System.Drawing.Point(0, 99999); $f.Refresh(); $nm += "-bottom" }
        $cb = New-Object System.Drawing.Bitmap($f.Width, $f.Height)
        $f.DrawToBitmap($cb, (New-Object System.Drawing.Rectangle(0, 0, $f.Width, $f.Height)))
        $cb.Save((Join-Path $RenderPreview "hub-$nm.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        $cb.Dispose()
        if ($Script:CapScrollNext) { $Script:CapScrollNext = $false; $H.Current.AutoScrollPosition = New-Object System.Drawing.Point(0, 0) }
        if ($Script:CapQueue.Count -eq 0) { $this.Stop(); $f.Close(); return }
        $next = [string]$Script:CapQueue.Dequeue()
        $parts = $next.Split(":")
        if ($parts[0] -ne $H.Mode) { $f.Close(); return }
        if ($parts[1] -eq "_scroll") { $Script:CapScrollNext = $true; return }
        Hub-Go $parts[1] 1 -NoAnim
    })
    [void]$Script:CapQueue.Dequeue()      # setup starts on its first page by itself
    $ct.Start()
    Show-Hub "setup" | Out-Null
    foreach ($pg in @("tour", "appearance", "behaviour", "focusbreaks", "workday", "favourites", "advanced", "account")) { $Script:CapQueue.Enqueue("settings:$pg") }
    $ct.Start()
    Show-Hub "settings" | Out-Null
    foreach ($th in @("Ocean", "Light", "Sunset")) {
        foreach ($k in $Script:Themes[$th].Keys) { $Script:Cfg[$k] = $Script:Themes[$th][$k] }
        Apply-Theme
        $Script:CapSuffix = "-" + $th.ToLower()
        $Script:CapQueue.Enqueue("settings:appearance")
        $ct.Start()
        Show-Hub "settings" | Out-Null
    }
    $Script:CapSuffix = ""
    $ct.Stop()
    # focus session look
    $Script:Cfg.Shape = "Large"; Apply-Theme; Set-Run "ev:1" "Q4 dashboard redesign" 4935 6120
    $Script:FocusPhase = "focus"; $Script:FocusLen = 1500; $Script:FocusEnd = (Get-Date).AddMinutes(17)
    Save-Preview "large-focus"
    $Script:FocusPhase = ""
    $Script:WeekByTask = @{ "ev:1" = @{ Name = "Q4 dashboard redesign"; Sec = 31000 }; "ev:2" = @{ Name = "Client sync call"; Sec = 14000 }
                            "ev:3" = @{ Name = "Break Time"; Sec = 9000 }; "ev:4" = @{ Name = "Email and planning"; Sec = 6000 }
                            "ev:5" = @{ Name = "Internal meeting"; Sec = 5400 }; "ev:6" = @{ Name = "Code review"; Sec = 3600 }; "ev:7" = @{ Name = "Hiring"; Sec = 1800 } }
    $Script:OpenGroup = "week"; Save-Preview "large-week"
    $Script:ListScroll = 2; Save-Preview "large-week-scrolled"; $Script:ListScroll = 0
    $Script:OpenGroup = ""; Save-Preview "large-groups-closed"
    $Script:OpenGroup = "today"
    $Script:Cfg.PrivacyMode = $true; Save-Preview "large-privacy"
    $Script:Cfg.Shape = "Wide"; Apply-Theme; Save-Preview "wide-privacy"; $Script:Cfg.Shape = "Large"; Apply-Theme
    $Script:Cfg.PrivacyMode = $false
    $Script:UpdateAvail = @{ Version = "8.1"; Notes = "" }; Save-Preview "large-update-pill"
    $Script:Cfg.Shape = "Wide"; Apply-Theme; Save-Preview "wide-update-pill"; $Script:UpdateAvail = $null
    $Script:Cfg.Shape = "Large"; Apply-Theme
    $Script:FocusPhase = ""; $Script:IsRunning = $false; $Script:TaskId = ""
    # clock in / out
    $Script:ClockUsed = $true
    $Script:ClockState = "out"; $Script:ClockInAt = (Get-Date).Date.AddHours(9.5); $Script:ClockOutAt = (Get-Date).Date.AddHours(18.6)
    foreach ($shape in @("Large", "Square", "Wide")) { $Script:Cfg.Shape = $shape; Apply-Theme; Save-Preview "$($shape.ToLower())-clockedout" }
    $Script:Cfg.Shape = "Large"; Apply-Theme
    $Script:Hover = "toggle"; Save-Preview "large-clockedout-hover"; $Script:Hover = ""
    $Script:ClockState = "in"; $Script:ClockOutAt = $null; $Script:ClockInAt = (Get-Date).AddMinutes(-4); $Script:StoppedSince = (Get-Date).AddHours(-15)
    Save-Preview "large-clockedin-stopped"
    Set-Run "ev:1" "Q4 dashboard redesign" 4935 6120; Save-Preview "large-clockedin-running"
    $Script:IsRunning = $false; $Script:TaskId = ""; $Script:ClockState = ""; $Script:ClockUsed = $false
    # add-missed-time picker
    $pt = New-Object System.Windows.Forms.Timer
    $pt.Interval = 4500
    $pt.Add_Tick({
        $this.Stop()
        $fm = $Script:PK.Form
        $cb = New-Object System.Drawing.Bitmap($fm.Width, $fm.Height)
        $fm.DrawToBitmap($cb, (New-Object System.Drawing.Rectangle(0, 0, $fm.Width, $fm.Height)))
        $cb.Save((Join-Path $RenderPreview "picker-addtime.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        $cb.Dispose(); $fm.Close()
    })
    $pt.Start(); Show-TaskPicker -AddTime
    Write-Host "Preview images written to $RenderPreview"
    exit
}


[System.Windows.Forms.Application]::Run($form)
