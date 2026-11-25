using System.Globalization;
using System.Text.Json;

namespace Convert.Core;

public sealed record Probe(double Duration = 0, int SampleRate = 0, bool HiRes = false, bool HasAudio = false, bool HasVideo = false, bool Ok = false);

/// <summary>ffmpeg arguments per target. Mirrors Sources/Convert/FFmpeg.swift with Windows encoders.</summary>
public static class FF
{
    public static Probe ProbeFile(string path)
    {
        if (Tools.FFprobe is not { } fp) return new Probe();
        try
        {
            var json = Proc.RunSync(fp, ["-v", "error", "-show_entries",
                "format=duration:stream=codec_type,sample_rate,sample_fmt,bits_per_sample,bits_per_raw_sample:stream_disposition=attached_pic",
                "-of", "json", path], 30_000);
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            double duration = 0;
            if (root.TryGetProperty("format", out var f) && f.TryGetProperty("duration", out var d))
                double.TryParse(d.GetString(), CultureInfo.InvariantCulture, out duration);
            bool hasVideo = false, hasAudio = false, hires = false;
            int rate = 0;
            if (root.TryGetProperty("streams", out var streams))
            {
                foreach (var s in streams.EnumerateArray())
                {
                    var type = s.TryGetProperty("codec_type", out var ct) ? ct.GetString() : null;
                    if (type == "video")
                    {
                        var attached = s.TryGetProperty("disposition", out var disp) && disp.TryGetProperty("attached_pic", out var ap) && ap.GetInt32() == 1;
                        if (!attached) hasVideo = true;   // ignore cover art
                    }
                    else if (type == "audio" && !hasAudio)
                    {
                        hasAudio = true;
                        if (s.TryGetProperty("sample_rate", out var sr)) int.TryParse(sr.GetString(), out rate);
                        var fmt = s.TryGetProperty("sample_fmt", out var sf) ? sf.GetString() ?? "" : "";
                        hires = IsHiRes(fmt, Number(s, "bits_per_sample"), Number(s, "bits_per_raw_sample"));
                    }
                }
            }
            return new Probe(duration, rate, hires, hasAudio, hasVideo, true);
        }
        catch (Exception) { return new Probe(); }
    }

    /// <summary>ffprobe writes some numbers as numbers and some as text.</summary>
    private static int Number(JsonElement stream, string name)
    {
        if (!stream.TryGetProperty(name, out var v)) return 0;
        if (v.ValueKind == JsonValueKind.Number) return v.TryGetInt32(out var n) ? n : 0;
        return v.ValueKind == JsonValueKind.String && int.TryParse(v.GetString(), CultureInfo.InvariantCulture, out var parsed) ? parsed : 0;
    }

    /// <summary>
    /// Whether a source has more than 16 bits per sample: 24/32-bit integer PCM, float PCM,
    /// 24-bit FLAC/ALAC. Lossy decoders (MP3, AAC, Opus…) also hand out float samples, but
    /// report no bit depth, so they count as 16-bit and "Match source" doesn't bloat them.
    /// </summary>
    public static bool IsHiRes(string sampleFormat, int bitsPerSample, int bitsPerRawSample) =>
        sampleFormat.StartsWith("s32", StringComparison.Ordinal) || Math.Max(bitsPerSample, bitsPerRawSample) > 16;

    // No -y: ffmpeg must never write over a file that appeared after the output name was chosen.
    public static readonly string[] Common = ["-hide_banner", "-nostdin", "-loglevel", "error", "-progress", "pipe:1", "-nostats"];

    private static readonly string[] Depth24 = ["-bits_per_raw_sample", "24"];

    // Audio

