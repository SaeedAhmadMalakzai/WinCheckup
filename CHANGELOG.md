# Changelog

Version numbers follow [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-11-10

This is the first public release. WinCheckup began as an inspection script I used on a field job, and this version rewrites it for general use.

- Reads the specification, storage and battery health, Windows activation, TPM, Secure Boot and BitLocker. It also checks for Device Manager and hardware errors.
- Has up to 17 guided physical tests with one-key answers. Wi-Fi, USB ports, video output, charging, and sleep and wake are detected automatically.
- Has a keyboard map, a touchpad check and a microphone level meter.
- Restores the speaker volume after the sound tests.
- Prints a one-page report and saves it as PDF, text and JSON. It also adds a row to a CSV log.
- Has a settings file that checks every value it reads, plus quick and unattended modes with exit codes.
- Works with Pashto, Dari, Arabic and other non-Latin keyboard layouts.
- Ships as a portable zip and a Windows installer.
