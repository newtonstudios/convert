"""Audio and video, with ffmpeg.

The arguments are the Mac's (``FFmpeg.swift``), with the encoders that exist
in a Linux ffmpeg: libmp3lame, the built-in AAC, libfdk_aac when the build has
it, libopus, libvorbis, libx264, libx265, prores_ks, libvpx-vp9 and libsvtav1.

Hardware encoding is asked for, not assumed: an encoder being compiled into
ffmpeg doesn't mean the GPU is there, so a three-frame test encode decides. If
a hardware encode then fails on the real file (a resolution or pixel format it
doesn't do, a driver in a bad mood), the conversion is tried once more in
software rather than failing.
"""

from __future__ import annotations

import json
import os
import uuid

from . import formats, paths, tools
from .errors import ConvertError

COMMON = ["-hide_banner", "-nostdin", "-loglevel", "error", "-progress", "pipe:1", "-nostats"]


class Probe:
    def __init__(self, duration=0.0, sample_rate=0, hi_res=False, has_audio=False,
                 has_video=False, ok=False):
        self.duration = duration
        self.sample_rate = sample_rate
        self.hi_res = hi_res
        self.has_audio = has_audio
        self.has_video = has_video
        self.ok = ok


def probe(path):
    ffprobe = tools.find("ffprobe")
    if not ffprobe:
        return Probe()
    try:
        _, out, _ = tools.run([ffprobe, "-v", "error", "-show_entries",
                               "format=duration:stream=codec_type,sample_rate,sample_fmt,"
                               "bits_per_sample,bits_per_raw_sample:"
                               "stream_disposition=attached_pic",
                               "-of", "json", path], timeout=30)
        data = json.loads(out)
    except (ConvertError, ValueError):
        return Probe()
    duration = 0.0
    try:
        duration = float(data.get("format", {}).get("duration") or 0)
    except (TypeError, ValueError):
        pass
    has_audio = has_video = hi_res = False
    rate = 0
    for stream in data.get("streams", []):
        kind = stream.get("codec_type")
        if kind == "video":
            # Cover art is a video stream too, and a song's artwork must not
            # make it look like a video.
            attached = stream.get("disposition", {}).get("attached_pic") == 1
            if not attached:
                has_video = True
        elif kind == "audio" and not has_audio:
            has_audio = True
            try:
                rate = int(stream.get("sample_rate") or 0)
            except (TypeError, ValueError):
                rate = 0
            hi_res = is_hi_res(stream.get("sample_fmt") or "",
                               _number(stream, "bits_per_sample"),
                               _number(stream, "bits_per_raw_sample"))
    return Probe(duration, rate, hi_res, has_audio, has_video, True)


def _number(stream, name):
    value = stream.get(name)
    if isinstance(value, bool):
        return 0
    if isinstance(value, (int, float)):
        return int(value)
    try:
        return int(str(value))
    except (TypeError, ValueError):
        return 0


def is_hi_res(sample_format, bits_per_sample, bits_per_raw_sample):
    """Whether a source has more than 16 bits per sample.

    Lossy decoders also hand out float samples but report no bit depth, so they
    count as 16-bit and "Match source" doesn't bloat them.
    """
    return sample_format.startswith("s32") or max(bits_per_sample, bits_per_raw_sample) > 16


# ── Hardware encoders ────────────────────────────────────────────────────


_hardware = {}


def hardware_vendor(ffmpeg):
    """``"nvenc"``, ``"qsv"``, ``"amf"`` or None (software).

    VAAPI is deliberately not used: it needs a device node and a filter graph,
    and on a machine where it is half-configured the encode fails rather than
    falling back.
    """
    if ffmpeg in _hardware:
        return _hardware[ffmpeg]
    vendor = None
    for name, codec in (("nvenc", "h264_nvenc"), ("qsv", "h264_qsv"), ("amf", "h264_amf")):
        if not tools.has_encoder(codec):
            continue
        try:
            tools.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi",
                       "-i", "color=black:s=320x240:d=0.2", "-frames:v", "3",
                       "-c:v", codec, "-pix_fmt", "yuv420p", "-f", "null", "-"],
                      timeout=15, check=True)
            vendor = name
            break
        except ConvertError:
            continue
    _hardware[ffmpeg] = vendor
    return vendor


# ── Arguments ────────────────────────────────────────────────────────────


