#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Unit tests for the parts of WinCheckup that do not need real hardware.
# Run:  Invoke-Pester ./tests        (Windows PowerShell 5.1 or PowerShell 7, any OS)
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester shares BeforeAll / BeforeEach variables with the It blocks.')]
param()

BeforeAll {
    $script:ScriptPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'WinCheckup.ps1'))
    $script:SourceDir = Split-Path -Parent $script:ScriptPath
    . $script:ScriptPath

    function New-FakeInventory {
        # Shape of what the background inventory returns, for a typical business laptop.
        param([int]$DesignCapacity = 50000, [int]$FullCapacity = 40000, [int]$DiskHealth = 0, [int]$LicenseStatus = 1)
        $store = New-InventoryStore
        $store.ComputerSystem = [pscustomobject]@{ Manufacturer = 'HP'; Model = 'EliteBook 840 G8'; TotalPhysicalMemory = 17000000000; SystemFamily = ''; SystemSKUNumber = '' }
        $store.OS = [pscustomobject]@{ Caption = 'Microsoft Windows 11 Pro'; BuildNumber = '22631'; OSArchitecture = '64-bit'; Version = '10.0.22631'; InstallDate = (Get-Date).AddYears(-1) }
        $store.Bios = [pscustomobject]@{ SerialNumber = 'To be filled by O.E.M.'; SMBIOSBIOSVersion = 'T37 Ver. 01.10.00'; ReleaseDate = (Get-Date).AddYears(-2); Manufacturer = 'HP' }
        $store.Product = [pscustomobject]@{ Version = ''; IdentifyingNumber = 'PRODUCT-SN'; UUID = '00000000-0000-0000-0000-000000000000'; Name = 'HP EliteBook' }
        $store.Enclosure = [pscustomobject]@{ SerialNumber = '5CG1234XYZ'; ChassisTypes = @(10); Manufacturer = 'HP'; SMBIOSAssetTag = '' }
        $store.Board = [pscustomobject]@{ Manufacturer = 'HP'; Product = '880D'; Version = 'KBC'; SerialNumber = 'PXXXX' }
        $store.Cpu = @([pscustomobject]@{ Name = 'Intel(R) Core(TM) i5-1145G7 @ 2.60GHz'; NumberOfCores = 4; NumberOfLogicalProcessors = 8; MaxClockSpeed = 2611 })
        $store.Ram = @(
            [pscustomobject]@{ Capacity = 8GB; SMBIOSMemoryType = 26; ConfiguredClockSpeed = 3200; Speed = 3200; DeviceLocator = 'DIMM 1' },
            [pscustomobject]@{ Capacity = 8GB; SMBIOSMemoryType = 26; ConfiguredClockSpeed = 3200; Speed = 3200; DeviceLocator = 'DIMM 2' }
        )
        $store.Gpu = @([pscustomobject]@{ Name = 'Intel(R) Iris(R) Xe Graphics'; Status = 'OK'; CurrentHorizontalResolution = 1920; CurrentVerticalResolution = 1080 })
        $store.Disks = @()
        $store.Volumes = @()
        $store.PhysicalDisks = @(
            [pscustomobject]@{ DeviceId = '0'; FriendlyName = 'Samsung PM981a 512GB'; MediaType = 4; BusType = 17; HealthStatus = $DiskHealth; Size = 512110190592 },
            [pscustomobject]@{ DeviceId = '1'; FriendlyName = 'SanDisk Cruzer (inspection stick)'; MediaType = 0; BusType = 7; HealthStatus = 0; Size = 32000000000 }
        )
        $store.Reliability = @{ '0' = [pscustomobject]@{ Wear = 3; PowerOnHours = 4100; Temperature = 38 } }
        $store.Audio = @()
        $store.Nics = @(
            [pscustomobject]@{ DeviceID = '1'; Name = 'Intel(R) Wi-Fi 6 AX201 160MHz'; NetConnectionID = 'Wi-Fi'; MACAddress = 'AA:BB:CC:DD:EE:01' },
            [pscustomobject]@{ DeviceID = '2'; Name = 'Intel(R) Ethernet Connection I219-LM'; NetConnectionID = 'Ethernet'; MACAddress = 'AA:BB:CC:DD:EE:02' }
        )
        $store.Monitors = @([pscustomobject]@{ MaxHorizontalImageSize = 31; MaxVerticalImageSize = 17; InstanceName = 'DISPLAY\1'; Active = $true })
        $store.Pnp = @(
            [pscustomobject]@{ Name = 'Intel Wireless Bluetooth'; PNPClass = 'Bluetooth'; PNPDeviceID = 'USB\VID_8087&PID_0026\5'; ConfigManagerErrorCode = 0; Status = 'OK' },
            [pscustomobject]@{ Name = 'HP HD Camera'; PNPClass = 'Camera'; PNPDeviceID = 'USB\VID_04F2&PID_B6BE\1'; ConfigManagerErrorCode = 0; Status = 'OK' }
        )
        $store.Battery = @([pscustomobject]@{ EstimatedChargeRemaining = 87; Name = 'Primary'; BatteryStatus = 2 })
        $store.BatteryStatic = @([pscustomobject]@{ DesignedCapacity = $DesignCapacity })
        $store.BatteryFull = @([pscustomobject]@{ FullChargedCapacity = $FullCapacity })
        $store.BatteryCycle = @([pscustomobject]@{ CycleCount = 212 })
        $store.DisplayVersion = '23H2'
        $store.Ubr = 4317
        $store.License = @([pscustomobject]@{ Name = 'Windows(R), Professional edition'; LicenseStatus = $LicenseStatus })
        $store.Tpm = $null
        $store.BitLocker = $null
        $store.SecureBoot = $true
        $store.Whea = @()
        $store.WheaReadable = $true
        return $store
    }

    function Reset-Run {
        # A fresh inspection with default settings and the fake laptop loaded.
        param($Inventory = (New-FakeInventory))
        Initialize-State
        $script:Config = Copy-DefaultConfig
        $built = Get-DeviceSpec $Inventory
        $script:Spec = $built.Spec
        $script:Facts = $built.Facts
        $script:Inspection.AssetTag = 'PC-0042'
        $script:Inspection.ItemNumber = '17'
        $script:Inspection.Inspector = 'Test Inspector'
    }

    function Get-ResultStatus {
        param([string]$Name)
        return ($script:Results | Where-Object { $_.Name -eq $Name } | Select-Object -First 1).Status
    }
}

