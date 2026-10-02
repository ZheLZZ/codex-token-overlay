param(
    [string]$DotnetPath = 'dotnet',
    [string]$TargetFramework = 'net10.0-windows',
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new()
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $repositoryRoot 'src\CodexTokenOverlay\CodexTokenOverlay.csproj'
$applicationDll = Join-Path $repositoryRoot "src\CodexTokenOverlay\bin\Release\$TargetFramework\CodexTokenOverlay.dll"
$temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testDirectoryName = 'CodexVisibleThreadRoute-' + [Guid]::NewGuid().ToString('N')
$testRoot = [IO.Path]::GetFullPath((Join-Path $temporaryParent $testDirectoryName))
$script:assertionCount = 0
$utf8 = [Text.UTF8Encoding]::new($false)

function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:assertionCount++
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
    Assert-Condition ($Actual -eq $Expected) "$Message expected=$Expected actual=$Actual"
}

function Assert-ThreadSet($Actual, [string[]]$Expected, [string]$Message) {
    $actualKey = @($Actual | Sort-Object) -join ','
    $expectedKey = @($Expected | Sort-Object) -join ','
    Assert-Equal $actualKey $expectedKey $Message
}

function Invoke-Probe([string[]]$Arguments, [string]$OutputPath) {
    # Start-Process is required because the application is a Windows GUI binary.
    # These arguments contain only generated paths, IDs, and fixed probe switches.
    $argumentsText = (@($applicationDll) + $Arguments | ForEach-Object { '"{0}"' -f $_ }) -join ' '
    $process = Start-Process -FilePath $DotnetPath -ArgumentList $argumentsText -WindowStyle Hidden -PassThru
    try {
        if (-not $process.WaitForExit(15000)) {
            $process.Kill()
            $process.WaitForExit()
            throw 'Visible-thread probe timed out.'
        }
        Assert-Equal $process.ExitCode 0 'Visible-thread probe failed.'
        Assert-Condition (Test-Path -LiteralPath $OutputPath -PathType Leaf) 'Probe output was not created.'
        return Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    finally {
        $process.Dispose()
    }
}

function New-FollowingFrame(
    [string]$ClientId, [string]$HostId, [string]$ThreadId, [bool]$Following = $true
) {
    return @{
        type = 'broadcast'; method = 'thread-stream-following-changed'; sourceClientId = $ClientId
        params = @{ conversationId = $ThreadId; hostId = $HostId; following = $Following }
    }
}

function New-DisconnectedFrame([string]$ClientId) {
    return @{
        type = 'broadcast'; method = 'client-status-changed'
        params = @{ clientId = $ClientId; status = 'disconnected' }
    }
}

function Write-SyntheticSession([string]$Directory, [string]$ThreadId, [long]$Total, [long]$ContextUsed) {
    $path = Join-Path $Directory "rollout-2026-01-01T00-00-00-$ThreadId.jsonl"
    $inputCount = $Total - 2000
    $lines = @(
        (@{ type = 'session_meta'; payload = @{ id = $ThreadId; originator = 'Codex Desktop'; source = 'vscode' } } | ConvertTo-Json -Depth 5 -Compress),
        '{"type":"turn_context","payload":{"model":"gpt-6-sol"}}',
        (@{ type = 'event_msg'; payload = @{ type = 'token_count'; info = @{
            total_token_usage = @{ total_tokens = $Total; input_tokens = $inputCount; cached_input_tokens = 4000; output_tokens = 2000; reasoning_output_tokens = 500 }
            last_token_usage = @{ total_tokens = $ContextUsed; input_tokens = $ContextUsed - 100; output_tokens = 100 }
            model_context_window = 128000
        } } } | ConvertTo-Json -Depth 8 -Compress)
    )
    [IO.File]::WriteAllLines($path, [string[]]$lines, $utf8)
    return $path
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    if (-not $SkipBuild) {
        & $DotnetPath build $projectPath -c Release --nologo "-p:TargetFramework=$TargetFramework"
        if ($LASTEXITCODE -ne 0) { throw 'Project build failed.' }
    }
    Assert-Condition (Test-Path -LiteralPath $applicationDll -PathType Leaf) 'Release application DLL is missing.'

    # All IDs, titles, broadcasts, and sessions below are synthetic. No real
    # Codex logs or catalog files are read by these probes.
    $localIds = @(
        'aaaaaaaa-1111-2222-3333-444444444441',
        'aaaaaaaa-1111-2222-3333-444444444442',
        'aaaaaaaa-1111-2222-3333-444444444443',
        'aaaaaaaa-1111-2222-3333-444444444444',
        'aaaaaaaa-1111-2222-3333-444444444445'
    )
    $remoteId = 'bbbbbbbb-1111-2222-3333-444444444446'
    $remoteHostId = 'remote-control:synthetic-host'
    $replayFrames = @($localIds | ForEach-Object { New-FollowingFrame 'client-a' 'local' $_ })
    $replayFrames += New-FollowingFrame 'client-a' $remoteHostId $remoteId

    $cases = @(
        @{ Name = 'replay-is-subscriptions'; DisplayTitle = 'Unknown visible page'; CandidateThreadIds = @(); Frames = $replayFrames },
        @{ Name = 'visible-local-survives-late-remote'; DisplayTitle = 'Visible local chat'; CandidateThreadIds = @($localIds[4]); Frames = $replayFrames;
            FramesAfterSelection = @((New-FollowingFrame 'client-a' $remoteHostId $remoteId)) },
        @{ Name = 'unfollow-removes-only-one-thread'; DisplayTitle = 'Visible local chat'; CandidateThreadIds = @($localIds[4]);
            Frames = @($replayFrames) + @((New-FollowingFrame 'client-a' 'local' $localIds[2] $false)) },
        @{ Name = 'unfollow-is-host-specific'; DisplayTitle = 'Visible local chat'; CandidateThreadIds = @($localIds[0]); Frames = @(
            (New-FollowingFrame 'client-a' 'local' $localIds[0]),
            (New-FollowingFrame 'client-a' $remoteHostId $localIds[0]),
            (New-FollowingFrame 'client-a' 'local' $localIds[1]),
            (New-FollowingFrame 'client-a' $remoteHostId $localIds[0] $false)
        ) },
        @{ Name = 'disconnect-keeps-other-client'; DisplayTitle = 'Visible second client'; CandidateThreadIds = @($localIds[0]);
            Frames = @($replayFrames) + @((New-FollowingFrame 'client-b' 'local' $localIds[0]), (New-DisconnectedFrame 'client-a')) },
        @{ Name = 'duplicate-subscription-counts-once'; DisplayTitle = 'Visible chat'; CandidateThreadIds = @($localIds[0]); Frames = @(
            (New-FollowingFrame 'client-a' 'local' $localIds[0]), (New-FollowingFrame 'client-a' 'local' $localIds[0])
        ) },
        @{ Name = 'unique-display-title'; DisplayTitle = 'Visible unique title'; CandidateThreadIds = @($localIds[0]); LocalFollowingThreadIds = @($localIds[1]) },
        @{ Name = 'duplicate-title-unique-local-following'; DisplayTitle = 'Duplicate title'; CandidateThreadIds = @($localIds[0], $localIds[1]); LocalFollowingThreadIds = @($localIds[1]) },
        @{ Name = 'duplicate-title-actual-ipc'; DisplayTitle = 'Duplicate title'; CandidateThreadIds = @($localIds[0], $localIds[1]);
            LocalFollowingThreadIds = @($localIds[1]); Frames = @((New-FollowingFrame 'client-a' 'local' $localIds[0])) },
        @{ Name = 'duplicate-title-still-ambiguous'; DisplayTitle = 'Duplicate title'; CandidateThreadIds = @($localIds[0], $localIds[1]); LocalFollowingThreadIds = @($localIds[0], $localIds[1]) },
        @{ Name = 'duplicate-title-no-following-match'; DisplayTitle = 'Duplicate title'; CandidateThreadIds = @($localIds[0], $localIds[1]); LocalFollowingThreadIds = @($localIds[2]) },
        @{ Name = 'home-page'; DisplayTitle = 'ChatGPT'; CandidateThreadIds = @($localIds[0]); LocalFollowingThreadIds = @($localIds[0]) },
        @{ Name = 'no-document'; HasDocument = $false; DisplayTitle = 'Unavailable document'; CandidateThreadIds = @($localIds[0]) },
        @{ Name = 'empty-document-title'; DisplayTitle = '  '; CandidateThreadIds = @($localIds[0]) },
        @{ Name = 'no-window'; HasWindow = $false; DisplayTitle = 'Inactive window'; CandidateThreadIds = @($localIds[0]) },
        @{ Name = 'unknown-remote-never-local-fallback'; DisplayTitle = 'Remote visible chat'; CandidateThreadIds = @();
            Frames = @((New-FollowingFrame 'client-a' 'local' $localIds[0]), (New-FollowingFrame 'client-a' $remoteHostId $remoteId)) },
        @{ Name = 'cloud-same-title-never-local-match'; IsCloudChat = $true; DisplayTitle = 'Visible cloud chat';
            CandidateThreadIds = @($localIds[0]); LocalFollowingThreadIds = @($localIds[0]) },
        @{ Name = 'observer-declines-discovery'; DisplayTitle = 'Home'; CandidateThreadIds = @(); Frames = @(
            @{ type = 'client-discovery-request'; requestId = 'synthetic-discovery'; request = @{ method = 'ide-context'; params = @{ workspaceRoot = 'synthetic-workspace' } } },
            @{ type = 'client-discovery-request'; requestId = 123; request = @{ method = 'ide-context' } }
        ) }
    )
    $requestPath = Join-Path $testRoot 'route-input.json'
    $outputPath = Join-Path $testRoot 'route-output.json'
    [IO.File]::WriteAllText($requestPath, (@{ Cases = $cases } | ConvertTo-Json -Depth 20), $utf8)
    $route = Invoke-Probe @('--route-probe', $outputPath, $requestPath) $outputPath
    $results = @{}
    foreach ($case in $route.Cases) { $results[$case.Name] = $case }
    Assert-Equal $results.Count $cases.Count 'Not all route cases were executed.'

    $replay = $results['replay-is-subscriptions']
    Assert-Equal $replay.Status.SubscribedThreadCount 6 'Replay must preserve all six subscriptions.'
    Assert-Equal $replay.Status.ActiveWindowCount 1 'A single IPC client must count once across hosts.'
    Assert-ThreadSet $replay.LocalFollowingThreadIds $localIds 'Remote subscription contaminated local candidates.'
    Assert-Equal $replay.Status.ThreadId $null 'Subscriptions alone must not choose the visible chat.'

    $lateRemote = $results['visible-local-survives-late-remote']
    Assert-Equal $lateRemote.Selection.ThreadId $localIds[4] 'Visible local title was not selected.'
    Assert-Equal $lateRemote.Status.ThreadId $localIds[4] 'A later remote broadcast overrode the visible local chat.'
    Assert-Equal $lateRemote.Status.SubscribedThreadCount 6 'Repeated remote broadcast lost a subscription.'
    Assert-Equal $lateRemote.Status.ActiveWindowCount 1 'Repeated remote broadcast changed the client count.'

    $unfollow = $results['unfollow-removes-only-one-thread']
    Assert-Equal $unfollow.Status.SubscribedThreadCount 5 'Unfollowing one local thread removed other subscriptions.'
    Assert-ThreadSet $unfollow.LocalFollowingThreadIds @($localIds[0], $localIds[1], $localIds[3], $localIds[4]) 'Unfollow removed the wrong local thread.'
    Assert-Equal $unfollow.Status.ThreadId $localIds[4] 'Unfollowing another chat changed the visible route.'
    Assert-Equal $results['unfollow-is-host-specific'].Status.SubscribedThreadCount 2 'Unfollow must include host identity.'
    Assert-ThreadSet $results['unfollow-is-host-specific'].LocalFollowingThreadIds @($localIds[0], $localIds[1]) 'Remote unfollow removed the matching local subscription.'

    $disconnect = $results['disconnect-keeps-other-client']
    Assert-Equal $disconnect.Status.SubscribedThreadCount 1 'Disconnect did not clear only the matching client.'
    Assert-Equal $disconnect.Status.ActiveWindowCount 1 'Remaining IPC client was lost after another disconnected.'
    Assert-ThreadSet $disconnect.LocalFollowingThreadIds @($localIds[0]) 'Disconnect cleared another client subscription.'
    Assert-Equal $results['duplicate-subscription-counts-once'].Status.SubscribedThreadCount 1 'Duplicate broadcast inflated subscription count.'

    foreach ($expected in @(
        @{ Name = 'unique-display-title'; Id = $localIds[0] },
        @{ Name = 'duplicate-title-unique-local-following'; Id = $localIds[1] },
        @{ Name = 'duplicate-title-actual-ipc'; Id = $localIds[0] }
    )) {
        Assert-Equal $results[$expected.Name].Selection.ThreadId $expected.Id "$($expected.Name) selected the wrong thread."
        Assert-Equal $results[$expected.Name].Status.ThreadId $expected.Id "$($expected.Name) was not published to route status."
    }
    foreach ($waitingCase in @(
        'duplicate-title-still-ambiguous', 'duplicate-title-no-following-match',
        'home-page', 'no-document', 'empty-document-title', 'no-window',
        'unknown-remote-never-local-fallback', 'cloud-same-title-never-local-match'
    )) {
        Assert-Equal $results[$waitingCase].Selection.ThreadId $null "$waitingCase must wait instead of guessing a thread."
        Assert-Equal $results[$waitingCase].Status.ThreadId $null "$waitingCase retained a stale visible route."
    }
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($results['duplicate-title-still-ambiguous'].Selection.Reason)) 'Duplicate titles did not report a waiting reason.'
    Assert-Condition ($results['duplicate-title-still-ambiguous'].Selection.Reason -ne $results['unique-display-title'].Selection.Reason) 'Ambiguous and synchronized routes reported the same status.'
    Assert-Equal $results['home-page'].Selection.Reason ([regex]::Unescape('\u975e\u804a\u5929\u9875\u9762')) 'Home must report a non-chat page despite a same-title local candidate.'
    $responses = @($results['observer-declines-discovery'].DiscoveryResponses)
    Assert-Equal $responses.Count 1 'Discovery response accepted an invalid request ID.'
    Assert-Equal $responses[0].type 'client-discovery-response' 'Wrong discovery response type.'
    Assert-Equal $responses[0].requestId 'synthetic-discovery' 'Discovery response did not preserve request ID.'
    Assert-Equal $responses[0].response.canHandle $false 'Read-only observer must decline handling application requests.'

    $sessionRoot = Join-Path $testRoot 'sessions'
    $sessionDirectory = Join-Path $sessionRoot '2026\01\01'
    New-Item -ItemType Directory -Path $sessionDirectory -Force | Out-Null
    $firstPath = Write-SyntheticSession $sessionDirectory $localIds[0] 11000 1000
    $secondPath = Write-SyntheticSession $sessionDirectory $localIds[1] 22000 2000
    [IO.File]::SetLastWriteTimeUtc($firstPath, [DateTime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc))
    [IO.File]::SetLastWriteTimeUtc($secondPath, [DateTime]::new(2026, 1, 2, 0, 0, 0, [DateTimeKind]::Utc))
    $firstVersion = [IO.File]::GetLastWriteTimeUtc($firstPath).Ticks
    $secondVersion = [IO.File]::GetLastWriteTimeUtc($secondPath).Ticks
    $strictPath = Join-Path $testRoot 'strict-route-output.json'
    $strict = Invoke-Probe @('--strict-route-probe', $strictPath, $localIds[0], $localIds[1], '--sessions', $sessionRoot) $strictPath
    Assert-Equal $strict.Initial $null 'Strict routing must not automatically select the newest log.'
    Assert-Equal $strict.First.ThreadId $localIds[0] 'Explicit route did not choose the older idle session.'
    Assert-Equal $strict.First.TotalTokens 11000 'First idle session token total is wrong.'
    Assert-Equal $strict.Cleared $null 'Clearing the visible route retained a token snapshot.'
    Assert-Equal $strict.ClearedId $null 'Clearing the visible route retained its thread ID.'
    Assert-Equal $strict.Pinned.ThreadId $localIds[0] 'Pinning did not retain the selected session when the visible route cleared.'
    Assert-Equal $strict.Pinned.TotalTokens 11000 'Pinned snapshot changed after clearing the visible route.'
    Assert-Equal $strict.Switched.ThreadId $localIds[1] 'Idle route switch did not choose the second session.'
    Assert-Equal $strict.Switched.TotalTokens 22000 'Idle route switch retained the old token total.'
    Assert-Equal $strict.Switched.ContextUsedTokens 2000 'Idle route switch retained old context usage.'
    Assert-Equal ([IO.File]::GetLastWriteTimeUtc($firstPath).Ticks) $firstVersion 'First session changed during read-only probes.'
    Assert-Equal ([IO.File]::GetLastWriteTimeUtc($secondPath).Ticks) $secondVersion 'Second session changed during read-only probes.'

    # Use the built assembly in a separate temporary host to verify that losing
    # the entire synthetic sessions directory clears its cached snapshot/route.
    # The helper guards both absolute paths before moving this generated fixture.
    $helperDirectory = Join-Path $testRoot 'directory-loss-helper'
    New-Item -ItemType Directory -Path $helperDirectory | Out-Null
    $helperProject = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><OutputType>Exe</OutputType><TargetFramework>$([Security.SecurityElement]::Escape($TargetFramework))</TargetFramework><UseWindowsForms>true</UseWindowsForms><UseWPF>true</UseWPF><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup>
</Project>
"@
    $helperProgram = @'
using System;
using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Text.RegularExpressions;

var assemblyPath = Path.GetFullPath(args[0]);
var fixtureRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(args[1]));
var sessions = Path.GetFullPath(args[2]);
var expectedThreadId = args[3];
var outputPath = Path.GetFullPath(args[4]);
var temporaryPrefix = Path.TrimEndingDirectorySeparator(Path.GetFullPath(Path.GetTempPath())) + Path.DirectorySeparatorChar;
if (!fixtureRoot.StartsWith(temporaryPrefix, StringComparison.OrdinalIgnoreCase)
    || !Regex.IsMatch(Path.GetFileName(fixtureRoot), "^CodexVisibleThreadRoute-[0-9a-f]{32}$")
    || (File.GetAttributes(fixtureRoot) & FileAttributes.ReparsePoint) != 0)
    throw new Exception("Refusing to use a fixture outside the generated temporary root");