def audio_args(target, settings, probed):
    a = ["-map", "0:a:0", "-vn", "-map_metadata", "0", "-map_metadata", "0:s:a:0"]
    rate = settings.audioBitrate if settings.audioBitrate in target.bitrate_options else target.default_bitrate
    deep = settings.bitDepth == 24 or (settings.bitDepth == 0 and probed.hi_res)
    cap_48 = target.is_lossy_audio and target.id not in ("opus", "mp3")

    if target.id == "mp3":
        a += ["-c:a", "libmp3lame"] + (["-q:a", "0"] if rate == 0 else ["-b:a", "%dk" % rate])
        a += ["-id3v2_version", "3"]
        cap_48 = True
    elif target.id == "m4a":
        a += ["-c:a", "aac", "-b:a", "%dk" % rate]
    elif target.id == "he-aac":
        a += ["-c:a", "libfdk_aac", "-profile:a", "aac_he", "-b:a", "%dk" % rate]
    elif target.id == "opus":
        a += ["-c:a", "libopus", "-b:a", "%dk" % rate]
    elif target.id == "ogg":
        if tools.has_encoder("libvorbis"):
            a += ["-c:a", "libvorbis", "-q:a", vorbis_quality(rate)]
        else:
            a += ["-c:a", "vorbis", "-strict", "experimental", "-ac", "2", "-q:a", vorbis_quality(rate)]
    elif target.id == "wma":
        a += ["-c:a", "wmav2", "-b:a", "%dk" % rate]
    elif target.id == "ac3":
        a += ["-c:a", "ac3", "-b:a", "%dk" % rate]
    elif target.id == "mp2":
        a += ["-c:a", "mp2", "-b:a", "%dk" % rate]
    elif target.id == "wav":
        a += ["-c:a", "pcm_s24le" if deep else "pcm_s16le"]
    elif target.id == "aiff":
        a += ["-c:a", "pcm_s24be" if deep else "pcm_s16be"]
    elif target.id == "flac":
        a += ["-c:a", "flac", "-sample_fmt", "s32" if deep else "s16"]
    elif target.id == "alac":
        a += ["-c:a", "alac", "-sample_fmt", "s32p" if deep else "s16p"]
    elif target.id == "wv":
        a += ["-c:a", "wavpack", "-sample_fmt", "s32p" if deep else "s16p"]
    if deep and target.id in ("flac", "alac", "wv"):
        # These store 24-bit audio in 32-bit samples; without the explicit depth
        # the encoder writes 32-bit.
        a += ["-bits_per_raw_sample", "24"]

    if settings.sampleRate > 0 and settings.sampleRate in target.sample_rates:
        a += ["-ar", str(settings.sampleRate)]
    elif cap_48 and probed.sample_rate > 48000:
        a += ["-ar", "48000"]
    if settings.channels > 0 and target.has_channel_option:
        a += ["-ac", str(settings.channels)]
    return a


def vorbis_quality(kbps):
    if kbps >= 320:
        return "9"
    if kbps >= 256:
        return "8"
    if kbps >= 192:
        return "6"
    if kbps >= 160:
        return "5"
    if kbps >= 128:
        return "4"
    return "2"


