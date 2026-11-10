<#
.SYNOPSIS
    Guided Windows 10/11 laptop inspection: hardware inventory, automatic health checks,
    physical tests and a printed report.

.DESCRIPTION
    WinCheckup reads the device specification (model, serial number, processor, memory,
    storage health, battery wear, Windows edition and activation, TPM, BitLocker ...), runs
    automatic health checks, then walks the inspector through the physical tests: condition,
    screen, keyboard, touchpad, camera, speakers, headphone jack, microphone, Wi-Fi, Bluetooth,
    USB ports, video output, charging and sleep.

    Results are saved as they happen (text report, JSON and one CSV row per device). The final
    report is printed on one or two pages and saved as PDF.

    Uses only what ships with Windows 10/11 (Windows PowerShell 5.1, .NET Framework, Windows
    Forms). Nothing is installed and no settings are changed, except the speaker volume during
    the sound tests, which is put back at the end.

.PARAMETER Quick
    Specification and automatic checks only - no physical tests.

.PARAMETER Unattended
    Asks nothing and never waits for a key. Implies -Quick, does not ask for administrator
    rights and does not print. For scripted inventory runs.

.PARAMETER AssetTag
    Asset tag of the device (otherwise asked at the start).

.PARAMETER ItemNumber
    Inventory item number (otherwise asked at the start when AskItemNumber is on).

.PARAMETER Inspector
    Name printed on the report as the inspector.

.PARAMETER ReportFolder
    Folder for the reports. Default: "Reports" next to this script, or
    Documents\WinCheckup Reports when that folder cannot be written.

.PARAMETER ConfigPath
    Extra settings file (JSON) applied after config.json.

.PARAMETER NoPrint
    Save the reports but do not print.

.PARAMETER NoElevate
    Do not ask for administrator rights (battery wear, disk wear, TPM and BitLocker may then be unknown).

.EXAMPLE
    .\WinCheckup.cmd
    Full guided inspection. Double-click the .cmd file.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\WinCheckup.ps1 -Unattended -AssetTag PC-0042 -ReportFolder D:\Inventory
    Silent inventory. Exit code 0 = saved, 1 = error, 2 = the report could not be saved.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Quick,
    [switch]$Unattended,
    [string]$AssetTag,
    [string]$ItemNumber,
    [string]$Inspector,
    [string]$ReportFolder,
    [string]$ConfigPath,
    [switch]$NoPrint,
    [switch]$NoElevate
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$script:ToolName = 'WinCheckup'
$script:ToolVersion = '1.0.0'
$script:ReportWidth = 92
$script:MicSoundThreshold = 6          # peak level (% of full scale) that counts as "sound picked up"
$script:UnrecordedTag = 'TAG-UNRECORDED'
$script:UnrecordedItem = 'ITEM-UNRECORDED'

# ------------------------------------------------------------------ settings
# Every key can be changed in config.json next to this script (see README). Keys starting with "_" are comments.
$script:DefaultConfig = [ordered]@{
    InspectorName           = ''        # empty = asked at the start (the last name used is offered)
    OrganizationName        = ''        # printed under the report title
    SiteName                = ''
    AssetTagExample         = 'PC-0001' # shown in the asset tag question
    AskItemNumber           = $true
    AskAssistant            = $true
    ReportFolder            = ''        # empty = "Reports" next to the script, or Documents if that is read-only
    AutoPrint               = $true
    PreferredPrinter        = ''        # part of a printer name to always use, e.g. "LaserJet"
    PrintCopies             = 1
    SavePdfCopy             = $true     # also save the printed page as PDF ("Microsoft Print to PDF")
    SaveBatteryReport       = $true     # also save Windows' own battery report (powercfg) next to the report
    BatteryWarnBelow        = 70        # battery health, % of original design capacity
    BatteryFailBelow        = 50
    SsdWearWarnAbove        = 80        # % of rated SSD life used
    SpeakerVolumePercent    = 70
    HeadphoneVolumePercent  = 30
    PowerWaitSeconds        = 25        # charging test: time allowed to unplug / plug in
    WifiWaitSeconds         = 90
    ScreenTestSeconds       = 120       # the colour window closes itself after this
    InputTestMinutes        = 10        # the keyboard window closes itself after this
    InventoryTimeoutSeconds = 150
    CriticalTests           = @('Screen / display', 'Keyboard', 'Storage health', 'Charging')  # a FAIL here = NOT FUNCTIONAL
    SkipTests               = @()       # names of physical tests to leave out, e.g. ["Fingerprint reader"]
}

$script:StatusColor = @{ 'PASS' = 'Green'; 'FAIL' = 'Red'; 'WARN' = 'Yellow'; 'SKIP' = 'DarkGray'; 'N/A' = 'DarkGray' }
$script:RootDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:FullLanguage = ($ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage')
$script:ExitCode = 0

function Test-IsAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}
$script:IsAdmin = Test-IsAdmin

function Copy-DefaultConfig {
    $copy = [ordered]@{}
    foreach ($key in $script:DefaultConfig.Keys) { $copy[$key] = $script:DefaultConfig[$key] }
    return $copy
}

function Initialize-State {
    # Everything one inspection run remembers. Called once per run (and by the tests).
    $script:Inspection = @{
        AssetTag = $script:UnrecordedTag; ItemNumber = $script:UnrecordedItem
        Inspector = ''; Assistant = ''; Remarks = ''; Mode = 'Full'
    }
    $script:Results = New-Object System.Collections.ArrayList
    $script:Detail = New-Object System.Text.StringBuilder
    $script:ToolProblems = New-Object System.Collections.ArrayList
    $script:Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:Started = Get-Date
    $script:ReportDir = $null
    $script:ReportPath = $null
    $script:Spec = @()
    $script:Facts = $null
    $script:TestIndex = @{}
    $script:UiReady = $false
    $script:WpfKeyboard = $false
    $script:InputResult = $null
    $script:AudioOriginals = @{}
}
$script:Config = Copy-DefaultConfig
Initialize-State

# ------------------------------------------------------------------ settings file
function Merge-Config {
    # Copies the known keys of a parsed JSON object onto $Target. Wrong types keep the default. Returns warnings.
    param([System.Collections.IDictionary]$Target, $Source, [string]$Origin)
    $warnings = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Source) { return , $warnings.ToArray() }
    foreach ($prop in $Source.PSObject.Properties) {
        $key = [string]$prop.Name
        if ($key.StartsWith('_')) { continue }
        $name = @($Target.Keys | Where-Object { $_ -eq $key }) | Select-Object -First 1
        if (-not $name) { $warnings.Add(('{0}: unknown setting "{1}" ignored' -f $Origin, $key)); continue }
        $default = $Target[$name]
        $value = $prop.Value
        try {
            if ($default -is [bool]) {
                if ($value -isnot [bool]) { throw 'needs true or false' }
            } elseif ($default -is [int]) {
                if (-not ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal])) { throw 'needs a number' }
                if ($value -lt 0) { throw 'needs a positive number' }
                $value = [int]$value
            } elseif ($default -is [array]) {
                $value = @(@($value) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
            } else {
                if ($null -eq $value) { $value = '' }
                if ($value -isnot [string]) { throw 'needs text in quotes' }
            }
            $Target[$name] = $value
        } catch {
            $warnings.Add(('{0}: "{1}" {2} - default kept' -f $Origin, $name, $_.Exception.Message))
        }
    }
    return , $warnings.ToArray()
}

function Import-ToolConfig {
    # Defaults <- config.json next to the script <- %APPDATA%\WinCheckup\config.json <- -ConfigPath.
    param([string]$ScriptRoot, [string]$ExplicitPath)
    $config = Copy-DefaultConfig
    $warnings = New-Object System.Collections.Generic.List[string]
    $sources = New-Object System.Collections.Generic.List[string]
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($ScriptRoot) { $candidates.Add((Join-Path $ScriptRoot 'config.json')) }
    if ($env:APPDATA) { $candidates.Add((Join-Path (Join-Path $env:APPDATA $script:ToolName) 'config.json')) }
    if ($ExplicitPath) {
        if (Test-Path -LiteralPath $ExplicitPath -PathType Leaf) { $candidates.Add($ExplicitPath) }
        else { $warnings.Add(('settings file not found: {0}' -f $ExplicitPath)) }
    }
    foreach ($path in $candidates) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            $data = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $warnings.Add(('{0} could not be read ({1}) - defaults used' -f $path, (Get-Clean $_.Exception.Message)))
            continue
        }
        foreach ($w in (Merge-Config $config $data $path)) { $warnings.Add($w) }
        $sources.Add($path)
    }
    return [pscustomobject]@{ Config = $config; Warnings = $warnings.ToArray(); Sources = $sources.ToArray() }
}

# ------------------------------------------------------------------ console helpers
function Write-Heading {
    param([string]$Title)
    Write-Host ''
    Write-Host (' {0} ' -f $Title) -ForegroundColor Black -BackgroundColor Cyan
}

function Clear-KeyBuffer {
    # Drops keys pressed while a test window was open, so they cannot answer the next question by accident.
    try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch { }
    try { $Host.UI.RawUI.FlushInputBuffer() } catch { }
}

function ConvertFrom-KeyPress {
    # Letters come from the physical key, not the typed character, so the answers also work while a
    # Pashto, Dari, Arabic or Cyrillic keyboard layout is active.
    param([System.ConsoleKeyInfo]$Key)
    if ($Key.Key -eq [ConsoleKey]::Enter) { return 'ENTER' }
    if ($Key.Key -ge [ConsoleKey]::A -and $Key.Key -le [ConsoleKey]::Z) { return [string]$Key.Key }
    return ([string]$Key.KeyChar).ToUpperInvariant()
}

function ConvertTo-LatinDigit {
    # Persian and Arabic-Indic digits (typed on a Pashto, Dari or Arabic layout) become 0-9.
    param([string]$Text)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in ([string]$Text).ToCharArray()) {
        $code = [int]$ch
        if ($code -ge 0x06F0 -and $code -le 0x06F9) { [void]$sb.Append([char](48 + $code - 0x06F0)) }
        elseif ($code -ge 0x0660 -and $code -le 0x0669) { [void]$sb.Append([char](48 + $code - 0x0660)) }
        else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

function Read-Choice {
    # Waits for one key from $Allowed ('ENTER' stands for the Enter key). Falls back to Read-Host without a console.
    param([string]$Prompt, [string[]]$Allowed)
    Clear-KeyBuffer
    Write-Host $Prompt -ForegroundColor White -NoNewline
    $emptyAnswers = 0
    while ($true) {
        try {
            $choice = ConvertFrom-KeyPress ([Console]::ReadKey($true))
        } catch {
            $typed = ([string](Read-Host)).Trim().ToUpperInvariant()
            $choice = if ($typed) { $typed.Substring(0, 1) } else { 'ENTER' }
            if (-not $typed) { $emptyAnswers++ } else { $emptyAnswers = 0 }
            if ($emptyAnswers -gt 3 -and $Allowed -notcontains 'ENTER') { throw 'No keyboard input is available.' }
        }
        if ($Allowed -contains $choice) {
            Write-Host (' ' + $choice)
            return $choice
        }
    }
}

function Read-Text {
    param([string]$Prompt, [string]$Default = '')
    Clear-KeyBuffer
    $value = ([string](Read-Host $Prompt)).Trim()
    if (-not $value) { return $Default }
    return $value
}

function Add-ToolProblem {
    # Records something the tool itself could not do. Listed at the end of the saved report.
    param([string]$Context, $Problem)
    $message = if ($Problem -is [System.Management.Automation.ErrorRecord]) { $Problem.Exception.Message } else { [string]$Problem }
    [void]$script:ToolProblems.Add(('{0}: {1}' -f $Context, (Get-Clean $message)))
}

function Set-Result {
    # Adds or updates one line of the results table and echoes it in colour.
    param(
        [string]$Name,
        [ValidateSet('PASS', 'FAIL', 'WARN', 'SKIP', 'N/A')][string]$Status,
        [string]$Note = '',
        [ValidateSet('Auto', 'Manual')][string]$Kind = 'Manual',
        [switch]$Quiet
    )
    $existing = $script:Results | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($existing) {
        $existing.Status = $Status
        $existing.Note = $Note
    } else {
        [void]$script:Results.Add([pscustomobject]@{ No = $script:Results.Count + 1; Name = $Name; Kind = $Kind; Status = $Status; Note = $Note })
    }
    if ($Quiet) { return }
    Write-Host ('  [{0,-4}] {1}' -f $Status, $Name) -ForegroundColor $script:StatusColor[$Status] -NoNewline
    if ($Note) { Write-Host (' - ' + $Note) -ForegroundColor DarkGray } else { Write-Host '' }
}

# ------------------------------------------------------------------ text helpers
function Get-Clean {
    param($Value)
    return ((([string]$Value) -replace '\s+', ' ').Trim())
}

function Test-Placeholder {
    # True for empty values and the filler text manufacturers leave in firmware fields.
    param([string]$Value)
    $v = Get-Clean $Value
    return (-not $v) -or ($v -match '^(?i)(to be filled.*|default string|system serial number|chassis serial number|none|n/a|unknown|not specified|not applicable|oem|0+|1234567890)$')
}

function Get-SafeFileToken {
    param([string]$Value, [string]$Fallback, [int]$MaxLength = 42)
    $token = ([string]$Value).Trim()
    $token = $token -replace '[^A-Za-z0-9._-]', '-'
    $token = $token -replace '-{2,}', '-'
    $token = $token.Trim([char[]]@('.', '-', '_'))
    if (-not $token) { return $Fallback }
    if ($token.Length -gt $MaxLength) { $token = $token.Substring(0, $MaxLength) }
    return $token
}

function Format-DiskSize {
    # Decimal units, as printed on the box (a "512 GB" SSD).
    param([double]$Bytes)
    if ($Bytes -le 0) { return 'Unknown size' }
    if ($Bytes -ge 1e12) { return ('{0:0.#} TB' -f ($Bytes / 1e12)) }
    return ('{0:0} GB' -f ($Bytes / 1e9))
}

function Format-GiB {
    param([double]$Bytes)
    if ($Bytes -le 0) { return 'Unknown' }
    return ('{0:N1} GB' -f ($Bytes / 1GB))
}

function Split-Wrap {
    # Word-wraps $Text to $Width characters; always returns at least one (possibly empty) line.
    param([string]$Text, [int]$Width)
    $lines = New-Object System.Collections.Generic.List[string]
    $current = ''
    foreach ($word in ([string]$Text -split ' ')) {
        while ($word.Length -gt $Width) {
            if ($current) { $lines.Add($current); $current = '' }
            $lines.Add($word.Substring(0, $Width))
            $word = $word.Substring($Width)
        }
        if (-not $current) { $current = $word }
        elseif (($current.Length + 1 + $word.Length) -le $Width) { $current = $current + ' ' + $word }
        else { $lines.Add($current); $current = $word }
    }
    $lines.Add($current)
    return , $lines.ToArray()
}

function Add-Detail { param([string]$Text = '') [void]$script:Detail.AppendLine($Text) }
function Add-DetailSection {
    param([string]$Title)
    Add-Detail ''
    Add-Detail ('-' * $script:ReportWidth)
    Add-Detail $Title
    Add-Detail ('-' * $script:ReportWidth)
}
function Add-DetailValue {
    param([string]$Label, $Value)
    $text = Get-Clean (@($Value) -join ', ')
    if (-not $text) { $text = 'Not reported' }
    Add-Detail ('{0,-28}: {1}' -f $Label, $text)
}

# ------------------------------------------------------------------ report folder
function Test-FolderWritable {
    param([string]$Path)
    if (-not $Path) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null }
        $probe = Join-Path $Path ('.write-test-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($probe, 'ok')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch { return $false }
}

function Test-UnderProgramFiles {
    param([string]$Path)
    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432)) {
        if ($pf -and $Path -and $Path.StartsWith($pf.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Resolve-ReportFolder {
    # First writable choice: the configured folder, "Reports" next to the script (USB stick; not when installed
    # under Program Files), Documents\WinCheckup Reports, then the Desktop.
    param([string]$Configured, [string]$ScriptRoot)
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Configured) {
        $expanded = [Environment]::ExpandEnvironmentVariables($Configured)
        if (-not [System.IO.Path]::IsPathRooted($expanded) -and $ScriptRoot) { $expanded = Join-Path $ScriptRoot $expanded }   # relative to the tool
        $candidates.Add($expanded)
    }
    if ($ScriptRoot -and -not (Test-UnderProgramFiles $ScriptRoot)) { $candidates.Add((Join-Path $ScriptRoot 'Reports')) }
    foreach ($special in @('MyDocuments', 'Desktop')) {
        $base = [Environment]::GetFolderPath($special)
        if ($base) { $candidates.Add((Join-Path $base ($script:ToolName + ' Reports'))) }
    }
    foreach ($dir in $candidates) { if (Test-FolderWritable $dir) { return $dir } }
    return $null
}

# ------------------------------------------------------------------ native helpers (C#, compiled in the background)
# Speaker volume through the Windows Core Audio API (so it can be put back afterwards) and a microphone level
# meter through winmm. C# 5 syntax only: Windows PowerShell 5.1 compiles it with the .NET Framework compiler.
$script:NativeSource = @'
using System;
using System.Runtime.InteropServices;

namespace WinCheckup
{
    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume
    {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int GetChannelCount(out int count);
        [PreserveSig] int SetMasterVolumeLevel(float levelDb, ref Guid context);
        [PreserveSig] int SetMasterVolumeLevelScalar(float level, ref Guid context);
        [PreserveSig] int GetMasterVolumeLevel(out float levelDb);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
        [PreserveSig] int SetChannelVolumeLevel(uint channel, float levelDb, ref Guid context);
        [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float level, ref Guid context);
        [PreserveSig] int GetChannelVolumeLevel(uint channel, out float levelDb);
        [PreserveSig] int GetChannelVolumeLevelScalar(uint channel, out float level);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid context);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
    }

    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, out IAudioEndpointVolume endpoint);
        [PreserveSig] int OpenPropertyStore(int access, out IntPtr properties);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    }

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorComObject { }

    // Master volume and mute of an output device. An empty id means the default output device.
    public static class SpeakerVolume
    {
        const int RenderFlow = 0;       // eRender
        const int MultimediaRole = 1;   // eMultimedia
        const int AllContexts = 23;     // CLSCTX_ALL

        static IMMDevice Device(string id)
        {
            IMMDeviceEnumerator enumerator = new MMDeviceEnumeratorComObject() as IMMDeviceEnumerator;
            if (enumerator == null) throw new InvalidOperationException("Windows Core Audio is not available.");
            IMMDevice device = null;
            if (string.IsNullOrEmpty(id)) Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(RenderFlow, MultimediaRole, out device));
            else Marshal.ThrowExceptionForHR(enumerator.GetDevice(id, out device));
            return device;
        }

        static IAudioEndpointVolume Endpoint(string id)
        {
            Guid iid = typeof(IAudioEndpointVolume).GUID;
            IAudioEndpointVolume volume = null;
            Marshal.ThrowExceptionForHR(Device(id).Activate(ref iid, AllContexts, IntPtr.Zero, out volume));
            return volume;
        }

        public static string DefaultDeviceId()
        {
            string id = null;
            Marshal.ThrowExceptionForHR(Device(null).GetId(out id));
            return id;
        }

        public static float GetLevel(string id)
        {
            float level = 0;
            Marshal.ThrowExceptionForHR(Endpoint(id).GetMasterVolumeLevelScalar(out level));
            return level;
        }

        public static void SetLevel(string id, float level)
        {
            Guid context = Guid.Empty;
            Marshal.ThrowExceptionForHR(Endpoint(id).SetMasterVolumeLevelScalar(Math.Max(0f, Math.Min(1f, level)), ref context));
        }

        public static bool GetMute(string id)
        {
            bool muted = false;
            Marshal.ThrowExceptionForHR(Endpoint(id).GetMute(out muted));
            return muted;
        }

        public static void SetMute(string id, bool muted)
        {
            Guid context = Guid.Empty;
            Marshal.ThrowExceptionForHR(Endpoint(id).SetMute(muted, ref context));
        }
    }

    // Records from the default microphone into a ring of buffers and reports the loudest sample.
    public sealed class MicMeter : IDisposable
    {
        [StructLayout(LayoutKind.Sequential)]
        struct WaveFormat
        {
            public ushort FormatTag;
            public ushort Channels;
            public uint SamplesPerSec;
            public uint AvgBytesPerSec;
            public ushort BlockAlign;
            public ushort BitsPerSample;
            public ushort ExtraSize;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct WaveHeader
        {
            public IntPtr Data;
            public uint BufferLength;
            public uint BytesRecorded;
            public IntPtr User;
            public uint Flags;
            public uint Loops;
            public IntPtr Next;
            public IntPtr Reserved;
        }

        [DllImport("winmm.dll")] static extern int waveInGetNumDevs();
        [DllImport("winmm.dll")] static extern int waveInOpen(out IntPtr handle, uint deviceId, ref WaveFormat format, IntPtr callback, IntPtr instance, uint flags);
        [DllImport("winmm.dll")] static extern int waveInPrepareHeader(IntPtr handle, IntPtr header, uint size);
        [DllImport("winmm.dll")] static extern int waveInUnprepareHeader(IntPtr handle, IntPtr header, uint size);
        [DllImport("winmm.dll")] static extern int waveInAddBuffer(IntPtr handle, IntPtr header, uint size);
        [DllImport("winmm.dll")] static extern int waveInStart(IntPtr handle);
        [DllImport("winmm.dll")] static extern int waveInReset(IntPtr handle);
        [DllImport("winmm.dll")] static extern int waveInClose(IntPtr handle);

        const uint WaveMapper = 0xFFFFFFFF;
        const int HeaderDone = 1;
        const int BufferCount = 4;
        const int BufferBytes = 4410 * 2;   // 100 ms of 44.1 kHz, 16-bit mono

        static readonly uint HeaderSize = (uint)Marshal.SizeOf(typeof(WaveHeader));
        static readonly int FlagsOffset = Marshal.OffsetOf(typeof(WaveHeader), "Flags").ToInt32();
        static readonly int RecordedOffset = Marshal.OffsetOf(typeof(WaveHeader), "BytesRecorded").ToInt32();

        IntPtr handle = IntPtr.Zero;
        readonly IntPtr[] headers = new IntPtr[BufferCount];
        readonly IntPtr[] buffers = new IntPtr[BufferCount];
        readonly bool[] prepared = new bool[BufferCount];

        public static int DeviceCount { get { return waveInGetNumDevs(); } }

        public MicMeter()
        {
            WaveFormat format = new WaveFormat();
            format.FormatTag = 1;
            format.Channels = 1;
            format.SamplesPerSec = 44100;
            format.BitsPerSample = 16;
            format.BlockAlign = 2;
            format.AvgBytesPerSec = 88200;
            format.ExtraSize = 0;
            Check(waveInOpen(out handle, WaveMapper, ref format, IntPtr.Zero, IntPtr.Zero, 0), "open the microphone");
            try
            {
                for (int i = 0; i < BufferCount; i++)
                {
                    buffers[i] = Marshal.AllocHGlobal(BufferBytes);
                    headers[i] = Marshal.AllocHGlobal((int)HeaderSize);
                    WaveHeader header = new WaveHeader();
                    header.Data = buffers[i];
                    header.BufferLength = BufferBytes;
                    Marshal.StructureToPtr(header, headers[i], false);
                    Check(waveInPrepareHeader(handle, headers[i], HeaderSize), "prepare a recording buffer");
                    prepared[i] = true;
                    Check(waveInAddBuffer(handle, headers[i], HeaderSize), "queue a recording buffer");
                }
                Check(waveInStart(handle), "start recording");
            }
            catch
            {
                Dispose();
                throw;
            }
        }

        // Loudest sample (0-100 % of full scale) in the buffers filled since the last call; those buffers are queued again.
        public int ReadPeakPercent()
        {
            if (handle == IntPtr.Zero) return 0;
            int peak = 0;
            for (int i = 0; i < BufferCount; i++)
            {
                int flags = Marshal.ReadInt32(headers[i], FlagsOffset);
                if ((flags & HeaderDone) == 0) continue;
                int recorded = Marshal.ReadInt32(headers[i], RecordedOffset);
                for (int offset = 0; offset + 1 < recorded; offset += 2)
                {
                    int sample = Marshal.ReadInt16(buffers[i], offset);
                    if (sample < 0) sample = -sample;
                    if (sample > peak) peak = sample;
                }
                Marshal.WriteInt32(headers[i], FlagsOffset, flags & ~HeaderDone);
                waveInAddBuffer(handle, headers[i], HeaderSize);
            }
            return Math.Min(100, peak * 100 / 32767);
        }

        public void Dispose()
        {
            if (handle != IntPtr.Zero)
            {
                waveInReset(handle);
                for (int i = 0; i < BufferCount; i++)
                {
                    if (prepared[i]) { waveInUnprepareHeader(handle, headers[i], HeaderSize); prepared[i] = false; }
                }
                waveInClose(handle);
                handle = IntPtr.Zero;
            }
            for (int i = 0; i < BufferCount; i++)
            {
                if (headers[i] != IntPtr.Zero) { Marshal.FreeHGlobal(headers[i]); headers[i] = IntPtr.Zero; }
                if (buffers[i] != IntPtr.Zero) { Marshal.FreeHGlobal(buffers[i]); buffers[i] = IntPtr.Zero; }
            }
        }

        static void Check(int result, string action)
        {
            if (result != 0) throw new InvalidOperationException("Could not " + action + " (winmm error " + result + ").");
        }
    }
}
'@

