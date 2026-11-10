# WinCheckup

<img src="assets/WinCheckup.png" width="72" align="right" alt="">

WinCheckup walks you through a hardware check of a Windows 10 or 11 laptop or desktop and prints a one-page report at the end. I wrote it for inspecting laptops before they are handed out, when they come back, and during inventory counts.

A full check takes 10 to 15 minutes. The tool reads the specification and health data from Windows, then takes you through the physical tests one at a time. You answer each test with one key: P for pass, F for fail, S for skip.

It is a single PowerShell script that runs on the Windows PowerShell 5.1 already present on every Windows 10 and 11 machine. It installs nothing on the computer being checked and does not use the network. The only setting it changes is the speaker volume during the sound tests, and it sets the volume back afterwards.

## Download

Get the files from the [latest release](../../releases/latest):

- `WinCheckup-x.y.z-portable.zip` is for checking many machines from a USB stick. Unzip it onto the stick and double-click `WinCheckup.cmd` on each machine. Reports are saved on the stick.
- `WinCheckup-x.y.z-setup.exe` installs the tool in Program Files with a Start menu shortcut. Run it with `/S` for a silent install.

The files are not code-signed yet, so SmartScreen warns about them the first time. Click "More info" and then "Run anyway". `SHA256SUMS.txt` lists the checksum of each file.

## What it checks

From Windows, without your help:

| Area | What is recorded |
| --- | --- |
| Identity | Manufacturer, model and serial number. When the BIOS serial is blank or "To be filled by O.E.M.", the chassis or product serial is used instead. |
| Hardware | Processor, memory size, type, speed and module layout, graphics, display size and resolution |
| Storage | Drive health, SSD wear and power-on hours. The USB stick the tool runs from is left out. |
| Battery | Health as a percentage of design capacity, and charge cycles |
| Windows | Edition, version, activation, TPM, Secure Boot and BitLocker |
| Problems | Device Manager errors, hardware errors in the event log over the last 30 days, a missing graphics driver, and a system clock set earlier than the BIOS date (a sign of a flat clock battery) |

With you, one test at a time:

| Test | What happens |
| --- | --- |
| Physical condition | A checklist of what to look at, including a swollen battery |
| Screen | Full-screen colours for spotting dead pixels, lines and uneven backlight |
| Keyboard | A keyboard map where each key turns green when Windows receives it. Left and right Shift, Ctrl and Alt are checked separately. |
| Touchpad | Pointer movement, left click, right click and two-finger scroll are each detected |
| Camera | Opens the Camera app, then closes it after you answer |
| Speakers and headphone jack | A tone plays on the left, then on the right |
| Microphone | A level meter that shows the loudest sound picked up |
| Wi-Fi | Passes on its own once Windows reports an internet connection |
| Bluetooth | Checks for a radio and opens the Bluetooth settings so you can scan for a device |
| USB ports | Names each device as you plug it in |
| Video output | Detects a monitor connected over HDMI, DisplayPort or USB-C |
| SD card reader, Ethernet | Checked by hand if the machine has them |
| Charging | Detects the charger being unplugged and plugged back in |
| Sleep and wake | Confirms from the event log that the machine actually slept and woke up |
| Touchscreen, fingerprint reader | Only offered when Windows reports one |

Before the report is saved you can review the results, change any of them, run a test again, or add remarks.

## The result

Each machine gets one of four results:

- FUNCTIONAL: everything that was tested works.
- FUNCTIONAL WITH ISSUES: something failed or needs attention.
- NOT FUNCTIONAL: a critical test failed. By default the critical tests are the screen, keyboard, storage health and charging.
- INCOMPLETE: only the quick inventory was run, or more than half of the physical tests were skipped.

## Reports

Reports are saved in a `Reports` folder next to the tool. When that folder cannot be written to, for example under Program Files or on a write-protected stick, they go to `Documents\WinCheckup Reports` instead.

For each machine you get:

- a text report with a technical appendix,
- a PDF of the printed page,
- a JSON copy for scripts and inventory systems,
- the Windows battery report (laptops only),
- one row in `WinCheckup_Log.csv`, which opens in Excel.

File names are built from the asset tag, item number, model, serial number and time, for example `PC-0042_Item-17_EliteBook-840-G8_SN-5CG1234XYZ_20261110_101500.txt`.

The text report is saved again after every test, so a crash or a flat battery does not lose the results so far.

## Settings

Settings live in `config.json` next to the script. Settings in `%APPDATA%\WinCheckup\config.json` override them for one Windows user. A few examples:

```json
{
  "OrganizationName": "Example IT Services",
  "SiteName": "Main office",
  "AssetTagExample": "PC-0001",
  "PreferredPrinter": "LaserJet",
  "BatteryWarnBelow": 70,
  "BatteryFailBelow": 50,
  "CriticalTests": ["Screen / display", "Keyboard", "Storage health", "Charging"],
  "SkipTests": ["Fingerprint reader"]
}
```

A misspelled setting or a value of the wrong type is reported when the tool starts, and the default is used instead. [`src/config.json`](src/config.json) lists every setting.

## Command line

```
WinCheckup.cmd                                       full check
WinCheckup.cmd -Quick                                specification and automatic checks only
WinCheckup.cmd -AssetTag PC-0042 -ItemNumber 17 -NoPrint
WinCheckup.cmd -Unattended -AssetTag PC-0042 -ReportFolder D:\Inventory
```

`-Unattended` asks no questions, does not print and does not wait for a key, so it can be run from a script. It exits with 0 when the report was saved, 1 on an error, and 2 when the report could not be saved.

`Get-Help .\WinCheckup.ps1 -Full` shows every option.

## Building from source

You need PowerShell 7 or Windows PowerShell 5.1. Building `setup.exe` also needs [NSIS 3](https://nsis.sourceforge.io/) (`winget install NSIS.NSIS`, `brew install makensis` or `apt install nsis`).

```
./build.ps1                  # writes the zip, setup.exe and SHA256SUMS.txt to dist/
./build.ps1 -SkipInstaller   # zip only
Invoke-Pester ./tests        # unit tests, Pester 5
```

Every push runs the linter and the tests on Windows PowerShell 5.1 and PowerShell 7. It also runs an unattended check of the GitHub Windows runner and builds the release files. Pushing a tag such as `v1.0.1` publishes a release with those files.

## Contributing

Bug reports and pull requests are welcome. Three rules keep the tool working everywhere:

- It must run on Windows PowerShell 5.1 with nothing extra installed.
- `src/WinCheckup.ps1` must stay plain ASCII. Windows PowerShell 5.1 reads a file without a byte order mark in the local code page, so other characters can turn into garbage.
- Changes in behaviour need a test in `tests/`.

## License

MIT. See [LICENSE](LICENSE).