    public static List<string> AudioArgs(Target t, ConvSettings s, Probe p)
    {
        var a = new List<string> { "-map", "0:a:0", "-vn", "-map_metadata", "0", "-map_metadata", "0:s:a:0" };
        var br = t.BitrateOptions.Contains(s.AudioBitrate) ? s.AudioBitrate : t.DefaultBitrate;
        var deep = s.BitDepth == 24 || (s.BitDepth == 0 && p.HiRes);
        var cap48 = t.IsLossyAudio && t.Id != "opus" && t.Id != "mp3";

        switch (t.Id)
        {
            case "mp3": a.AddRange(["-c:a", "libmp3lame", .. br == 0 ? new[] { "-q:a", "0" } : ["-b:a", $"{br}k"], "-id3v2_version", "3"]); cap48 = true; break;
            case "m4a": a.AddRange(["-c:a", "aac", "-b:a", $"{br}k"]); break;
            case "he-aac": a.AddRange(["-c:a", "libfdk_aac", "-profile:a", "aac_he", "-b:a", $"{br}k"]); break;
            case "opus": a.AddRange(["-c:a", "libopus", "-b:a", $"{br}k"]); break;
            case "ogg":
                a.AddRange(Tools.HasEncoder("libvorbis")
                        ? ["-c:a", "libvorbis", "-q:a", VorbisQuality(br)]
                        : ["-c:a", "vorbis", "-strict", "experimental", "-ac", "2", "-q:a", VorbisQuality(br)]); break;
            case "wma": a.AddRange(["-c:a", "wmav2", "-b:a", $"{br}k"]); break;
            case "ac3": a.AddRange(["-c:a", "ac3", "-b:a", $"{br}k"]); break;
            case "mp2": a.AddRange(["-c:a", "mp2", "-b:a", $"{br}k"]); break;
            case "wav": a.AddRange(["-c:a", deep ? "pcm_s24le" : "pcm_s16le"]); break;
            case "aiff": a.AddRange(["-c:a", deep ? "pcm_s24be" : "pcm_s16be"]); break;
            // These store 24-bit audio in 32-bit samples; without the explicit depth WavPack writes 32-bit.
            case "flac": a.AddRange(["-c:a", "flac", "-sample_fmt", deep ? "s32" : "s16", .. deep ? Depth24 : []]); break;
            case "alac": a.AddRange(["-c:a", "alac", "-sample_fmt", deep ? "s32p" : "s16p", .. deep ? Depth24 : []]); break;
            case "wv": a.AddRange(["-c:a", "wavpack", "-sample_fmt", deep ? "s32p" : "s16p", .. deep ? Depth24 : []]); break;
        }
        if (s.SampleRate > 0 && t.SampleRates.Contains(s.SampleRate)) a.AddRange(["-ar", $"{s.SampleRate}"]);
        else if (cap48 && p.SampleRate > 48000) a.AddRange(["-ar", "48000"]);
        if (s.Channels > 0 && t.HasChannelOption) a.AddRange(["-ac", $"{s.Channels}"]);
        return a;
    }

    private static string VorbisQuality(int kbps) => kbps switch
    {
        >= 320 => "9",
        >= 256 => "8",
        >= 192 => "6",
        >= 160 => "5",
        >= 128 => "4",
        _ => "2",
    };

    // Video

    /// <summary>
    /// Targets whose encoders store 4:2:0 chroma and need an even width and height: libx264 and libx265
    /// fail on odd sizes ("Nothing was written into output file"), as do older SVT-AV1 builds, and GPU
    /// encoders can refuse them or drop the odd row/column. VP9 and ProRes take odd sizes as they are.
    /// </summary>
    public static readonly IReadOnlySet<string> EvenSizeTargets = new HashSet<string> { "mp4-h264", "mkv", "mp4-hevc", "mp4-av1" };

    /// <summary>
    /// Trims an odd last row/column, after any scaling (a capped height can still be odd). Cropping
    /// one pixel keeps the picture sharp where scaling would resample it, and is a no-op for even sizes.
    /// </summary>
    public const string EvenSize = "crop=trunc(iw/2)*2:trunc(ih/2)*2:0:0";