# ------------------------------------------------------------------ hardware inventory
# Runs in a background runspace while the inspector types the asset tag. It writes into a synchronized hashtable,
# so whatever was read before a timeout is still used.
$script:InventoryScript = {
    param([bool]$IsAdmin, [hashtable]$inv, [string]$NativeSource)
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    function Get-Cim {
        param([string]$Class, [string]$Namespace = 'root/cimv2', [string]$Filter, [string[]]$Property)
        try {
            $query = @{ ClassName = $Class; Namespace = $Namespace; ErrorAction = 'Stop'; OperationTimeoutSec = 20 }
            if ($Filter) { $query.Filter = $Filter }
            if ($Property) { $query.Property = $Property }
            return @(Get-CimInstance @query)
        } catch {
            [void]$inv.Errors.Add(('{0}: {1}' -f $Class, $_.Exception.Message))
            return @()
        }
    }

    $inv.Step = 'system'
    $inv.ComputerSystem = Get-Cim Win32_ComputerSystem | Select-Object -First 1
    $inv.OS = Get-Cim Win32_OperatingSystem | Select-Object -First 1
    $inv.Bios = Get-Cim Win32_BIOS | Select-Object -First 1
    $inv.Product = Get-Cim Win32_ComputerSystemProduct | Select-Object -First 1
    $inv.Enclosure = Get-Cim Win32_SystemEnclosure | Select-Object -First 1
    $inv.Board = Get-Cim Win32_BaseBoard | Select-Object -First 1
    $inv.Step = 'processor and memory'
    $inv.Cpu = @(Get-Cim Win32_Processor)
    $inv.Ram = @(Get-Cim Win32_PhysicalMemory)
    $inv.Step = 'graphics and storage'
    $inv.Gpu = @(Get-Cim Win32_VideoController)
    $inv.Disks = @(Get-Cim Win32_DiskDrive)
    $inv.Volumes = @(Get-Cim Win32_LogicalDisk -Filter 'DriveType=3')
    $inv.PhysicalDisks = @(Get-Cim MSFT_PhysicalDisk -Namespace 'root/Microsoft/Windows/Storage')
    $inv.Reliability = @{}
    foreach ($pd in $inv.PhysicalDisks) {
        try {
            $counter = Get-CimAssociatedInstance -InputObject $pd -ResultClassName MSFT_StorageReliabilityCounter -OperationTimeoutSec 15 -ErrorAction Stop | Select-Object -First 1
            if ($counter) { $inv.Reliability[[string]$pd.DeviceId] = $counter }
        } catch { [void]$inv.Errors.Add(('Disk wear counters ({0}): {1}' -f $pd.FriendlyName, $_.Exception.Message)) }
    }
    $inv.Step = 'devices'
    $inv.Audio = @(Get-Cim Win32_SoundDevice)
    $inv.Nics = @(Get-Cim Win32_NetworkAdapter -Filter 'PhysicalAdapter=TRUE')
    $inv.Monitors = @(Get-Cim WmiMonitorBasicDisplayParams -Namespace 'root/wmi')
    $inv.Pnp = @(Get-Cim Win32_PnPEntity -Property 'Name', 'PNPClass', 'Manufacturer', 'Status', 'ConfigManagerErrorCode', 'PNPDeviceID')

    $inv.Step = 'battery'
    $inv.Battery = @(Get-Cim Win32_Battery)
    $inv.BatteryStatic = @(); $inv.BatteryFull = @(); $inv.BatteryCycle = @()
    if ($inv.Battery.Count -gt 0) {
        $inv.BatteryStatic = @(Get-Cim BatteryStaticData -Namespace 'root/wmi')
        $inv.BatteryFull = @(Get-Cim BatteryFullChargedCapacity -Namespace 'root/wmi')
        $inv.BatteryCycle = @(Get-Cim BatteryCycleCount -Namespace 'root/wmi')
    }

    $inv.Step = 'Windows'
    $inv.DisplayVersion = ''; $inv.Ubr = $null
    try {
        $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $inv.DisplayVersion = [string]$cv.DisplayVersion
        if (-not $inv.DisplayVersion) { $inv.DisplayVersion = [string]$cv.ReleaseId }
        $inv.Ubr = $cv.UBR
    } catch { [void]$inv.Errors.Add('Windows version: ' + $_.Exception.Message) }
    # Application ID of Windows itself.
    $inv.License = @(Get-Cim SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -Property 'Name', 'LicenseStatus')

    $inv.Step = 'security'
    $inv.Tpm = $null; $inv.BitLocker = $null
    if ($IsAdmin) {
        $inv.Tpm = Get-Cim Win32_Tpm -Namespace 'root/cimv2/Security/MicrosoftTpm' | Select-Object -First 1
        $inv.BitLocker = Get-Cim Win32_EncryptableVolume -Namespace 'root/cimv2/Security/MicrosoftVolumeEncryption' -Filter ("DriveLetter='{0}'" -f $env:SystemDrive) | Select-Object -First 1
    }
    try { $inv.SecureBoot = Confirm-SecureBootUEFI -ErrorAction Stop } catch { $inv.SecureBoot = $null }

    # WHEA = hardware errors logged by Windows (CPU, memory, PCIe). "No events" is a pass, not a read failure.
    $inv.Step = 'event log'
    try {
        $inv.Whea = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 20 -ErrorAction Stop)
        $inv.WheaReadable = $true
    } catch {
        $inv.Whea = @()
        $inv.WheaReadable = ([string]$_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*')
    }

    # Load the window libraries and compile the sound helpers now, so the tests open instantly later.
    $inv.Step = 'test tools'
    try { Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction Stop } catch { [void]$inv.Errors.Add('Windows Forms: ' + $_.Exception.Message) }
    try { Add-Type -AssemblyName PresentationCore -ErrorAction Stop } catch { [void]$inv.Errors.Add('WPF keyboard: ' + $_.Exception.Message) }
    if ($NativeSource -and -not ('WinCheckup.SpeakerVolume' -as [type])) {
        try { Add-Type -TypeDefinition $NativeSource -Language CSharp -ErrorAction Stop }
        catch { [void]$inv.Errors.Add('Sound helpers (volume / microphone meter): ' + $_.Exception.Message) }
    }
    $inv.Step = 'done'
    $inv.Done = $true
}

function New-InventoryStore {
    $store = [hashtable]::Synchronized(@{})
    $store.Errors = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $store.Step = 'starting'
    $store.Done = $false
    return $store
}

function Start-Inventory {
    $store = New-InventoryStore
    if ($script:FullLanguage) {
        try {
            $shell = [powershell]::Create()
            [void]$shell.AddScript($script:InventoryScript.ToString()).AddArgument($script:IsAdmin).AddArgument($store).AddArgument($script:NativeSource)
            return [pscustomobject]@{ Shell = $shell; Handle = $shell.BeginInvoke(); Data = $store }
        } catch { [void]$store.Errors.Add('Background reading: ' + $_.Exception.Message) }
    }
    return [pscustomobject]@{ Shell = $null; Handle = $null; Data = $store }
}

function Wait-Inventory {
    param($Job, [int]$TimeoutSeconds = 150, [switch]$Animate)
    if ($Job.Shell) {
        $deadline = (Get-Date).AddSeconds([Math]::Max(30, $TimeoutSeconds))
        $spinner = '|/-\'
        $i = 0
        while (-not $Job.Handle.IsCompleted -and (Get-Date) -lt $deadline) {
            if ($Animate) { Write-Host ("`r  Reading hardware information ({0})... {1}      " -f $Job.Data.Step, $spinner[$i % 4]) -NoNewline -ForegroundColor DarkCyan }
            $i++
            Start-Sleep -Milliseconds 150
        }
        if ($Animate) { Write-Host ("`r" + (' ' * 78) + "`r") -NoNewline }
        if ($Job.Handle.IsCompleted) {
            try { [void]$Job.Shell.EndInvoke($Job.Handle) } catch { [void]$Job.Data.Errors.Add('Hardware reading: ' + $_.Exception.Message) }
            $Job.Shell.Dispose()
        } else {
            [void]$Job.Data.Errors.Add(('Hardware reading stopped after {0} s while reading {1}; later items are missing.' -f $TimeoutSeconds, $Job.Data.Step))
            Write-Host ('  Reading {0} took too long - continuing without it.' -f $Job.Data.Step) -ForegroundColor Yellow
            try { [void]$Job.Shell.BeginStop($null, $null) } catch { }
        }
        if ($Job.Data.ContainsKey('ComputerSystem')) { return $Job.Data }
    }
    Write-Host '  Reading hardware information...' -ForegroundColor DarkCyan
    $store = New-InventoryStore
    foreach ($e in $Job.Data.Errors) { [void]$store.Errors.Add($e) }
    try { & $script:InventoryScript $script:IsAdmin $store $script:NativeSource }
    catch { [void]$store.Errors.Add('Hardware reading: ' + $_.Exception.Message) }
    return $store
}

# ------------------------------------------------------------------ specifications
$script:MemoryTypes = @{ 18 = 'DDR'; 19 = 'DDR2'; 20 = 'DDR2'; 24 = 'DDR3'; 26 = 'DDR4'; 27 = 'LPDDR'; 28 = 'LPDDR2'; 29 = 'LPDDR3'; 30 = 'LPDDR4'; 34 = 'DDR5'; 35 = 'LPDDR5' }

function Get-ChassisName {
    param($Codes, [bool]$HasBattery)
    foreach ($code in @($Codes)) {
        if ($null -eq $code) { continue }
        $c = [int]$code
        if (@(8, 9, 10, 14) -contains $c) { return 'Laptop' }
        if (@(30, 31, 32) -contains $c) { return 'Tablet / 2-in-1' }
        if ($c -eq 13) { return 'All-in-one' }
        if (@(3, 4, 5, 6, 7, 15, 16, 35, 36) -contains $c) { return 'Desktop' }
    }
    if ($HasBattery) { return 'Laptop' }
    return 'Computer'
}

function Get-DiskInfo {
    # Internal drives only: the USB stick running this tool (bus type 7) is left out.
    param($Inv)
    $reliability = if ($Inv.Reliability) { $Inv.Reliability } else { @{} }
    $items = @()
    foreach ($d in @($Inv.PhysicalDisks | Where-Object { $null -ne $_ -and [int]$_.BusType -ne 7 })) {
        $kind = switch ([int]$d.MediaType) { 3 { 'HDD' } 4 { 'SSD' } 5 { 'SSD' } default { 'drive' } }
        $bus = switch ([int]$d.BusType) { 17 { 'NVMe ' } 11 { 'SATA ' } 3 { 'ATA ' } 13 { 'eMMC ' } 12 { 'SD ' } default { '' } }
        $health = switch ([int]$d.HealthStatus) { 0 { 'Healthy' } 1 { 'Warning' } 2 { 'Unhealthy' } default { 'Unknown' } }
        $counter = $reliability[[string]$d.DeviceId]
        $wear = $null; $hours = $null
        if ($counter) {
            if ($counter.Wear -gt 0) { $wear = [int]$counter.Wear }
            if ($counter.PowerOnHours -gt 0) { $hours = [int64]$counter.PowerOnHours }
        }
        $text = '{0} {1}{2} ({3}) - {4}' -f (Format-DiskSize ([double]$d.Size)), $bus, $kind, (Get-Clean $d.FriendlyName), $health
        if ($null -ne $wear) { $text += (', {0}% life used' -f $wear) }
        $items += [pscustomobject]@{ Text = $text; Health = $health; Wear = $wear; Hours = $hours; Name = (Get-Clean $d.FriendlyName) }
    }
    if ($items.Count -eq 0) {
        foreach ($d in @($Inv.Disks | Where-Object { $null -ne $_ -and $_.InterfaceType -ne 'USB' -and $_.MediaType -notmatch '(?i)removable|external' })) {
            $health = if ($d.Status -eq 'OK') { 'Healthy' } elseif ($d.Status) { [string]$d.Status } else { 'Unknown' }
            $text = '{0} {1} ({2}) - {3}' -f (Format-DiskSize ([double]$d.Size)), $d.InterfaceType, (Get-Clean $d.Model), $health
            $items += [pscustomobject]@{ Text = $text; Health = $health; Wear = $null; Hours = $null; Name = (Get-Clean $d.Model) }
        }
    }
    return , $items
}

