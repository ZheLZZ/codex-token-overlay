namespace CodexTokenOverlay;

internal sealed record TokenCostEstimate(
    decimal InputCostUsd,
    decimal CachedInputCostUsd,
    decimal OutputCostUsd)
{
    public decimal TotalCostUsd => InputCostUsd + CachedInputCostUsd + OutputCostUsd;
    public bool HasUnknownPricing { get; init; }
}

internal static class TokenCostEstimator
{
    // Standard API-equivalent USD rates per 1M tokens, verified 2026-09-30.
    // https://developers.openai.com/api/docs/pricing
    // https://developers.openai.com/api/docs/models/gpt-6.1-sol
    // Logs do not report the actual processing tier or regional surcharge.
    private static readonly IReadOnlyDictionary<string, ModelRates> Rates =
        new Dictionary<string, ModelRates>(StringComparer.OrdinalIgnoreCase)
        {
            ["gpt-6.1-sol"] = new(2.00m, 0.10m, 10.00m),
            ["gpt-6-sol"] = new(2.00m, 0.20m, 10.00m),
            ["gpt-6-astra"] = new(10.00m, 1.00m, 50.00m),
            ["gpt-6-luna"] = new(0.10m, 0.01m, 0.50m),
            ["gpt-5.6-sol"] = new(4.00m, 0.40m, 20.00m),
            ["gpt-5.6"] = new(4.00m, 0.40m, 20.00m),
            ["gpt-5.6-terra"] = new(2.00m, 0.20m, 12.00m),
            ["gpt-5.6-luna"] = new(0.20m, 0.02m, 1.20m),
            ["gpt-5.5"] = new(5.00m, 0.50m, 30.00m, 1m)
        };
    private const decimal TokensPerMillion = 1_000_000m;

    public static TokenCostEstimate Estimate(TokenSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        var usages = snapshot.PricingUsages.Count > 0
            ? snapshot.PricingUsages
            : new[]
            {
                new TokenPricingUsage(
                    "unknown",
                    snapshot.TotalTokens,
                    snapshot.InputTokens,
                    snapshot.CachedInputTokens,
                    snapshot.OutputTokens,
                    IsMainAgent: true)
            };

        return Estimate(usages);
    }

    public static TokenCostEstimate Estimate(IEnumerable<TokenPricingUsage> usages)
    {
        ArgumentNullException.ThrowIfNull(usages);

        var input = 0m;
        var cached = 0m;
        var output = 0m;
        var hasUnknownPricing = false;
        foreach (var usage in usages)
        {
            if (!Rates.TryGetValue(usage.Model ?? string.Empty, out var rates))
            {
                hasUnknownPricing |= usage.TotalTokens > 0 || usage.InputTokens > 0 || usage.OutputTokens > 0;
                continue;
            }

            var inputMultiplier = usage.IsLongContext ? 2m : 1m;
            var outputMultiplier = usage.IsLongContext ? 1.5m : 1m;
            var cacheReads = Math.Clamp(usage.CachedInputTokens, 0, Math.Max(0, usage.InputTokens));
            var cacheWrites = Math.Clamp(usage.CacheWriteInputTokens, 0, Math.Max(0, usage.InputTokens) - cacheReads);
            input += Cost(Math.Max(0, usage.InputTokens) - cacheReads - cacheWrites, rates.InputUsdPerMillion * inputMultiplier);
            input += Cost(cacheWrites, rates.InputUsdPerMillion * rates.CacheWriteMultiplier * inputMultiplier);
            cached += Cost(cacheReads, rates.CachedInputUsdPerMillion * inputMultiplier);
            output += Cost(usage.OutputTokens, rates.OutputUsdPerMillion * outputMultiplier);
        }

        return new TokenCostEstimate(input, cached, output) { HasUnknownPricing = hasUnknownPricing };
    }

    private static decimal Cost(long tokens, decimal usdPerMillion) =>
        Math.Max(0, tokens) * usdPerMillion / TokensPerMillion;

    private readonly record struct ModelRates(
        decimal InputUsdPerMillion,
        decimal CachedInputUsdPerMillion,
        decimal OutputUsdPerMillion,
        decimal CacheWriteMultiplier = 1.25m);
}
