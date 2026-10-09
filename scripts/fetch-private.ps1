Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:VF_PRIVATE_REPO) -or
    [string]::IsNullOrWhiteSpace($env:VF_SOURCE_TOKEN)) {
    throw 'Private builder secrets are not configured.'
}

$sourceRef = 'build-candidate'
$archive = Join-Path $env:RUNNER_TEMP 'vf-private-source.zip'
$unpacked = Join-Path $env:RUNNER_TEMP 'vf-private-source-unpacked'
$target = Join-Path $env:GITHUB_WORKSPACE 'private-source'
$headers = @{
    Accept = 'application/vnd.github+json'
    Authorization = "Bearer $env:VF_SOURCE_TOKEN"
    'User-Agent' = 'VocalForge-Windows-Builder'
}

try {
    $url = "https://api.github.com/repos/$($env:VF_PRIVATE_REPO)/zipball/$sourceRef"
    Invoke-WebRequest -Uri $url -Headers $headers -OutFile $archive `
        -MaximumRedirection 5 -ErrorAction Stop
    New-Item -ItemType Directory -Path $unpacked -Force | Out-Null
    Expand-Archive -LiteralPath $archive -DestinationPath $unpacked -Force
    $children = @(Get-ChildItem -LiteralPath $unpacked -Directory)
    if ($children.Count -ne 1 -or -not (Test-Path (Join-Path $children[0].FullName 'CMakeLists.txt'))) {
        throw 'Invalid source archive.'
    }
    Move-Item -LiteralPath $children[0].FullName -Destination $target
    if (Test-Path (Join-Path $target '.git')) {
        throw 'Snapshot unexpectedly contains Git metadata.'
    }
} catch {
    throw 'Private snapshot download failed. Check read-only token, repository selection, and build-candidate branch.'
} finally {
    Remove-Variable headers -ErrorAction SilentlyContinue
}

Write-Host 'Private source snapshot loaded without repository history.'
