using System;
using System.Collections.Generic;

namespace Demo.App;

/// <summary>Documentation.</summary>
/**
 * <param name="x">Block documentation.</param>
 * a * / b
 */
[Serializable]
public sealed class User : Base, IComparable<User>
{
    private const int Limit = 0x1F;
    public string Name { get; init; } = "anon";

    public async Task<int?> CountAsync(double scale = 1.5e3)
    {
        // a comment
        var list = new List<int> { 1, 2, 3 };
        if (list is { Count: > 0 } && Name != null)
        {
            Console.WriteLine($"Hello {Name}, {list.Count} items\n" + @"C:\path");
        }
        return await Task.FromResult<int?>(null);
    }
}