    public static List<string> VideoArgs(Target t, ConvSettings s, Probe p)
    {
        var q = Math.Clamp(s.VideoQuality, 0, 1);
        var v = new List<string> { "-map", "0:v:0", "-map_metadata", "0" };

        if (t.Id == "gif")
        {
            var vf = $"fps={s.GifFps},scale=min(iw\\,{s.GifWidth}):-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a";
            v.AddRange(["-vf", vf, "-loop", "0", "-an"]);
            return v;
        }

        var filters = new List<string>();
        if (s.Fps > 0) filters.Add($"fps={s.Fps}");
        if (s.VideoHeight > 0) filters.Add($"scale=-2:min(ih\\,{s.VideoHeight})");

        string[] audio = ["-c:a", "aac", "-b:a", "192k"];
        var hw = s.Hardware ? HardwareEncoder.Vendor : null;
        int Crf(double top, double range) => (int)Math.Round(top - q * range);

        switch (t.Id)
        {
            case "mp4-h264":
            case "mkv":
                v.AddRange(hw switch
                {
                    "nvenc" => ["-c:v", "h264_nvenc", "-preset", "p5", "-rc", "vbr", "-cq", $"{Crf(32, 13)}", "-b:v", "0", "-pix_fmt", "yuv420p"],
                    "qsv" => ["-c:v", "h264_qsv", "-preset", "medium", "-global_quality", $"{Crf(32, 13)}"],
                    "amf" => ["-c:v", "h264_amf", "-quality", "balanced", "-rc", "cqp", "-qp_i", $"{Crf(30, 12)}", "-qp_p", $"{Crf(30, 12)}", "-qp_b", $"{Crf(30, 12)}", "-pix_fmt", "yuv420p"],
                    _ => ["-c:v", "libx264", "-preset", "medium", "-crf", $"{Crf(30, 12)}", "-pix_fmt", "yuv420p"],
                });
                break;
            case "mp4-hevc":
                v.AddRange(hw switch
                {
                    "nvenc" => ["-c:v", "hevc_nvenc", "-preset", "p5", "-rc", "vbr", "-cq", $"{Crf(34, 13)}", "-b:v", "0", "-pix_fmt", "yuv420p"],
                    "qsv" => ["-c:v", "hevc_qsv", "-preset", "medium", "-global_quality", $"{Crf(34, 13)}"],
                    "amf" => ["-c:v", "hevc_amf", "-quality", "balanced", "-rc", "cqp", "-qp_i", $"{Crf(32, 12)}", "-qp_p", $"{Crf(32, 12)}", "-pix_fmt", "yuv420p"],
                    _ => ["-c:v", "libx265", "-preset", "medium", "-crf", $"{Crf(32, 12)}", "-x265-params", "log-level=error", "-pix_fmt", "yuv420p"],
                });
                v.AddRange(["-tag:v", "hvc1"]);
                break;
            case "mov-prores":
                v.AddRange(["-c:v", "prores_ks", "-profile:v", "2", "-pix_fmt", "yuv422p10le"]);
                audio = ["-c:a", "pcm_s16le"];
                break;
            case "webm":
                v.AddRange(["-c:v", "libvpx-vp9", "-crf", $"{Crf(42, 17)}", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4"]);
                audio = ["-c:a", "libopus", "-b:a", "128k"];
                break;
            case "mp4-av1":
                v.AddRange(["-c:v", "libsvtav1", "-crf", $"{Crf(46, 20)}", "-preset", "8"]);
                break;
        }
        if (EvenSizeTargets.Contains(t.Id)) filters.Add(EvenSize);
        if (filters.Count > 0) v.AddRange(["-vf", string.Join(",", filters)]);

        if (s.KeepAudio && p.HasAudio)
        {
            v.AddRange(["-map", "0:a:0", .. audio]);
            if (audio[1] == "aac" && p.SampleRate > 48000) v.AddRange(["-ar", "48000"]);
        }
        else v.Add("-an");
        if (t.Ext is "mp4" or "mov") v.AddRange(["-movflags", "+faststart"]);
        return v;
    }
}

/// <summary>
/// Finds a working GPU encoder: an encoder being compiled into ffmpeg doesn't mean the GPU is there.
/// Found out once per installed ffmpeg, and again when ffmpeg is installed, updated or removed.
/// </summary>
public static class HardwareEncoder
{
    private static readonly object gate = new();
    private static string? detectedFor;
    private static string? vendor;

    /// <summary>"nvenc", "qsv", "amf" or null (software).</summary>
    public static string? Vendor
    {
        get
        {
            if (Tools.FFmpeg is not { } ff) return null;
            var stamp = Tools.Stamp(ff);
            lock (gate)
            {
                if (detectedFor != stamp)
                {
                    vendor = Detect(ff);
                    detectedFor = stamp;
                }
                return vendor;
            }
        }
    }

    /// <summary>Starts detection in the background so the first conversion doesn't wait for it.</summary>
    public static void Warmup() => Task.Run(() => Vendor);

    private static string? Detect(string ff)
    {
        foreach (var (name, codec) in new[] { ("nvenc", "h264_nvenc"), ("qsv", "h264_qsv"), ("amf", "h264_amf") })
        {
            if (!Tools.HasEncoder(codec)) continue;
            try
            {
                Proc.RunSync(ff, ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=black:s=320x240:d=0.2",
                                  "-frames:v", "3", "-c:v", codec, "-pix_fmt", "yuv420p", "-f", "null", "-"], 15_000);
                return name;
            }
            catch (ConvertException) { }
        }
        return null;
    }
}
