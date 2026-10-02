using System.Text;
using System.Text.Json;

namespace CodexTokenOverlay;

internal static class TokenPricingLogReader
{
    private const long LongContextThreshold = 272_000;

    public static IReadOnlyList<TokenPricingUsage> Read(string path, TokenSnapshot snapshot, bool isMainAgent)
    {
        var groups = new Dictionary<(string Model, bool LongContext), TokenPricingUsage>();
        var model = "unknown";
        var previous = new Counters(0, 0, 0, 0, 0);
        var target = new Counters(snapshot.TotalTokens, snapshot.InputTokens, snapshot.CachedInputTokens, 0, snapshot.OutputTokens);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var reader = new StreamReader(stream, Encoding.UTF8, true, 64 * 1024);
        while (reader.ReadLine() is { } line)
        {
            if (!line.Contains("\"turn_context\"", StringComparison.Ordinal)
                && !line.Contains("\"token_count\"", StringComparison.Ordinal))
            {
                continue;
            }

            try
            {
                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;
                if (!root.TryGetProperty("type", out var type)
                    || !root.TryGetProperty("payload", out var payload)
                    || payload.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }

                if (type.GetString() == "turn_context")
                {
                    model = payload.TryGetProperty("model", out var value)
                        && value.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(value.GetString())
                        ? value.GetString()!.Trim().ToLowerInvariant()
                        : "unknown";
                    continue;
                }

                if (type.GetString() != "event_msg"
                    || !payload.TryGetProperty("type", out var eventType) || eventType.GetString() != "token_count"
                    || !payload.TryGetProperty("info", out var info) || info.ValueKind != JsonValueKind.Object
                    || !info.TryGetProperty("total_token_usage", out var total) || total.ValueKind != JsonValueKind.Object
                    || !info.TryGetProperty("last_token_usage", out var last) || last.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }

                // Ignore records beyond the chosen snapshot (including higher counters
                // replayed from a parent); never clamp such records into new usage.
                if (Number(total, "total_tokens") > target.Total || Number(total, "input_tokens") > target.Input
                    || Number(total, "cached_input_tokens") > target.Cached || Number(total, "output_tokens") > target.Output)
                {
                    continue;
                }

                // Difference consecutive cumulative counters, ignoring duplicate events.
                var current = new Counters(
                    Bounded(total, "total_tokens", previous.Total, target.Total),
                    Bounded(total, "input_tokens", previous.Input, target.Input),
                    Bounded(total, "cached_input_tokens", previous.Cached, target.Cached),
                    Math.Max(previous.Writes, Number(total, "cache_write_input_tokens")),
                    Bounded(total, "output_tokens", previous.Output, target.Output));
                var delta = new Counters(current.Total - previous.Total, current.Input - previous.Input,
                    current.Cached - previous.Cached, current.Writes - previous.Writes, current.Output - previous.Output);
                previous = current;
                if (delta.Total == 0 && delta.Input == 0 && delta.Output == 0 && delta.Cached == 0 && delta.Writes == 0)
                {
                    continue;
                }

                // Use input length for THIS request, never the cumulative session total
                // or the context-window capacity. Older logs can omit last.input_tokens.
                var requestInput = last.TryGetProperty("input_tokens", out var requestInputValue)
                    && requestInputValue.TryGetInt64(out var requestInputTokens) ? requestInputTokens : delta.Input;
                var key = (model, requestInput > LongContextThreshold);
                var usage = new TokenPricingUsage(model, delta.Total, delta.Input, delta.Cached, delta.Output, isMainAgent)
                {
                    CacheWriteInputTokens = delta.Writes,
                    IsLongContext = key.Item2,
                    SessionId = snapshot.ThreadId,
                    DisplayModel = snapshot.PricingUsages.FirstOrDefault()?.Model ?? "unknown"
                };
                if (groups.TryGetValue(key, out var existing))
                {
                    usage = usage with
                    {
                        TotalTokens = Add(existing.TotalTokens, usage.TotalTokens),
                        InputTokens = Add(existing.InputTokens, usage.InputTokens),
                        CachedInputTokens = Add(existing.CachedInputTokens, usage.CachedInputTokens),
                        CacheWriteInputTokens = Add(existing.CacheWriteInputTokens, usage.CacheWriteInputTokens),
                        OutputTokens = Add(existing.OutputTokens, usage.OutputTokens)
                    };
                }
                groups[key] = usage;

                // Stop at the snapshot selected by the tail reader, even if new lines
                // are appended while we read. The next refresh will include them.
                if (current.Total == target.Total && current.Input == target.Input
                    && current.Cached == target.Cached && current.Output == target.Output)
                {
                    break;
                }
            }
            catch (Exception exception) when (exception is JsonException or InvalidOperationException)
            {
                // Skip incomplete/malformed records; do not let them change counters/model.
            }
        }

        return groups.Values.ToArray();
    }

    private static long Bounded(JsonElement total, string name, long previous, long target) =>
        Math.Clamp(Number(total, name), previous, Math.Max(previous, Math.Max(0, target)));

    private static long Number(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.TryGetInt64(out var number) ? Math.Max(0, number) : 0;

    private static long Add(long left, long right) => long.MaxValue - left < right ? long.MaxValue : left + right;

    private readonly record struct Counters(long Total, long Input, long Cached, long Writes, long Output);
}