Describe 'Script files' {
    It 'uses only ASCII characters, so Windows PowerShell 5.1 reads it the same in every locale' {
        $bytes = [System.IO.File]::ReadAllBytes($script:ScriptPath)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'parses without syntax errors' {
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $script:ScriptPath).Path, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'ships a settings file that matches the built-in defaults' {
        $json = Get-Content -Raw -LiteralPath (Join-Path $script:SourceDir 'config.json') | ConvertFrom-Json
        $keys = @($json.PSObject.Properties.Name | Where-Object { -not $_.StartsWith('_') })
        $keys | Sort-Object | Should -Be (@($script:DefaultConfig.Keys) | Sort-Object)
        $target = Copy-DefaultConfig
        Merge-Config $target $json 'config.json' | Should -BeNullOrEmpty
    }

    It 'has a launcher with Windows line endings' {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:SourceDir 'WinCheckup.cmd'))
        $text | Should -Match "`r`n"
        $text -replace "`r`n", '' | Should -Not -Match "`n"
    }
}

Describe 'Text helpers' {
    It 'turns an asset tag into a safe file name part' {
        Get-SafeFileToken 'PC/AF 99:x' 'NONE' | Should -Be 'PC-AF-99-x'
    }

    It 'uses the fallback for an empty value' {
        Get-SafeFileToken '  ' 'TAG-UNRECORDED' | Should -Be 'TAG-UNRECORDED'
    }

    It 'shortens long values' {
        (Get-SafeFileToken ('A' * 80) 'X' 10).Length | Should -Be 10
    }

    It 'recognises firmware placeholder text' -ForEach @(
        @{ Value = 'To be filled by O.E.M.'; Expected = $true }
        @{ Value = 'Default string'; Expected = $true }
        @{ Value = '0000000'; Expected = $true }
        @{ Value = ''; Expected = $true }
        @{ Value = '5CG1234XYZ'; Expected = $false }
    ) {
        Test-Placeholder $Value | Should -Be $Expected
    }

    It 'prints disk sizes the way the box does' -ForEach @(
        @{ Bytes = 512110190592; Expected = '512 GB' }
        @{ Bytes = 2000398934016; Expected = '2 TB' }
        @{ Bytes = 0; Expected = 'Unknown size' }
    ) {
        Format-DiskSize $Bytes | Should -Be $Expected
    }

    It 'wraps text to the given width without losing words' {
        $text = 'one two three four five six seven eight nine ten'
        $lines = Split-Wrap $text 12
        @($lines | Where-Object { $_.Length -gt 12 }).Count | Should -Be 0
        ($lines -join ' ') | Should -Be $text
    }

    It 'splits a word longer than the width' {
        $lines = Split-Wrap ('X' * 25) 10
        $lines.Count | Should -Be 3
    }

    It 'returns one empty line for empty text' {
        $lines = Split-Wrap '' 10
        $lines.Count | Should -Be 1
        $lines[0] | Should -Be ''
    }
}

