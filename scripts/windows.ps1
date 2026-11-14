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

function Invoke-Checked([string] $Executable, [string[]] $Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed with exit code $LASTEXITCODE." }
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
        Copy-CallRingtones
        Invoke-Checked node @('scripts/build-pet-viewer.mjs')
        if ($IncludeLocalModel) { Invoke-Checked node @('scripts/stage-pet-models.mjs') }
        if (!$Device) {
            $adb = Join-Path $androidRoot 'platform-tools\adb.exe'
            $targets = @(& $adb devices | Where-Object { $_ -match '^([^\s]+)\s+device$' } | ForEach-Object { ($_ -split '\s+')[0] })
            if ($targets.Count -ne 1) { throw 'Connect one authorized Android device or emulator, or pass -Device <id>.' }
            $Device = $targets[0]
        }
        $arguments = @('run', '-d', $Device)
        Invoke-Checked $flutter $arguments
    }
    'Build' {
        if ($Release -and !(Test-Path -LiteralPath (Join-Path $root 'android\key.properties'))) {
            throw 'Release requires android\key.properties and a release keystore. Omit -Release for a sideloadable debug APK.'
        }
        $mode = if ($Release) { 'release' } else { 'debug' }
        Copy-CallRingtones
        Invoke-Checked node @('scripts/build-pet-viewer.mjs')
        if ($IncludeLocalModel) {
            if ($Release) { throw 'Local models are for private debug builds.' }
            Invoke-Checked node @('scripts/stage-pet-models.mjs')
        }
        Invoke-Checked $flutter @('build', 'apk', "--$mode")
        $output = Join-Path $root 'dist'
        New-Item -ItemType Directory -Force -Path $output | Out-Null
        $apk = Join-Path $output "WorldlineBoxMobile-$mode.apk"
        Copy-Item -LiteralPath (Join-Path $root "build\app\outputs\flutter-apk\app-$mode.apk") -Destination $apk -Force
        Write-Output $apk
    }
}
