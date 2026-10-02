using System.Globalization;
using System.Runtime.InteropServices;

namespace CodexTokenOverlay;

internal enum LocalThreadTitleMatchStatus
{
    EmptyTitle,
    StateUnavailable,
    NoMatch,
    Unique,
    Ambiguous,
    Error
}

/// <summary>
/// Resolves a visible conversation title through the local Codex catalog without
/// writing to the catalog or exposing its title/prompt fields to callers.
/// </summary>
internal sealed class LocalThreadTitleIndex
{
    private const int SqliteOk = 0;
    private const int SqliteRow = 100;
    private const int SqliteDone = 101;
    private const int SqliteOpenReadOnly = 0x00000001;
    private const int BusyTimeoutMilliseconds = 100;
    private static readonly IntPtr SqliteTransient = new(-1);
    private readonly string? _catalogDirectory;
    private readonly object _sync = new();

    public string? StatePath { get; private set; }
    public string? LastError { get; private set; }
    public LocalThreadTitleMatchStatus LastMatchStatus { get; private set; } =
        LocalThreadTitleMatchStatus.StateUnavailable;

    public LocalThreadTitleIndex(string sessionRoot)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sessionRoot);
        var normalizedRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(sessionRoot));
        _catalogDirectory = Directory.GetParent(normalizedRoot)?.FullName;
    }

    /// <summary>
    /// Returns every matching ID. A caller must resolve duplicate display titles
    /// against an independent window/route signal rather than catalog recency.
    /// </summary>
    public IReadOnlyList<string> ReadCandidates(string displayTitle)
    {
        lock (_sync)
        {
            LastError = null;
            if (string.IsNullOrWhiteSpace(displayTitle))
            {
                LastMatchStatus = LocalThreadTitleMatchStatus.EmptyTitle;
                return Array.Empty<string>();
            }

            var title = displayTitle.Trim();
            if (title.Contains('\0'))
            {
                LastError = "invalid-display-title";
                LastMatchStatus = LocalThreadTitleMatchStatus.Error;
                return Array.Empty<string>();
            }

            var connection = IntPtr.Zero;
            try
            {
                StatePath = FindStatePath();
                if (StatePath is null)
                {
                    LastError = "state-database-not-found";
                    LastMatchStatus = LocalThreadTitleMatchStatus.StateUnavailable;
                    return Array.Empty<string>();
                }

                CheckResult(Native.sqlite3_open_v2(
                    StatePath,
                    out connection,
                    SqliteOpenReadOnly,
                    IntPtr.Zero), "open");
                CheckResult(Native.sqlite3_busy_timeout(connection, BusyTimeoutMilliseconds), "busy-timeout");

                var columns = ReadThreadColumns(connection);
                if (!columns.Contains("id")
                    || (!columns.Contains("name") && !columns.Contains("title")))
                {
                    LastError = "unsupported-thread-schema";
                    LastMatchStatus = LocalThreadTitleMatchStatus.Error;
                    return Array.Empty<string>();
                }

                // Newer catalogs separate the display name from the initial user
                // prompt. Read the legacy title only when no display name exists.
                var titleExpression = columns.Contains("name")
                    ? columns.Contains("title")
                        ? "coalesce(nullif(name, ''), title)"
                        : "nullif(name, '')"
                    : "title";
                var candidates = ReadMatchingIds(connection, titleExpression, title);
                LastMatchStatus = candidates.Count switch
                {
                    0 => LocalThreadTitleMatchStatus.NoMatch,
                    1 => LocalThreadTitleMatchStatus.Unique,
                    _ => LocalThreadTitleMatchStatus.Ambiguous
                };
                return candidates;
            }
            catch (SqliteReadException exception)
            {
                // Error codes/stages contain no catalog titles or conversation data.
                LastError = $"sqlite-{exception.Stage}-{exception.ResultCode}";
            }
            catch (Exception exception) when (exception is IOException
                or UnauthorizedAccessException
                or ArgumentException
                or NotSupportedException
                or DllNotFoundException
                or EntryPointNotFoundException
                or BadImageFormatException)
            {
                LastError = exception switch
                {
                    DllNotFoundException or EntryPointNotFoundException or BadImageFormatException
                        => "sqlite-runtime-unavailable",
                    UnauthorizedAccessException => "state-database-inaccessible",
                    _ => "state-database-unavailable"
                };
            }
            finally
            {
                if (connection != IntPtr.Zero)
                {
                    // Both query helpers finalize every statement before close.
                    Native.sqlite3_close(connection);
                }
            }

            LastMatchStatus = LocalThreadTitleMatchStatus.Error;
            return Array.Empty<string>();
        }
    }

    private string? FindStatePath()
    {
        if (_catalogDirectory is null || !Directory.Exists(_catalogDirectory))
        {
            return null;
        }

        string? selectedPath = null;
        ulong selectedVersion = 0;
        foreach (var path in Directory.EnumerateFiles(
            _catalogDirectory, "state_*.sqlite", SearchOption.TopDirectoryOnly))
        {
            var fileName = Path.GetFileNameWithoutExtension(path);
            if (!fileName.StartsWith("state_", StringComparison.OrdinalIgnoreCase)
                || !ulong.TryParse(fileName.AsSpan("state_".Length),
                    NumberStyles.None, CultureInfo.InvariantCulture, out var version))
            {
                continue;
            }

            if (selectedPath is null || version > selectedVersion
                || (version == selectedVersion
                    && string.Compare(path, selectedPath, StringComparison.OrdinalIgnoreCase) < 0))
            {
                selectedPath = path;
                selectedVersion = version;
            }
        }

        return selectedPath;
    }

    private static HashSet<string> ReadThreadColumns(IntPtr connection)
    {
        var statement = IntPtr.Zero;
        try
        {
            CheckResult(Native.sqlite3_prepare_v2(
                connection, "PRAGMA table_info(threads);", -1, out statement, IntPtr.Zero), "schema-prepare");
            var columns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            while (true)
            {
                var result = Native.sqlite3_step(statement);
                if (result == SqliteDone)
                {
                    return columns;
                }
                CheckStep(result, "schema-step");
                var name = Marshal.PtrToStringUTF8(Native.sqlite3_column_text(statement, 1));
                if (!string.IsNullOrEmpty(name))
                {
                    columns.Add(name);
                }
            }
        }
        finally
        {
            if (statement != IntPtr.Zero)
            {
                Native.sqlite3_finalize(statement);
            }
        }
    }

    private static IReadOnlyList<string> ReadMatchingIds(
        IntPtr connection, string titleExpression, string displayTitle)
    {
        var statement = IntPtr.Zero;
        try
        {
            // The expression is chosen exclusively from fixed schema variants.
            // Only the visible title is supplied by the caller, through a binding.
            var sql = $"SELECT id FROM threads WHERE trim({titleExpression}) = ?1 COLLATE BINARY ORDER BY id;";
            CheckResult(Native.sqlite3_prepare_v2(
                connection, sql, -1, out statement, IntPtr.Zero), "title-prepare");
            CheckResult(Native.sqlite3_bind_text(
                statement, 1, displayTitle, -1, SqliteTransient), "title-bind");

            var ids = new List<string>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            while (true)
            {
                var result = Native.sqlite3_step(statement);
                if (result == SqliteDone)
                {
                    return ids.ToArray();
                }
                CheckStep(result, "title-step");
                var id = Marshal.PtrToStringUTF8(Native.sqlite3_column_text(statement, 0));
                if (!string.IsNullOrWhiteSpace(id) && seen.Add(id))
                {
                    ids.Add(id);
                }
            }
        }
        finally
        {
            if (statement != IntPtr.Zero)
            {
                Native.sqlite3_finalize(statement);
            }
        }
    }

    private static void CheckResult(int result, string stage)
    {
        if (result != SqliteOk)
        {
            throw new SqliteReadException(stage, result);
        }
    }

    private static void CheckStep(int result, string stage)
    {
        if (result != SqliteRow)
        {
            throw new SqliteReadException(stage, result);
        }
    }

    private sealed class SqliteReadException(string stage, int resultCode) : Exception
    {
        public string Stage { get; } = stage;
        public int ResultCode { get; } = resultCode;
    }

    private static class Native
    {
        private const string LibraryName = "winsqlite3.dll";

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern int sqlite3_open_v2(
            [MarshalAs(UnmanagedType.LPUTF8Str)] string fileName,
            out IntPtr connection,
            int flags,
            IntPtr vfs);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern int sqlite3_busy_timeout(IntPtr connection, int milliseconds);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern int sqlite3_prepare_v2(
            IntPtr connection,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string sql,
            int byteCount,
            out IntPtr statement,
            IntPtr tail);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern int sqlite3_bind_text(
            IntPtr statement,
            int index,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string text,
            int byteCount,
            IntPtr destructor);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern int sqlite3_step(IntPtr statement);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern IntPtr sqlite3_column_text(IntPtr statement, int column);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern int sqlite3_finalize(IntPtr statement);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern int sqlite3_close(IntPtr connection);
    }
}
