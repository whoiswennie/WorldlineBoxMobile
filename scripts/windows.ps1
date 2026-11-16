[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Setup', 'Dev', 'Build')]
    [string] $Action,
    [uri] $Proxy,
    [string] $Device,
    [switch] $Update,
    [switch] $Release,
    [switch] $IncludeLocalModel
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root
$tools = Join-Path $root '.tools'
$downloads = Join-Path $tools 'downloads'
$flutterRoot = Join-Path $tools 'flutter'
$androidRoot = Join-Path $tools 'android'
$flutter = Join-Path $flutterRoot 'bin\flutter.bat'
$sdkManager = Join-Path $androidRoot 'cmdline-tools\latest\bin\sdkmanager.bat'
$emulator = Join-Path $androidRoot 'emulator\emulator.exe'
$testAvd = 'WorldlineBoxTest'

function Invoke-Checked([string] $Executable, [string[]] $Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed with exit code $LASTEXITCODE." }
}

function Get-AndroidDeviceRows([string] $Adb) {
    Invoke-Checked $Adb @('devices') | Where-Object { $_ -match '^\S+\t' }
}

function Test-AndroidDeviceReady([string] $Adb, [string] $Serial) {
    # An online ADB transport can still close shell commands during boot or reconnect.
    $ErrorActionPreference = 'Continue'
    $properties = & $Adb -s $Serial shell getprop 2>$null
    return ($LASTEXITCODE -eq 0 -and
        $properties -match '^\[sys\.boot_completed\]: \[1\]\s*$' -and
        $properties -match '^\[ro\.build\.version\.sdk\]: \[\d+\]\s*$' -and
        $properties -match '^\[ro\.product\.cpu\.abi\]: \[\S+\]\s*$')
}

function Wait-AndroidDevice([string] $Adb, [string] $Serial) {
    if (Test-AndroidDeviceReady $Adb $Serial) { return }

    Write-Host "Waiting for Android device $Serial to finish booting and respond to ADB..."
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalMinutes -lt 3) {
        Start-Sleep -Seconds 2
        if (Test-AndroidDeviceReady $Adb $Serial) { return }
    }
    throw "ADB could not read Android properties from $Serial. Check that the emulator is running or that the phone is unlocked and has authorized USB debugging, then rerun 02-Start-Development.bat."
}

function Start-TestEmulator([string] $Adb) {
    $avdHome = Join-Path $tools 'avd'
    if (!(Test-Path -LiteralPath $emulator -PathType Leaf) -or
        !(Test-Path -LiteralPath (Join-Path $avdHome "$testAvd.ini") -PathType Leaf)) {
        throw 'No Android device detected. Connect a phone with USB debugging enabled and accept its authorization prompt, or start an Android emulator and rerun 02-Start-Development.bat.'
    }

    $env:ANDROID_AVD_HOME = $avdHome
    $stdout = Join-Path $tools 'dev-emulator-out.log'
    $stderr = Join-Path $tools 'dev-emulator-error.log'
    Write-Host "Opening the $testAvd emulator window and waiting for Android to boot..."
    $process = Start-Process -FilePath $emulator -ArgumentList @('-avd', $testAvd) -WindowStyle Normal -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalMinutes -lt 3) {
        if ($process.HasExited) {
            throw "The $testAvd emulator exited with code $($process.ExitCode). See '$stderr' and '$stdout'."
        }

        foreach ($row in (Get-AndroidDeviceRows $Adb)) {
            if ($row -notmatch '^(emulator-\d+)\s+device\s*$') { continue }
            $serial = $Matches[1]
            $name = & $Adb -s $serial emu avd name
            if ($LASTEXITCODE -ne 0 -or $name -notcontains $testAvd) { continue }
            if (Test-AndroidDeviceReady $Adb $serial) { return $serial }
        }
        Start-Sleep -Seconds 2
    }
    throw "Timed out waiting for $testAvd to boot. See '$stderr' and '$stdout'."
}

function Show-TestEmulator([string] $Adb, [string] $Serial) {
    if ($Serial -notmatch '^emulator-\d+$') { return $Serial }
    $name = & $Adb -s $Serial emu avd name
    if ($LASTEXITCODE -ne 0 -or $name -notcontains $testAvd) { return $Serial }

    $avdArgument = '\s(?:-avd\s+"?{0}"?|@{0})(?:\s|$)' -f [regex]::Escape($testAvd)
    $launcher = Get-CimInstance Win32_Process -Filter "Name = 'emulator.exe'" | Where-Object {
        $_.ExecutablePath -eq $emulator -and $_.CommandLine -match $avdArgument -and
            $_.CommandLine -match '\s-no-window(?:\s|$)'
    } | Select-Object -First 1
    if (!$launcher) { return $Serial }

    $workerIds = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($launcher.ProcessId)" |
        Where-Object { $_.Name -like 'qemu-system-*-headless.exe' } | Select-Object -ExpandProperty ProcessId)
    $processes = Get-Process -Id (@($launcher.ProcessId) + @($workerIds)) -ErrorAction SilentlyContinue
    Write-Host "$testAvd is running without a window. Restarting it with a visible window..."
    Invoke-Checked $Adb @('-s', $Serial, 'emu', 'kill') | Out-Null
    if ($processes) { Wait-Process -InputObject $processes -Timeout 30 }
    return (Start-TestEmulator $Adb)
}

