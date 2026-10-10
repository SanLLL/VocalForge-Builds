Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:VF_PRIVATE_REPO) -or
    [string]::IsNullOrWhiteSpace($env:VF_DELIVERY_TOKEN)) {
    throw 'Private delivery secrets are not configured.'
}

$logs = Join-Path $env:RUNNER_TEMP 'vf-private-diagnostics'
$packages = Join-Path $env:RUNNER_TEMP 'vf-private-packages'
New-Item -ItemType Directory -Path $logs, $packages -Force | Out-Null
if (-not (Test-Path (Join-Path $logs 'result.txt'))) {
    $stageFile = Join-Path $logs 'current-stage.txt'
    $stage = if (Test-Path $stageFile) {
        (Get-Content -LiteralPath $stageFile -Raw).Trim()
    } else {
        'unknown'
    }
    "Build stopped before producing a result. Last recorded stage: $stage" |
        Set-Content -LiteralPath (Join-Path $logs 'result.txt')
}

$diagZip = Join-Path $env:RUNNER_TEMP 'VocalForge-Private-Build-Diagnostics.zip'
Compress-Archive -Path (Join-Path $logs '*') -DestinationPath $diagZip -Force
$assets = @($diagZip)
$state = 'Failed'
if ($env:VF_BUILD_OUTCOME -eq 'success') {
    $files = @(Get-ChildItem -LiteralPath $packages -Filter '*.zip' -File)
    if ($files.Count -ne 2) {
        throw 'Private package set is incomplete; refusing publication.'
    }
    $assets += $files.FullName
    $state = 'Passed'
}

$tag = "private-win-$($env:GITHUB_RUN_ID)-$($env:GITHUB_RUN_ATTEMPT)"
$env:GH_TOKEN = $env:VF_DELIVERY_TOKEN
$privateGhOutput = Join-Path $logs 'private-delivery.txt'
try {
    & gh release create $tag @assets `
        --repo $env:VF_PRIVATE_REPO `
        --target build-candidate `
        --prerelease --latest=false `
        --title "VocalForge private Windows build $tag" `
        --notes "$state - internal Windows build. Source is available from GitHub’s built-in release source downloads." `
        *> $privateGhOutput
    if ($LASTEXITCODE -ne 0) {
        throw 'Private release API rejected upload.'
    }
    Write-Host 'Private result delivered to the private repository Releases page.'
} catch {
    throw 'Private delivery failed. Check delivery token scope, private repository access, and existing tags.'
} finally {
    Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
}
