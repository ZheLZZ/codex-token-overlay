using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Windows.Automation;

namespace CodexTokenOverlay;

internal sealed record VisibleThreadObservation(
    bool HasWindow,
    bool HasDocument,
    long WindowHandle,
    string? DisplayTitle,
    IReadOnlyList<string> CandidateThreadIds,
    string? Error,
    DateTime ObservedAtUtc)
{
    public bool IsCloudChat { get; init; }
}

internal sealed record VisibleThreadSelection(string? ThreadId, string Reason);

internal static class VisibleThreadRouteResolver
{
    private static readonly HashSet<string> GenericPageTitles = new(StringComparer.OrdinalIgnoreCase)
    {
        "ChatGPT", "Codex", "OpenAI Codex", "Home", "首页"
    };

    public static VisibleThreadSelection Resolve(
        VisibleThreadObservation observation,
        IReadOnlyCollection<string> localFollowingThreadIds)
    {
        if (!observation.HasWindow)
        {
            return new(null, "后台");
        }
        if (!observation.HasDocument || string.IsNullOrWhiteSpace(observation.DisplayTitle))
        {
            return new(null, "等待窗口信息");
        }

        if (observation.IsCloudChat)
        {
            return new(null, "云端聊天");
        }
        if (GenericPageTitles.Contains(observation.DisplayTitle.Trim()))
        {
            return new(null, "非聊天页面");
        }

        var candidates = observation.CandidateThreadIds
            .Where(id => !string.IsNullOrWhiteSpace(id))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        if (candidates.Length == 1)
        {
            return new(candidates[0], "窗口同步");
        }
        if (candidates.Length > 1)
        {
            var following = new HashSet<string>(localFollowingThreadIds, StringComparer.OrdinalIgnoreCase);
            var matches = candidates.Where(following.Contains).ToArray();
            if (matches.Length == 1)
            {
                return new(matches[0], "窗口同步");
            }
            return new(null, "聊天标题重复");
        }
        return new(null, observation.Error is null ? "无本机会话" : "等待本机索引");
    }
}

internal sealed class VisibleThreadRouteProbeRequest
{
    public IReadOnlyList<VisibleThreadRouteProbeCase> Cases { get; init; } = [];
}

internal sealed class VisibleThreadRouteProbeCase
{
    public string Name { get; init; } = string.Empty;
    public bool HasWindow { get; init; } = true;
    public bool HasDocument { get; init; } = true;
    public string? DisplayTitle { get; init; }
    public IReadOnlyList<string> CandidateThreadIds { get; init; } = [];
    public IReadOnlyList<string> LocalFollowingThreadIds { get; init; } = [];
    public IReadOnlyList<JsonElement> Frames { get; init; } = [];
    public IReadOnlyList<JsonElement> FramesAfterSelection { get; init; } = [];
    public bool IsCloudChat { get; init; }
}

internal static class VisibleThreadRouteProbe
{
    public static object Execute(VisibleThreadRouteProbeRequest request)
    {
        return new
        {
            Cases = request.Cases.Select(item =>
            {
                using var ipc = new CodexIpcActiveThreadMonitor(connect: false);
                foreach (var frame in item.Frames)
                {
                    ipc.ProcessFrame(Encoding.UTF8.GetBytes(frame.GetRawText()));
                }
                var observation = new VisibleThreadObservation(
                    item.HasWindow, item.HasDocument, 1, item.DisplayTitle,
                    item.CandidateThreadIds, null, DateTime.UtcNow) { IsCloudChat = item.IsCloudChat };
                var following = item.Frames.Count > 0
                    ? ipc.GetLocalFollowingThreadIds()
                    : item.LocalFollowingThreadIds;
                var selection = VisibleThreadRouteResolver.Resolve(observation, following);
                ipc.SetVisibleSelection(selection);
                foreach (var frame in item.FramesAfterSelection)
                {
                    ipc.ProcessFrame(Encoding.UTF8.GetBytes(frame.GetRawText()));
                }
                return new
                {
                    item.Name,
                    Selection = selection,
                    Status = ipc.GetStatus(),
                    LocalFollowingThreadIds = ipc.GetLocalFollowingThreadIds(),
                    DiscoveryResponses = item.Frames
                        .Select(frame => CodexIpcActiveThreadMonitor.CreateDiscoveryResponse(
                            Encoding.UTF8.GetBytes(frame.GetRawText())))
                        .Where(response => response is not null)
                        .Select(response => JsonSerializer.Deserialize<JsonElement>(response!)).ToArray()
                };
            }).ToArray()
        };
    }
}