function Get-DeviceSpec {
    # Returns the printable specification list (Spec) and the facts the checks and tests need (Facts).
    param($Inv)
    $cs = $Inv.ComputerSystem; $os = $Inv.OS; $bios = $Inv.Bios; $prod = $Inv.Product
    $spec = New-Object System.Collections.ArrayList
    $addSpec = { param([string]$Label, [string]$Value) if (-not $Value) { $Value = 'Not reported' }; [void]$spec.Add([pscustomobject]@{ Label = $Label; Value = $Value }) }

    $manufacturer = Get-Clean $cs.Manufacturer
    $model = Get-Clean $cs.Model
    if ($manufacturer -match '(?i)lenovo' -and (Get-Clean $prod.Version)) { $model = '{0} ({1})' -f (Get-Clean $prod.Version), $model }

    $serial = Get-Clean $bios.SerialNumber
    if (Test-Placeholder $serial) { $serial = Get-Clean $Inv.Enclosure.SerialNumber }
    if (Test-Placeholder $serial) { $serial = Get-Clean $prod.IdentifyingNumber }
    $serialOk = -not (Test-Placeholder $serial)

    $hasBattery = @($Inv.Battery | Where-Object { $null -ne $_ }).Count -gt 0
    & $addSpec 'Device type' (Get-ChassisName $Inv.Enclosure.ChassisTypes $hasBattery)
    & $addSpec 'Manufacturer' $manufacturer
    & $addSpec 'Model' $model
    & $addSpec 'Serial number' $(if ($serialOk) { $serial } else { 'Not reported by firmware - read the label' })

    $cpus = @($Inv.Cpu | Where-Object { $null -ne $_ })
    $cpuText = ''
    if ($cpus.Count -gt 0) {
        $cpuName = Get-Clean (([string]$cpus[0].Name) -replace '\((R|TM|C)\)', '' -replace '\s+CPU\s+', ' ')
        $cores = ($cpus | Measure-Object -Property NumberOfCores -Sum).Sum
        $threads = ($cpus | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        $cpuText = '{0} - {1} cores / {2} threads' -f $cpuName, $cores, $threads
        if ($cpuName -notmatch 'GHz' -and $cpus[0].MaxClockSpeed) { $cpuText += (', {0:0.0} GHz' -f ($cpus[0].MaxClockSpeed / 1000)) }
    }
    & $addSpec 'Processor' $cpuText

    $modules = @($Inv.Ram | Where-Object { $null -ne $_ })
    $ramBytes = [double](($modules | Measure-Object -Property Capacity -Sum).Sum)
    if ($ramBytes -le 0) { $ramBytes = [double]$cs.TotalPhysicalMemory }
    $ramText = ''
    if ($ramBytes -gt 0) {
        $ramText = '{0} GB' -f [Math]::Round($ramBytes / 1GB)
        if ($modules.Count -gt 0) {
            $first = $modules[0]
            $type = $script:MemoryTypes[[int]$first.SMBIOSMemoryType]
            $speed = if ($first.ConfiguredClockSpeed) { $first.ConfiguredClockSpeed } else { $first.Speed }
            if ($type) { $ramText += ' ' + $type }
            if ($speed) { $ramText += (' {0} MHz' -f $speed) }
            $sizes = @($modules | ForEach-Object { [Math]::Round($_.Capacity / 1GB) })
            if (@($sizes | Select-Object -Unique).Count -eq 1) { $ramText += (' ({0} x {1} GB)' -f $sizes.Count, $sizes[0]) }
            else { $ramText += (' ({0} GB)' -f ($sizes -join ' + ')) }
        }
    }
    & $addSpec 'Memory (RAM)' $ramText

    $disks = Get-DiskInfo $Inv
    if ($disks.Count -eq 0) { & $addSpec 'Storage' '' }
    for ($i = 0; $i -lt $disks.Count; $i++) {
        $label = if ($disks.Count -gt 1) { 'Storage {0}' -f ($i + 1) } else { 'Storage' }
        & $addSpec $label $disks[$i].Text
    }
    $systemDrive = @($Inv.Volumes | Where-Object { $null -ne $_ -and $_.DeviceID -eq $env:SystemDrive }) | Select-Object -First 1
    if ($systemDrive) { & $addSpec 'Free space (C:)' ('{0} free of {1}' -f (Format-GiB $systemDrive.FreeSpace), (Format-GiB $systemDrive.Size)) }

    $gpus = @($Inv.Gpu | Where-Object { $null -ne $_ -and $_.Name -notmatch '(?i)remote display|mirror|indirect display|virtual|citrix|dameware|parsec' })
    & $addSpec 'Graphics' ((@($gpus | ForEach-Object { Get-Clean ($_.Name -replace '\((R|TM)\)', '') }) | Select-Object -Unique) -join ' + ')

    $displayText = ''
    $active = $gpus | Where-Object { $_.CurrentHorizontalResolution -gt 0 } | Select-Object -First 1
    if ($active) { $displayText = '{0} x {1}' -f $active.CurrentHorizontalResolution, $active.CurrentVerticalResolution }
    $panel = @($Inv.Monitors | Where-Object { $null -ne $_ -and $_.MaxHorizontalImageSize -gt 0 -and $_.MaxVerticalImageSize -gt 0 }) |
        Sort-Object -Property MaxHorizontalImageSize | Select-Object -First 1
    if ($panel) {
        $inches = [Math]::Sqrt([Math]::Pow($panel.MaxHorizontalImageSize, 2) + [Math]::Pow($panel.MaxVerticalImageSize, 2)) / 2.54
        $displayText = ('{0:0.0}-inch, ' -f $inches) + $displayText
    }
    & $addSpec 'Display' $displayText.Trim(', '.ToCharArray())

    $batteryHealth = $null
    $batteryText = 'No battery detected'
    if ($hasBattery) {
        $design = [double](($Inv.BatteryStatic | Measure-Object -Property DesignedCapacity -Sum).Sum)
        $full = [double](($Inv.BatteryFull | Measure-Object -Property FullChargedCapacity -Sum).Sum)
        $parts = @()
        if ($design -gt 0 -and $full -gt 0) {
            $batteryHealth = [int][Math]::Round(100 * $full / $design)
            $parts += ('Health {0}% of original capacity' -f $batteryHealth)
        } else { $parts += 'Health not reported' }
        $charge = @($Inv.Battery)[0].EstimatedChargeRemaining
        if ($null -ne $charge) { $parts += ('charge {0}%' -f $charge) }
        $cycles = (@($Inv.BatteryCycle) | Select-Object -First 1).CycleCount
        if ($cycles -gt 0) { $parts += ('{0} charge cycles' -f $cycles) }
        $batteryText = $parts -join ', '
    }
    & $addSpec 'Battery' $batteryText

    $winName = Get-Clean (([string]$os.Caption) -replace '^Microsoft\s+', '')
    $build = [string]$os.BuildNumber
    if ($null -ne $Inv.Ubr) { $build = '{0}.{1}' -f $build, $Inv.Ubr }
    $windowsText = ''
    if ($winName) { $windowsText = Get-Clean ('{0} {1} (build {2}), {3}' -f $winName, $Inv.DisplayVersion, $build, $os.OSArchitecture) }
    & $addSpec 'Windows' $windowsText
    $licenses = @($Inv.License | Where-Object { $null -ne $_ })
    $activation = if (@($licenses | Where-Object { [int]$_.LicenseStatus -eq 1 }).Count -gt 0) { 'Activated' }
        elseif ($licenses.Count -gt 0) { 'NOT activated' } else { 'Unknown' }
    & $addSpec 'Windows activation' $activation

    $biosDate = ''
    if ($bios.ReleaseDate -is [datetime]) { $biosDate = ' ({0:yyyy-MM-dd})' -f $bios.ReleaseDate }
    & $addSpec 'BIOS' ((Get-Clean (@($bios.SMBIOSBIOSVersion) -join ' ')) + $biosDate)

    $tpmText = if ($Inv.Tpm) { 'TPM ' + (([string]$Inv.Tpm.SpecVersion -split ',')[0]).Trim() } elseif ($script:IsAdmin) { 'No TPM detected' } else { 'TPM unknown (not administrator)' }
    $secureText = if ($Inv.SecureBoot -eq $true) { 'Secure Boot on' } elseif ($Inv.SecureBoot -eq $false) { 'Secure Boot off' } else { 'Secure Boot unknown' }
    & $addSpec 'Security chip' ('{0}, {1}' -f $tpmText, $secureText)

    $encryption = if ($Inv.BitLocker) {
        switch ([int]$Inv.BitLocker.ProtectionStatus) { 1 { 'BitLocker on' } 0 { 'BitLocker off or suspended' } default { 'BitLocker status unknown' } }
    } elseif ($script:IsAdmin) { 'BitLocker not available' } else { 'Unknown (not administrator)' }
    & $addSpec 'Disk encryption' $encryption

    $nics = @($Inv.Nics | Where-Object { $null -ne $_ -and $_.Name -notmatch '(?i)virtual|vpn|hyper-v|tap-|miniport|loopback|bluetooth|wan ' })
    $wifi = @($nics | Where-Object { $_.Name -match '(?i)wi-?fi|wireless|wlan|802\.11' -or [string]$_.NetConnectionID -match '(?i)wi-?fi|wireless|wlan' })
    $wifiIds = @($wifi | ForEach-Object { $_.DeviceID })
    $ethernet = @($nics | Where-Object { $wifiIds -notcontains $_.DeviceID })
    $nicText = { param($n) '{0} (MAC {1})' -f (Get-Clean ($n.Name -replace '\((R|TM)\)', '')), $(if ($n.MACAddress) { $n.MACAddress } else { 'not reported' }) }
    & $addSpec 'Wi-Fi' $(if ($wifi.Count) { & $nicText $wifi[0] } else { 'Not detected' })
    & $addSpec 'Ethernet' $(if ($ethernet.Count) { & $nicText $ethernet[0] } else { 'Not detected' })

    $pnp = @($Inv.Pnp | Where-Object { $null -ne $_ })
    $bluetooth = @($pnp | Where-Object { $_.PNPClass -eq 'Bluetooth' -and [string]$_.PNPDeviceID -match '^(USB|PCI|SD|ACPI|UART|BTHUSB)\\' })
    $cameras = @($pnp | Where-Object { ($_.PNPClass -eq 'Camera' -or ($_.PNPClass -eq 'Image' -and $_.Name -notmatch '(?i)scan')) -or $_.Name -match '(?i)webcam|\bcamera\b' } |
        Where-Object { $_.Name -notmatch '(?i)virtual|obs|frame server' })
    $touch = @($pnp | Where-Object { $_.Name -match '(?i)touch ?screen' })
    $fingerprint = @($pnp | Where-Object { $_.PNPClass -eq 'Biometric' -or $_.Name -match '(?i)fingerprint' })
    $describe = { param($list) if ($list.Count) { 'Yes - ' + ((@($list | ForEach-Object { Get-Clean ($_.Name -replace '\((R|TM)\)', '') }) | Select-Object -Unique -First 2) -join ', ') } else { 'Not detected' } }
    & $addSpec 'Bluetooth' (& $describe $bluetooth)
    & $addSpec 'Camera' (& $describe $cameras)
    & $addSpec 'Fingerprint reader' (& $describe $fingerprint)
    & $addSpec 'Touchscreen' (& $describe $touch)
    & $addSpec 'Computer name' $env:COMPUTERNAME

    $facts = [pscustomobject]@{
        Manufacturer = $manufacturer; Model = $model; Serial = $serial; SerialOk = $serialOk
        Cpu = $cpuText; RamText = $ramText; RamGB = [Math]::Round($ramBytes / 1GB); Disks = $disks
        HasBattery = $hasBattery; BatteryHealth = $batteryHealth; Windows = $winName; Activation = $activation; Encryption = $encryption
        Wifi = $wifi; Bluetooth = $bluetooth; Cameras = $cameras; Touch = $touch; Fingerprint = $fingerprint; Gpus = $gpus
    }
    return [pscustomobject]@{ Spec = $spec.ToArray(); Facts = $facts }
}

function Get-DeviceLabel {
    # Device Manager name, or the hardware ID for devices that have no driver and so no name.
    param($Device)
    $name = Get-Clean $Device.Name
    if ($name) { return $name }
    $id = Get-Clean $Device.PNPDeviceID
    if ($id.Length -gt 48) { $id = $id.Substring(0, 48) + '...' }
    if ($id) { return 'Unnamed device ' + $id }
    return 'Unnamed device'
}

function Invoke-AutoChecks {
    # Checks Windows can answer by itself. Physical tests follow later.
    param($Inv, $Facts, [switch]$Quiet)
    if (-not $Quiet) { Write-Heading 'AUTOMATIC CHECKS' }
    $set = { param($Name, $Status, $Note) Set-Result -Name $Name -Status $Status -Note $Note -Kind 'Auto' -Quiet:$Quiet }

    if ($Facts.SerialOk) { & $set 'Serial number readable' 'PASS' '' }
    else { & $set 'Serial number readable' 'WARN' 'Firmware has no serial - copy it from the label' }

    if ($Facts.Disks.Count -eq 0) { & $set 'Storage health' 'WARN' 'No internal drive reported' }
    else {
        $bad = @($Facts.Disks | Where-Object { $_.Health -eq 'Unhealthy' })
        $warn = @($Facts.Disks | Where-Object { $_.Health -eq 'Warning' })
        if ($bad.Count) { & $set 'Storage health' 'FAIL' ('Drive reports UNHEALTHY: ' + (($bad | ForEach-Object { $_.Name }) -join ', ')) }
        elseif ($warn.Count) { & $set 'Storage health' 'WARN' ('Drive reports a warning: ' + (($warn | ForEach-Object { $_.Name }) -join ', ')) }
        else { & $set 'Storage health' 'PASS' 'Drive reports healthy' }
        $worn = @($Facts.Disks | Where-Object { $null -ne $_.Wear -and $_.Wear -ge $script:Config.SsdWearWarnAbove })
        if ($worn.Count) { & $set 'SSD life' 'WARN' ('{0}% of rated life used' -f ($worn | Measure-Object -Property Wear -Maximum).Maximum) }
    }

    if (-not $Facts.HasBattery) { & $set 'Battery health' 'N/A' 'No battery' }
    elseif ($null -eq $Facts.BatteryHealth) { & $set 'Battery health' 'SKIP' 'Capacity not reported by the battery' }
    elseif ($Facts.BatteryHealth -lt $script:Config.BatteryFailBelow) { & $set 'Battery health' 'FAIL' ('{0}% of original capacity - replace battery' -f $Facts.BatteryHealth) }
    elseif ($Facts.BatteryHealth -lt $script:Config.BatteryWarnBelow) { & $set 'Battery health' 'WARN' ('{0}% of original capacity - worn' -f $Facts.BatteryHealth) }
    else { & $set 'Battery health' 'PASS' ('{0}% of original capacity' -f $Facts.BatteryHealth) }

    $basic = @($Facts.Gpus | Where-Object { $_.Name -match '(?i)basic display|basic render' })
    $badGpu = @($Facts.Gpus | Where-Object { $_.Status -and $_.Status -ne 'OK' })
    if ($Facts.Gpus.Count -eq 0) { & $set 'Graphics driver' 'WARN' 'No graphics adapter reported' }
    elseif ($basic.Count -or $badGpu.Count) { & $set 'Graphics driver' 'WARN' 'Graphics driver missing or reporting an error' }
    else { & $set 'Graphics driver' 'PASS' '' }

    $pnp = @($Inv.Pnp | Where-Object { $null -ne $_ })
    $problems = @($pnp | Where-Object { $null -ne $_.ConfigManagerErrorCode -and [int]$_.ConfigManagerErrorCode -ne 0 })
    if ($pnp.Count -eq 0) { & $set 'Device Manager errors' 'SKIP' 'Device list unavailable' }
    elseif ($problems.Count) {
        $names = (@($problems | Select-Object -First 3 | ForEach-Object { '{0} (code {1})' -f (Get-DeviceLabel $_), $_.ConfigManagerErrorCode })) -join '; '
        if ($problems.Count -gt 3) { $names += ('; +{0} more' -f ($problems.Count - 3)) }
        & $set 'Device Manager errors' 'WARN' $names
    } else { & $set 'Device Manager errors' 'PASS' 'All devices working' }

    $whea = @($Inv.Whea | Where-Object { $null -ne $_ })
    if ($whea.Count -gt 0) { & $set 'Hardware error log' 'WARN' ('{0} hardware error(s) logged in the last 30 days' -f $whea.Count) }
    elseif ($Inv.WheaReadable) { & $set 'Hardware error log' 'PASS' 'No hardware errors in the last 30 days' }
    else { & $set 'Hardware error log' 'SKIP' 'Event log not readable' }

    if ($Facts.Activation -eq 'Activated') { & $set 'Windows activation' 'PASS' '' }
    elseif ($Facts.Activation -eq 'NOT activated') { & $set 'Windows activation' 'WARN' 'Windows is not activated' }
    else { & $set 'Windows activation' 'SKIP' 'Activation status unknown' }

    # A date earlier than the BIOS or the Windows installation points to a flat clock (CMOS) battery.
    $now = Get-Date
    $biosDate = $Inv.Bios.ReleaseDate
    $installDate = $Inv.OS.InstallDate
    if (($biosDate -is [datetime] -and $now -lt $biosDate.Date) -or ($installDate -is [datetime] -and $now -lt $installDate.AddDays(-1))) {
        & $set 'System clock' 'WARN' ('Date shows {0:yyyy-MM-dd}, before the BIOS / Windows date - clock battery may be flat' -f $now)
    }
}

function Write-DetailedInventory {
    # Full technical appendix for the saved report (not printed).
    param($Inv)
    $cs = $Inv.ComputerSystem; $bios = $Inv.Bios; $prod = $Inv.Product; $enc = $Inv.Enclosure; $board = $Inv.Board; $os = $Inv.OS
    Add-DetailSection 'DETAILED INVENTORY - IDENTIFICATION'
    Add-DetailValue 'Manufacturer' $cs.Manufacturer
    Add-DetailValue 'Model' $cs.Model
    Add-DetailValue 'System family / SKU' ('{0} / {1}' -f $cs.SystemFamily, $cs.SystemSKUNumber)
    Add-DetailValue 'System serial (BIOS)' $bios.SerialNumber
    Add-DetailValue 'System UUID' $prod.UUID
    Add-DetailValue 'Product name / version' ('{0} / {1}' -f $prod.Name, $prod.Version)
    Add-DetailValue 'Product identifying number' $prod.IdentifyingNumber
    Add-DetailValue 'Chassis manufacturer' $enc.Manufacturer
    Add-DetailValue 'Chassis serial' $enc.SerialNumber
    Add-DetailValue 'Chassis asset tag' $enc.SMBIOSAssetTag
    Add-DetailValue 'Chassis type code(s)' $enc.ChassisTypes
    Add-DetailValue 'BIOS manufacturer / version' ('{0} / {1}' -f $bios.Manufacturer, (@($bios.SMBIOSBIOSVersion) -join ' '))
    Add-DetailValue 'BIOS release date' $bios.ReleaseDate
    Add-DetailValue 'Mainboard' ('{0} {1} (version {2})' -f $board.Manufacturer, $board.Product, $board.Version)
    Add-DetailValue 'Mainboard serial' $board.SerialNumber
    Add-DetailValue 'Windows edition' $os.Caption
    Add-DetailValue 'Windows version / build' ('{0} / {1}' -f $os.Version, $os.BuildNumber)
    Add-DetailValue 'Windows install date' $os.InstallDate
    Add-DetailValue 'Registered organization' $os.Organization
    Add-DetailValue 'Last boot' $os.LastBootUpTime
    Add-DetailValue 'Run as administrator' $script:IsAdmin
    if ($Inv.BitLocker) { Add-DetailValue 'BitLocker (system drive)' ('protection status {0}' -f $Inv.BitLocker.ProtectionStatus) }

    Add-DetailSection 'PROCESSOR'
    foreach ($c in @($Inv.Cpu | Where-Object { $null -ne $_ })) {
        Add-Detail ('{0} | {1} cores / {2} threads | max {3} MHz | L2 {4} KB | L3 {5} KB | socket {6} | status {7}' -f (Get-Clean $c.Name), $c.NumberOfCores, $c.NumberOfLogicalProcessors, $c.MaxClockSpeed, $c.L2CacheSize, $c.L3CacheSize, $c.SocketDesignation, $c.Status)
    }
    Add-DetailSection 'MEMORY MODULES'
    $modules = @($Inv.Ram | Where-Object { $null -ne $_ })
    foreach ($m in $modules) {
        Add-Detail ('{0} | {1} | {2} | {3} MHz | part {4} | serial {5} | type {6}' -f $m.DeviceLocator, (Format-GiB $m.Capacity), (Get-Clean $m.Manufacturer), $m.ConfiguredClockSpeed, (Get-Clean $m.PartNumber), (Get-Clean $m.SerialNumber), $script:MemoryTypes[[int]$m.SMBIOSMemoryType])
    }
    if ($modules.Count -eq 0) { Add-Detail 'No module details reported (memory may be soldered).' }

    Add-DetailSection 'GRAPHICS, DISPLAY AND AUDIO'
    foreach ($g in @($Inv.Gpu | Where-Object { $null -ne $_ })) { Add-Detail ('GPU: {0} | driver {1} | {2} | status {3}' -f (Get-Clean $g.Name), $g.DriverVersion, $g.VideoModeDescription, $g.Status) }
    foreach ($mon in @($Inv.Monitors | Where-Object { $null -ne $_ })) { Add-Detail ('Monitor: {0} | image size {1} x {2} cm | active {3}' -f $mon.InstanceName, $mon.MaxHorizontalImageSize, $mon.MaxVerticalImageSize, $mon.Active) }
    foreach ($a in @($Inv.Audio | Where-Object { $null -ne $_ })) { Add-Detail ('Audio: {0} | {1} | status {2}' -f (Get-Clean $a.Name), (Get-Clean $a.Manufacturer), $a.Status) }

    Add-DetailSection 'STORAGE'
    $reliability = if ($Inv.Reliability) { $Inv.Reliability } else { @{} }
    foreach ($d in @($Inv.Disks | Where-Object { $null -ne $_ })) { Add-Detail ('Disk: {0} | {1} | {2} | firmware {3} | serial {4} | status {5}' -f (Get-Clean $d.Model), (Format-DiskSize ([double]$d.Size)), $d.InterfaceType, (Get-Clean $d.FirmwareRevision), (Get-Clean $d.SerialNumber), $d.Status) }
    foreach ($p in @($Inv.PhysicalDisks | Where-Object { $null -ne $_ })) {
        $counter = $reliability[[string]$p.DeviceId]
        $extra = if ($counter) { ' | wear {0}% | power-on hours {1} | temperature {2} C' -f $counter.Wear, $counter.PowerOnHours, $counter.Temperature } else { '' }
        Add-Detail ('Physical disk: {0} | bus type {1} | media type {2} | health status {3}{4}' -f (Get-Clean $p.FriendlyName), $p.BusType, $p.MediaType, $p.HealthStatus, $extra)
    }
    foreach ($v in @($Inv.Volumes | Where-Object { $null -ne $_ })) { Add-Detail ('Volume {0} | {1} free of {2}' -f $v.DeviceID, (Format-GiB $v.FreeSpace), (Format-GiB $v.Size)) }

    Add-DetailSection 'BATTERY'
    $batteries = @($Inv.Battery | Where-Object { $null -ne $_ })
    foreach ($b in $batteries) { Add-Detail ('Battery: {0} | charge {1}% | status code {2} | chemistry code {3}' -f (Get-Clean $b.Name), $b.EstimatedChargeRemaining, $b.BatteryStatus, $b.Chemistry) }
    foreach ($s in @($Inv.BatteryStatic | Where-Object { $null -ne $_ })) { Add-Detail ('Design capacity: {0} mWh | manufacturer {1} | serial {2}' -f $s.DesignedCapacity, (Get-Clean $s.ManufactureName), (Get-Clean $s.SerialNumber)) }
    foreach ($f in @($Inv.BatteryFull | Where-Object { $null -ne $_ })) { Add-Detail ('Full-charge capacity: {0} mWh' -f $f.FullChargedCapacity) }
    if ($batteries.Count -eq 0) { Add-Detail 'No battery reported.' }

    Add-DetailSection 'NETWORK ADAPTERS'
    foreach ($n in @($Inv.Nics | Where-Object { $null -ne $_ })) { Add-Detail ('{0} | MAC {1} | connection status {2} | {3}' -f (Get-Clean $n.Name), $n.MACAddress, $n.NetConnectionStatus, $n.PNPDeviceID) }

    Add-DetailSection 'HARDWARE ERROR LOG (WHEA, LAST 30 DAYS)'
    $whea = @($Inv.Whea | Where-Object { $null -ne $_ })
    foreach ($e in $whea) {
        $message = Get-Clean $e.Message
        if ($message.Length -gt 180) { $message = $message.Substring(0, 180) }
        Add-Detail ('{0} | event {1} | {2}' -f $e.TimeCreated, $e.Id, $message)
    }
    if ($whea.Count -eq 0) { Add-Detail 'No events.' }

    $pnp = @($Inv.Pnp | Where-Object { $null -ne $_ })
    Add-DetailSection ('ALL DEVICES (PLUG AND PLAY) - {0} DEVICES' -f $pnp.Count)
    foreach ($dev in ($pnp | Sort-Object -Property PNPClass, Name)) {
        Add-Detail ('{0} | class {1} | status {2} | problem code {3} | {4}' -f (Get-Clean $dev.Name), $dev.PNPClass, $dev.Status, $dev.ConfigManagerErrorCode, $dev.PNPDeviceID)
    }
    $errors = @($Inv.Errors)
    if ($errors.Count -gt 0) {
        Add-DetailSection 'ITEMS WINDOWS COULD NOT REPORT'
        foreach ($err in $errors) { Add-Detail (Get-Clean $err) }
    }
}

# ------------------------------------------------------------------ test windows
function Set-FormIcon {
    param($Form)
    $path = Join-Path $script:RootDir ($script:ToolName + '.ico')
    if (-not (Test-Path -LiteralPath $path)) { return }
    try { $Form.Icon = New-Object System.Drawing.Icon($path) } catch { }   # cosmetic only
}

function Show-ScreenTest {
    # Full-screen colours. The window shows its own instructions, reacts to mouse AND keyboard (keyboard focus can stay
    # on the console on some PCs), closes itself after the last colour and has a safety timeout - so it can never
    # leave the inspector on a black screen.
    if (-not $script:UiReady) { return $false }
    $colors = @(
        [System.Drawing.Color]::White, [System.Drawing.Color]::Black, [System.Drawing.Color]::Red,
        [System.Drawing.Color]::Lime, [System.Drawing.Color]::Blue, [System.Drawing.Color]::Gray
    )
    $K = [System.Windows.Forms.Keys]
    $state = @{ Index = -1 }
    $form = New-Object System.Windows.Forms.Form
    $timer = New-Object System.Windows.Forms.Timer
    try {
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        $form.Bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $form.TopMost = $true
        $form.KeyPreview = $true
        $form.BackColor = [System.Drawing.Color]::FromArgb(20, 30, 45)
        $form.Text = 'Screen test'

        $label = New-Object System.Windows.Forms.Label
        $label.Dock = [System.Windows.Forms.DockStyle]::Fill
        $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $label.ForeColor = [System.Drawing.Color]::White
        $label.Font = New-Object System.Drawing.Font('Segoe UI', 22)
        $label.Text = "SCREEN TEST`r`n`r`nCLICK the mouse (or press SPACE) to show the next colour.`r`n" +
            "Look for dead or stuck dots, lines, dark patches, flicker or uneven light.`r`n`r`n" +
            "6 colours - the window closes by itself after the last one.`r`nRight-click = previous colour.   ESC = finish now."
        $form.Controls.Add($label)

        $advance = {
            $state.Index++
            if ($state.Index -ge $colors.Count) { $form.Close(); return }
            $label.Visible = $false
            $form.BackColor = $colors[$state.Index]
        }
        $back = {
            if ($state.Index -gt 0) { $state.Index--; $form.BackColor = $colors[$state.Index] }
        }
        $onClick = {
            param($src, $e)
            if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) { & $back } else { & $advance }
        }
        $form.Add_MouseClick($onClick)
        $label.Add_MouseClick($onClick)
        $form.Add_KeyDown({
            param($src, $e)
            $k = $e.KeyCode
            if ($k -eq $K::Escape) { $form.Close() }
            elseif (@($K::Left, $K::Up, $K::PageUp, $K::Back) -contains $k) { & $back }
            else { & $advance }
            $e.SuppressKeyPress = $true
        })
        $timer.Interval = [Math]::Max(10, $script:Config.ScreenTestSeconds) * 1000
        $timer.Add_Tick({ $timer.Stop(); $form.Close() })
        $form.Add_Shown({ $form.Activate(); $timer.Start() })
        [void]$form.ShowDialog()
        return $true
    } catch {
        Write-Host ('  The screen test window could not open: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        Add-ToolProblem 'Screen test window' $_
        return $false
    } finally {
        $timer.Stop(); $timer.Dispose(); $form.Dispose()
        Clear-KeyBuffer
    }
}

function Get-ModifierSide {
    # WinForms reports "Shift" without saying which one; ask WPF (if loaded) which side is down.
    param([int]$LeftCode, [int]$RightCode, [string]$WpfLeft, [string]$WpfRight)
    if ($script:WpfKeyboard) {
        try {
            $sides = @()
            if ([System.Windows.Input.Keyboard]::IsKeyDown($WpfLeft)) { $sides += $LeftCode }
            if ([System.Windows.Input.Keyboard]::IsKeyDown($WpfRight)) { $sides += $RightCode }
            if ($sides.Count) { return $sides }
        } catch { }
    }
    return @($LeftCode, $RightCode)
}

function Show-InputTest {
    # On-screen keyboard map (keys turn green when pressed) plus a touchpad area (move, left, right, scroll).
    if (-not $script:UiReady) { return $null }
    $layout = @(
        @('Esc|Escape', 'F1|F1', 'F2|F2', 'F3|F3', 'F4|F4', 'F5|F5', 'F6|F6', 'F7|F7', 'F8|F8', 'F9|F9', 'F10|F10', 'F11|F11', 'F12|F12', 'PrtSc|PrintScreen|1|opt', 'Ins|Insert|1|opt', 'Del|Delete'),
        @('`|Oemtilde', '1|D1', '2|D2', '3|D3', '4|D4', '5|D5', '6|D6', '7|D7', '8|D8', '9|D9', '0|D0', '-|OemMinus', '=|Oemplus', 'Backspace|Back|2'),
        @('Tab|Tab|1.5', 'Q|Q', 'W|W', 'E|E', 'R|R', 'T|T', 'Y|Y', 'U|U', 'I|I', 'O|O', 'P|P', '[|OemOpenBrackets', ']|OemCloseBrackets', '\|OemPipe|1.5'),
        @('Caps|CapsLock|1.75', 'A|A', 'S|S', 'D|D', 'F|F', 'G|G', 'H|H', 'J|J', 'K|K', 'L|L', ';|OemSemicolon', '''|OemQuotes', 'Enter|Enter|2.25'),
        @('Shift|LShiftKey|1.25', '<>|OemBackslash|1|opt', 'Z|Z', 'X|X', 'C|C', 'V|V', 'B|B', 'N|N', 'M|M', ',|Oemcomma', '.|OemPeriod', '/|OemQuestion', 'Shift|RShiftKey|2.75'),
        @('Ctrl|LControlKey|1.5', 'Win|LWin|1.25', 'Alt|LMenu|1.25', 'Space|Space|6', 'Alt|RMenu|1.25', 'Ctrl|RControlKey|1.25|opt', 'Left|Left', 'Up|Up', 'Down|Down', 'Right|Right'),
        @('Home|Home|1.25|opt', 'End|End|1.25|opt', 'PgUp|PageUp|1.25|opt', 'PgDn|PageDown|1.25|opt', 'Menu|Apps|1.25|opt')
    )
    $sideNames = @{ 160 = 'Left Shift'; 161 = 'Right Shift'; 162 = 'Left Ctrl'; 163 = 'Right Ctrl'; 164 = 'Left Alt'; 165 = 'Right Alt' }
    $green = [System.Drawing.Color]::FromArgb(34, 160, 80)
    $keyIdle = [System.Drawing.Color]::FromArgb(60, 66, 78)
    $optIdle = [System.Drawing.Color]::FromArgb(42, 46, 54)
    $state = @{ Seen = @{}; Extra = (New-Object System.Collections.ArrayList); EscCount = 0; Distance = 0.0; LastPoint = $null
        Move = $false; Left = $false; Right = $false; Scroll = $false }
    $keyLabels = @{}
    $allKeys = New-Object System.Collections.ArrayList

    $form = New-Object System.Windows.Forms.Form
    $timer = New-Object System.Windows.Forms.Timer
    try {
        $area = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        $form.Bounds = $area
        $form.TopMost = $true
        $form.KeyPreview = $true
        $form.BackColor = [System.Drawing.Color]::FromArgb(24, 26, 31)
        $form.ForeColor = [System.Drawing.Color]::White
        $form.Text = 'Keyboard and touchpad test'

        # Key size: 17 key widths across, and the right-hand column (12.3 units + margins) must fit the height.
        $unit = [Math]::Min([Math]::Floor(($area.Width - 60) / 17), [Math]::Floor(($area.Height - 90) / 12.3))
        $unit = [Math]::Max(30, [Math]::Min(72, $unit))
        $keyHeight = [int]($unit * 0.8)
        $keyFont = New-Object System.Drawing.Font('Segoe UI', [single][Math]::Max(8, $unit / 6))
        $textFont = New-Object System.Drawing.Font('Segoe UI', [single][Math]::Max(10, $unit / 5))

        $title = New-Object System.Windows.Forms.Label
        $title.SetBounds(30, 14, $area.Width - 60, [int]($unit * 1.1))
        $title.Font = New-Object System.Drawing.Font('Segoe UI', [single][Math]::Max(11, $unit / 4.5), [System.Drawing.FontStyle]::Bold)
        $title.Text = 'KEYBOARD + TOUCHPAD TEST - press every key once (each turns green). Use the touchpad in the box below.' +
            "`r`nWindows key opens Start - press Esc to close it. Fn keys may not show. FINISH: click the green button, or press Esc 3 times."
        $form.Controls.Add($title)

        $focusWarning = New-Object System.Windows.Forms.Label
        $focusWarning.SetBounds(30, 14, $area.Width - 60, [int]($unit * 1.1))
        $focusWarning.BackColor = [System.Drawing.Color]::FromArgb(190, 40, 40)
        $focusWarning.Font = $title.Font
        $focusWarning.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $focusWarning.Text = 'Keys are not reaching this window - CLICK HERE once, then continue pressing keys.'
        $focusWarning.Visible = $false
        $form.Controls.Add($focusWarning)
        $focusWarning.BringToFront()

        $y = 20 + [int]($unit * 1.3)
        foreach ($row in $layout) {
            $x = 30
            foreach ($entry in $row) {
                $parts = $entry -split '\|'
                $widthUnits = if ($parts.Count -gt 2) { [double]$parts[2] } else { 1.0 }
                $optional = ($parts.Count -gt 3 -and $parts[3] -eq 'opt')
                $code = [int]([System.Windows.Forms.Keys]$parts[1])
                $lbl = New-Object System.Windows.Forms.Label
                $lbl.SetBounds($x, $y, [int]($unit * $widthUnits) - 5, $keyHeight)
                $lbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
                $lbl.Font = $keyFont
                $lbl.Text = $parts[0]
                $lbl.BackColor = $(if ($optional) { $optIdle } else { $keyIdle })
                $form.Controls.Add($lbl)
                if (-not $keyLabels.ContainsKey($code)) { $keyLabels[$code] = New-Object System.Collections.ArrayList }
                [void]$keyLabels[$code].Add($lbl)
                $display = if ($sideNames.ContainsKey($code)) { $sideNames[$code] } else { $parts[0] }
                [void]$allKeys.Add([pscustomobject]@{ Code = $code; Name = $display; Optional = $optional })
                $x += [int]($unit * $widthUnits)
            }
            $y += $keyHeight + 5
        }

        $status = New-Object System.Windows.Forms.Label
        $status.SetBounds(30, $y + 4, $area.Width - 60, [int]($unit * 0.9))
        $status.Font = $textFont
        $form.Controls.Add($status)
        $y += [int]($unit * 1.0)

        $padHeight = [Math]::Max(120, $area.Height - $y - [int]($unit * 1.6))
        $pad = New-Object System.Windows.Forms.Panel
        $pad.SetBounds(30, $y + 6, [int](($area.Width - 60) * 0.62), $padHeight)
        $pad.BackColor = [System.Drawing.Color]::FromArgb(48, 52, 62)
        $form.Controls.Add($pad)
        $padText = New-Object System.Windows.Forms.Label
        $padText.Dock = [System.Windows.Forms.DockStyle]::Fill
        $padText.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $padText.Font = $textFont
        $padText.ForeColor = [System.Drawing.Color]::Gainsboro
        $padText.Text = "TOUCHPAD AREA`r`nMove the pointer here, LEFT-click, RIGHT-click,`r`nand scroll with two fingers."
        $pad.Controls.Add($padText)

        $indicatorX = 30 + $pad.Width + 20
        $indicatorWidth = $area.Width - $indicatorX - 30
        $indicators = @{}
        $iy = $y + 6
        foreach ($name in @('Move', 'Left', 'Right', 'Scroll')) {
            $ind = New-Object System.Windows.Forms.Label
            $ind.SetBounds($indicatorX, $iy, $indicatorWidth, [int]($unit * 0.75))
            $ind.Font = $textFont
            $ind.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
            $ind.BackColor = $keyIdle
            $ind.Text = '  ' + @{ Move = 'Pointer moves'; Left = 'Left click'; Right = 'Right click'; Scroll = 'Scroll' }[$name]
            $form.Controls.Add($ind)
            $indicators[$name] = $ind
            $iy += [int]($unit * 0.85)
        }
        $finish = New-Object System.Windows.Forms.Label
        $finish.SetBounds($indicatorX, $iy + 10, $indicatorWidth, [int]($unit * 1.0))
        $finish.Font = $title.Font
        $finish.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $finish.BackColor = $green
        $finish.Cursor = [System.Windows.Forms.Cursors]::Hand
        $finish.Text = 'FINISH TEST'
        $form.Controls.Add($finish)

        $required = @($allKeys | Where-Object { -not $_.Optional }).Count
        $updateStatus = {
            $done = @($allKeys | Where-Object { -not $_.Optional -and $state.Seen.ContainsKey($_.Code) }).Count
            $text = 'Main keys detected: {0} of {1}' -f $done, $required
            if ($state.Extra.Count) { $text += '    Other keys: ' + (($state.Extra | Select-Object -Last 8) -join ', ') }
            $status.Text = $text
        }
        $mark = {
            param([int]$c)
            if ($state.Seen.ContainsKey($c)) { return }
            $state.Seen[$c] = $true
            if ($keyLabels.ContainsKey($c)) { foreach ($l in $keyLabels[$c]) { $l.BackColor = $green } }
            else { [void]$state.Extra.Add(([string]([System.Windows.Forms.Keys]$c))) }
            & $updateStatus
        }
        $markPad = {
            param([string]$name)
            if ($state[$name]) { return }
            $state[$name] = $true
            $indicators[$name].BackColor = $green
            $indicators[$name].Text = $indicators[$name].Text + '  - OK'
        }

        $form.Add_PreviewKeyDown({ param($src, $e) $e.IsInputKey = $true })
        $form.Add_KeyDown({
            param($src, $e)
            $e.SuppressKeyPress = $true
            $code = [int]$e.KeyCode
            if ($code -eq 27) { $state.EscCount++; if ($state.EscCount -ge 3) { $form.Close() } } else { $state.EscCount = 0 }
            $codes = switch ($code) {
                16 { Get-ModifierSide 160 161 'LeftShift' 'RightShift' }
                17 { Get-ModifierSide 162 163 'LeftCtrl' 'RightCtrl' }
                18 { Get-ModifierSide 164 165 'LeftAlt' 'RightAlt' }
                default { @($code) }
            }
            foreach ($c in @($codes)) { & $mark ([int]$c) }
        })
        $form.Add_KeyUp({
            param($src, $e)
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::PrintScreen) { & $mark 44 }
            $e.Handled = $true
        })
        $onMove = {
            param($src, $e)
            $point = $e.Location
            if ($null -ne $state.LastPoint) { $state.Distance += [Math]::Abs($point.X - $state.LastPoint.X) + [Math]::Abs($point.Y - $state.LastPoint.Y) }
            $state.LastPoint = $point
            if ($state.Distance -gt 400) { & $markPad 'Move' }
        }
        $onDown = {
            param($src, $e)
            if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { & $markPad 'Left' }
            elseif ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) { & $markPad 'Right' }
        }
        $onWheel = { param($src, $e) if ($e.Delta -ne 0) { & $markPad 'Scroll' } }
        foreach ($target in @($pad, $padText)) { $target.Add_MouseMove($onMove); $target.Add_MouseDown($onDown); $target.Add_MouseWheel($onWheel) }
        $form.Add_MouseWheel($onWheel)
        $finish.Add_Click({ $form.Close() })
        $focusWarning.Add_Click({ $form.Activate() })
        $form.Add_Deactivate({ $focusWarning.Visible = $true })
        $form.Add_Activated({ $focusWarning.Visible = $false })
        $timer.Interval = [Math]::Max(1, $script:Config.InputTestMinutes) * 60000
        $timer.Add_Tick({ $timer.Stop(); $form.Close() })
        $form.Add_Shown({ $form.Activate(); & $updateStatus; $timer.Start() })
        [void]$form.ShowDialog()

        $missing = @($allKeys | Where-Object { -not $_.Optional -and -not $state.Seen.ContainsKey($_.Code) } | ForEach-Object { $_.Name })
        $missingOptional = @($allKeys | Where-Object { $_.Optional -and -not $state.Seen.ContainsKey($_.Code) } | ForEach-Object { $_.Name })
        return [pscustomobject]@{
            Required = $required; Detected = ($required - $missing.Count); Missing = $missing; MissingOptional = $missingOptional
            Move = $state.Move; Left = $state.Left; Right = $state.Right; Scroll = $state.Scroll; SidesChecked = $script:WpfKeyboard
        }
    } catch {
        Write-Host ('  The keyboard test window could not open: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        Add-ToolProblem 'Keyboard test window' $_
        return $null
    } finally {
        $timer.Stop(); $timer.Dispose(); $form.Dispose()
        Clear-KeyBuffer
    }
}

function Show-MicrophoneTest {
    # Live level bar for the default microphone. Returns Peak (0-100) and Error, or $null when no meter is available.
    $meterType = 'WinCheckup.MicMeter' -as [type]
    if (-not $script:UiReady -or -not $meterType) { return $null }
    $state = @{ Peak = 0; Error = $null }
    try {
        if ($meterType::DeviceCount -lt 1) { $state.Error = 'Windows reports no microphone'; return [pscustomobject]$state }
    } catch { return $null }
    $meter = $null
    $form = New-Object System.Windows.Forms.Form
    $timer = New-Object System.Windows.Forms.Timer
    try {
        $meter = $meterType::new()
        $font = New-Object System.Drawing.Font('Segoe UI', 13)
        $green = [System.Drawing.Color]::FromArgb(34, 160, 80)
        $form.Text = 'Microphone test'
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.TopMost = $true
        $form.KeyPreview = $true
        $form.ClientSize = New-Object System.Drawing.Size(680, 300)
        $form.BackColor = [System.Drawing.Color]::FromArgb(24, 26, 31)
        $form.ForeColor = [System.Drawing.Color]::White
        Set-FormIcon $form

        $title = New-Object System.Windows.Forms.Label
        $title.SetBounds(30, 20, 620, 70)
        $title.Font = $font
        $title.Text = "Speak, count to five or clap near the laptop.`r`nThe bar should jump every time you make a sound."
        $form.Controls.Add($title)
        $track = New-Object System.Windows.Forms.Panel
        $track.SetBounds(30, 105, 620, 44)
        $track.BackColor = [System.Drawing.Color]::FromArgb(48, 52, 62)
        $form.Controls.Add($track)
        $fill = New-Object System.Windows.Forms.Panel
        $fill.SetBounds(0, 0, 0, 44)
        $fill.BackColor = $green
        $track.Controls.Add($fill)
        $status = New-Object System.Windows.Forms.Label
        $status.SetBounds(30, 162, 620, 40)
        $status.Font = $font
        $status.Text = 'Highest level so far: 0 %'
        $form.Controls.Add($status)
        $done = New-Object System.Windows.Forms.Button
        $done.SetBounds(470, 228, 180, 48)
        $done.Text = 'Done'
        $done.Font = $font
        $done.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $done.BackColor = $green
        $done.ForeColor = [System.Drawing.Color]::White
        $done.Add_Click({ $form.Close() })
        $form.Controls.Add($done)
        $form.AcceptButton = $done
        $form.Add_KeyDown({ param($src, $e) if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $form.Close() } })

        $started = Get-Date
        $timer.Interval = 60
        $timer.Add_Tick({
            try { $level = $meter.ReadPeakPercent() }
            catch { $state.Error = $_.Exception.Message; $timer.Stop(); $form.Close(); return }
            $fill.Width = [int]($track.Width * [Math]::Sqrt($level / 100.0))   # square root makes quiet sounds visible
            if ($level -gt $state.Peak) {
                $state.Peak = $level
                $heard = if ($level -ge $script:MicSoundThreshold) { '   - sound picked up' } else { '' }
                $status.Text = 'Highest level so far: {0} %{1}' -f $level, $heard
            }
            if (((Get-Date) - $started).TotalSeconds -gt 45) { $timer.Stop(); $form.Close() }
        })
        $form.Add_Shown({ $form.Activate(); $timer.Start() })
        [void]$form.ShowDialog()
    } catch {
        $state.Error = $_.Exception.Message
    } finally {
        $timer.Stop(); $timer.Dispose(); $form.Dispose()
        if ($meter) { $meter.Dispose() }
        Clear-KeyBuffer
    }
    return [pscustomobject]$state
}

# ------------------------------------------------------------------ sound
function New-StereoTone {
    # Builds a WAV in memory: 0.6 s tone in the LEFT channel, a short gap, then 0.6 s in the RIGHT channel.
    $rate = 22050; $samplesPerCycle = 50          # 441 Hz
    $toneCycles = 265; $gapBytes = 6000 * 4
    $left = New-Object byte[] ($samplesPerCycle * 4)
    $right = New-Object byte[] ($samplesPerCycle * 4)
    for ($i = 0; $i -lt $samplesPerCycle; $i++) {
        $bytes = [BitConverter]::GetBytes([int16][Math]::Round(9000 * [Math]::Sin(2 * [Math]::PI * $i / $samplesPerCycle)))
        $left[$i * 4] = $bytes[0]; $left[$i * 4 + 1] = $bytes[1]
        $right[$i * 4 + 2] = $bytes[0]; $right[$i * 4 + 3] = $bytes[1]
    }
    $pcm = New-Object System.IO.MemoryStream
    for ($i = 0; $i -lt $toneCycles; $i++) { $pcm.Write($left, 0, $left.Length) }
    $pcm.Write((New-Object byte[] $gapBytes), 0, $gapBytes)
    for ($i = 0; $i -lt $toneCycles; $i++) { $pcm.Write($right, 0, $right.Length) }
    $data = $pcm.ToArray()

    $wav = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter($wav)
    $ascii = [System.Text.Encoding]::ASCII
    $writer.Write($ascii.GetBytes('RIFF')); $writer.Write([int](36 + $data.Length)); $writer.Write($ascii.GetBytes('WAVE'))
    $writer.Write($ascii.GetBytes('fmt ')); $writer.Write([int]16); $writer.Write([int16]1); $writer.Write([int16]2)
    $writer.Write([int]$rate); $writer.Write([int]($rate * 4)); $writer.Write([int16]4); $writer.Write([int16]16)
    $writer.Write($ascii.GetBytes('data')); $writer.Write([int]$data.Length); $writer.Write($data)
    $writer.Flush()
    $wav.Position = 0
    return $wav
}

function Set-SpeakerVolume {
    # Sets the default output device to $Percent and un-mutes it. The first time each device is touched its original
    # level is remembered, so Restore-SpeakerVolume can put it back.
    param([int]$Percent)
    $api = 'WinCheckup.SpeakerVolume' -as [type]
    if ($api) {
        try {
            $id = $api::DefaultDeviceId()
            if (-not $script:AudioOriginals.ContainsKey($id)) {
                $script:AudioOriginals[$id] = [pscustomobject]@{ Level = $api::GetLevel($id); Muted = $api::GetMute($id) }
            }
            $api::SetMute($id, $false)
            $api::SetLevel($id, [single]([Math]::Min(100, [Math]::Max(0, $Percent)) / 100))
            return $true
        } catch {
            Add-ToolProblem 'Speaker volume' $_   # e.g. no output device for a moment after plugging in headphones
            return $false
        }
    }
    try {
        # Only without the Core Audio helper: volume keys (2 % per press), which cannot be undone afterwards.
        $shell = New-Object -ComObject WScript.Shell
        for ($i = 0; $i -lt 50; $i++) { $shell.SendKeys([string][char]174) }
        for ($i = 0; $i -lt [int]($Percent / 2); $i++) { $shell.SendKeys([string][char]175) }
        return $true
    } catch {
        Add-ToolProblem 'Speaker volume (keys)' $_
        return $false
    }
}

function Restore-SpeakerVolume {
    $api = 'WinCheckup.SpeakerVolume' -as [type]
    if (-not $api -or $script:AudioOriginals.Count -eq 0) { return }
    foreach ($id in @($script:AudioOriginals.Keys)) {
        $original = $script:AudioOriginals[$id]
        try {
            $api::SetLevel($id, [single]$original.Level)
            $api::SetMute($id, [bool]$original.Muted)
        } catch { Add-ToolProblem 'Putting the volume back' $_ }   # e.g. headphones already unplugged
    }
    $script:AudioOriginals.Clear()
}

function Invoke-SpeakerTone {
    try {
        $wav = New-StereoTone
        $player = New-Object System.Media.SoundPlayer($wav)
        $player.PlaySync()
        $player.Dispose(); $wav.Dispose()
        return $true
    } catch {
        Add-ToolProblem 'Test tone' $_
        try { [Console]::Beep(660, 500); [Console]::Beep(880, 500); return $true } catch { return $false }
    }
}

# ------------------------------------------------------------------ live probes used by the tests
function Wait-Condition {
    # Polls $Condition until it returns $true. Returns OK, TIMEOUT or SKIP (S or Esc pressed).
    param([scriptblock]$Condition, [int]$Seconds, [int]$IntervalMs = 400)
    $deadline = (Get-Date).AddSeconds($Seconds)
    Clear-KeyBuffer
    while ((Get-Date) -lt $deadline) {
        $met = $false
        try { $met = [bool](& $Condition) } catch { $met = $false }
        if ($met) { Write-Host ("`r" + (' ' * 60) + "`r") -NoNewline; return 'OK' }
        $left = [int][Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
        Write-Host ("`r    Waiting... {0,3} s   (press S to stop waiting)" -f $left) -NoNewline -ForegroundColor DarkGray
        try {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq 'S' -or $key.Key -eq 'Escape') { Write-Host ''; return 'SKIP' }
            }
        } catch { }
        Start-Sleep -Milliseconds $IntervalMs
    }
    Write-Host ''
    # One last look: the loop can overrun its deadline (slow query, console paused by a mouse selection).
    $met = $false
    try { $met = [bool](& $Condition) } catch { $met = $false }
    if ($met) { return 'OK' }
    return 'TIMEOUT'
}

function Get-AcOnline {
    # $true = charger connected, $false = on battery, $null = unknown.
    if ($script:UiReady) {
        try {
            $line = [string][System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus
            if ($line -eq 'Online') { return $true }
            if ($line -eq 'Offline') { return $false }
        } catch { }
    }
    try {
        $status = [int](Get-CimInstance -ClassName Win32_Battery -OperationTimeoutSec 5 -ErrorAction Stop | Select-Object -First 1).BatteryStatus
        if ($status -eq 1 -or $status -eq 4 -or $status -eq 5) { return $false }
        if (@(2, 3, 6, 7, 8, 9) -contains $status) { return $true }
    } catch { }
    return $null
}

function Get-WifiState {
    # 'Internet', 'Connected' or 'Disconnected' for the Wi-Fi adapter(s). Reads Windows' own connectivity status;
    # it sends nothing over the network.
    $ids = @($script:Facts.Wifi | ForEach-Object { [string]$_.DeviceID })
    $connected = @(Get-CimInstance -ClassName Win32_NetworkAdapter -Filter 'PhysicalAdapter=TRUE' -OperationTimeoutSec 5 -ErrorAction SilentlyContinue |
        Where-Object { $ids -contains [string]$_.DeviceID -and $_.NetConnectionStatus -eq 2 })
    if ($connected.Count -eq 0) { return 'Disconnected' }
    $aliases = @($connected | ForEach-Object { [string]$_.NetConnectionID })
    try {
        $profiles = @(Get-NetConnectionProfile -ErrorAction Stop | Where-Object { $aliases -contains [string]$_.InterfaceAlias })
        foreach ($p in $profiles) {
            foreach ($value in @($p.IPv4Connectivity, $p.IPv6Connectivity)) {
                if ([string]$value -eq 'Internet' -or [string]$value -eq '4') { return 'Internet' }
            }
        }
    } catch { }
    return 'Connected'
}

function Get-UsbDeviceMap {
    # id -> name of every connected USB device (one entry per device, not per interface).
    $map = @{}
    foreach ($d in @(Get-CimInstance -ClassName Win32_PnPEntity -Filter "PNPDeviceID LIKE 'USB\\VID%'" -Property 'Name', 'PNPDeviceID' -OperationTimeoutSec 5 -ErrorAction Stop)) {
        $id = [string]$d.PNPDeviceID
        if ($id -match '&MI_') { continue }
        $map[$id] = $(if ($d.Name) { Get-Clean $d.Name } else { 'USB device' })
    }
    return $map
}

function Get-DisplayMap {
    # id -> name of every active display, built-in panel included.
    $names = @{}
    foreach ($id in @(Get-CimInstance -Namespace 'root/wmi' -ClassName WmiMonitorID -OperationTimeoutSec 5 -ErrorAction SilentlyContinue)) {
        $friendly = -join @($id.UserFriendlyName | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ })
        if ($friendly) { $names[[string]$id.InstanceName] = Get-Clean $friendly }
    }
    $map = @{}
    foreach ($m in @(Get-CimInstance -Namespace 'root/wmi' -ClassName WmiMonitorBasicDisplayParams -OperationTimeoutSec 5 -ErrorAction Stop)) {
        if (-not $m.Active) { continue }
        $key = [string]$m.InstanceName
        $map[$key] = $(if ($names.ContainsKey($key)) { $names[$key] } else { 'Display' })
    }
    return $map
}

function Watch-NewDevices {
    # Polls $Probe (returns an id -> name map) and lists every device that appears. Enter = finished, S = skip.
    # Returns $null when the probe does not work, otherwise Skipped and Events (one entry per plug-in).
    param([scriptblock]$Probe, [string]$What, [int]$TimeoutSeconds = 300)
    try { $known = & $Probe } catch { return $null }
    if ($null -eq $known) { return $null }
    $events = New-Object System.Collections.ArrayList
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $nextPoll = Get-Date
    Clear-KeyBuffer
    Write-Host ('  > Watching for {0}. Press ENTER when finished, S to skip.' -f $What) -ForegroundColor Cyan
    while ((Get-Date) -lt $deadline) {
        try {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq 'Enter') { break }
                if ($key.Key -eq 'S' -or $key.Key -eq 'Escape') { return [pscustomobject]@{ Skipped = $true; Events = $events.ToArray() } }
            }
        } catch { break }
        if ((Get-Date) -ge $nextPoll) {
            $now = $null
            try { $now = & $Probe } catch { $now = $null }
            if ($null -ne $now) {
                $new = @($now.Keys | Where-Object { -not $known.ContainsKey($_) })
                if ($new.Count) {
                    $names = @($new | ForEach-Object { $now[$_] } | Select-Object -Unique)
                    [void]$events.Add(($names -join ', '))
                    Write-Host ('    {0}. Detected: {1}' -f $events.Count, ($names -join ', ')) -ForegroundColor Green
                }
                $known = $now
            }
            $nextPoll = (Get-Date).AddMilliseconds(1500)
        }
        Start-Sleep -Milliseconds 150
    }
    return [pscustomobject]@{ Skipped = $false; Events = $events.ToArray() }
}

function Get-LastResumeTime {
    # Newest "woke up from sleep" event since $Since (S3 sleep or Modern Standby), or $null.
    param([datetime]$Since)
    $filters = @(
        @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Power-Troubleshooter'; Id = 1; StartTime = $Since },
        @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 107, 507; StartTime = $Since }
    )
    $latest = $null
    foreach ($filter in $filters) {
        try {
            $found = Get-WinEvent -FilterHashtable $filter -MaxEvents 1 -ErrorAction Stop | Select-Object -First 1
            if ($found -and ($null -eq $latest -or $found.TimeCreated -gt $latest)) { $latest = $found.TimeCreated }
        } catch { }   # "no events found" is the normal answer when nothing happened
    }
    return $latest
}

# ------------------------------------------------------------------ guided tests
function Invoke-GuidedTest {
    # One test: show the steps, run its helper (window, sound, probe), then record P / F / S.
    # The helper may return @{ Hint; PassNote; FailNote; Done } - Done means it already recorded the result.
    param([hashtable]$Test, [int]$Number, [int]$Total, [int]$FirstAttempt = 1)
    if ($Number -gt 0) { Write-Heading ('TEST {0} of {1}:  {2}' -f $Number, $Total, $Test.Name) }
    else { Write-Heading ('TEST AGAIN:  {0}' -f $Test.Name) }
    foreach ($step in $Test.Steps) { Write-Host ('  - ' + $step) }
    $attempt = $FirstAttempt - 1
    while ($true) {
        $attempt++
        $info = @{}
        if ($Test.Action) {
            try {
                $returned = @(& $Test.Action $attempt) | Where-Object { $_ -is [hashtable] } | Select-Object -Last 1
                if ($returned) { $info = $returned }
            } catch {
                Add-ToolProblem ('Test "{0}"' -f $Test.Name) $_
                $info = @{ Hint = ('The automatic part of this test failed ({0}) - check by hand.' -f (Get-Clean $_.Exception.Message)) }
            }
        }
        if ($info.Done) { break }
        if ($info.Hint) { Write-Host ('  > ' + $info.Hint) -ForegroundColor Cyan }
        $allowed = @('P', 'F', 'S')
        $prompt = '  Result:  [P] Pass   [F] Fail   [S] Skip'
        if ($Test.Repeat) { $allowed += 'R'; $prompt += '   [R] Repeat' }
        $choice = Read-Choice ($prompt + '  > ') $allowed
        if ($choice -eq 'R') { continue }
        switch ($choice) {
            'P' { Set-Result $Test.Name 'PASS' ([string]$info.PassNote) }
            'F' {
                $default = [string]$info.FailNote
                $promptText = if ($default) { '  What is wrong? (Enter = "{0}")' -f $default } else { '  What is wrong? (short note)' }
                $note = Read-Text $promptText $default
                if (-not $note) { $note = 'Not working' }
                Set-Result $Test.Name 'FAIL' $note
            }
            'S' { Set-Result $Test.Name 'SKIP' 'Not tested' }
        }
        break
    }
    if ($Test.Cleanup) {
        try { & $Test.Cleanup } catch { Add-ToolProblem ('Closing test "{0}"' -f $Test.Name) $_ }
    }
}

function Get-GuidedTests {
    # The physical tests in the order they are done. Each action reads the device facts from $script:Facts.
    $tests = New-Object System.Collections.ArrayList

    [void]$tests.Add(@{
        Name = 'Physical condition'
        Steps = @('Look over the whole device: lid, base, hinges, screen glass and bezel, keys, rubber feet, screws, port openings.',
            'FAIL for cracks, broken hinges, missing keys or parts, liquid damage - or a SWOLLEN BATTERY (base bulging,',
            'touchpad pushed up). Do not charge or keep using a device with a swollen battery.')
    })

    [void]$tests.Add(@{
        Name = 'Screen / display'; Repeat = $true
        Steps = @('A full-screen colour test opens. CLICK (or press SPACE) for each colour.',
            'Look for dead or stuck dots, lines, dark patches, flicker or uneven brightness.')
        Action = {
            param($attempt)
            if (Show-ScreenTest) { return @{ Hint = 'Did every colour look clean and even?'; FailNote = 'Screen fault (dots / lines / patches)' } }
            return @{ Hint = 'Window unavailable - check the screen by eye (white and dark backgrounds).' }
        }
    })

    [void]$tests.Add(@{
        Name = 'Keyboard'; Repeat = $true
        Steps = @('A keyboard map opens. Press EVERY key once - each key turns green when Windows receives it.',
            'Also try the touchpad in the grey box (used for the next test). Click FINISH TEST when done.')
        Action = {
            param($attempt)
            $script:InputResult = Show-InputTest
            $r = $script:InputResult
            if (-not $r) { return @{ Hint = 'Window unavailable - type in Notepad to check every key.' } }
            if ($r.Missing.Count -eq 0) {
                return @{ Hint = ('All {0} main keys detected.' -f $r.Required); PassNote = ('All {0} main keys work' -f $r.Required) }
            }
            $list = $r.Missing -join ', '
            return @{ Hint = ('{0} of {1} keys detected. NOT detected: {2}' -f $r.Detected, $r.Required, $list)
                PassNote = ('{0} of {1} keys detected' -f $r.Detected, $r.Required); FailNote = ('Keys not working: ' + $list) }
        }
    })

    [void]$tests.Add(@{
        Name = 'Touchpad / mouse'; Repeat = $true
        Steps = @('Uses the touchpad box from the keyboard window: move, left-click, right-click, two-finger scroll.')
        Action = {
            param($attempt)
            if ($attempt -gt 1 -or -not $script:InputResult) { $script:InputResult = Show-InputTest }
            $r = $script:InputResult
            if (-not $r) { return @{ Hint = 'Window unavailable - test pointer, both buttons and scrolling by hand.' } }
            $failed = @()
            if (-not $r.Move) { $failed += 'pointer movement' }
            if (-not $r.Left) { $failed += 'left click' }
            if (-not $r.Right) { $failed += 'right click' }
            if (-not $r.Scroll) { $failed += 'scrolling' }
            if ($failed.Count -eq 0) { return @{ Hint = 'Movement, left click, right click and scroll all detected.'; PassNote = 'Move, clicks and scroll work' } }
            return @{ Hint = ('Not detected: {0}  (press R to open the window again)' -f ($failed -join ', ')); FailNote = ('Not working: ' + ($failed -join ', ')) }
        }
    })

    if ($script:Facts.Touch.Count -gt 0) {
        [void]$tests.Add(@{
            Name = 'Touchscreen'
            Steps = @('Tap several places on the screen, drag a window, and pinch / zoom if supported.')
        })
    }

    if ($script:Facts.Fingerprint.Count -gt 0) {
        [void]$tests.Add(@{
            Name = 'Fingerprint reader'
            Steps = @('Sign-in options open. Touch the reader (or set up a test finger) and check it responds.')
            Action = { param($attempt) try { Start-Process 'ms-settings:signinoptions' -ErrorAction Stop } catch { }; return @{} }
        })
    }

    [void]$tests.Add(@{
        Name = 'Camera'; Repeat = $true
        Steps = @('The Camera app opens. Check for a clear, live picture (and the camera light if it has one).',
            'The app closes automatically after you answer.')
        Action = {
            param($attempt)
            $hint = if ($script:Facts.Cameras.Count) { 'Windows detects a camera.' } else { 'Windows does NOT detect any camera.' }
            try { Start-Process 'microsoft.windows.camera:' -ErrorAction Stop }
            catch { $hint += ' Camera app not found - open it from the Start menu.' }
            $fail = if ($script:Facts.Cameras.Count) { 'No picture / poor picture' } else { 'No camera detected' }
            return @{ Hint = $hint; FailNote = $fail }
        }
        Cleanup = { Get-Process -Name 'WindowsCamera' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
    })

    [void]$tests.Add(@{
        Name = 'Speakers'; Repeat = $true; Cleanup = { Restore-SpeakerVolume }
        Steps = @(('The volume is set to {0} % (it is put back at the end). A tone plays LEFT, then RIGHT.' -f $script:Config.SpeakerVolumePercent),
            'Both sides should be clear, with no crackle or buzzing.')
        Action = {
            param($attempt)
            [void](Set-SpeakerVolume $script:Config.SpeakerVolumePercent)
            Clear-KeyBuffer
            if (Invoke-SpeakerTone) { return @{ Hint = 'Did you hear the tone on the LEFT and then on the RIGHT?  (R = play again)'; FailNote = 'No sound / one side not working' } }
            return @{ Hint = 'The tone could not play - play any sound or video to check.' }
        }
    })

    [void]$tests.Add(@{
        Name = 'Headphone jack'; Repeat = $true; Cleanup = { Restore-SpeakerVolume }
        Steps = @('Plug headphones into the headphone jack - hold them a little away from your ears.',
            ('A quieter tone ({0} % volume) plays LEFT, then RIGHT. Press S if there is no jack or no headphones.' -f $script:Config.HeadphoneVolumePercent))
        Action = {
            param($attempt)
            if ($attempt -eq 1) {
                $go = Read-Choice '  Plug in the headphones, then press Enter to play the tone  (S = skip)  > ' @('ENTER', 'S')
                if ($go -eq 'S') { Set-Result 'Headphone jack' 'SKIP' 'Not tested'; return @{ Done = $true } }
            }
            [void](Set-SpeakerVolume $script:Config.HeadphoneVolumePercent)
            if (Invoke-SpeakerTone) { return @{ Hint = 'Did you hear the tone LEFT, then RIGHT in the headphones?  (R = play again)'; FailNote = 'No sound / one side missing in headphones' } }
            return @{ Hint = 'The tone could not play - play any sound to check.' }
        }
    })

    [void]$tests.Add(@{
        Name = 'Microphone'; Repeat = $true
        Steps = @('A level meter opens. Speak or clap near the laptop and watch the bar jump. Click Done (or press Enter).')
        Action = {
            param($attempt)
            $r = Show-MicrophoneTest
            if ($null -eq $r -or ($r.Error -and $r.Error -notmatch 'no microphone')) {
                if ($r -and $r.Error) { Add-ToolProblem 'Microphone meter' $r.Error }
                try { Start-Process 'control.exe' -ArgumentList 'mmsys.cpl,,1' -ErrorAction Stop } catch { }
                return @{ Hint = 'The Sound "Recording" panel opened instead - speak and watch the green level bar, then close it.'; FailNote = 'Microphone does not pick up sound' }
            }
            if ($r.Error) { return @{ Hint = 'Windows reports NO microphone.'; FailNote = 'No microphone detected' } }
            if ($r.Peak -ge $script:MicSoundThreshold) {
                return @{ Hint = ('Sound was picked up (highest level {0} %).' -f $r.Peak); PassNote = ('Picks up sound (peak {0} %)' -f $r.Peak); FailNote = 'Microphone sound poor' }
            }
            return @{ Hint = ('Almost no sound picked up (highest level {0} %). Check it is not muted, and Settings > Privacy > Microphone allows desktop apps.  (R = try again)' -f $r.Peak)
                FailNote = 'Microphone picks up no sound' }
        }
    })

    [void]$tests.Add(@{
        Name = 'Wi-Fi'; Repeat = $true
        Steps = @('Connect to a known Wi-Fi network (the network list opens). The test passes by itself once the internet works.')
        Action = {
            param($attempt)
            if ($script:Facts.Wifi.Count -eq 0) { return @{ Hint = 'Windows does NOT detect a Wi-Fi adapter.'; FailNote = 'No Wi-Fi adapter detected' } }
            if ((Get-WifiState) -ne 'Internet') {
                try { Start-Process 'ms-availablenetworks:' -ErrorAction Stop } catch { }
                Write-Host '  > Waiting for the Wi-Fi connection...' -ForegroundColor Cyan
                [void](Wait-Condition { (Get-WifiState) -eq 'Internet' } $script:Config.WifiWaitSeconds 1500)
            }
            $now = Get-WifiState
            if ($now -eq 'Internet') { Set-Result 'Wi-Fi' 'PASS' 'Connected, internet working'; return @{ Done = $true } }
            if ($now -eq 'Connected') { return @{ Hint = 'Wi-Fi is connected but this network has no internet (it may need a sign-in page).'; PassNote = 'Connects (no internet on this network)'; FailNote = 'Connects but no internet' } }
            return @{ Hint = 'Wi-Fi did not connect.  (R = wait again)'; FailNote = 'Cannot connect to Wi-Fi' }
        }
    })

    [void]$tests.Add(@{
        Name = 'Bluetooth'
        Steps = @('Bluetooth settings open. Turn Bluetooth on and check a phone or headset is found when scanning.')
        Action = {
            param($attempt)
            try { Start-Process 'ms-settings:bluetooth' -ErrorAction Stop } catch { }
            if ($script:Facts.Bluetooth.Count -eq 0) { return @{ Hint = 'Windows does NOT detect a Bluetooth radio (press S if the model has none).'; FailNote = 'No Bluetooth detected' } }
            return @{ Hint = 'Bluetooth radio detected. Does scanning find a device?'; FailNote = 'Bluetooth does not find devices' }
        }
    })

    [void]$tests.Add(@{
        Name = 'USB ports'; Repeat = $true
        Steps = @('Plug a USB flash drive or mouse into EACH USB-A / USB-C port in turn, unplugging it before the next port.',
            'Every plug-in is listed below. Do not remove this inspection USB stick.')
        Action = {
            param($attempt)
            $watch = Watch-NewDevices -Probe { Get-UsbDeviceMap } -What 'USB devices'
            if ($null -eq $watch) { return @{ Hint = 'USB devices could not be listed - check each port by hand.'; FailNote = 'USB port(s) not working' } }
            $n = $watch.Events.Count
            if ($n -gt 0) { return @{ Hint = ('{0} plug-in(s) detected. Did every port work?' -f $n); PassNote = ('{0} port(s) detected a device' -f $n); FailNote = 'One or more USB ports do not work' } }
            return @{ Hint = 'No USB device was detected.  (R = watch again)'; FailNote = 'USB ports do not detect devices' }
        }
    })

    [void]$tests.Add(@{
        Name = 'Video out (HDMI / USB-C)'; Repeat = $true
        Steps = @('Connect a monitor or projector to HDMI / DisplayPort / video USB-C. Each display that appears is listed.',
            'Check the picture is stable, then press Enter. Press S if there is no video port or no monitor available.')
        Action = {
            param($attempt)
            $watch = Watch-NewDevices -Probe { Get-DisplayMap } -What 'a new display'
            if ($null -eq $watch) { return @{ Hint = 'Displays could not be listed - check the picture by eye.'; FailNote = 'No picture on external display' } }
            if ($watch.Skipped) { Set-Result 'Video out (HDMI / USB-C)' 'SKIP' 'Not tested'; return @{ Done = $true } }
            if ($watch.Events.Count -gt 0) { return @{ Hint = ('External display detected: {0}' -f ($watch.Events -join '; ')); PassNote = ('Display detected: {0}' -f $watch.Events[0]); FailNote = 'Picture unstable / wrong' } }
            return @{ Hint = 'No new display was detected.  (R = watch again)'; FailNote = 'No picture on external display' }
        }
    })

    [void]$tests.Add(@{
        Name = 'Other ports'
        Steps = @('SD card reader and Ethernet port, if fitted: insert a card / plug in a network cable and check it works.',
            'Press S if the laptop has neither. If one fails, type which port in the note.')
    })

    if ($script:Facts.HasBattery) {
        [void]$tests.Add(@{
            Name = 'Charging'
            Steps = @('Automatic test: the tool watches the charger connection.')
            Action = {
                param($attempt)
                $initial = Get-AcOnline
                if ($null -eq $initial) { return @{ Hint = 'Power state is not readable - check the charging light by eye.' } }
                Write-Host '  1) UNPLUG the charger now.' -ForegroundColor White
                $unplug = Wait-Condition { (Get-AcOnline) -eq $false } $script:Config.PowerWaitSeconds
                if ($unplug -eq 'OK') { Write-Host '     Running on battery - OK' -ForegroundColor Green }
                elseif ($unplug -eq 'TIMEOUT') { Write-Host '     Still on charger power.' -ForegroundColor Yellow }
                Write-Host '  2) PLUG the charger back in.' -ForegroundColor White
                $plug = Wait-Condition { (Get-AcOnline) -eq $true } $script:Config.PowerWaitSeconds
                if ($plug -eq 'OK') { Write-Host '     Charger detected - OK' -ForegroundColor Green }
                if ($unplug -eq 'OK' -and $plug -eq 'OK') { Set-Result 'Charging' 'PASS' 'Runs on battery; charger detected'; return @{ Done = $true } }
                if ($unplug -eq 'OK' -and $plug -eq 'TIMEOUT') { Set-Result 'Charging' 'FAIL' 'Charger not detected - check adapter, cable and port'; return @{ Done = $true } }
                if ($plug -eq 'OK') { return @{ Hint = 'Charger works, but running on battery was not confirmed.'; PassNote = 'Charger detected' } }
                return @{ Hint = 'Check by eye: charging light on, Windows battery icon shows charging.'; FailNote = 'Not charging' }
            }
        })
    } else {
        [void]$tests.Add(@{ Name = 'Charging'; Steps = @('No battery - check the power adapter powers the computer.') })
    }

    [void]$tests.Add(@{
        Name = 'Sleep and wake'; Repeat = $true
        Steps = @('Close the lid (or Start > Power > Sleep), wait 10 seconds, then open it / press the power button.',
            'Screen, keyboard, touchpad, Wi-Fi and sound should all come back. This window stays open.')
        Action = {
            param($attempt)
            $since = (Get-Date).AddSeconds(-5)
            $answer = Read-Choice '  Put the laptop to sleep now. When it is awake again, press Enter  (S = skip)  > ' @('ENTER', 'S')
            if ($answer -eq 'S') { Set-Result 'Sleep and wake' 'SKIP' 'Not tested'; return @{ Done = $true } }
            $resume = Get-LastResumeTime $since
            if ($resume) {
                return @{ Hint = ('Windows recorded a wake-up at {0:HH:mm:ss}. Do screen, keyboard, touchpad, Wi-Fi and sound work?' -f $resume)
                    PassNote = ('Woke from sleep at {0:HH:mm}' -f $resume); FailNote = 'Problem after waking up' }
            }
            return @{ Hint = 'Windows did not record a sleep / wake since this test started (lid closed 10+ seconds?).  R = try again.'; FailNote = 'Does not sleep / wake correctly' }
        }
    })

    $skip = @($script:Config.SkipTests)
    $tests | Where-Object { $skip -notcontains $_.Name }   # one hashtable per test
}

function Invoke-Review {
    # Lets the inspector correct, re-test or add remarks before the final report is saved.
    while ($true) {
        Write-Heading 'REVIEW - CHECK THE RESULTS BEFORE SAVING'
        foreach ($r in $script:Results) {
            Write-Host ('  {0,2}. [{1,-4}] {2}' -f $r.No, $r.Status, $r.Name) -ForegroundColor $script:StatusColor[$r.Status] -NoNewline
            if ($r.Note) { Write-Host (' - ' + $r.Note) -ForegroundColor DarkGray } else { Write-Host '' }
        }
        if ($script:Inspection.Remarks) { Write-Host ('  Remarks: ' + $script:Inspection.Remarks) -ForegroundColor Gray }
        $typed = Read-Text '  Enter = finish   a number = change that result   N = remarks for the report'
        if (-not $typed) { return }
        if ($typed -match '^(?i)n$') {
            $script:Inspection.Remarks = Read-Text '  Remarks (Enter = keep)' $script:Inspection.Remarks
            continue
        }
        $number = 0
        if (-not [int]::TryParse((ConvertTo-LatinDigit $typed), [ref]$number)) { continue }
        $item = $script:Results | Where-Object { $_.No -eq $number } | Select-Object -First 1
        if (-not $item) { continue }
        $test = $script:TestIndex[$item.Name]
        $allowed = @('P', 'F', 'W', 'S')
        $prompt = '  New result for "{0}":  [P] Pass  [F] Fail  [W] Warning  [S] Skip' -f $item.Name
        if ($test) { $allowed += 'T'; $prompt += '  [T] Test again' }
        $choice = Read-Choice ($prompt + '  > ') $allowed
        if ($choice -eq 'T') {
            Invoke-GuidedTest -Test $test -Number 0 -Total 0 -FirstAttempt 2
            [void](Save-Report)
            continue
        }
        $newStatus = @{ P = 'PASS'; F = 'FAIL'; W = 'WARN'; S = 'SKIP' }[$choice]
        $note = Read-Text ('  Note (Enter = keep "{0}")' -f $item.Note) $item.Note
        if ($newStatus -eq 'SKIP' -and -not $note) { $note = 'Not tested' }
        Set-Result $item.Name $newStatus $note $item.Kind
    }
}

# ------------------------------------------------------------------ report
function Get-Counts {
    $c = @{}
    foreach ($s in @('PASS', 'FAIL', 'WARN', 'SKIP', 'N/A')) { $c[$s] = @($script:Results | Where-Object { $_.Status -eq $s }).Count }
    return $c
}

function Get-Overall {
    # One verdict for the device, matching the paper checklist: FUNCTIONAL / FUNCTIONAL WITH ISSUES / NOT FUNCTIONAL / INCOMPLETE.
    $c = Get-Counts
    $critical = @($script:Results | Where-Object { $_.Status -eq 'FAIL' -and @($script:Config.CriticalTests) -contains $_.Name })
    if ($critical.Count) {
        return [pscustomobject]@{ Code = 'NOT FUNCTIONAL'; Text = ('NOT FUNCTIONAL - failed: {0}' -f (($critical | ForEach-Object { $_.Name }) -join ', ')) }
    }
    if ($script:Inspection.Mode -eq 'Quick') {
        $extra = if ($c.FAIL -or $c.WARN) { ', {0} not working, {1} warning(s)' -f $c.FAIL, $c.WARN } else { '' }
        return [pscustomobject]@{ Code = 'INCOMPLETE'; Text = ('INCOMPLETE - quick inventory only' + $extra) }
    }
    $manual = @($script:Results | Where-Object { $_.Kind -eq 'Manual' -and $_.Status -ne 'N/A' })
    $manualSkipped = @($manual | Where-Object { $_.Status -eq 'SKIP' })
    if ($manual.Count -eq 0 -or ($manualSkipped.Count * 2) -gt $manual.Count) {
        return [pscustomobject]@{ Code = 'INCOMPLETE'; Text = ('INCOMPLETE - {0} of {1} physical tests not done' -f $manualSkipped.Count, $manual.Count) }
    }
    if ($c.FAIL -gt 0 -or $c.WARN -gt 0) {
        return [pscustomobject]@{ Code = 'FUNCTIONAL WITH ISSUES'; Text = ('FUNCTIONAL WITH ISSUES - {0} not working, {1} warning(s)' -f $c.FAIL, $c.WARN) }
    }
    if ($c.SKIP -gt 0) { return [pscustomobject]@{ Code = 'FUNCTIONAL'; Text = ('FUNCTIONAL - {0} item(s) not tested' -f $c.SKIP) } }
    return [pscustomobject]@{ Code = 'FUNCTIONAL'; Text = 'FUNCTIONAL - everything tested is working' }
}

function Get-OverallColor {
    param([string]$Code)
    switch ($Code) { 'NOT FUNCTIONAL' { 'Red' } 'FUNCTIONAL' { 'Green' } default { 'Yellow' } }
}

function Get-OrganizationLine {
    $parts = @()
    if ($script:Config.OrganizationName) { $parts += $script:Config.OrganizationName }
    if ($script:Config.SiteName) { $parts += ('Site: ' + $script:Config.SiteName) }
    return ($parts -join '  |  ')
}

function New-ReportLines {
    # The one-to-two page report: header, overall result, specifications, test table, problems, sign-off.
    # Each line has a Style the printer uses: Title, Sub, Overall, Section, Text, Bold, Small.
    $lines = New-Object System.Collections.ArrayList
    $add = { param([string]$Style, [string]$Text) [void]$lines.Add([pscustomobject]@{ Style = $Style; Text = $Text }) }
    $c = Get-Counts
    $overall = Get-Overall
    $minutes = [Math]::Max(1, [int]((Get-Date) - $script:Started).TotalMinutes)
    $inspector = if ($script:Inspection.Inspector) { $script:Inspection.Inspector } else { '-' }
    $assistant = if ($script:Inspection.Assistant) { $script:Inspection.Assistant } else { '-' }
    $mode = if ($script:Inspection.Mode -eq 'Quick') { 'Quick inventory (no physical tests)' } else { 'Full inspection' }
    $sub = Get-OrganizationLine
    if (-not $sub) { $sub = '{0} {1}' -f $script:ToolName, $script:ToolVersion }

    & $add 'Title' 'IT DEVICE INSPECTION REPORT'
    & $add 'Sub' $sub
    & $add 'Text' ''
    & $add 'Text' ('{0,-12}: {1,-32}{2,-12}: {3}' -f 'Asset tag', $script:Inspection.AssetTag, 'Item no.', $script:Inspection.ItemNumber)
    & $add 'Text' ('{0,-12}: {1,-32}{2,-12}: {3}' -f 'Date', (Get-Date -Format 'dd MMM yyyy  HH:mm'), 'Inspector', $inspector)
    & $add 'Text' ('{0,-12}: {1,-32}{2,-12}: {3} min' -f 'Assisted by', $assistant, 'Duration', $minutes)
    & $add 'Text' ('{0,-12}: {1}' -f 'Inspection', $mode)
    & $add 'Overall' ('OVERALL RESULT:  ' + $overall.Text)
    & $add 'Text' ('Working (PASS): {0}    Not working (FAIL): {1}    Warnings: {2}    Not tested: {3}' -f $c.PASS, $c.FAIL, $c.WARN, $c.SKIP)

    & $add 'Section' 'DEVICE SPECIFICATIONS'
    foreach ($item in $script:Spec) {
        $wrapped = Split-Wrap $item.Value ($script:ReportWidth - 22)
        & $add 'Text' ('{0,-20}: {1}' -f $item.Label, $wrapped[0])
        for ($i = 1; $i -lt $wrapped.Count; $i++) { & $add 'Text' ((' ' * 22) + $wrapped[$i]) }
    }

    & $add 'Section' 'TEST RESULTS'
    & $add 'Bold' ('{0,-3} {1,-28} {2,-7} {3}' -f 'No', 'Test', 'Result', 'Notes')
    $noteWidth = $script:ReportWidth - 41
    foreach ($r in $script:Results) {
        $wrapped = Split-Wrap $r.Note $noteWidth
        $style = if ($r.Status -eq 'FAIL') { 'Bold' } else { 'Text' }
        $name = if ($r.Name.Length -gt 28) { $r.Name.Substring(0, 28) } else { $r.Name }
        & $add $style ('{0,-3} {1,-28} {2,-7} {3}' -f $r.No, $name, $r.Status, $wrapped[0])
        for ($i = 1; $i -lt $wrapped.Count; $i++) { & $add $style ((' ' * 41) + $wrapped[$i]) }
    }

    $problems = @($script:Results | Where-Object { $_.Status -eq 'FAIL' -or $_.Status -eq 'WARN' })
    if ($problems.Count) {
        & $add 'Section' 'NOT WORKING / NEEDS ATTENTION'
        foreach ($p in $problems) {
            $label = if ($p.Status -eq 'FAIL') { 'NOT WORKING' } else { 'CHECK' }
            foreach ($w in (Split-Wrap ('- {0} ({1}): {2}' -f $p.Name, $label, $p.Note) $script:ReportWidth)) { & $add 'Bold' $w }
        }
    }
    $skipped = @($script:Results | Where-Object { $_.Status -eq 'SKIP' })
    if ($skipped.Count) {
        & $add 'Section' 'NOT TESTED'
        foreach ($w in (Split-Wrap (($skipped | ForEach-Object { $_.Name }) -join ', ') $script:ReportWidth)) { & $add 'Text' $w }
    }
    if ($script:Inspection.Remarks) {
        & $add 'Section' 'REMARKS'
        foreach ($w in (Split-Wrap $script:Inspection.Remarks $script:ReportWidth)) { & $add 'Text' $w }
    }

    $inspectedBy = if ($script:Inspection.Inspector) { $script:Inspection.Inspector } else { '______________________' }
    & $add 'Section' 'SIGN-OFF'
    & $add 'Text' ''
    & $add 'Text' ('Inspected by: {0,-22}   Signature: _______________   Date: ____________' -f $inspectedBy)
    & $add 'Text' ''
    & $add 'Text' 'Received by:  ______________________   Signature: _______________   Date: ____________'
    & $add 'Text' ''
    & $add 'Small' 'Automatic checks are read from Windows; physical tests were confirmed by the inspector. This is not a stress test.'
    & $add 'Small' ('{0} {1}' -f $script:ToolName, $script:ToolVersion)
    return , $lines.ToArray()
}

function ConvertTo-PlainText {
    param([object[]]$Lines)
    $sb = New-Object System.Text.StringBuilder
    foreach ($l in $Lines) {
        switch ($l.Style) {
            'Title' { [void]$sb.AppendLine('=' * $script:ReportWidth); [void]$sb.AppendLine($l.Text) }
            'Sub' { [void]$sb.AppendLine($l.Text); [void]$sb.AppendLine('=' * $script:ReportWidth) }
            'Overall' { [void]$sb.AppendLine(''); [void]$sb.AppendLine('>>> ' + $l.Text + ' <<<') }
            'Section' { [void]$sb.AppendLine(''); [void]$sb.AppendLine($l.Text); [void]$sb.AppendLine('-' * $script:ReportWidth) }
            default { [void]$sb.AppendLine($l.Text) }
        }
    }
    return $sb.ToString()
}

function Get-ToolProblemText {
    if ($script:ToolProblems.Count -eq 0) { return '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('-' * $script:ReportWidth)
    [void]$sb.AppendLine('THINGS THE TOOL COULD NOT DO')
    [void]$sb.AppendLine('-' * $script:ReportWidth)
    foreach ($p in $script:ToolProblems) { [void]$sb.AppendLine($p) }
    return $sb.ToString()
}

function Get-ReportBaseName {
    $f = $script:Facts
    $model = if ($f) { $f.Model } else { '' }
    $serial = if ($f -and $f.SerialOk) { $f.Serial } else { '' }
    return ('{0}_Item-{1}_{2}_SN-{3}_{4}' -f (Get-SafeFileToken $script:Inspection.AssetTag $script:UnrecordedTag 32),
        (Get-SafeFileToken $script:Inspection.ItemNumber $script:UnrecordedItem 24), (Get-SafeFileToken $model 'MODEL-UNKNOWN' 42),
        (Get-SafeFileToken $serial 'SERIAL-UNKNOWN' 42), $script:Stamp)
}

function Save-TextFile {
    # Writes into the report folder. If that fails (USB removed or write-protected), switches to Documents / Desktop.
    param([string]$FileName, [string]$Content, [switch]$NoBom)
    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList (-not $NoBom)
    for ($try = 0; $try -lt 2; $try++) {
        if ($script:ReportDir) {
            try {
                if (-not (Test-Path -LiteralPath $script:ReportDir)) { New-Item -ItemType Directory -Path $script:ReportDir -Force -ErrorAction Stop | Out-Null }
                $path = Join-Path $script:ReportDir $FileName
                [System.IO.File]::WriteAllText($path, $Content, $encoding)
                return $path
            } catch { Add-ToolProblem ('Saving ' + $FileName) $_ }
        }
        $fallback = Resolve-ReportFolder '' ''
        if (-not $fallback -or $fallback -eq $script:ReportDir) { break }
        Write-Host ('  Cannot write to {0} - saving to {1} instead.' -f $script:ReportDir, $fallback) -ForegroundColor Yellow
        $script:ReportDir = $fallback
    }
    return $null
}

function Save-Report {
    # Saves the text report (summary + technical appendix). Called after every test, so a freeze loses nothing.
    param([switch]$Final)
    if (-not $script:Facts) { return $null }
    $content = (ConvertTo-PlainText (New-ReportLines)) + "`r`n" + $script:Detail.ToString() + (Get-ToolProblemText)
    if (-not $Final) { $content = "*** INSPECTION IN PROGRESS - NOT FINAL ***`r`n" + $content }
    $path = Save-TextFile ((Get-ReportBaseName) + '.txt') $content
    if ($path) { $script:ReportPath = $path }
    return $path
}

function ConvertTo-ReportJson {
    # Machine-readable copy of the report, for inventory systems and scripts.
    $overall = Get-Overall
    $f = $script:Facts
    $device = [ordered]@{}
    if ($f) {
        $device = [ordered]@{
            manufacturer = $f.Manufacturer; model = $f.Model; serial = $f.Serial; serialReadable = [bool]$f.SerialOk
            processor = $f.Cpu; memory = $f.RamText; memoryGB = $f.RamGB; storage = @($f.Disks | ForEach-Object { $_.Text })
            batteryHealthPercent = $f.BatteryHealth; windows = $f.Windows; activation = $f.Activation; encryption = $f.Encryption
            computerName = $env:COMPUTERNAME
        }
    }
    $data = [ordered]@{
        tool = [ordered]@{ name = $script:ToolName; version = $script:ToolVersion }
        inspection = [ordered]@{
            assetTag = $script:Inspection.AssetTag; itemNumber = $script:Inspection.ItemNumber
            inspector = $script:Inspection.Inspector; assistedBy = $script:Inspection.Assistant
            organization = $script:Config.OrganizationName; site = $script:Config.SiteName
            mode = $script:Inspection.Mode; started = $script:Started.ToString('s'); finished = (Get-Date).ToString('s')
            overall = $overall.Code; summary = $overall.Text; remarks = $script:Inspection.Remarks; administrator = [bool]$script:IsAdmin
        }
        device = $device
        specifications = @($script:Spec | ForEach-Object { [ordered]@{ label = $_.Label; value = $_.Value } })
        results = @($script:Results | ForEach-Object { [ordered]@{ no = $_.No; name = $_.Name; kind = $_.Kind; status = $_.Status; note = $_.Note } })
        toolProblems = @($script:ToolProblems)
    }
    return (ConvertTo-Json -InputObject $data -Depth 6)
}

function New-LogRow {
    # One row of the device log (WinCheckup_Log.csv) - opens in Excel to update the inventory list.
    $c = Get-Counts
    $f = $script:Facts
    return [pscustomobject][ordered]@{
        Date = (Get-Date -Format 'yyyy-MM-dd HH:mm'); AssetTag = $script:Inspection.AssetTag; ItemNumber = $script:Inspection.ItemNumber
        Manufacturer = $f.Manufacturer; Model = $f.Model; Serial = $f.Serial; Processor = $f.Cpu
        RAM = $f.RamText; Storage = (@($f.Disks | ForEach-Object { $_.Text }) -join ' | ')
        BatteryHealthPct = $f.BatteryHealth; Windows = $f.Windows; Activation = $f.Activation; Encryption = $f.Encryption
        Mode = $script:Inspection.Mode; Overall = (Get-Overall).Text; Passed = $c.PASS; Failed = $c.FAIL; Warnings = $c.WARN; NotTested = $c.SKIP
        NotWorking = ((@($script:Results | Where-Object { $_.Status -eq 'FAIL' }) | ForEach-Object { '{0}: {1}' -f $_.Name, $_.Note }) -join ' | ')
        Remarks = $script:Inspection.Remarks; Inspector = $script:Inspection.Inspector; AssistedBy = $script:Inspection.Assistant
        Site = $script:Config.SiteName; ReportFile = $(if ($script:ReportPath) { Split-Path -Leaf $script:ReportPath } else { '' })
        ToolVersion = $script:ToolVersion
    }
}

function Get-LogNames {
    $major = ($script:ToolVersion -split '\.')[0]
    return @(($script:ToolName + '_Log.csv'), ('{0}_Log_v{1}.csv' -f $script:ToolName, $major))
}

function Add-InspectionLog {
    # Appends the device row. A log written by an older version (other columns) is left alone and a new one started.
    param([string]$Folder)
    $row = New-LogRow
    $header = @($row | ConvertTo-Csv -NoTypeInformation)[0]
    $targets = New-Object System.Collections.Generic.List[string]
    foreach ($name in (Get-LogNames)) {
        $path = Join-Path $Folder $name
        if (-not (Test-Path -LiteralPath $path)) { $targets.Add($path); break }
        $existing = Get-Content -LiteralPath $path -TotalCount 1 -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($existing -eq $header) { $targets.Add($path); break }
    }
    $targets.Add((Join-Path $Folder ('{0}_Log_{1}.csv' -f $script:ToolName, $script:Stamp)))   # used when the log is open in Excel
    foreach ($path in $targets) {
        try {
            $row | Export-Csv -LiteralPath $path -Append -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
            return $path
        } catch { Add-ToolProblem ('Device log ' + (Split-Path -Leaf $path)) $_ }
    }
    return $null
}

function Get-LastInspector {
    # The inspector of the newest row in the device log, offered as the default name.
    param([string]$Folder)
    if (-not $Folder) { return '' }
    $names = Get-LogNames
    [array]::Reverse($names)
    foreach ($name in $names) {
        $path = Join-Path $Folder $name
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            $last = Import-Csv -LiteralPath $path -Encoding UTF8 -ErrorAction Stop | Select-Object -Last 1
            if ($last -and $last.Inspector) { return [string]$last.Inspector }
        } catch { }
    }
    return ''
}

function Save-BatteryReport {
    # Windows' own battery report (capacity history, recent usage) saved next to the inspection report.
    if (-not $script:Config.SaveBatteryReport -or -not $script:Facts -or -not $script:Facts.HasBattery -or -not $script:ReportPath) { return $null }
    $path = $script:ReportPath -replace '\.txt$', '_battery.html'
    try {
        $powercfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'
        $null = & $powercfg /batteryreport /output $path /duration 14 2>&1
        if (Test-Path -LiteralPath $path) { return $path }
        Add-ToolProblem 'Battery report' 'powercfg did not create the file'
    } catch { Add-ToolProblem 'Battery report' $_ }
    return $null
}

# ------------------------------------------------------------------ printing
$script:VirtualPrinterPattern = '(?i)pdf|xps|onenote|fax|send to|snagit|document writer|print to file'
$script:VirtualPortPattern = '(?i)^(portprompt:|nul:|shrfax:|file:|xpsport:|pdf|microsoft\.office|onenote)'

function Get-RealPrinters {
    # Physical printers only, best first: preferred name, Windows default, online, USB-connected.
    $all = @(Get-CimInstance -ClassName Win32_Printer -ErrorAction SilentlyContinue)
    $real = @($all | Where-Object { $_.Name -notmatch $script:VirtualPrinterPattern -and [string]$_.PortName -notmatch $script:VirtualPortPattern })
    $preferred = $script:Config.PreferredPrinter
    return , @($real | Sort-Object -Property @(
            @{ Expression = { if ($preferred -and $_.Name -like ('*' + $preferred + '*')) { 0 } else { 1 } } },
            @{ Expression = { if ($_.Default) { 0 } else { 1 } } },
            @{ Expression = { if ($_.WorkOffline -or [int]$_.PrinterStatus -eq 7) { 1 } else { 0 } } },
            @{ Expression = { if ([string]$_.PortName -like 'USB*') { 0 } else { 1 } } }
        ))
}

function Send-ReportToPrinter {
    # Draws the report with GDI+: monospace body so the table columns line up, bold headings, page numbers.
    param([object[]]$Lines, [string]$PrinterName, [string]$PdfPath)
    $doc = New-Object System.Drawing.Printing.PrintDocument
    $fonts = @{}
    $pen = $null
    try {
        $doc.DocumentName = 'Device inspection ' + $script:Inspection.AssetTag
        $doc.PrinterSettings.PrinterName = $PrinterName
        if (-not $doc.PrinterSettings.IsValid) { throw ('Printer "{0}" is not available.' -f $PrinterName) }
        if ($PdfPath) {
            $doc.PrinterSettings.PrintToFile = $true
            $doc.PrinterSettings.PrintFileName = $PdfPath
        } else {
            $doc.PrinterSettings.Copies = [int16][Math]::Max(1, $script:Config.PrintCopies)
        }
        $doc.PrintController = New-Object System.Drawing.Printing.StandardPrintController
        $doc.DefaultPageSettings.Margins = New-Object System.Drawing.Printing.Margins(50, 50, 45, 45)

        $mono = 'Consolas'
        $probe = New-Object System.Drawing.Font($mono, 9)
        if ($probe.Name -ne $mono) { $mono = 'Courier New' }
        $probe.Dispose()
        $bold = [System.Drawing.FontStyle]::Bold
        $fonts.Title = New-Object System.Drawing.Font('Segoe UI', 15, $bold)
        $fonts.Sub = New-Object System.Drawing.Font('Segoe UI', 9.5)
        $fonts.Overall = New-Object System.Drawing.Font('Segoe UI', 11.5, $bold)
        $fonts.Section = New-Object System.Drawing.Font('Segoe UI', 10.5, $bold)
        $fonts.Text = New-Object System.Drawing.Font($mono, 8.6)
        $fonts.Bold = New-Object System.Drawing.Font($mono, 8.6, $bold)
        $fonts.Small = New-Object System.Drawing.Font('Segoe UI', 7)
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, 1)
        $state = @{ Index = 0; Page = 0 }

        $doc.add_PrintPage({
            param($src, $e)
            $g = $e.Graphics
            $box = $e.MarginBounds
            $state.Page++
            $y = [single]$box.Top
            $bottom = [single]($box.Bottom - $fonts.Small.GetHeight($g) - 8)
            $drawn = 0
            while ($state.Index -lt $Lines.Count) {
                $line = $Lines[$state.Index]
                $font = $fonts[$line.Style]
                if (-not $font) { $font = $fonts.Text }
                $h = [single]$font.GetHeight($g)
                $textWidth = [single]($box.Width - 16)
                if ($line.Style -eq 'Overall') { $h = [single]$g.MeasureString($line.Text, $font, [int]$textWidth).Height }   # long verdicts wrap
                $before = switch ($line.Style) { 'Section' { 10 } 'Overall' { 8 } default { 0 } }
                $after = switch ($line.Style) { 'Section' { 5 } 'Overall' { 6 } 'Sub' { 6 } default { 0 } }
                if ($drawn -gt 0 -and ($y + $before + $h + $after) -gt $bottom) { break }
                $y += $before
                if ($line.Style -eq 'Overall') {
                    $g.DrawRectangle($pen, [single]$box.Left, [single]($y - 3), [single]$box.Width, [single]($h + 6))
                    $g.DrawString($line.Text, $font, [System.Drawing.Brushes]::Black, (New-Object System.Drawing.RectangleF([single]($box.Left + 8), $y, $textWidth, $h)))
                } else {
                    $g.DrawString($line.Text, $font, [System.Drawing.Brushes]::Black, [single]$box.Left, $y)
                }
                $y += $h
                if ($line.Style -eq 'Section' -or $line.Style -eq 'Sub') { $g.DrawLine($pen, [single]$box.Left, [single]($y + 1), [single]$box.Right, [single]($y + 1)) }
                $y += $after
                $state.Index++
                $drawn++
            }
            $footer = 'Asset tag {0}  |  Item {1}  |  Page {2}' -f $script:Inspection.AssetTag, $script:Inspection.ItemNumber, $state.Page
            $g.DrawString($footer, $fonts.Small, [System.Drawing.Brushes]::DimGray, [single]$box.Left, [single]($box.Bottom - $fonts.Small.GetHeight($g)))
            $e.HasMorePages = ($state.Index -lt $Lines.Count)
        })
        $doc.Print()
    } finally {
        foreach ($f in $fonts.Values) { $f.Dispose() }
        if ($pen) { $pen.Dispose() }
        $doc.Dispose()
    }
}

function Save-PdfCopy {
    # Silent PDF through the built-in "Microsoft Print to PDF" printer, saved next to the .txt report.
    param([object[]]$Lines)
    if (-not $script:Config.SavePdfCopy -or -not $script:UiReady -or -not $script:ReportPath) { return $null }
    $pdfPrinter = Get-CimInstance -ClassName Win32_Printer -Filter "Name='Microsoft Print to PDF'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pdfPrinter) { Add-ToolProblem 'PDF copy' '"Microsoft Print to PDF" is not installed'; return $null }
    $pdfPath = [System.IO.Path]::ChangeExtension($script:ReportPath, '.pdf')
    try {
        Send-ReportToPrinter -Lines $Lines -PrinterName $pdfPrinter.Name -PdfPath $pdfPath
        for ($i = 0; $i -lt 20 -and -not (Test-Path -LiteralPath $pdfPath); $i++) { Start-Sleep -Milliseconds 250 }
        if (Test-Path -LiteralPath $pdfPath) { return $pdfPath }
        Add-ToolProblem 'PDF copy' 'the PDF file did not appear'
    } catch { Add-ToolProblem 'PDF copy' $_ }
    return $null
}

function Invoke-Printing {
    param([object[]]$Lines, [string]$PlainText)
    Write-Heading 'PRINTING'
    $choose = $false
    while ($true) {
        $printers = Get-RealPrinters
        if ($printers.Count -eq 0) {
            Write-Host '  No printer found. Connect the printer (USB cable or network), switch it on and wait for' -ForegroundColor Yellow
            Write-Host '  Windows to finish installing it.' -ForegroundColor Yellow
            if ((Read-Choice '  [R] Retry   [Enter] Skip printing  > ' @('R', 'ENTER')) -eq 'R') { continue }
            return $false
        }
        $target = $printers[0]
        if ($choose -or ($printers.Count -gt 1 -and -not $target.Default -and -not $script:Config.PreferredPrinter)) {
            for ($i = 0; $i -lt $printers.Count; $i++) { Write-Host ('   {0}. {1}{2}' -f ($i + 1), $printers[$i].Name, $(if ($printers[$i].Default) { '  (default)' } else { '' })) }
            $pick = 0
            $typed = Read-Text '  Choose printer number (Enter = 1)' '1'
            if ([int]::TryParse((ConvertTo-LatinDigit $typed), [ref]$pick) -and $pick -ge 1 -and $pick -le $printers.Count) { $target = $printers[$pick - 1] }
            $choose = $false
        }
        if ($target.WorkOffline -or [int]$target.PrinterStatus -eq 7) {
            Write-Host ('  Windows reports "{0}" as OFFLINE - check it is switched on and connected.' -f $target.Name) -ForegroundColor Yellow
        }
        Write-Host ('  Printing to: {0} ...' -f $target.Name) -ForegroundColor White
        $sent = $false
        if ($script:UiReady) {
            try { Send-ReportToPrinter -Lines $Lines -PrinterName $target.Name; $sent = $true }
            catch {
                Write-Host ('  Formatted printing failed: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
                Add-ToolProblem 'Printing' $_
            }
        }
        if (-not $sent) {
            try { $PlainText | Out-Printer -Name $target.Name -ErrorAction Stop; $sent = $true }
            catch {
                Write-Host ('  Printing failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
                Add-ToolProblem 'Printing (plain text)' $_
            }
        }
        if ($sent) { Write-Host '  Sent to the printer.' -ForegroundColor Green }
        $next = Read-Choice '  [Enter] Done   [R] Print again   [C] Choose another printer  > ' @('ENTER', 'R', 'C')
        if ($next -eq 'ENTER') { return $sent }
        if ($next -eq 'C') { $choose = $true }
    }
}

# ------------------------------------------------------------------ start-up
function ConvertTo-FullPath {
    # Command-line paths are relative to the folder the tool was started from.
    param([string]$Path)
    if (-not $Path) { return $Path }
    try { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) } catch { return $Path }
}

function Format-ProcessArgument {
    # Quotes one argument for a Windows command line (CommandLineToArgvW rules).
    param([string]$Value)
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Get-RelaunchArguments {
    # Command line for the elevated copy: same script, same parameters, plus -NoElevate.
    param([string]$ScriptPath, [System.Collections.IDictionary]$Bound)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($p in @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Format-ProcessArgument $ScriptPath))) { $parts.Add($p) }
    if ($Bound) {
        foreach ($key in @($Bound.Keys | Sort-Object)) {
            if ($key -eq 'NoElevate') { continue }
            $value = $Bound[$key]
            if ($value -is [System.Management.Automation.SwitchParameter] -or $value -is [bool]) {
                if ([bool]$value) { $parts.Add('-' + $key) }
            } else {
                $parts.Add('-' + $key)
                $parts.Add((Format-ProcessArgument ([string]$value)))
            }
        }
    }
    $parts.Add('-NoElevate')
    return ($parts -join ' ')
}

function Get-UncPath {
    # A drive letter mapped by the normal user does not exist for the elevated copy; use \\server\share\... instead.
    param([string]$Path)
    try {
        $qualifier = Split-Path -Qualifier $Path -ErrorAction Stop
        $drive = Get-PSDrive -Name $qualifier.TrimEnd(':') -PSProvider FileSystem -ErrorAction Stop
        if ($drive.DisplayRoot -and $drive.DisplayRoot.StartsWith('\\')) { return $drive.DisplayRoot.TrimEnd('\') + $Path.Substring($qualifier.Length) }
    } catch { }   # not a drive path, or not a mapped drive
    return $Path
}

function Request-Elevation {
    # Starts an elevated copy. True = it is running (this copy should exit); false = carry on here.
    param([System.Collections.IDictionary]$Bound)
    # The elevated copy starts in System32, so relative paths are made absolute first.
    $pass = [ordered]@{}
    if ($Bound) { foreach ($key in $Bound.Keys) { $pass[$key] = $Bound[$key] } }
    foreach ($key in @('ReportFolder', 'ConfigPath')) {
        if ($pass.Contains($key) -and $pass[$key]) { $pass[$key] = Get-UncPath (ConvertTo-FullPath ([string]$pass[$key])) }
    }
    try {
        $argLine = Get-RelaunchArguments (Get-UncPath $PSCommandPath) $pass
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -Verb RunAs -PassThru -ErrorAction Stop
    } catch { return $false }   # the inspector clicked No
    # If the elevated copy stops at once (for example it cannot reach the script), carry on here instead of vanishing.
    try { if ($process -and $process.WaitForExit(4000) -and $process.ExitCode -ne 0) { return $false } } catch { }
    return $true
}

function Initialize-Console {
    try {
        $Host.UI.RawUI.WindowTitle = ('{0} {1} - device inspection' -f $script:ToolName, $script:ToolVersion)
        $raw = $Host.UI.RawUI
        $width = [Math]::Min(112, $raw.MaxPhysicalWindowSize.Width)
        if ($raw.BufferSize.Width -lt $width) { $raw.BufferSize = New-Object Management.Automation.Host.Size($width, 3000) }
        if ($raw.WindowSize.Width -lt $width) { $raw.WindowSize = New-Object Management.Automation.Host.Size($width, [Math]::Min(42, $raw.MaxPhysicalWindowSize.Height)) }
    } catch { }   # cosmetic only (Windows Terminal manages its own size)
}

function Initialize-Ui {
    if ($script:FullLanguage -and -not ('System.Windows.Forms.Form' -as [type])) {
        try { Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction Stop } catch { Add-ToolProblem 'Windows Forms' $_ }
    }
    if ($script:FullLanguage -and -not ('WinCheckup.SpeakerVolume' -as [type])) {
        # Normally compiled during the hardware reading; needed here when that reading timed out early.
        try { Add-Type -TypeDefinition $script:NativeSource -Language CSharp -ErrorAction Stop } catch { Add-ToolProblem 'Sound helpers (volume / microphone meter)' $_ }
    }
    $script:UiReady = $script:FullLanguage -and [bool]('System.Windows.Forms.Form' -as [type])
    $script:WpfKeyboard = [bool]('System.Windows.Input.Keyboard' -as [type])
    if ($script:UiReady) { try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { } }
}

function Write-Banner {
    Write-Host ''
    Write-Host ('  {0} {1}  -  IT DEVICE INSPECTION' -f $script:ToolName.ToUpperInvariant(), $script:ToolVersion) -ForegroundColor Cyan
    $org = Get-OrganizationLine
    if ($org) { Write-Host ('  ' + $org) -ForegroundColor DarkGray }
    if (-not $script:IsAdmin) { Write-Host '  Running WITHOUT administrator rights - some health data will be missing.' -ForegroundColor Yellow }
    Write-Host ''
}

function Read-InspectionDetails {
    # The questions at the start. The hardware is read in the background meanwhile.
    if ($script:Inspection.Mode -eq 'Full') {
        $pick = Read-Choice '  [Enter] Full inspection (10-15 min)    [Q] Quick inventory only (1 min)  > ' @('ENTER', 'Q')
        if ($pick -eq 'Q') { $script:Inspection.Mode = 'Quick' }
    }
    if ($Inspector) { $script:Inspection.Inspector = $Inspector }
    elseif ($script:Config.InspectorName) { $script:Inspection.Inspector = $script:Config.InspectorName }
    else {
        $last = Get-LastInspector $script:ReportDir
        $prompt = if ($last) { '  Inspector name (Enter = {0})' -f $last } else { '  Inspector name' }
        $script:Inspection.Inspector = Read-Text $prompt $last
    }
    if ($AssetTag) { $script:Inspection.AssetTag = $AssetTag }
    else {
        $example = if ($script:Config.AssetTagExample) { ' (e.g. {0})' -f $script:Config.AssetTagExample } else { '' }
        $script:Inspection.AssetTag = Read-Text ('  Asset tag' + $example) $script:UnrecordedTag
    }
    if ($ItemNumber) { $script:Inspection.ItemNumber = $ItemNumber }
    elseif ($script:Config.AskItemNumber) { $script:Inspection.ItemNumber = Read-Text '  Inventory item number (Enter if none)' $script:UnrecordedItem }
    if ($script:Config.AskAssistant) { $script:Inspection.Assistant = Read-Text '  Assisted by (Enter to skip)' '' }
}

function Complete-Inspection {
    # Final files: text report, PDF, battery report, device log row and JSON. Returns their paths.
    $files = [ordered]@{ Text = (Save-Report -Final); Pdf = $null; Battery = $null; Log = $null; Json = $null }
    if (-not $files.Text) { return [pscustomobject]$files }
    $problemsBefore = $script:ToolProblems.Count
    $files.Pdf = Save-PdfCopy (New-ReportLines)
    $files.Battery = Save-BatteryReport
    $files.Log = Add-InspectionLog (Split-Path -Parent $files.Text)
    $files.Json = Save-TextFile ((Get-ReportBaseName) + '.json') (ConvertTo-ReportJson) -NoBom
    if ($script:ToolProblems.Count -ne $problemsBefore) { [void](Save-Report -Final) }
    return [pscustomobject]$files
}

function Show-Result {
    param($Files)
    Write-Heading 'RESULT'
    $overall = Get-Overall
    Write-Host ('  ' + $overall.Text) -ForegroundColor (Get-OverallColor $overall.Code)
    if ($Files.Text) { Write-Host ('  Report       : {0}' -f $Files.Text) -ForegroundColor Green }
    else { Write-Host '  The report could not be saved (USB write-protected or removed?).' -ForegroundColor Red }
    if ($Files.Pdf) { Write-Host ('  PDF copy     : {0}' -f $Files.Pdf) -ForegroundColor Green }
    if ($Files.Json) { Write-Host ('  JSON         : {0}' -f $Files.Json) -ForegroundColor Green }
    if ($Files.Battery) { Write-Host ('  Battery      : {0}' -f $Files.Battery) -ForegroundColor Green }
    if ($Files.Log) { Write-Host ('  Device log   : {0}' -f $Files.Log) -ForegroundColor Green }
}

function Show-Finish {
    while ($true) {
        $choice = Read-Choice '  [Enter] Close   [O] Open the reports folder  > ' @('ENTER', 'O')
        if ($choice -eq 'ENTER') { return }
        try {
            if ($script:ReportPath) { Start-Process 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $script:ReportPath) }
            elseif ($script:ReportDir) { Start-Process 'explorer.exe' -ArgumentList ('"{0}"' -f $script:ReportDir) }
        } catch { Write-Host ('  Could not open Explorer: {0}' -f $_.Exception.Message) -ForegroundColor Yellow }
    }
}

# ------------------------------------------------------------------ main
function Invoke-Main {
    param([System.Collections.IDictionary]$Bound)
    Initialize-State
    $loaded = Import-ToolConfig -ScriptRoot $script:RootDir -ExplicitPath (ConvertTo-FullPath $ConfigPath)
    $script:Config = $loaded.Config
    if ($ReportFolder) { $script:Config.ReportFolder = ConvertTo-FullPath $ReportFolder }
    $interactive = -not $Unattended
    if ($Quick -or $Unattended) { $script:Inspection.Mode = 'Quick' }

    if (-not $script:IsAdmin -and -not $NoElevate -and $interactive) {
        if (Request-Elevation $Bound) { exit 0 }   # the elevated copy carries on in its own window
        Write-Host 'Continuing without administrator rights - some checks are limited.' -ForegroundColor Yellow
        Write-Host '(Battery wear, disk wear, TPM and BitLocker may show as unknown.)' -ForegroundColor Yellow
        Start-Sleep -Seconds 2
    }

    if ($interactive) { Initialize-Console; Clear-Host }
    Write-Banner
    foreach ($w in $loaded.Warnings) { Write-Host ('  Settings: ' + $w) -ForegroundColor Yellow }
    $script:ReportDir = Resolve-ReportFolder $script:Config.ReportFolder $script:RootDir
    if (-not $script:ReportDir) { Write-Host '  WARNING: no folder can be written here - the report cannot be saved.' -ForegroundColor Red }

    $job = Start-Inventory
    try {
        if ($interactive) { Read-InspectionDetails }
        else {
            $script:Inspection.Inspector = if ($Inspector) { $Inspector } else { $script:Config.InspectorName }
            if ($AssetTag) { $script:Inspection.AssetTag = $AssetTag }
            if ($ItemNumber) { $script:Inspection.ItemNumber = $ItemNumber }
        }

        if (-not $interactive) { Write-Host '  Reading hardware information...' -ForegroundColor DarkCyan }
        $inventory = Wait-Inventory $job $script:Config.InventoryTimeoutSeconds -Animate:$interactive
        Initialize-Ui
        $built = Get-DeviceSpec $inventory
        $script:Spec = $built.Spec
        $script:Facts = $built.Facts
        Write-Heading 'DEVICE SPECIFICATIONS'
        foreach ($item in $script:Spec) {
            Write-Host ('  {0,-20}' -f $item.Label) -ForegroundColor DarkGray -NoNewline
            Write-Host $item.Value -ForegroundColor White
        }
        Invoke-AutoChecks $inventory $script:Facts
        Write-DetailedInventory $inventory
        [void](Save-Report)

        if ($script:Inspection.Mode -eq 'Full') {
            $tests = @(Get-GuidedTests)
            foreach ($t in $tests) { $script:TestIndex[$t.Name] = $t }
            Write-Host ''
            Write-Host ('  {0} physical tests follow. Answer each with ONE key: P = pass, F = fail, S = skip.' -f $tests.Count) -ForegroundColor White
            for ($i = 0; $i -lt $tests.Count; $i++) {
                Invoke-GuidedTest $tests[$i] ($i + 1) $tests.Count
                [void](Save-Report)
            }
            Restore-SpeakerVolume
        }
        if ($interactive) { Invoke-Review }
        Restore-SpeakerVolume

        $files = Complete-Inspection
        Show-Result $files
        if (-not $files.Text) { $script:ExitCode = 2 }
        if ($interactive -and $script:Config.AutoPrint -and -not $NoPrint) { [void](Invoke-Printing (New-ReportLines) (ConvertTo-PlainText (New-ReportLines))) }
    } catch {
        $script:ExitCode = 1
        Write-Host ''
        Write-Host ('  Something went wrong: {0}' -f $_.Exception.Message) -ForegroundColor Red
        Write-Host ('  (line {0})' -f $_.InvocationInfo.ScriptLineNumber) -ForegroundColor DarkGray
        Add-ToolProblem ('Stopped at line {0}' -f $_.InvocationInfo.ScriptLineNumber) $_
        try {
            $partial = Save-Report
            if ($partial) { Write-Host ('  Results so far were saved to: {0}' -f $partial) -ForegroundColor Yellow }
        } catch { Write-Host ('  The partial report could not be saved: {0}' -f $_.Exception.Message) -ForegroundColor Red }
    } finally {
        Restore-SpeakerVolume
        if ($interactive) {
            Write-Host ''
            try { Show-Finish } catch { }
        }
    }
}

# Run unless dot-sourced (the tests load the functions with ". .\WinCheckup.ps1").
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main -Bound $PSBoundParameters
    exit $script:ExitCode
}