Describe 'Keyboard answers' {
    It 'reads P from the physical key while a Pashto or Dari layout is active' {
        $press = New-Object System.ConsoleKeyInfo([char]0x067E, [ConsoleKey]::P, $false, $false, $false)
        ConvertFrom-KeyPress $press | Should -Be 'P'
    }

    It 'reports Enter as ENTER' {
        $press = New-Object System.ConsoleKeyInfo([char]13, [ConsoleKey]::Enter, $false, $false, $false)
        ConvertFrom-KeyPress $press | Should -Be 'ENTER'
    }

    It 'turns Persian and Arabic-Indic digits into 0-9' {
        $persian = [string][char]0x06F1 + [char]0x06F2
        $arabic = [string][char]0x0663
        ConvertTo-LatinDigit $persian | Should -Be '12'
        ConvertTo-LatinDigit $arabic | Should -Be '3'
        ConvertTo-LatinDigit 'N' | Should -Be 'N'
    }
}

Describe 'Waiting for the charger' {
    It 'checks one last time when the waiting time is over' {
        Wait-Condition { $true } 0 6> $null | Should -Be 'OK'
    }

    It 'reports a timeout when the condition never comes true' {
        Wait-Condition { $false } 0 6> $null | Should -Be 'TIMEOUT'
    }
}

Describe 'Settings' {
    BeforeEach { $target = Copy-DefaultConfig }

    It 'copies known settings, ignoring the case of the name' {
        $source = '{ "inspectorname": "Ana", "PrintCopies": 2, "AutoPrint": false }' | ConvertFrom-Json
        Merge-Config $target $source 'test' | Should -BeNullOrEmpty
        $target.InspectorName | Should -Be 'Ana'
        $target.PrintCopies | Should -Be 2
        $target.AutoPrint | Should -BeFalse
    }

    It 'ignores notes that start with an underscore' {
        $source = '{ "_comment": "hello" }' | ConvertFrom-Json
        Merge-Config $target $source 'test' | Should -BeNullOrEmpty
    }

    It 'warns about unknown settings' {
        $source = '{ "PrintCopys": 2 }' | ConvertFrom-Json
        $warnings = Merge-Config $target $source 'test'
        $warnings | Should -Match 'unknown setting "PrintCopys"'
    }

    It 'keeps the default when a value has the wrong type' {
        $source = '{ "AutoPrint": "yes", "PrintCopies": "two", "BatteryFailBelow": -5 }' | ConvertFrom-Json
        $warnings = Merge-Config $target $source 'test'
        @($warnings).Count | Should -Be 3
        $target.AutoPrint | Should -BeTrue
        $target.PrintCopies | Should -Be 1
        $target.BatteryFailBelow | Should -Be 50
    }

    It 'rounds decimal numbers and accepts lists' {
        $source = '{ "BatteryWarnBelow": 72.6, "SkipTests": ["Bluetooth", "Other ports"] }' | ConvertFrom-Json
        Merge-Config $target $source 'test' | Should -BeNullOrEmpty
        $target.BatteryWarnBelow | Should -Be 73
        $target.SkipTests | Should -Be @('Bluetooth', 'Other ports')
    }

    Context 'loading the files' {
        BeforeEach {
            $savedAppData = $env:APPDATA
            $env:APPDATA = Join-Path $TestDrive 'appdata'
            $root = Join-Path $TestDrive ('root-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root | Out-Null
        }
        AfterEach { $env:APPDATA = $savedAppData }

        It 'applies the file next to the script, then the per-user file, then -ConfigPath' {
            Set-Content -LiteralPath (Join-Path $root 'config.json') -Value '{ "SiteName": "Root", "PrintCopies": 3 }'
            $userDir = Join-Path $env:APPDATA $script:ToolName
            New-Item -ItemType Directory -Path $userDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $userDir 'config.json') -Value '{ "SiteName": "User" }'
            $extra = Join-Path $TestDrive 'extra.json'
            Set-Content -LiteralPath $extra -Value '{ "InspectorName": "Extra" }'

            $loaded = Import-ToolConfig -ScriptRoot $root -ExplicitPath $extra

            $loaded.Config.SiteName | Should -Be 'User'
            $loaded.Config.PrintCopies | Should -Be 3
            $loaded.Config.InspectorName | Should -Be 'Extra'
            $loaded.Sources.Count | Should -Be 3
            Remove-Item -LiteralPath $userDir -Recurse -Force
        }

        It 'keeps the defaults and warns when a file is not valid JSON' {
            Set-Content -LiteralPath (Join-Path $root 'config.json') -Value '{ "SiteName": '
            $loaded = Import-ToolConfig -ScriptRoot $root
            $loaded.Config.SiteName | Should -Be ''
            $loaded.Warnings | Should -Match 'could not be read'
        }

        It 'warns when the -ConfigPath file does not exist' {
            $loaded = Import-ToolConfig -ScriptRoot $root -ExplicitPath (Join-Path $TestDrive 'missing.json')
            $loaded.Warnings | Should -Match 'not found'
        }
    }
}