function Receive-Archive([string] $Url, [string] $Destination) {
    $arguments = @('--fail', '--location', '--retry', '4', '--retry-all-errors', '--continue-at', '-', '--output', $Destination, $Url)
    if ($Proxy) { $arguments = @('--proxy', $Proxy.AbsoluteUri) + $arguments }
    Invoke-Checked curl.exe $arguments
}

function Copy-CallRingtones {
    $source = Join-Path (Split-Path -Parent $root) 'WorldlineBox\public\companion-call'
    $target = Join-Path $root 'android\app\src\main\assets\pet-ringtones'
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item -LiteralPath (Join-Path $source 'ringtone.wav') -Destination (Join-Path $target 'common.wav') -Force
    Copy-Item -LiteralPath (Join-Path $source 'ringtones\dafeiyu.ogg') -Destination (Join-Path $target 'dafeiyu.ogg') -Force

    $originals = Join-Path (Split-Path -Parent $root) 'WorldlineBox\.tools\original-call-ringtones'
    $debugTarget = Join-Path $root 'android\app\src\debug\assets\pet-private-ringtones'
    foreach ($track in @(@{ Source = 'dafeiyu.wav'; Name = 'dafeiyu.wav' }, @{ Source = 'ringtone.wav'; Name = 'phoebe.wav' })) {
        $original = Join-Path $originals $track.Source
        $destination = Join-Path $debugTarget $track.Name
        if (Test-Path -LiteralPath $original -PathType Leaf) {
            New-Item -ItemType Directory -Force -Path $debugTarget | Out-Null
            Copy-Item -LiteralPath $original -Destination $destination -Force
        } elseif (Test-Path -LiteralPath $destination -PathType Leaf) {
            Remove-Item -LiteralPath $destination
        }
    }
}

if ($Proxy) {
    if ($Proxy.Scheme -ne 'http' -or $Proxy.Port -le 0) { throw 'Use an HTTP proxy URL such as http://127.0.0.1:7897.' }
    $env:HTTP_PROXY = $Proxy.AbsoluteUri
    $env:HTTPS_PROXY = $Proxy.AbsoluteUri
}

$javaRoot = Join-Path $tools 'java'
$java = if (Test-Path -LiteralPath $javaRoot) {
    Get-ChildItem -LiteralPath $javaRoot -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\java.exe') } | Select-Object -First 1
}

if ($Action -eq 'Setup') {
    New-Item -ItemType Directory -Force -Path $downloads, $javaRoot, $androidRoot | Out-Null
    $gitOptions = @('-c', 'core.longpaths=true')
    if ($Proxy) { $gitOptions += @('-c', ('http.proxy=' + $Proxy.AbsoluteUri)) }
    if (!(Test-Path -LiteralPath $flutter)) {
        Invoke-Checked git ($gitOptions + @('clone', '--depth', '1', '--branch', '3.50.0', 'https://github.com/flutter/flutter.git', $flutterRoot))
    } elseif ($Update) {
        Invoke-Checked git ($gitOptions + @('-C', $flutterRoot, 'fetch', '--depth', '1', 'origin', 'refs/tags/3.50.0'))
        Invoke-Checked git ($gitOptions + @('-C', $flutterRoot, 'checkout', '--detach', 'FETCH_HEAD'))
    }
    if (!$java) {
        $jdkArchive = Join-Path $downloads 'jdk.zip'
        Receive-Archive 'https://aka.ms/download-jdk/microsoft-jdk-17-windows-x64.zip' $jdkArchive
        Invoke-Checked tar.exe @('-xf', $jdkArchive, '-C', $javaRoot)
        $java = Get-ChildItem -LiteralPath $javaRoot -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\java.exe') } | Select-Object -First 1
    }
    if (!(Test-Path -LiteralPath $sdkManager)) {
        $archive = Join-Path $downloads 'android-tools.zip'
        $commandTools = Join-Path $androidRoot 'cmdline-tools'
        New-Item -ItemType Directory -Force -Path $commandTools | Out-Null
        Receive-Archive 'https://dl.google.com/android/repository/commandlinetools-win-13114758_latest.zip' $archive
        Invoke-Checked tar.exe @('-xf', $archive, '-C', $commandTools)
        Rename-Item -LiteralPath (Join-Path $commandTools 'cmdline-tools') -NewName 'latest'
    }
}

if (!$java -or !(Test-Path -LiteralPath $flutter) -or !(Test-Path -LiteralPath $sdkManager)) {
    throw 'Run 01-Setup-Environment.bat first.'
}
$env:JAVA_HOME = $java.FullName
$env:ANDROID_HOME = $androidRoot
$env:ANDROID_SDK_ROOT = $androidRoot
$env:GRADLE_USER_HOME = Join-Path $tools 'gradle'
$env:PATH = (Join-Path $env:JAVA_HOME 'bin') + ';' + (Join-Path $androidRoot 'platform-tools') + ';' + $env:PATH
if ($Proxy) {
    $env:GRADLE_OPTS = "-Dhttp.proxyHost=$($Proxy.Host) -Dhttp.proxyPort=$($Proxy.Port) -Dhttps.proxyHost=$($Proxy.Host) -Dhttps.proxyPort=$($Proxy.Port)"
}

