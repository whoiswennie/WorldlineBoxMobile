[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Setup', 'Dev', 'Build')]
    [string] $Action,
    [uri] $Proxy,
    [string] $Device,
    [switch] $Update,
    [switch] $Release
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

function Assert-ApkFile($Archive, [string] $EntryName, [string] $SourcePath) {
    $entry = $Archive.GetEntry($EntryName)
    if (!$entry) { throw "APK entry missing: $EntryName" }
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = $entry.Open()
        try { $actual = [BitConverter]::ToString($hash.ComputeHash($stream)) }
        finally { $stream.Dispose() }
        $stream = [IO.File]::OpenRead($SourcePath)
        try { $expected = [BitConverter]::ToString($hash.ComputeHash($stream)) }
        finally { $stream.Dispose() }
    } finally { $hash.Dispose() }
    if ($actual -ne $expected) { throw "APK entry differs from the staged source: $EntryName" }
}

function Assert-BundledCallAssets([string] $Apk) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $source = Join-Path $root 'android/app/src/bundled/assets/pet-models'
    $expectedModels = @{ 'builtin-dafeiyu' = 'dafeiyu'; 'yachiyo-runami' = 'yachiyo' }
    $prefix = 'assets/pet-models/'
    $archive = [IO.Compression.ZipFile]::OpenRead($Apk)
    try {
        foreach ($track in 'dafeiyu.wav', 'phoebe.wav') {
            $entryName = "assets/call-ringtones/$track"
            $entry = $archive.GetEntry($entryName)
            if (!$entry -or $entry.Length -lt 1MB -or $entry.CompressedLength -ne $entry.Length) {
                throw "Missing or compressed call ringtone: $entryName. Check Git LFS and androidResources.noCompress."
            }
            Assert-ApkFile $archive $entryName (Join-Path $root "android/app/src/bundled/assets/call-ringtones/$track")
        }
        Write-Host 'Verified both bundled call ringtones in the APK.'
        Assert-ApkFile $archive ($prefix + 'live2dcubismcore.min.js') (Join-Path $source 'live2dcubismcore.min.js')
        Assert-ApkFile $archive ($prefix + 'models.json') (Join-Path $source 'models.json')
        Assert-ApkFile $archive 'assets/flutter_assets/assets/portraits/yachiyo-runami.png' (Join-Path $root 'assets/portraits/yachiyo-runami.png')
        $registry = Get-Content -LiteralPath (Join-Path $source 'models.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $registeredModels = @($archive.Entries | Where-Object { $_.FullName.StartsWith($prefix) -and $_.Name -like '*.model3.json' })
        if (@($registry.PSObject.Properties).Count -ne 2 -or $registeredModels.Count -ne 2) {
            throw 'The APK must contain exactly two registered Live2D models.'
        }
        foreach ($id in $expectedModels.Keys) {
            $directory = $expectedModels[$id]
            $model = $registry.$id
            if ($model.model -notmatch "^$directory/[0-9]+\.model3\.json$" -or
                $model.license -ne "$directory/license.txt" -or $model.cacheKey -notmatch "^$directory-[0-9a-f]{64}$") {
                throw "Wrong bundled Live2D model for $id."
            }
            $manifest = Get-Content -LiteralPath (Join-Path $source $model.model) -Raw -Encoding UTF8 | ConvertFrom-Json
            $refs = $manifest.FileReferences
            $moc = Join-Path (Join-Path $source $directory) $refs.Moc
            $stream = [IO.File]::OpenRead($moc)
            try {
                $magic = New-Object byte[] 4
                if ($stream.Read($magic, 0, 4) -ne 4 -or [Text.Encoding]::ASCII.GetString($magic) -cne 'MOC3') {
                    throw "Invalid Live2D model binary for $id. Run git lfs pull."
                }
            } finally { $stream.Dispose() }
            $textureCount = if ($id -eq 'builtin-dafeiyu') { 5 } else { 2 }
            if (@($refs.Textures).Count -ne $textureCount) { throw "Missing Live2D textures for $id." }
            foreach ($entry in Get-ChildItem -LiteralPath (Join-Path $source $directory) -File) {
                if ($entry.Extension -eq '.png') {
                    $stream = $entry.OpenRead()
                    try {
                        $magic = New-Object byte[] 8
                        if ($stream.Read($magic, 0, 8) -ne 8 -or [BitConverter]::ToString($magic) -ne '89-50-4E-47-0D-0A-1A-0A') {
                            throw "Invalid Live2D texture $($entry.Name). Run git lfs pull."
                        }
                    } finally { $stream.Dispose() }
                }
                Assert-ApkFile $archive "$prefix$directory/$($entry.Name)" $entry.FullName
            }
            foreach ($file in @($refs.Moc, $refs.Physics, $refs.DisplayInfo, $refs.Pose, $refs.UserData) +
                @($refs.Textures) + @($refs.Expressions | ForEach-Object { $_.File }) +
                @($refs.Motions.PSObject.Properties | ForEach-Object { $_.Value } | ForEach-Object { $_.File })) {
                if ($file -and !$archive.GetEntry("$prefix$directory/$file")) {
                    throw "Missing Live2D dependency for ${id}: $file"
                }
            }
            Write-Host "Verified $id in the APK."
        }
    } finally { $archive.Dispose() }
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
        Invoke-Checked node @('scripts/build-pet-viewer.mjs')
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
        Invoke-Checked node @('scripts/build-pet-viewer.mjs')
        Invoke-Checked $flutter @('build', 'apk', "--$mode")
        $built = Join-Path $root "build\app\outputs\flutter-apk\app-$mode.apk"
        if ($Release) { Assert-BundledCallAssets $built }
        $output = Join-Path $root 'dist'
        New-Item -ItemType Directory -Force -Path $output | Out-Null
        $filename = "WorldlineBoxMobile-$mode.apk"
        $apk = Join-Path $output $filename
        Copy-Item -LiteralPath $built -Destination $apk -Force
        Write-Output $apk
    }
}