Describe 'Device specification' {
    BeforeAll { Reset-Run }

    It 'reads the serial from the chassis when the BIOS has placeholder text' {
        $script:Facts.Serial | Should -Be '5CG1234XYZ'
        $script:Facts.SerialOk | Should -BeTrue
    }

    It 'describes the memory modules' {
        $script:Facts.RamText | Should -Be '16 GB DDR4 3200 MHz (2 x 8 GB)'
    }

    It 'lists the internal drive and leaves out the USB stick running the tool' {
        $script:Facts.Disks.Count | Should -Be 1
        $script:Facts.Disks[0].Text | Should -Be '512 GB NVMe SSD (Samsung PM981a 512GB) - Healthy, 3% life used'
    }

    It 'works out battery health from design and full-charge capacity' {
        $script:Facts.BatteryHealth | Should -Be 80
    }

    It 'shortens the processor name' {
        $script:Facts.Cpu | Should -Be 'Intel Core i5-1145G7 @ 2.60GHz - 4 cores / 8 threads'
    }

    It 'names the device type from the chassis code' {
        ($script:Spec | Where-Object { $_.Label -eq 'Device type' }).Value | Should -Be 'Laptop'
    }

    It 'separates Wi-Fi and Ethernet adapters' {
        $script:Facts.Wifi.Count | Should -Be 1
        ($script:Spec | Where-Object { $_.Label -eq 'Ethernet' }).Value | Should -Match 'I219-LM'
    }

    It 'shows the Lenovo product name in front of the machine type' {
        $inv = New-FakeInventory
        $inv.ComputerSystem.Manufacturer = 'LENOVO'
        $inv.ComputerSystem.Model = '20XW0026US'
        $inv.Product.Version = 'ThinkPad X1 Carbon Gen 9'
        (Get-DeviceSpec $inv).Facts.Model | Should -Be 'ThinkPad X1 Carbon Gen 9 (20XW0026US)'
    }

    It 'says so when no serial number is readable anywhere' {
        $inv = New-FakeInventory
        $inv.Enclosure.SerialNumber = 'Chassis Serial Number'
        $inv.Product.IdentifyingNumber = 'Default string'
        $built = Get-DeviceSpec $inv
        $built.Facts.SerialOk | Should -BeFalse
        ($built.Spec | Where-Object { $_.Label -eq 'Serial number' }).Value | Should -Match 'read the label'
    }

    It 'copes with an inventory where nothing could be read' {
        $built = Get-DeviceSpec (New-InventoryStore)
        $built.Spec.Count | Should -BeGreaterThan 10
        $built.Facts.HasBattery | Should -BeFalse
    }
}