def video_args(target, settings, probed):
    q = max(0.0, min(1.0, settings.videoQuality))
    v = ["-map", "0:v:0", "-map_metadata", "0"]

    if target.id == "gif":
        graph = ("fps=%d,scale=min(iw\\,%d):-2:flags=lanczos,split[a][b];"
                 "[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a"
                 % (settings.gifFps, settings.gifWidth))
        v += ["-vf", graph, "-loop", "0", "-an"]
        return v

    filters = []
    if settings.fps > 0:
        filters.append("fps=%d" % settings.fps)
    if settings.videoHeight > 0:
        filters.append("scale=-2:min(ih\\,%d)" % settings.videoHeight)

    audio = ["-c:a", "aac", "-b:a", "192k"]
    ffmpeg = tools.find("ffmpeg")
    vendor = hardware_vendor(ffmpeg) if (settings.hardware and target.has_hardware_option) else None

    def crf(top, span):
        return int(round(top - q * span))

    if target.id in ("mp4-h264", "mkv"):
        if vendor == "nvenc":
            v += ["-c:v", "h264_nvenc", "-preset", "p5", "-rc", "vbr", "-cq", str(crf(32, 13)),
                  "-b:v", "0", "-pix_fmt", "yuv420p"]
        elif vendor == "qsv":
            v += ["-c:v", "h264_qsv", "-preset", "medium", "-global_quality", str(crf(32, 13))]
        elif vendor == "amf":
            v += ["-c:v", "h264_amf", "-quality", "balanced", "-rc", "cqp",
                  "-qp_i", str(crf(30, 12)), "-qp_p", str(crf(30, 12)), "-qp_b", str(crf(30, 12)),
                  "-pix_fmt", "yuv420p"]
        else:
            v += ["-c:v", "libx264", "-preset", "medium", "-crf", str(crf(30, 12)), "-pix_fmt", "yuv420p"]
    elif target.id == "mp4-hevc":
        if vendor == "nvenc":
            v += ["-c:v", "hevc_nvenc", "-preset", "p5", "-rc", "vbr", "-cq", str(crf(34, 13)),
                  "-b:v", "0", "-pix_fmt", "yuv420p"]
        elif vendor == "qsv":
            v += ["-c:v", "hevc_qsv", "-preset", "medium", "-global_quality", str(crf(34, 13))]
        elif vendor == "amf":
            v += ["-c:v", "hevc_amf", "-quality", "balanced", "-rc", "cqp",
                  "-qp_i", str(crf(32, 12)), "-qp_p", str(crf(32, 12)), "-pix_fmt", "yuv420p"]
        else:
            v += ["-c:v", "libx265", "-preset", "medium", "-crf", str(crf(32, 12)),
                  "-x265-params", "log-level=error", "-pix_fmt", "yuv420p"]
        v += ["-tag:v", "hvc1"]
    elif target.id == "mov-prores":
        v += ["-c:v", "prores_ks", "-profile:v", "2", "-pix_fmt", "yuv422p10le"]
        audio = ["-c:a", "pcm_s16le"]
    elif target.id == "webm":
        v += ["-c:v", "libvpx-vp9", "-crf", str(crf(42, 17)), "-b:v", "0", "-row-mt", "1",
              "-deadline", "good", "-cpu-used", "4"]
        audio = ["-c:a", "libopus", "-b:a", "128k"]
    elif target.id == "mp4-av1":
        v += ["-c:v", "libsvtav1", "-crf", str(crf(46, 20)), "-preset", "8"]

    # 4:2:0 and 4:2:2 encoders need even dimensions; a screen recording of a
    # dragged area often isn't (issue #29). A no-op for even sizes.
    filters.append("crop=trunc(iw/2)*2:trunc(ih/2)*2:0:0")
    v += ["-vf", ",".join(filters)]

    if settings.keepAudio and probed.has_audio:
        v += ["-map", "0:a:0"] + audio
        if audio[1] == "aac" and probed.sample_rate > 48000:
            v += ["-ar", "48000"]
    else:
        v.append("-an")
    if target.ext in ("mp4", "mov"):
        v += ["-movflags", "+faststart"]
    return v


# ── The conversion ───────────────────────────────────────────────────────


def convert(input_path, target, settings, runner, progress):
    ffmpeg = tools.find("ffmpeg")
    if not ffmpeg:
        raise ConvertError("ffmpeg isn't installed. Install it with your package manager "
                           "(for example: sudo apt install ffmpeg)")
    probed = probe(input_path)
    if probed.ok and target.group == formats.AUDIO and not probed.has_audio:
        raise ConvertError("This file has no audio track")
    if probed.ok and target.group == formats.VIDEO and not probed.has_video:
        raise ConvertError("This file has no video track")

    # Encoded under a hidden name next to where it will end up (same filesystem,
    # so the final move is a link, not a copy of a large video), and only moved
    # to its real name once ffmpeg has finished successfully.
    folder = paths.folder_for(input_path)
    out = os.path.join(folder, ".convert-%s.%s" % (uuid.uuid4().hex, target.ext))

    def encode(use_hardware):
        # No -y: ffmpeg must never write over a file that appeared after the
        # output name was chosen.
        args = [ffmpeg] + COMMON + ["-i", input_path]
        if target.group == formats.AUDIO:
            args += audio_args(target, settings, probed)
        else:
            args += video_args(target, settings.replace(hardware=use_hardware), probed)
        args.append(out)
        done = {"seconds": 0.0}

        def line(text):
            if text.startswith("out_time_ms=") and probed.duration > 0:
                try:
                    done["seconds"] = int(text.split("=", 1)[1].strip()) / 1_000_000.0
                except ValueError:
                    return
                progress(min(0.99, done["seconds"] / probed.duration))

        try:
            tools.run(args, runner=runner, on_line=line, check=True)
        except ConvertError:
            paths.try_delete(out)
            raise
        if not os.path.exists(out) or os.path.getsize(out) == 0:
            paths.try_delete(out)
            raise ConvertError("ffmpeg wrote nothing")

    hardware = settings.hardware and target.has_hardware_option and hardware_vendor(ffmpeg) is not None
    try:
        encode(hardware)
    except ConvertError:
        if not hardware or runner.cancelled:
            raise
        # A GPU encoder that passed the quick check can still refuse the real
        # job; slower is better than failed.
        encode(False)
    dest = paths.unique_output(input_path, target.ext)
    try:
        paths.move_into_place(out, dest)
    finally:
        paths.try_delete(out)
    progress(1.0)
    return [dest]