string GuardChild(string path, string expectedName)
{
    var full = Path.GetFullPath(path);
    var expected = Path.Combine(fixtureRoot, expectedName);
    if (!full.Equals(expected, StringComparison.OrdinalIgnoreCase)
        || !full.StartsWith(fixtureRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
        || (Directory.Exists(full) && (File.GetAttributes(full) & FileAttributes.ReparsePoint) != 0))
        throw new Exception("Refusing to move a directory outside the generated fixture root");
    return full;
}
sessions = GuardChild(sessions, "sessions");
var unavailableSessions = GuardChild(Path.Combine(fixtureRoot, "sessions-unavailable-fixture"), "sessions-unavailable-fixture");
if (Directory.Exists(unavailableSessions)) throw new Exception("Unexpected destination fixture already exists");
if (!outputPath.Equals(Path.Combine(fixtureRoot, "directory-loss-output.json"), StringComparison.OrdinalIgnoreCase))
    throw new Exception("Refusing to write helper output outside the generated fixture root");

var monitorType = Assembly.LoadFrom(assemblyPath).GetType("CodexTokenOverlay.TokenLogMonitor", throwOnError: true)!;
var monitor = Activator.CreateInstance(monitorType, new object[] { sessions })!;
var poll = monitorType.GetMethod("Poll")!;
var activeId = monitorType.GetProperty("ActiveThreadId")!;
var activeVersion = monitorType.GetProperty("ActiveSessionVersion")!;
bool moved = false;
try
{
    monitorType.GetProperty("RequirePreferredThread")!.SetValue(monitor, true);
    monitorType.GetProperty("PreferredThreadId")!.SetValue(monitor, expectedThreadId);
    var first = poll.Invoke(monitor, new object[] { false });
    if (first is null || (string?)activeId.GetValue(monitor) != expectedThreadId
        || (long?)first.GetType().GetProperty("TotalTokens")!.GetValue(first) != 11000)
        throw new Exception("The synthetic session was not cached before directory loss");
    var beforeVersion = (long)activeVersion.GetValue(monitor)!;
    // Revalidate the exact source and destination immediately before moving.
    Directory.Move(GuardChild(sessions, "sessions"), GuardChild(unavailableSessions, "sessions-unavailable-fixture"));
    moved = true;
    var cleared = poll.Invoke(monitor, new object[] { false });
    var clearedId = (string?)activeId.GetValue(monitor);
    var afterVersion = (long)activeVersion.GetValue(monitor)!;
    File.WriteAllText(outputPath, JsonSerializer.Serialize(new {
        InitialSnapshotPresent = first is not null,
        ClearedSnapshot = cleared is null,
        ClearedId = clearedId,
        BeforeVersion = beforeVersion,
        AfterVersion = afterVersion
    }));
}
finally
{
    try
    {
        if (moved)
            Directory.Move(GuardChild(unavailableSessions, "sessions-unavailable-fixture"), GuardChild(sessions, "sessions"));
    }
    finally { ((IDisposable)monitor).Dispose(); }
}
'@
    $helperProjectPath = Join-Path $helperDirectory 'helper.csproj'
    $directoryLossOutput = Join-Path $testRoot 'directory-loss-output.json'
    [IO.File]::WriteAllText($helperProjectPath, $helperProject, $utf8)
    [IO.File]::WriteAllText((Join-Path $helperDirectory 'Program.cs'), $helperProgram, $utf8)
    & $DotnetPath run --project $helperProjectPath --configuration Release -- $applicationDll $testRoot $sessionRoot $localIds[0] $directoryLossOutput
    if ($LASTEXITCODE -ne 0) { throw 'Synthetic session-directory loss helper failed.' }
    $directoryLoss = Get-Content -LiteralPath $directoryLossOutput -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal $directoryLoss.InitialSnapshotPresent $true 'Directory-loss fixture never formed its initial snapshot.'
    Assert-Equal $directoryLoss.ClearedSnapshot $true 'Unavailable sessions directory retained a cached snapshot.'
    Assert-Equal $directoryLoss.ClearedId $null 'Unavailable sessions directory retained its active thread ID.'
    Assert-Condition ($directoryLoss.AfterVersion -gt $directoryLoss.BeforeVersion) 'Unavailable sessions directory did not increment its route version.'
    Assert-Condition (Test-Path -LiteralPath $sessionRoot -PathType Container) 'Synthetic sessions directory was not restored.'

    Write-Output "PASS: visible-thread routing ($($cases.Count) cases, $script:assertionCount checks), subscription replay, discovery, and strict idle-session switching."
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedRoot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $testRoot).ProviderPath)
        $temporaryPrefix = $temporaryParent.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedRoot.Equals($testRoot, [StringComparison]::OrdinalIgnoreCase) -or
            -not $resolvedRoot.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolvedRoot) -ne $testDirectoryName) {
            throw 'Refusing cleanup outside the generated test directory.'
        }
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