Describe 'Automatic checks' {
    It 'passes a healthy laptop' {
        Reset-Run
        Invoke-AutoChecks (New-FakeInventory) $script:Facts -Quiet
        Get-ResultStatus 'Storage health' | Should -Be 'PASS'
        Get-ResultStatus 'Battery health' | Should -Be 'PASS'
        Get-ResultStatus 'Windows activation' | Should -Be 'PASS'
        Get-ResultStatus 'Hardware error log' | Should -Be 'PASS'
        Get-ResultStatus 'Device Manager errors' | Should -Be 'PASS'
    }

    It 'grades battery health against the limits' -ForEach @(
        @{ Full = 45000; Expected = 'PASS' }
        @{ Full = 30000; Expected = 'WARN' }
        @{ Full = 20000; Expected = 'FAIL' }
    ) {
        $inv = New-FakeInventory -FullCapacity $Full
        Reset-Run $inv
        Invoke-AutoChecks $inv $script:Facts -Quiet
        Get-ResultStatus 'Battery health' | Should -Be $Expected
    }

    It 'fails storage when the drive reports unhealthy' {
        $inv = New-FakeInventory -DiskHealth 2
        Reset-Run $inv
        Invoke-AutoChecks $inv $script:Facts -Quiet
        Get-ResultStatus 'Storage health' | Should -Be 'FAIL'
    }

    It 'warns when Windows is not activated' {
        $inv = New-FakeInventory -LicenseStatus 5
        Reset-Run $inv
        Invoke-AutoChecks $inv $script:Facts -Quiet
        Get-ResultStatus 'Windows activation' | Should -Be 'WARN'
    }

    It 'names devices with a Device Manager problem' {
        $inv = New-FakeInventory
        $inv.Pnp += [pscustomobject]@{ Name = 'Unknown device'; PNPClass = ''; PNPDeviceID = 'ACPI\X'; ConfigManagerErrorCode = 28; Status = 'Error' }
        Reset-Run $inv
        Invoke-AutoChecks $inv $script:Facts -Quiet
        ($script:Results | Where-Object { $_.Name -eq 'Device Manager errors' }).Note | Should -Match 'Unknown device \(code 28\)'
    }

    It 'names a device that has no driver by its hardware ID' {
        $inv = New-FakeInventory
        $inv.Pnp += [pscustomobject]@{ Name = $null; PNPClass = ''; PNPDeviceID = 'ACPI\VMBUS\0'; ConfigManagerErrorCode = 28; Status = 'Error' }
        Reset-Run $inv
        Invoke-AutoChecks $inv $script:Facts -Quiet
        ($script:Results | Where-Object { $_.Name -eq 'Device Manager errors' }).Note | Should -Be 'Unnamed device ACPI\VMBUS\0 (code 28)'
    }

    It 'warns about a clock set before the BIOS date' {
        $inv = New-FakeInventory
        $inv.Bios.ReleaseDate = (Get-Date).AddYears(1)
        Reset-Run $inv
        Invoke-AutoChecks $inv $script:Facts -Quiet
        Get-ResultStatus 'System clock' | Should -Be 'WARN'
    }
}

Describe 'Overall result' {
    BeforeEach {
        Reset-Run
        Set-Result 'Storage health' 'PASS' '' 'Auto' -Quiet
        foreach ($name in @('Screen / display', 'Keyboard', 'Speakers', 'Camera', 'Charging')) { Set-Result $name 'PASS' '' -Quiet }
    }

    It 'is FUNCTIONAL when everything passes' {
        (Get-Overall).Code | Should -Be 'FUNCTIONAL'
    }

    It 'is FUNCTIONAL WITH ISSUES when a normal test fails' {
        Set-Result 'Camera' 'FAIL' 'No picture' -Quiet
        (Get-Overall).Code | Should -Be 'FUNCTIONAL WITH ISSUES'
    }

    It 'is NOT FUNCTIONAL when a critical test fails' {
        Set-Result 'Keyboard' 'FAIL' 'Keys not working: J' -Quiet
        $overall = Get-Overall
        $overall.Code | Should -Be 'NOT FUNCTIONAL'
        $overall.Text | Should -Match 'Keyboard'
    }

    It 'is INCOMPLETE for a quick inventory' {
        $script:Inspection.Mode = 'Quick'
        (Get-Overall).Code | Should -Be 'INCOMPLETE'
    }

    It 'is INCOMPLETE when most physical tests were skipped' {
        foreach ($name in @('Screen / display', 'Speakers', 'Camera')) { Set-Result $name 'SKIP' 'Not tested' -Quiet }
        (Get-Overall).Code | Should -Be 'INCOMPLETE'
    }

    It 'counts a few skipped tests without failing the device' {
        Set-Result 'Camera' 'SKIP' 'Not tested' -Quiet
        (Get-Overall).Text | Should -Be 'FUNCTIONAL - 1 item(s) not tested'
    }

    It 'lets the settings choose the critical tests' {
        $script:Config.CriticalTests = @('Camera')
        Set-Result 'Camera' 'FAIL' 'No picture' -Quiet
        (Get-Overall).Code | Should -Be 'NOT FUNCTIONAL'
    }
}

