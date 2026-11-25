using Convert.Core;
using Xunit;

namespace Convert.Core.Tests;

/// <summary>The ffmpeg arguments for video targets: the filter chain that decides the output size.</summary>
public sealed class VideoArgsTests
{
    private static readonly Probe Source = new(Duration: 1, HasVideo: true, Ok: true);

    // Software encoders: the even size doesn't depend on the encoder, and this skips GPU detection.
    private static List<string> Args(string id, int height = 0, int fps = 0)
    {
        var target = Targets.Catalogue.Single(t => t.Id == id);
        var s = new ConvSettings { Hardware = false, VideoHeight = height, Fps = fps };
        return FF.VideoArgs(target, s, Source);
    }

    /// <summary>The <c>-vf</c> filter chain, or null without one.</summary>
    private static string? Vf(List<string> a)
    {
        var i = a.IndexOf("-vf");
        return i >= 0 && i + 1 < a.Count ? a[i + 1] : null;
    }

    [Theory]
    [InlineData("mp4-h264")]
    [InlineData("mkv")]
    [InlineData("mp4-hevc")]
    [InlineData("mp4-av1")]
    public void FourTwoZeroTargetsAlwaysGetAnEvenSize(string id)
    {
        var a = Args(id);
        Assert.Equal(FF.EvenSize, Vf(a));
        Assert.Equal(1, a.Count(x => x == "-vf"));
    }

    [Fact]
    public void EvenSizeComesAfterScaling()
    {
        // scale=-2 makes the width even, but a height capped at the source's own can still be odd.
        Assert.Equal($"fps=30,scale=-2:min(ih\\,720),{FF.EvenSize}", Vf(Args("mp4-h264", height: 720, fps: 30)));
    }

    [Theory]
    [InlineData("webm")]
    [InlineData("mov-prores")]
    public void TargetsThatTakeOddSizesAreLeftAlone(string id)
    {
        Assert.Null(Vf(Args(id)));
        Assert.Equal("scale=-2:min(ih\\,720)", Vf(Args(id, height: 720)));
    }

    [Fact]
    public void GifIsLeftAlone()
    {
        Assert.DoesNotContain("crop=", string.Join(" ", Args("gif")));
    }
}
