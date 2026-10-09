Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$source = Join-Path $env:GITHUB_WORKSPACE 'private-source'
$logs = Join-Path $env:RUNNER_TEMP 'vf-private-diagnostics'
$packages = Join-Path $env:RUNNER_TEMP 'vf-private-packages'
New-Item -ItemType Directory -Path $logs, $packages -Force | Out-Null

function Invoke-Quiet {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Executable,
        [string[]]$Arguments = @()
    )
    $logFile = Join-Path $logs "$Name.log"
    & $Executable @Arguments *> $logFile
    $status = $LASTEXITCODE
    if ($status -ne 0) {
        throw "$Name failed (exit $status). Diagnostics will be delivered privately."
    }
}

function Invoke-PrivateTest {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Executable,
        [Parameter(Mandatory=$true)][string]$Argument
    )
    $out = Join-Path $logs "$Name.stdout.txt"
    $err = Join-Path $logs "$Name.stderr.txt"
    $process = Start-Process -FilePath $Executable -ArgumentList $Argument `
        -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $out -RedirectStandardError $err
    if ($process.ExitCode -ne 0) {
        throw "$Name failed (exit $($process.ExitCode)). Diagnostics will be delivered privately."
    }
}

Write-Host 'Compiling the private Windows candidate. Full logs will stay private.'
Push-Location $source
try {
    Invoke-Quiet -Name 'cmake-configure' -Executable 'cmake' -Arguments @(
        '-S', '.', '-B', 'build', '-G', 'Ninja',
        '-DCMAKE_BUILD_TYPE=Release',
        '-DCMAKE_C_COMPILER=clang-cl',
        '-DCMAKE_CXX_COMPILER=clang-cl'
    )
    Invoke-Quiet -Name 'cmake-compile' -Executable 'cmake' -Arguments @(
        '--build', 'build', '--parallel', '4'
    )

    $studio = Join-Path $source 'build\VocalForge Studio.exe'
    $converter = Join-Path $source 'build\VocalForge Voicebank Converter.exe'
    if (-not (Test-Path $studio) -or -not (Test-Path $converter)) {
        throw 'Expected Windows application executables are missing.'
    }

    $studioDist = Join-Path $source 'dist\VocalForge Studio'
    $converterDist = Join-Path $source 'dist\VocalForge Voicebank Converter'
    New-Item -ItemType Directory -Path $studioDist, $converterDist -Force | Out-Null
    Copy-Item -LiteralPath $studio -Destination $studioDist -Force
    Copy-Item -LiteralPath $converter -Destination $converterDist -Force
    $onnx = Join-Path $source 'build\onnxruntime.dll'
    if (Test-Path $onnx) {
        Copy-Item -LiteralPath $onnx -Destination $studioDist -Force
    }

    Invoke-Quiet -Name 'deploy-studio' -Executable 'windeployqt' -Arguments @(
        '--release', '--compiler-runtime', '--no-translations',
        (Join-Path $studioDist 'VocalForge Studio.exe')
    )
    Invoke-Quiet -Name 'deploy-converter' -Executable 'windeployqt' -Arguments @(
        '--release', '--compiler-runtime', '--no-translations',
        (Join-Path $converterDist 'VocalForge Voicebank Converter.exe')
    )

    $voices = Join-Path $source 'voices'
    if (-not (Test-Path $voices)) {
        throw 'Required bundled voice assets are missing.'
    }
    Copy-Item -LiteralPath $voices -Destination $studioDist -Recurse -Force
    $dict = Join-Path $source 'build\dict'
    if (Test-Path $dict) {
        Copy-Item -LiteralPath $dict -Destination $studioDist -Recurse -Force
    }

    $studioTest = Join-Path $studioDist 'VocalForge Studio.exe'
    $converterTest = Join-Path $converterDist 'VocalForge Voicebank Converter.exe'
    Invoke-PrivateTest -Name 'studio-native' -Executable $studioTest -Argument '--self-test'
    Invoke-PrivateTest -Name 'converter-native' -Executable $converterTest -Argument '--self-test'
    Invoke-PrivateTest -Name 'studio-ui-100pct' -Executable $studioTest -Argument '--ui-smoke-test'
    try {
        $env:QT_SCALE_FACTOR = '1.25'
        Invoke-PrivateTest -Name 'studio-ui-125pct' -Executable $studioTest -Argument '--ui-smoke-test'
    } finally {
        Remove-Item Env:QT_SCALE_FACTOR -ErrorAction SilentlyContinue
    }
    Invoke-PrivateTest -Name 'converter-ui' -Executable $converterTest -Argument '--ui-smoke-test'

    $cmakeContent = Get-Content -LiteralPath (Join-Path $source 'CMakeLists.txt') -Raw
    $found = [regex]::Match($cmakeContent, 'project\(VocalForge VERSION ([0-9.]+)')
    if (-not $found.Success) {
        throw 'Could not read VocalForge version from the CMake project.'
    }
    $version = $found.Groups[1].Value

    Compress-Archive -Path (Join-Path $studioDist '*') `
        -DestinationPath (Join-Path $packages "VocalForge-Studio-Windows-x64-v$version.zip") -Force
    Compress-Archive -Path (Join-Path $converterDist '*') `
        -DestinationPath (Join-Path $packages "VocalForge-Voicebank-Converter-Windows-x64-v$version.zip") -Force
    Copy-Item -LiteralPath (Join-Path $env:RUNNER_TEMP 'vf-private-source.zip') `
        -Destination (Join-Path $packages "VocalForge-Source-v$version.zip") -Force
    "Version: $version; native tests and UI smoke tests passed." |
        Set-Content -LiteralPath (Join-Path $logs 'result.txt')
    Write-Host 'Windows compiler and desktop tests succeeded; private delivery is next.'
} catch {
    'Windows build or smoke test failed; see the private diagnostic files.' |
        Set-Content -LiteralPath (Join-Path $logs 'result.txt')
    throw 'Private Windows build failed. Diagnostic details will be delivered privately.'
} finally {
    Pop-Location
}