switch ($Action) {
    'Setup' {
        $sdkOptions = @("--sdk_root=$androidRoot")
        if ($Proxy) { $sdkOptions += @('--proxy=http', "--proxy_host=$($Proxy.Host)", "--proxy_port=$($Proxy.Port)") }
        Invoke-Checked $sdkManager ($sdkOptions + @('--licenses'))
        Invoke-Checked $sdkManager ($sdkOptions + @('platform-tools', 'platforms;android-35', 'platforms;android-36', 'build-tools;36.0.0', 'ndk;28.2.13676358', 'cmake;3.22.1'))
        Invoke-Checked $flutter @('pub', 'get')
        Invoke-Checked $flutter @('doctor', '-v')
    }
    'Dev' {
        $adb = Join-Path $androidRoot 'platform-tools\adb.exe'
        $autoDevice = !$Device
        if ($autoDevice) {
            $rows = @(Get-AndroidDeviceRows $adb)
            $targets = @($rows | Where-Object { $_ -match '^\S+\s+device\s*$' } | ForEach-Object { ($_ -split '\s+')[0] })
            if ($targets.Count -gt 1) {
                throw "Multiple Android devices are ready. Pass -Device <id>. Available IDs: $($targets -join ', ')."
            }
            if ($targets.Count -eq 1) {
                $Device = $targets[0]
            } elseif ($rows.Count -eq 1 -and $rows[0] -match '^(emulator-\d+)\s+offline\s*$') {
                $Device = $Matches[1]
            } elseif ($rows.Count -gt 0) {
                throw "Android devices detected but not ready: $($rows -join '; '). Accept the USB debugging prompt on your phone or wait for the emulator to finish booting, then rerun the script."
            } else {
                $Device = Start-TestEmulator $adb
            }
        }
        Copy-CallRingtones
        Invoke-Checked node @('scripts/build-pet-viewer.mjs')
        if ($IncludeLocalModel) { Invoke-Checked node @('scripts/stage-pet-models.mjs') }
        Wait-AndroidDevice $adb $Device
        if ($autoDevice) { $Device = Show-TestEmulator $adb $Device }
        Write-Host "Launching WorldlineBox on $Device. Flutter keeps this terminal open for logs and hot reload."
        $arguments = @('run', '-d', $Device)
        Invoke-Checked $flutter $arguments
    }
    'Build' {
        if ($Release -and !(Test-Path -LiteralPath (Join-Path $root 'android\key.properties'))) {
            throw 'Release requires android\key.properties and a release keystore. Omit -Release for a sideloadable debug APK.'
        }
        $mode = if ($Release) { 'release' } else { 'debug' }
        $privateRelease = $Release -and $IncludeLocalModel
        Copy-CallRingtones
        Invoke-Checked node @('scripts/build-pet-viewer.mjs')
        if ($IncludeLocalModel) {
            $stageArguments = @('scripts/stage-pet-models.mjs')
            if ($privateRelease) { $stageArguments += '--private-release' }
            Invoke-Checked node $stageArguments
        }
        $previousPrivateModel = $env:WORLDLINEBOX_PRIVATE_ANDROID_MODEL
        try {
            $env:WORLDLINEBOX_PRIVATE_ANDROID_MODEL = if ($privateRelease) { '1' } else { '0' }
            Invoke-Checked $flutter @('build', 'apk', "--$mode")
        } finally {
            $env:WORLDLINEBOX_PRIVATE_ANDROID_MODEL = $previousPrivateModel
        }
        $built = Join-Path $root "build\app\outputs\flutter-apk\app-$mode.apk"
        if ($Release -or $IncludeLocalModel) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [IO.Compression.ZipFile]::OpenRead($built)
            try {
                $modelFiles = @($archive.Entries | Where-Object { $_.FullName.StartsWith('assets/pet-models/') })
                if ($IncludeLocalModel) {
                    if (-not $archive.GetEntry('assets/pet-models/models.json') -or
                        -not $archive.GetEntry('assets/pet-models/live2dcubismcore.min.js') -or
                        -not ($modelFiles.FullName -match '\.moc3$') -or -not ($modelFiles.FullName -match '\.png$')) {
                        throw 'The private APK is missing required Live2D assets.'
                    }
                } elseif ($modelFiles.Count -gt 0) {
                    throw 'The public APK contains private Live2D assets.'
                }
            } finally { $archive.Dispose() }
        }
        $output = Join-Path $root 'dist'
        New-Item -ItemType Directory -Force -Path $output | Out-Null
        $filename = if ($privateRelease) { 'WorldlineBoxMobile-private-release.apk' } else { "WorldlineBoxMobile-$mode.apk" }
        $apk = Join-Path $output $filename
        Copy-Item -LiteralPath $built -Destination $apk -Force
        Write-Output $apk
    }
}