Describe 'Physical test list' {
    It 'only offers the touchscreen test when Windows sees a touchscreen' {
        Reset-Run
        $names = @(Get-GuidedTests | ForEach-Object { $_.Name })
        $names | Should -Not -Contain 'Touchscreen'
        $names | Should -Contain 'Camera'
    }

    It 'leaves out the tests named in SkipTests' {
        Reset-Run
        $script:Config.SkipTests = @('Bluetooth', 'Other ports')
        $names = @(Get-GuidedTests | ForEach-Object { $_.Name })
        $names | Should -Not -Contain 'Bluetooth'
        $names | Should -Not -Contain 'Other ports'
    }

    It 'gives every test a unique name and instructions' {
        Reset-Run
        $tests = @(Get-GuidedTests)
        @($tests.Name | Select-Object -Unique).Count | Should -Be $tests.Count
        @($tests | Where-Object { -not $_.Steps }).Count | Should -Be 0
    }

    It 'names only real tests or checks as critical' {
        Reset-Run
        Invoke-AutoChecks (New-FakeInventory) $script:Facts -Quiet
        $known = @(Get-GuidedTests | ForEach-Object { $_.Name }) + @($script:Results | ForEach-Object { $_.Name })
        foreach ($critical in $script:DefaultConfig.CriticalTests) { $known | Should -Contain $critical }
    }
}

Describe 'Running one physical test' {
    BeforeEach { Reset-Run }

    It 'records a pass with the note the test suggested' {
        Mock Read-Choice { 'P' }
        $test = @{ Name = 'Camera'; Steps = @('Look'); Action = { param($attempt) @{ PassNote = 'Clear picture' } } }
        Invoke-GuidedTest $test 1 1 6> $null
        Get-ResultStatus 'Camera' | Should -Be 'PASS'
        ($script:Results | Where-Object { $_.Name -eq 'Camera' }).Note | Should -Be 'Clear picture'
    }

    It 'offers the suggested fault as the default failure note' {
        Mock Read-Choice { 'F' }
        Mock Read-Text { $Default }
        $test = @{ Name = 'Speakers'; Steps = @('Listen'); Action = { param($attempt) @{ FailNote = 'Right side silent' } } }
        Invoke-GuidedTest $test 1 1 6> $null
        ($script:Results | Where-Object { $_.Name -eq 'Speakers' }).Note | Should -Be 'Right side silent'
    }

    It 'runs the test again on R' {
        $script:answers = [System.Collections.Queue]::new(@('R', 'P'))
        $script:attempts = @()
        Mock Read-Choice { $script:answers.Dequeue() }
        $test = @{ Name = 'Speakers'; Repeat = $true; Steps = @('Listen'); Action = { param($attempt) $script:attempts += $attempt; @{} } }
        Invoke-GuidedTest $test 1 1 6> $null
        $script:attempts | Should -Be @(1, 2)
        Get-ResultStatus 'Speakers' | Should -Be 'PASS'
    }

    It 'does not ask when the test already recorded its result' {
        Mock Read-Choice { throw 'should not be asked' }
        $test = @{ Name = 'Wi-Fi'; Steps = @('Connect'); Action = { param($attempt) Set-Result 'Wi-Fi' 'PASS' 'Connected' -Quiet; @{ Done = $true } } }
        Invoke-GuidedTest $test 1 1 6> $null
        Get-ResultStatus 'Wi-Fi' | Should -Be 'PASS'
    }

    It 'still asks the inspector when the automatic part crashes, and notes the problem' {
        Mock Read-Choice { 'S' }
        $test = @{ Name = 'USB ports'; Steps = @('Plug in'); Action = { param($attempt) throw 'device list broken' } }
        Invoke-GuidedTest $test 1 1 6> $null
        Get-ResultStatus 'USB ports' | Should -Be 'SKIP'
        $script:ToolProblems | Should -Match 'device list broken'
    }

    It 'always runs the clean-up step' {
        Mock Read-Choice { 'P' }
        $script:cleaned = $false
        $test = @{ Name = 'Camera'; Steps = @('Look'); Cleanup = { $script:cleaned = $true } }
        Invoke-GuidedTest $test 1 1 6> $null
        $script:cleaned | Should -BeTrue
    }
}

