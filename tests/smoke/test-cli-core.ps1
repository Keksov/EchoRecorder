# EchoRecorder CLI core smoke test
# Run: EchoRecorder\cli\scripts\smoke_x64.bat
# Or:  pwsh EchoRecorder\tests\smoke\test-cli-core.ps1

param(
    [string]$FixturePath = ""
)

$ErrorActionPreference = "Stop"

$scriptRoot = $PSScriptRoot
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot "..\.."))
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot ".."))
$cliRoot = Join-Path $repoRoot "cli"
$testsRoot = Join-Path $repoRoot "tests"
$commandsRoot = Join-Path $projectRoot "tests\audio\commands\ru"

$buildScript = Join-Path $cliRoot "scripts\build_x64.bat"
$cliExe = Join-Path $cliRoot "build\x64\EchoRecorderCore.exe"
$startScript = Join-Path $projectRoot "tests\start-test-orchestrator.ps1"
$stopScript = Join-Path $projectRoot "tests\stop-test-orchestrator.ps1"
$outputPath = Join-Path $cliRoot "build\x64\smoke-cli-result.json"
$speechMode = "command"
$baseUrl = if ($env:ECHOSCRIPT_TEST_BASE_URL) {
    [string]$env:ECHOSCRIPT_TEST_BASE_URL
} else {
    "http://localhost:3001"
}

function Assert-True {
    param(
        [string]$Name,
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw "$Name failed: $Message"
    }
}

function Assert-Equal {
    param(
        [string]$Name,
        $Expected,
        $Actual
    )

    if ($Expected -ne $Actual) {
        throw "$Name failed: expected '$Expected', got '$Actual'"
    }
}

function Get-FixturePath {
    param([string]$RequestedPath)

    if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
        $fixtureRoots = @($commandsRoot, $testsRoot)
        foreach ($fixtureRoot in $fixtureRoots) {
            if (-not (Test-Path $fixtureRoot)) {
                continue
            }

            $fixtures = @(Get-ChildItem -Path $fixtureRoot -Filter *.ogg -File | Sort-Object Name)
            if ($fixtures.Count -gt 0) {
                return $fixtures[0].FullName
            }
        }

        throw "No .ogg fixtures found in $commandsRoot or $testsRoot"
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $RequestedPath))
}

function Get-ResultPayload {
    param([string]$Path)

    $rows = Get-ResultRows -Path $Path
    if ($null -eq $rows) {
        return $null
    }

    $payload = $rows | Where-Object { $_.event -eq 'error' } | Select-Object -First 1
    if ($null -ne $payload) {
        return $payload
    }

    return $rows | Where-Object { $_.event -eq 'final' } | Select-Object -Last 1
}

function Get-ResultRows {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $null
    }

    try {
        return @(Get-Content -Path $Path | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | ForEach-Object {
            $_ | ConvertFrom-Json
        })
    }
    catch {
        return $null
    }
}

function Test-RetryableWarmupTimeout {
    param($Payload)

    if ($null -eq $Payload) {
        return $false
    }

    $statusCode = 0
    try {
        $statusCode = [int]$Payload.status_code
    }
    catch {
        $statusCode = 0
    }

    $errorText = [string]$Payload.error_text
    return ($statusCode -eq 504) -and $errorText.Contains("Timed out waiting for speech result")
}

function Invoke-RecorderCli {
    param(
        [string]$ExecutablePath,
        [string]$BaseUrl,
        [string]$Mode,
        [string]$InputPath,
        [string]$OutputPath,
        [int]$MaxAttempts = 2
    )

    $format = [System.IO.Path]::GetExtension($InputPath).TrimStart('.').ToLower()

    $attempt = 1
    while ($attempt -le $MaxAttempts) {
        & $ExecutablePath --base-url $BaseUrl --mode $Mode --language ru --format $format --input $InputPath --log=jsonl:$OutputPath
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            return
        }

        $payload = Get-ResultPayload -Path $OutputPath
        if (($attempt -lt $MaxAttempts) -and (Test-RetryableWarmupTimeout -Payload $payload)) {
            Write-Host "Warm-up timeout on attempt ${attempt}/${MaxAttempts}; retrying once" -ForegroundColor Yellow
            $attempt++
            continue
        }

        if ($null -ne $payload) {
            throw "CLI run failed with exit code ${exitCode}: $([string]$payload.error_text)"
        }

        throw "CLI run failed with exit code $exitCode"
    }
}

$fixture = Get-FixturePath -RequestedPath $FixturePath

Write-Host "=== EchoRecorder CLI core smoke ===" -ForegroundColor Cyan
Write-Host "Fixture: $fixture" -ForegroundColor DarkGray
Write-Host "Mode: $speechMode" -ForegroundColor DarkGray
Write-Host "Base URL: $baseUrl" -ForegroundColor DarkGray

try {
    if (Test-Path $outputPath) {
        Remove-Item $outputPath -Force
    }

    & $startScript
    & $buildScript
    if ($LASTEXITCODE -ne 0) {
        throw "CLI build failed with exit code $LASTEXITCODE"
    }

    Assert-True "cli executable exists" (Test-Path $cliExe) "missing $cliExe"

    Invoke-RecorderCli -ExecutablePath $cliExe -BaseUrl $baseUrl -Mode $speechMode -InputPath $fixture -OutputPath $outputPath

    Assert-True "output file exists" (Test-Path $outputPath) "missing $outputPath"

    $rows = Get-ResultRows -Path $outputPath
    Assert-True "jsonl rows present" ($null -ne $rows -and $rows.Count -gt 0) "CLI result JSONL is empty"

    $sourceEvent = $rows | Where-Object { $_.event -eq 'source' } | Select-Object -First 1
    $serverFinalEvent = $rows | Where-Object { $_.event -eq 'server_final' } | Select-Object -Last 1
    $payload = $rows | Where-Object { $_.event -eq 'final' } | Select-Object -Last 1

    Assert-True "final event present" ($null -ne $payload) "missing final event"
    Assert-True "source event present" ($null -ne $sourceEvent) "missing source event"
    Assert-True "server_final event present" ($null -ne $serverFinalEvent) "missing server_final event"

    Assert-True "payload ok" ([bool]$payload.ok) "CLI returned a failed payload"
    Assert-Equal "backend" "transport" ([string]$payload.backend)
    Assert-Equal "mode" "command" ([string]$payload.mode)
    Assert-Equal "language" "ru" ([string]$payload.language)
    Assert-Equal "file_name" ([System.IO.Path]::GetFileName($fixture)) ([string]$sourceEvent.file_name)
    Assert-Equal "input_path" ([System.IO.Path]::GetFullPath($fixture)) ([string]$payload.input_path)
    Assert-Equal "target model" "vosk_ru_cmd" ([string]$payload.target_model)
    Assert-Equal "command status" "matched" ([string]$payload.command_status)
    Assert-True "text present" (-not [string]::IsNullOrWhiteSpace([string]$payload.text)) "text is empty"
    Assert-True "normalized text present" (-not [string]::IsNullOrWhiteSpace([string]$payload.normalized_text)) "normalized_text is empty"
    Assert-True "raw text present" (-not [string]::IsNullOrWhiteSpace([string]$payload.raw_text)) "raw_text is empty"
    Assert-Equal "normalized matches text" ([string]$payload.text) ([string]$payload.normalized_text)
    Assert-Equal "server_final target model" "vosk_ru_cmd" ([string]$serverFinalEvent.target_model)

    Write-Host "Smoke passed" -ForegroundColor Green
    Write-Host "Result file: $outputPath" -ForegroundColor DarkGray
}
finally {
    & $stopScript
}