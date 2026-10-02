param(
    [string]$DotnetPath = 'dotnet',
    [string]$TargetFramework = 'net10.0-windows'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new()
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$indexSource = Join-Path $repositoryRoot 'src\CodexTokenOverlay\LocalThreadTitleIndex.cs'
$temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testDirectoryName = 'CodexLocalTitleIndex-' + [Guid]::NewGuid().ToString('N')
$testRoot = [IO.Path]::GetFullPath((Join-Path $temporaryParent $testDirectoryName))
$utf8 = [Text.UTF8Encoding]::new($false)

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    # Compile only the catalog reader in an isolated temporary console project.
    # This never rebuilds or competes for the overlay application's artifacts.
    $sourceXml = [Security.SecurityElement]::Escape($indexSource)
    $frameworkXml = [Security.SecurityElement]::Escape($TargetFramework)
    $project = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><OutputType>Exe</OutputType><TargetFramework>$frameworkXml</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup>
  <ItemGroup><Compile Include="$sourceXml" Link="LocalThreadTitleIndex.cs" /></ItemGroup>
</Project>
"@
    $program = @'
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using CodexTokenOverlay;

var root = args[0];
int checks = 0;
void Require(bool condition, string message) { if (!condition) throw new Exception(message); checks++; }
LocalThreadTitleIndex Reader(string name) => new(Path.Combine(root, name, "sessions"));
string Catalog(string name, int version, string schema, params string[] statements)
{
    var directory = Path.Combine(root, name);
    Directory.CreateDirectory(Path.Combine(directory, "sessions"));
    var path = Path.Combine(directory, $"state_{version}.sqlite");
    var result = Native.sqlite3_open_v2(path, out var connection, 2 | 4, IntPtr.Zero);
    try
    {
        Require(result == 0 && connection != IntPtr.Zero, "Synthetic fixture database could not open");
        Require(Native.sqlite3_exec(connection, schema + string.Join("", statements), IntPtr.Zero, IntPtr.Zero, IntPtr.Zero) == 0, "Synthetic fixture schema failed");
    }
    finally { if (connection != IntPtr.Zero) Native.sqlite3_close(connection); }
    return path;
}
void Matches(LocalThreadTitleIndex reader, string title, params string[] expected)
{
    var actual = reader.ReadCandidates(title);
    Require(actual.SequenceEqual(expected), $"Candidate mismatch; status={reader.LastMatchStatus}, error={reader.LastError}");
}

// Fixture values are deliberately synthetic, including the legacy prompt column.
// Native write calls below are restricted to this newly generated test directory.
var unicodeTitle = "\u5c4f\u5e55\u804a\u5929 ' ; DROP TABLE threads;--";
var oldTitle = "\u65e7\u6807\u9898";
Catalog("modern", 4, "CREATE TABLE threads(id TEXT, title TEXT);", "INSERT INTO threads VALUES('wrong-version','same');");
var dbPath = Catalog("modern", 12, "CREATE TABLE threads(id TEXT PRIMARY KEY, title TEXT, name TEXT);",
    "INSERT INTO threads VALUES('id-a','synthetic seed-a','same');",
    "INSERT INTO threads VALUES('id-b','synthetic seed-b','same');",
    "INSERT INTO threads VALUES('id-seed','same','other display');",
    "INSERT INTO threads VALUES('id-display','synthetic hidden seed','  " + unicodeTitle.Replace("'", "''") + "  ');",
    "INSERT INTO threads VALUES('id-fallback','legacy display',NULL);",
    "INSERT INTO threads VALUES('id-empty-name','empty-name fallback','');",
    "INSERT INTO threads VALUES('id-case','synthetic seed','Case');");
File.WriteAllText(Path.Combine(root, "modern", "state_bad.sqlite"), "not a database");
Catalog("legacy", 5, "CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT);", "INSERT INTO threads VALUES('legacy-id','" + oldTitle + "');");
Catalog("nameonly", 5, "CREATE TABLE threads(id TEXT PRIMARY KEY,name TEXT);", "INSERT INTO threads VALUES('name-only-id','name-only display');");
Catalog("badschema", 5, "CREATE TABLE threads(id TEXT PRIMARY KEY);");
var lockPath = Catalog("locked", 5, "CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT);", "INSERT INTO threads VALUES('lock-id','locked title');");
Directory.CreateDirectory(Path.Combine(root, "missing", "sessions"));
Directory.CreateDirectory(Path.Combine(root, "corrupt", "sessions"));
File.WriteAllText(Path.Combine(root, "corrupt", "state_5.sqlite"), "not a SQLite database");

var modern = Reader("modern");
var before = SHA256.HashData(File.ReadAllBytes(dbPath));
Matches(modern, "same", "id-a", "id-b");
Require(modern.LastMatchStatus == LocalThreadTitleMatchStatus.Ambiguous, "Duplicate names must stay ambiguous");
Require(modern.StatePath == dbPath, "Numeric state version selection failed");
Matches(modern, unicodeTitle, "id-display");
Require(modern.LastMatchStatus == LocalThreadTitleMatchStatus.Unique, "Unicode/parameter binding failed");
Matches(modern, "legacy display", "id-fallback");
Matches(modern, "empty-name fallback", "id-empty-name");
Matches(modern, "synthetic seed-a");
Require(modern.LastMatchStatus == LocalThreadTitleMatchStatus.NoMatch, "Nonempty display name must suppress seed title");
Matches(modern, "case");
Matches(modern, "  same  ", "id-a", "id-b");
Matches(modern, "");
Require(modern.LastMatchStatus == LocalThreadTitleMatchStatus.EmptyTitle, "Empty title must not query");
Matches(modern, "same\0other");
Require(modern.LastError == "invalid-display-title", "Embedded NUL was not rejected");
for (int i = 0; i < 20; i++) Matches(modern, "same", "id-a", "id-b");
Require(before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(dbPath))), "Read-only query changed database bytes");
Require(!File.Exists(dbPath + "-journal"), "Reader unexpectedly created a journal");
Matches(Reader("legacy"), oldTitle, "legacy-id");
Matches(Reader("nameonly"), "name-only display", "name-only-id");
var missing = Reader("missing"); Matches(missing, "any");
Require(missing.LastMatchStatus == LocalThreadTitleMatchStatus.StateUnavailable, "Missing state handling failed");
var schema = Reader("badschema"); Matches(schema, "any");
Require(schema.LastError == "unsupported-thread-schema", "Bad schema handling failed");
var corrupt = Reader("corrupt"); Matches(corrupt, "any");
Require(corrupt.LastMatchStatus == LocalThreadTitleMatchStatus.Error && corrupt.LastError != null, "Corrupt file handling failed");
Native.sqlite3_open_v2(lockPath, out var writer, 2, IntPtr.Zero);
try
{
    Require(writer != IntPtr.Zero, "Fixture lock connection unavailable");
    Require(Native.sqlite3_exec(writer, "BEGIN EXCLUSIVE;", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero) == 0, "Could not lock synthetic fixture");
    var locked = Reader("locked"); var stopwatch = Stopwatch.StartNew(); Matches(locked, "locked title"); stopwatch.Stop();
    Require(locked.LastMatchStatus == LocalThreadTitleMatchStatus.Error, "Busy query must not return incomplete IDs");
    Require(stopwatch.Elapsed < TimeSpan.FromSeconds(2), "Busy timeout exceeded its bound");
    Require(Native.sqlite3_exec(writer, "ROLLBACK;", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero) == 0, "Synthetic fixture unlock failed");
    Matches(locked, "locked title", "lock-id");
}
finally { if (writer != IntPtr.Zero) Native.sqlite3_close(writer); }
File.Delete(lockPath);
Require(!File.Exists(lockPath), "Reader leaked a database handle");
Console.WriteLine($"PASS: local thread-title index ({checks} checks), native SQLite, duplicate titles, display-name precedence, schema compatibility, binding, read-only bytes, bounded locks, and resource release.");

static class Native
{
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] public static extern int sqlite3_open_v2([MarshalAs(UnmanagedType.LPUTF8Str)] string path, out IntPtr connection, int flags, IntPtr vfs);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] public static extern int sqlite3_exec(IntPtr connection, [MarshalAs(UnmanagedType.LPUTF8Str)] string sql, IntPtr callback, IntPtr callbackArgument, IntPtr error);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] public static extern int sqlite3_close(IntPtr connection);
}
'@
    $projectPath = Join-Path $testRoot 'probe.csproj'
    [IO.File]::WriteAllText($projectPath, $project, $utf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'Program.cs'), $program, $utf8)
    & $DotnetPath run --project $projectPath --configuration Release -- $testRoot
    if ($LASTEXITCODE -ne 0) { throw 'Local thread-title index checks failed.' }
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