Describe 'Report' {
    BeforeAll {
        Reset-Run
        Invoke-AutoChecks (New-FakeInventory) $script:Facts -Quiet
        Set-Result 'Screen / display' 'PASS' '' -Quiet
        Set-Result 'Keyboard' 'PASS' 'All 79 main keys work' -Quiet
        Set-Result 'Camera' 'FAIL' 'No picture / poor picture, the image is dark and blurred even in a bright room with the lid fully open' -Quiet
        $script:Inspection.Remarks = 'Sticker residue on the lid.'
        $lines = New-ReportLines
        $text = ConvertTo-PlainText $lines
    }

    It 'shows the asset tag, the overall result and the sign-off' {
        $text | Should -Match 'PC-0042'
        $text | Should -Match '>>> OVERALL RESULT:  FUNCTIONAL WITH ISSUES'
        $text | Should -Match 'Received by:'
    }

    It 'lists every result and the remarks' {
        foreach ($r in $script:Results) { $text | Should -Match ([regex]::Escape($r.Name)) }
        $text | Should -Match 'Sticker residue'
    }

    It 'lists failures again under NOT WORKING' {
        $text | Should -Match '(?m)^- Camera \(NOT WORKING\)'
    }

    It 'keeps the table lines within the page width' {
        $tooWide = @($lines | Where-Object { $_.Style -in @('Text', 'Bold') -and $_.Text.Length -gt $script:ReportWidth })
        $tooWide | Should -BeNullOrEmpty
    }

    It 'builds a file name from tag, item, model, serial and time' {
        Get-ReportBaseName | Should -Match '^PC-0042_Item-17_EliteBook-840-G8_SN-5CG1234XYZ_\d{8}_\d{6}$'
    }

    It 'writes a JSON copy that reads back' {
        $data = ConvertTo-ReportJson | ConvertFrom-Json
        $data.tool.version | Should -Be $script:ToolVersion
        $data.inspection.assetTag | Should -Be 'PC-0042'
        $data.inspection.overall | Should -Be 'FUNCTIONAL WITH ISSUES'
        $data.device.serial | Should -Be '5CG1234XYZ'
        @($data.results).Count | Should -Be $script:Results.Count
    }
}

Describe 'Saving files' {
    BeforeEach {
        Reset-Run
        $script:ReportDir = Join-Path $TestDrive ('reports-' + [guid]::NewGuid().ToString('N'))
    }

    It 'saves the text report with a byte order mark and JSON without one' {
        $txt = Save-TextFile 'a.txt' 'hello'
        $json = Save-TextFile 'a.json' '{}' -NoBom
        [System.IO.File]::ReadAllBytes($txt)[0] | Should -Be 0xEF
        [System.IO.File]::ReadAllBytes($json)[0] | Should -Be ([byte][char]'{')
    }

    It 'marks the in-progress report as not final' {
        $path = Save-Report
        Get-Content -LiteralPath $path -TotalCount 1 | Should -Match 'IN PROGRESS'
        $final = Save-Report -Final
        Get-Content -LiteralPath $final -TotalCount 1 | Should -Not -Match 'IN PROGRESS'
    }

    It 'adds one log row per device and remembers the inspector' {
        New-Item -ItemType Directory -Path $script:ReportDir | Out-Null
        $first = Add-InspectionLog $script:ReportDir
        $script:Inspection.Inspector = 'Second Inspector'
        $second = Add-InspectionLog $script:ReportDir
        $second | Should -Be $first
        @(Import-Csv -LiteralPath $first).Count | Should -Be 2
        Get-LastInspector $script:ReportDir | Should -Be 'Second Inspector'
    }

    It 'starts a new log instead of mixing columns with an older version''s log' {
        New-Item -ItemType Directory -Path $script:ReportDir | Out-Null
        $old = Join-Path $script:ReportDir 'WinCheckup_Log.csv'
        Set-Content -LiteralPath $old -Value '"Date","AssetTag","Overall"'
        $written = Add-InspectionLog $script:ReportDir
        Split-Path -Leaf $written | Should -Be 'WinCheckup_Log_v1.csv'
        @(Get-Content -LiteralPath $old).Count | Should -Be 1
    }

    It 'uses the configured report folder when it can be written' {
        $wanted = Join-Path $TestDrive 'configured'
        Resolve-ReportFolder $wanted $TestDrive | Should -Be $wanted
    }

    It 'reads a relative report folder from the settings as next to the tool' {
        $root = Join-Path $TestDrive 'usb'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Resolve-ReportFolder 'Inspections' $root | Should -Be (Join-Path $root 'Inspections')
    }

    It 'resolves a relative command-line path from the current folder' {
        Push-Location $TestDrive
        try { ConvertTo-FullPath 'out' | Should -Be (Join-Path (Get-Location).ProviderPath 'out') }
        finally { Pop-Location }
    }

    It 'recognises a folder under Program Files' {
        $saved = $env:ProgramFiles
        try {
            $env:ProgramFiles = Join-Path $TestDrive 'Program Files'
            Test-UnderProgramFiles (Join-Path $env:ProgramFiles 'WinCheckup') | Should -BeTrue
            Test-UnderProgramFiles (Join-Path $TestDrive 'USB') | Should -BeFalse
        } finally { $env:ProgramFiles = $saved }
    }
}

