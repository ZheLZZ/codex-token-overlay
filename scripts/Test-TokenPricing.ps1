param([string]$ExecutablePath)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new()
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$probeRoot = Join-Path ([IO.Path]::GetTempPath()) ('CodexTokenPricing-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $probeRoot | Out-Null

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) { throw "$Message expected=$Expected actual=$Actual" }
}

function Invoke-Probe([string[]]$Arguments, [string]$OutputPath) {
    if ($ExecutablePath) {
        $filePath = [IO.Path]::GetFullPath($ExecutablePath)
        $argumentsText = ($Arguments | ForEach-Object { '"{0}"' -f $_ }) -join ' '
    }
    else {
        $filePath = 'dotnet'
        $argumentsText = (@($applicationDll) + $Arguments | ForEach-Object { '"{0}"' -f $_ }) -join ' '
    }
    $process = Start-Process -FilePath $filePath -ArgumentList $argumentsText -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit(10000)) { $process.Kill(); throw 'Pricing probe timed out' }
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) { throw 'Pricing probe failed' }
    return Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json
}

function New-Usage([string]$Model, [bool]$LongContext = $false, [long]$Writes = 0) {
    return @{ Model=$Model; TotalTokens=3000000; InputTokens=2000000; CachedInputTokens=1000000;
        OutputTokens=1000000; IsMainAgent=$true; IsLongContext=$LongContext; CacheWriteInputTokens=$Writes }
}

function New-TokenEvent([long]$InputCount, [long]$Cached, [long]$Writes, [long]$OutputCount, [long]$LastInput) {
    return (@{ type='event_msg'; payload=@{ type='token_count'; info=@{
        total_token_usage=@{ total_tokens=($InputCount + $OutputCount); input_tokens=$InputCount;
            cached_input_tokens=$Cached; cache_write_input_tokens=$Writes; output_tokens=$OutputCount; reasoning_output_tokens=0 }
        last_token_usage=@{ total_tokens=($LastInput + 10000); input_tokens=$LastInput; output_tokens=10000 }
        model_context_window=1050000
    } } } | ConvertTo-Json -Depth 8 -Compress)
}

