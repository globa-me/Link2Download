using System.Reflection;
using Link2Download.Windows.Core.Abstractions;

namespace Link2Download.Windows.Infrastructure.Runtime;

public static class EmbeddedRuntimeBootstrapper
{
    private const string ResourcePrefix = "BundledRuntime.";

    public static async Task<string?> PrepareAsync(
        string localRoot,
        Assembly bundleAssembly,
        IDiagnosticsLogger diagnostics,
        CancellationToken cancellationToken = default)
    {
        var bundledResources = bundleAssembly
            .GetManifestResourceNames()
            .Where(name => name.StartsWith(ResourcePrefix, StringComparison.OrdinalIgnoreCase))
            .OrderBy(name => name, StringComparer.OrdinalIgnoreCase)
            .ToList();

        if (bundledResources.Count == 0)
        {
            return null;
        }

        var runtimeDirectory = Path.Combine(localRoot, "runtime", "win-x64");
        Directory.CreateDirectory(runtimeDirectory);

        foreach (var resourceName in bundledResources)
        {
            var fileName = resourceName[ResourcePrefix.Length..];
            var destinationPath = Path.Combine(runtimeDirectory, fileName);
            await ExtractIfChangedAsync(bundleAssembly, resourceName, destinationPath, cancellationToken);
        }

        var hasCoreRuntime = File.Exists(Path.Combine(runtimeDirectory, "yt-dlp.exe")) &&
                             File.Exists(Path.Combine(runtimeDirectory, "ffmpeg.exe"));
        if (!hasCoreRuntime)
        {
            diagnostics.Warning($"Bundled runtime extraction skipped because required tools were not found in {runtimeDirectory}.");
            return null;
        }

        Environment.SetEnvironmentVariable("L2D_WINDOWS_RUNTIME_DIR", runtimeDirectory);
        diagnostics.Info($"Bundled runtime prepared at {runtimeDirectory}");
        return runtimeDirectory;
    }

    private static async Task ExtractIfChangedAsync(
        Assembly bundleAssembly,
        string resourceName,
        string destinationPath,
        CancellationToken cancellationToken)
    {
        await using var resourceStream = bundleAssembly.GetManifestResourceStream(resourceName)
            ?? throw new InvalidOperationException($"Missing embedded resource: {resourceName}");

        var needsWrite = !File.Exists(destinationPath) ||
                         new FileInfo(destinationPath).Length != resourceStream.Length;
        if (!needsWrite)
        {
            return;
        }

        var tempPath = $"{destinationPath}.tmp";
        Directory.CreateDirectory(Path.GetDirectoryName(destinationPath)!);

        await using (var output = File.Create(tempPath))
        {
            await resourceStream.CopyToAsync(output, cancellationToken);
        }

        File.Move(tempPath, destinationPath, overwrite: true);
    }
}