Describe 'Starting the elevated copy' {
    It 'quotes arguments the way Windows splits them' -ForEach @(
        @{ Value = 'C:\Program Files\tool.ps1'; Expected = '"C:\Program Files\tool.ps1"' }
        @{ Value = 'say "hi"'; Expected = '"say \"hi\""' }
        @{ Value = 'D:\Reports\'; Expected = '"D:\Reports\\"' }
        @{ Value = ''; Expected = '""' }
    ) {
        Format-ProcessArgument $Value | Should -Be $Expected
    }

    It 'passes the same parameters on and adds -NoElevate once' {
        $bound = @{ AssetTag = 'PC 7'; Quick = [System.Management.Automation.SwitchParameter]$true; NoPrint = [System.Management.Automation.SwitchParameter]$false; NoElevate = [System.Management.Automation.SwitchParameter]$true }
        $line = Get-RelaunchArguments 'C:\Tools\WinCheckup.ps1' $bound
        $line | Should -Match '-File "C:\\Tools\\WinCheckup\.ps1"'
        $line | Should -Match '-AssetTag "PC 7"'
        $line | Should -Match ' -Quick'
        $line | Should -Not -Match 'NoPrint'
        ([regex]::Matches($line, '-NoElevate')).Count | Should -Be 1
    }
}

Describe 'Paths for the elevated copy' {
    It 'leaves a path that is not on a mapped network drive unchanged' {
        Get-UncPath $TestDrive | Should -Be $TestDrive
    }
}

Describe 'Test tone' {
    It 'is a valid stereo WAV file' {
        $wav = New-StereoTone
        $reader = New-Object System.IO.BinaryReader($wav)
        [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) | Should -Be 'RIFF'
        $riffSize = $reader.ReadInt32()
        [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) | Should -Be 'WAVE'
        $wav.Position = 22
        $reader.ReadInt16() | Should -Be 2
        $reader.ReadInt32() | Should -Be 22050
        $riffSize | Should -Be ($wav.Length - 8)
        $wav.Dispose()
    }
}

Describe 'Native sound helpers' {
    It 'compile with the C# 5 compiler that ships with Windows PowerShell 5.1' {
        if ('WinCheckup.SpeakerVolume' -as [type]) { Set-ItResult -Skipped -Because 'already loaded in this session'; return }
        $options = @{}
        if ($PSVersionTable.PSEdition -eq 'Core') { $options.CompilerOptions = '-langversion:5' }
        { Add-Type -TypeDefinition $script:NativeSource -Language CSharp @options -ErrorAction Stop } | Should -Not -Throw
        'WinCheckup.SpeakerVolume' -as [type] | Should -Not -BeNullOrEmpty
        'WinCheckup.MicMeter' -as [type] | Should -Not -BeNullOrEmpty
    }
}