try {
    if (-not $ExecutablePath) {
        & dotnet build (Join-Path $repositoryRoot 'src\CodexTokenOverlay\CodexTokenOverlay.csproj') -c Release --nologo
        if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
        $applicationDll = Join-Path $repositoryRoot 'src\CodexTokenOverlay\bin\Release\net10.0-windows\CodexTokenOverlay.dll'
    }

    # Fixed expected values test the official rates independently of the rate table.
    # Each usage represents a bucket containing many short requests, even though
    # its cumulative input is >272K. Only IsLongContext selects the long rate.
    $rateCases = @(
        @{ Name='sol61'; Usage=(New-Usage 'gpt-6.1-sol'); Expected='$12.10' },
        @{ Name='sol61-long'; Usage=(New-Usage 'gpt-6.1-sol' $true); Expected='$19.20' },
        @{ Name='sol6'; Usage=(New-Usage 'gpt-6-sol'); Expected='$12.20' },
        @{ Name='astra'; Usage=(New-Usage 'gpt-6-astra'); Expected='$61.00' },
        @{ Name='astra-long'; Usage=(New-Usage 'gpt-6-astra' $true); Expected='$97.00' },
        @{ Name='luna6'; Usage=(New-Usage 'gpt-6-luna'); Expected='$0.61' },
        @{ Name='luna6-long'; Usage=(New-Usage 'gpt-6-luna' $true); Expected='$0.97' },
        @{ Name='sol56'; Usage=(New-Usage 'gpt-5.6-sol'); Expected='$24.40' },
        @{ Name='sol56-alias'; Usage=(New-Usage 'gpt-5.6'); Expected='$24.40' },
        @{ Name='terra'; Usage=(New-Usage 'gpt-5.6-terra'); Expected='$14.20' },
        @{ Name='luna56'; Usage=(New-Usage 'gpt-5.6-luna'); Expected='$1.42' },
        @{ Name='gpt55'; Usage=(New-Usage 'gpt-5.5'); Expected='$35.50' },
        @{ Name='case-insensitive'; Usage=(New-Usage 'GPT-6.1-SOL'); Expected='$12.10' },
        @{ Name='cache-writes'; Usage=(New-Usage 'gpt-6.1-sol' $false 500000); Expected='$12.35' },
        @{ Name='cache-writes-long'; Usage=(New-Usage 'gpt-6.1-sol' $true 500000); Expected='$19.70' },
        @{ Name='unknown-model'; Usage=(New-Usage 'gpt-6.2-sol'); Expected='—' }
    )
    $cases = @($rateCases | ForEach-Object {
        @{ Name=$_.Name; Operation='Create'; Snapshot=@{ ThreadId='synthetic'; LogPath='synthetic';
            TotalTokens=3000000; InputTokens=2000000; OutputTokens=1000000; CachedInputTokens=1000000;
            PricingUsages=@($_.Usage) }; PrimaryField=1024; SecondaryField=1; VisibleFields=32767 }
    })
    $childShort = New-Usage 'gpt-6.1-sol'
    $childShort.IsMainAgent = $false
    $childShort.SessionId = 'one-child'
    $childLong = New-Usage 'gpt-6.1-sol' $true
    $childLong.IsMainAgent = $false
    $childLong.SessionId = 'one-child'
    $cases += @{ Name='one-child-two-buckets'; Operation='Create'; Snapshot=@{
        ThreadId='synthetic'; LogPath='synthetic'; TotalTokens=6000000; PricingUsages=@($childShort,$childLong)
    }; PrimaryField=4096; SecondaryField=16384; VisibleFields=32767 }
    $requestPath = Join-Path $probeRoot 'rates-request.json'
    $outputPath = Join-Path $probeRoot 'rates-output.json'
    [IO.File]::WriteAllText($requestPath, (@{Cases=$cases} | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    $response = Invoke-Probe @('--presentation-probe',$outputPath,$requestPath) $outputPath
    foreach ($rateCase in $rateCases) {
        $actual = @($response.Cases | Where-Object Name -EQ $rateCase.Name)[0].Presentation.Primary.Value
        Assert-Equal $actual $rateCase.Expected $rateCase.Name
    }
    $childResult = @($response.Cases | Where-Object Name -EQ 'one-child-two-buckets')[0].Presentation
    Assert-Equal $childResult.Primary.ExpandedLabel '子代理（GPT-6.1 Sol×1）' 'Buckets must not inflate agent count'
    Assert-Equal $childResult.Secondary.Value '$31.30' 'Short and long child costs must be summed'

    # Actual JSONL: Astra -> Sol 6.1, exactly 272K then 272K+1 input, duplicate
    # events, a context-only switch, and an incomplete final line.
    $threadId = '11111111-2222-3333-4444-555555555555'
    $sessions = Join-Path $probeRoot 'sessions'
    New-Item -ItemType Directory -Path $sessions | Out-Null
    $logPath = Join-Path $sessions "rollout-2026-09-30T00-00-00-$threadId.jsonl"
    $astraEvent = New-TokenEvent 200000 100000 40000 10000 200000
    $boundaryEvent = New-TokenEvent 472000 300000 40000 20000 272000
    $longEvent = New-TokenEvent 744001 500000 60000 30000 272001
    [IO.File]::WriteAllLines($logPath, [string[]]@(
        ('{"type":"session_meta","payload":{"id":"' + $threadId + '","originator":"Codex Desktop","source":"vscode"}}'),
        '{"type":"turn_context","payload":{"model":"gpt-6-astra"}}',
        (New-TokenEvent 2000000 1000000 400000 100000 200000),
        $astraEvent, $astraEvent,
        '{"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}',
        $boundaryEvent, $longEvent, $longEvent,
        '{"type":"turn_context","payload":{"model":"gpt-6-luna"}}',
        '{"type":"event_msg","payload":{"type":"token_count"'
    ), [Text.UTF8Encoding]::new($false))
    $snapshotPath = Join-Path $probeRoot 'parsed.json'
    $snapshot = Invoke-Probe @('--probe',$snapshotPath,'--sessions',$sessions) $snapshotPath
    Assert-Equal $snapshot.TotalTokens 774001 'Latest total must not sum cumulative events'
    Assert-Equal $snapshot.PricingUsages.Count 3 'Model and context buckets'
    $astra = @($snapshot.PricingUsages | Where-Object Model -EQ 'gpt-6-astra')
    Assert-Equal $astra[0].InputTokens 200000 'Astra tokens remain at Astra rates'
    Assert-Equal $astra[0].CacheWriteInputTokens 40000 'Cache-write counters parsed'
    $short = @($snapshot.PricingUsages | Where-Object { $_.Model -eq 'gpt-6.1-sol' -and -not $_.IsLongContext })
    $long = @($snapshot.PricingUsages | Where-Object { $_.Model -eq 'gpt-6.1-sol' -and $_.IsLongContext })
    Assert-Equal $short[0].InputTokens 272000 '272K exact boundary is short'
    Assert-Equal $long[0].InputTokens 272001 '272K+1 boundary is long'
    Assert-Equal @($snapshot.PricingUsages | Where-Object Model -EQ 'gpt-6-luna').Count 0 'Context-only model switch must not reprice history'
    [IO.File]::WriteAllText($requestPath, (@{Cases=@(@{
        Name='history'; Operation='Create'; Snapshot=$snapshot; PrimaryField=1024; SecondaryField=1; VisibleFields=32767
    })} | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $response = Invoke-Probe @('--presentation-probe',$outputPath,$requestPath) $outputPath
    Assert-Equal $response.Cases[0].Presentation.Primary.Value '$2.46' 'Mixed model, long context and writes combined'
    $mainLabel = @($response.Cases[0].Presentation.ExpandedRows | Where-Object Field -EQ 2048)[0].ExpandedLabel
    Assert-Equal $mainLabel '主代理（GPT-6 Luna）' 'Display current model while pricing each historical model'
    Write-Host "费用规则测试通过：$($rateCases.Count) 个单价案例、子代理计数、切换模型、重复事件、长上下文边界、缓存写入。"
}
finally {
    $resolvedRoot = [IO.Path]::GetFullPath($probeRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedRoot).StartsWith('CodexTokenPricing-')) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
