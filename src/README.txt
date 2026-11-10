WINCHECKUP - IT DEVICE INSPECTION
=================================

A guided inspection for Windows 10 / 11 laptops and desktops. It reads the
device specification, runs automatic health checks, walks you through the
physical tests and prints a one-to-two page report.

Nothing is installed on the device being inspected and no settings are
changed, except the speaker volume during the sound tests (it is put back
at the end).


START
-----
1. Double-click  WinCheckup.cmd
   (installed version: Start menu > WinCheckup)
2. Click "Yes" when Windows asks for administrator permission.
   Without it, battery wear, disk wear, TPM and BitLocker show as unknown.
3. Choose  [Enter] Full inspection (10-15 min)  or  [Q] Quick inventory (1 min).
4. Type the inspector name, asset tag and item number. The hardware is read
   in the background while you type.


THE TESTS
---------
Answer each test with ONE key:  P = pass   F = fail   S = skip   R = repeat

 Physical condition   Look over the case, hinges, screen, keys, feet, ports.
                      A SWOLLEN BATTERY is a FAIL - do not charge that device.
 Screen / display     Full-screen colours. Click or press Space for the next
                      one. Look for dead dots, lines, patches, flicker.
 Keyboard             A keyboard map opens. Press every key; each turns green.
                      Click FINISH TEST (or press Esc three times).
 Touchpad / mouse     The grey box in the same window: move, left click,
                      right click, two-finger scroll.
 Touchscreen          Only shown when Windows detects one.
 Fingerprint reader   Only shown when Windows detects one.
 Camera               The Camera app opens and closes again after you answer.
 Speakers             A tone plays LEFT, then RIGHT.
 Headphone jack       Plug in headphones, press Enter, a quieter tone plays.
 Microphone           A level meter opens. Speak or clap; the bar should jump.
 Wi-Fi                Connect to a network. Passes by itself once the
                      internet works.
 Bluetooth            Bluetooth settings open. Scan for a phone or headset.
 USB ports            Plug a flash drive or mouse into each port in turn.
                      Every plug-in is listed. Press Enter when finished.
 Video out            Connect a monitor (HDMI / DisplayPort / USB-C). The new
                      display is listed. S = no port or no monitor.
 Other ports          SD card reader and Ethernet, if fitted.
 Charging             Unplug the charger, then plug it back in. Automatic.
 Sleep and wake       Close the lid for 10 seconds, open it, press Enter.

At the end you can review every result: type its number to change it or
test it again, or N to add remarks.


THE RESULT
----------
 FUNCTIONAL               Everything tested works.
 FUNCTIONAL WITH ISSUES   Something failed or needs attention.
 NOT FUNCTIONAL           A critical test failed (screen, keyboard, storage
                          health or charging - see CriticalTests in config.json).
 INCOMPLETE               Quick inventory, or more than half of the physical
                          tests were skipped.


THE FILES
---------
Saved in the "Reports" folder next to the tool. When that folder cannot be
written (for example the tool is installed under Program Files, or the USB
stick is write-protected) they go to  Documents\WinCheckup Reports.

 <tag>_Item-<no>_<model>_SN-<serial>_<date>.txt    full report + technical appendix
 <same name>.pdf                                   the printed page
 <same name>.json                                  for inventory systems / scripts
 <same name>_battery.html                          Windows battery report
 WinCheckup_Log.csv                                one row per device (Excel)

The text report is saved after every test, so a crash or power cut loses
nothing. Press [O] at the end to open the folder.


PRINTING
--------
The report goes to the default printer (or the one named in PreferredPrinter).
Connect the printer by USB or network and switch it on before the end of the
inspection. If none is found you can retry or skip; the PDF is always saved.


SETTINGS (config.json)
----------------------
Open config.json in Notepad. The most useful settings:

 InspectorName, OrganizationName, SiteName   printed on the report
 AssetTagExample                             shown in the asset tag question
 ReportFolder                                where reports go
 AutoPrint, PreferredPrinter, PrintCopies    printing
 BatteryWarnBelow, BatteryFailBelow          battery health limits (%)
 CriticalTests, SkipTests                    which tests matter most / are left out

Per-user settings can also go in  %APPDATA%\WinCheckup\config.json
(they win over the file next to the tool).


COMMAND LINE
------------
 WinCheckup.cmd -Quick                         specification + checks only
 WinCheckup.cmd -AssetTag PC-0042 -ItemNumber 17
 WinCheckup.cmd -Unattended -AssetTag PC-0042 -ReportFolder D:\Inventory
     asks nothing, never prints, exit code 0 = saved, 1 = error, 2 = not saved
 WinCheckup.cmd -NoPrint                       save only
 WinCheckup.cmd -ConfigPath D:\site.json       extra settings file


TROUBLESHOOTING
---------------
 "Windows protected your PC"   Click "More info" > "Run anyway" (the tool is
                               not code-signed).
 Keys do not turn green        Click once inside the keyboard window. A red bar
                               appears when the window loses focus.
 Fn / media keys missing       Normal: many laptops handle them in firmware.
 No sound in the speaker test  Check the volume is not muted by a hardware key;
                               press R to play the tone again.
 Microphone shows 0 %          Settings > Privacy > Microphone > allow desktop
                               apps to use the microphone.
 Battery health "not reported" Some batteries do not report their capacity.
                               Open the _battery.html file for Windows' view.

Source code, bug reports and new versions:
https://github.com/SaeedAhmadMalakzai/WinCheckup
