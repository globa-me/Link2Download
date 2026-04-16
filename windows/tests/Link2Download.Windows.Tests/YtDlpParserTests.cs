using Link2Download.Windows.Infrastructure.Runtime;

namespace Link2Download.Windows.Tests;

public sealed class YtDlpParserTests
{
    [Fact]
    public void StructuredProgressParsesPercentAndTransfer()
    {
        var parser = new YtDlpOutputParser();

        var parsed = parser.ParseStructuredProgressPayload("42.5%\t425000\t1000000\t1000000\t250000\t10");

        Assert.Equal(42.5, parsed.RawPercent);
        Assert.NotNull(parsed.Transfer);
        Assert.Equal(425000, parsed.Transfer!.DownloadedBytes);
        Assert.Equal(1000000, parsed.Transfer.TotalBytes);
        Assert.Equal(250000, parsed.Transfer.AverageSpeedBytesPerSecond);
    }

    [Fact]
    public void MetadataAndCompletedFileAreExtractedFromTaggedLines()
    {
        var parser = new YtDlpOutputParser();
        var tempRoot = Path.Combine(Path.GetTempPath(), "Link2Download.Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        var filePath = Path.Combine(tempRoot, "video.mp4");
        File.WriteAllBytes(filePath, [1, 2, 3, 4]);

        try
        {
            var meta = parser.ParseLine("__L2D_META__:Test title\t61\tYoutube\tUploader");
            parser.ParseLine("__L2D_ITEM__:Test title\t61\tmp4\t1080p");
            var file = parser.ParseLine($"__L2D_FILE__:{filePath}");

            Assert.Equal("Test title", meta.Metadata!.Title);
            Assert.Equal("YouTube", meta.Metadata.ServiceName);
            Assert.NotNull(file.CompletedFile);
            Assert.Equal(filePath, file.CompletedFile!.Path);
            Assert.Equal("mp4", file.CompletedFile.Ext);
            Assert.Equal("1080p", file.CompletedFile.Resolution);
            Assert.Equal(4, file.CompletedFile.FileSizeBytes);
        }
        finally
        {
            Directory.Delete(tempRoot, recursive: true);
        }
    }
}