/// <summary>
/// Reads only the main web document's title. IPC following notifications describe
/// subscriptions, so they cannot identify the selected page in newer Desktop builds.
/// </summary>
internal sealed class VisibleThreadRouteMonitor
{
    private static readonly TimeSpan ReadInterval = TimeSpan.FromMilliseconds(500);
    private static readonly TimeSpan MaximumObservationAge = TimeSpan.FromSeconds(3);
    private readonly LocalThreadTitleIndex _titleIndex;
    private readonly object _sync = new();
    private Task<VisibleThreadObservation>? _readTask;
    private VisibleThreadObservation? _latest;
    private DateTime _lastReadStartedUtc = DateTime.MinValue;

    public VisibleThreadRouteMonitor(string sessionRoot)
    {
        _titleIndex = new LocalThreadTitleIndex(sessionRoot);
    }

    public VisibleThreadObservation Poll()
    {
        if (!CodexWindowLocator.TryGetForegroundCodexTarget(out var target))
        {
            return new(false, false, 0, null, [], null, DateTime.UtcNow);
        }

        var handle = target.HostWindow.Handle;
        var now = DateTime.UtcNow;
        lock (_sync)
        {
            if (_readTask?.IsCompleted == true)
            {
                if (_readTask.Status == TaskStatus.RanToCompletion)
                {
                    _latest = _readTask.Result;
                }
                _readTask = null;
            }

            // Keep at most one accessibility call in flight. A stalled provider
            // cannot block the token-log polling task or create unbounded workers.
            if (_readTask is null && now - _lastReadStartedUtc >= ReadInterval)
            {
                _lastReadStartedUtc = now;
                _readTask = Task.Run(() => ReadWindow(handle));
            }
            if (_latest is not null
                && _latest.WindowHandle == handle.ToInt64()
                && now - _latest.ObservedAtUtc <= MaximumObservationAge)
            {
                return _latest;
            }
        }
        return new(true, false, handle.ToInt64(), null, [], null, now);
    }

    public VisibleThreadObservation ReadForegroundNow()
    {
        return CodexWindowLocator.TryGetForegroundCodexTarget(out var target)
            ? ReadWindow(target.HostWindow.Handle)
            : new(false, false, 0, null, [], null, DateTime.UtcNow);
    }

    public VisibleThreadObservation ReadKnownWindowNow(IntPtr handle) => ReadWindow(handle, requireForeground: false);

    private VisibleThreadObservation ReadWindow(IntPtr handle, bool requireForeground = true)
    {
        string? title = null;
        try
        {
            var root = AutomationElement.FromHandle(handle);
            var document = root.FindFirst(
                TreeScope.Descendants,
                new AndCondition(
                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Document),
                    new PropertyCondition(AutomationElement.AutomationIdProperty, "RootWebArea")));
            if (document is null || document.Current.IsOffscreen)
            {
                return new(true, false, handle.ToInt64(), null, [], null, DateTime.UtcNow);
            }
            title = document.Current.Name?.Trim();
            var isCloudChat = HasCloudChatMarker(document, title);
            var candidates = string.IsNullOrWhiteSpace(title)
                ? Array.Empty<string>()
                : _titleIndex.ReadCandidates(title);

            // Navigation or focus can change while an out-of-process provider is
            // answering. Never publish a result from a different document/window.
            if ((requireForeground && (!CodexWindowLocator.TryGetForegroundCodexTarget(out var current)
                || current.HostWindow.Handle != handle))
                || !string.Equals(document.Current.Name?.Trim(), title, StringComparison.Ordinal))
            {
                return new(true, false, handle.ToInt64(), null, [], null, DateTime.UtcNow);
            }
            return new(true, true, handle.ToInt64(), title, candidates, _titleIndex.LastError, DateTime.UtcNow)
            {
                IsCloudChat = isCloudChat
            };
        }
        catch (Exception exception) when (exception is ElementNotAvailableException
            or COMException or InvalidOperationException or UnauthorizedAccessException)
        {
            return new(true, false, handle.ToInt64(), title, [], exception.GetType().Name, DateTime.UtcNow);
        }
    }

    private static bool HasCloudChatMarker(AutomationElement document, string? title)
    {
        if (string.IsNullOrWhiteSpace(title))
        {
            return false;
        }
        var buttons = document.FindAll(TreeScope.Descendants, new AndCondition(
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button),
            new PropertyCondition(AutomationElement.NameProperty, title)));
        foreach (AutomationElement button in buttons)
        {
            if (!button.Current.ClassName.Split(' ').Contains("bg-primary-ghost-hover", StringComparer.Ordinal))
            {
                continue;
            }
            var cloud = button.FindFirst(TreeScope.Descendants, new OrCondition(
                new PropertyCondition(AutomationElement.NameProperty, "Cloud chat"),
                new PropertyCondition(AutomationElement.NameProperty, "云端聊天"),
                new PropertyCondition(AutomationElement.NameProperty, "云聊天")));
            if (cloud is not null)
            {
                return true;
            }
        }
        return false;
    }
}
