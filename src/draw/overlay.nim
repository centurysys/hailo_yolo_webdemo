## Pixie based drawing helpers.
##
## JPEG jobs generate the 640x640 RGB/NHWC YOLO input buffer from TurboJPEG
## decoded RGBX pixels. MP4 preview jobs decode one I420 frame via libav_nim and
## build the YOLO input directly from that I420 frame.

import pixie
import std/[algorithm, math, os, strformat, strutils, times]

import libav_nim
import threadtools

import ../infer/hailo_worker
import ../media/[convert, decoded_source, jpeg, mp4]
import ../types

const
  LabelFontSize = 18.float32
  LabelHeight = 24.float32
  LabelPadX = 6.float32
  BoxThickness = 4.float32

  ## Keep small and crowded detections readable: draw all boxes, but only
  ## annotate boxes large enough for a useful label.
  MinLabelBoxHeight = 64.float32
  MinLabelBoxArea = 3000.float32
  MaxLabels = 12

  ## MP4 progress represents encoded video work only.
  ## Setup/open/finalize phases are intentionally not mapped to artificial
  ## progress ranges, because they are short and make the wait page feel like it
  ## starts or stops at odd positions.
  VideoProgressStart = 0
  VideoProgressEnd = 100

type
  OverlayStats* = object
    imageWidth*: int
    imageHeight*: int
    detections*: int
    boxesDrawn*: int
    labelsDrawn*: int
    decodeMs*: int
    decoderOpenMs*: int
    readFrameMs*: int
    readFramesMs*: seq[int]
    previewFrameIndex*: int
    requestedProbeFrames*: int
    decoderName*: string
    letterboxMs*: int
    inferMs*: int
    inferSubmitMs*: int
    inferWaitMs*: int
    inferOverlapMs*: int
    hailoWriteUs*: int64
    hailoReadUs*: int64
    hailoParseUs*: int64
    hailoSortUs*: int64
    pipelineFrames*: int
    pipelineSubmitted*: int
    pipelineReplies*: int
    pipelineInFlight*: int
    letterboxFramesMs*: seq[int]
    inferSubmitFramesMs*: seq[int]
    inferWaitFramesMs*: seq[int]
    rgbxFramesMs*: seq[int]
    rgbxMs*: int
    drawMs*: int
    encodeMs*: int
    encoderOpenMs*: int
    writerOpenMs*: int
    encoderFlushMs*: int
    writerFinishMs*: int
    videoFrames*: int
    videoPackets*: int
    videoPacketBytes*: int64
    inputDurationSeconds*: float64
    sourceFps*: float64
    estimatedTotalFrames*: int
    inputDurationSource*: string
    sourceFpsSource*: string
    progressSeconds*: float64
    outputBitrate*: int
    outputFps*: float64
    outputFpsNum*: int
    outputFpsDen*: int
    outputFpsSource*: string
    totalMs*: int

  OverlayProgressCallback* = proc(ctx: pointer; progress: int; message: string) {.gcsafe.}
  OverlayStopCallback* = proc(ctx: pointer): bool {.gcsafe.}

  VideoProgressInfo = object
    durationSeconds: float64
    hasDuration: bool
    sourceFps: float64
    sourceFpsNum: int
    sourceFpsDen: int
    hasSourceFps: bool
    estimatedTotalFrames: int
    hasEstimatedTotalFrames: bool

  VideoOutputFpsInfo = object
    num: int
    den: int
    fps: float64
    fpsForBitrate: int
    gopSize: int
    source: string

  VideoBitrateConfig = object
    fixedBitrate: int
    autoMultiplierPercent: int

  DetectionJsonWriter = object
    outputPath: string
    tmpPath: string
    file: File
    opened: bool
    firstFrame: bool
    livePath: string
    liveFile: File
    liveOpened: bool
    width: int
    height: int
    frameCount: int
    detectionCount: int

  OverlayDrawOptions* = object
    maxBoxes: int
    maxLabels: int
    minBoxScore: float32
    minLabelScore: float32
    minLabelBoxHeight: float32
    minLabelBoxArea: float32

  OverlayDrawResult* = object
    boxes*: int
    labels*: int

proc parseEnvIntDraw(name: string; defaultValue: int): int =
  let raw = getEnv(name, "").strip()
  if raw.len == 0:
    return defaultValue

  try:
    result = parseInt(raw)
  except ValueError:
    result = defaultValue

proc parseEnvFloat32Draw(name: string; defaultValue: float32): float32 =
  let raw = getEnv(name, "").strip()
  if raw.len == 0:
    return defaultValue

  try:
    result = parseFloat(raw).float32
  except ValueError:
    result = defaultValue

proc resolveStillDrawOptions(): OverlayDrawOptions =
  ## Still image/JPEG preview defaults keep the existing behavior: draw all
  ## boxes, but cap labels so crowded images remain readable.
  result.maxBoxes = parseEnvIntDraw("HAILO_DEMO_MAX_BOXES", 0)
  result.maxLabels = max(0, parseEnvIntDraw("HAILO_DEMO_MAX_LABELS", MaxLabels))
  result.minBoxScore = parseEnvFloat32Draw("HAILO_DEMO_MIN_BOX_SCORE", 0.0.float32)
  result.minLabelScore = parseEnvFloat32Draw("HAILO_DEMO_MIN_LABEL_SCORE", 0.0.float32)
  result.minLabelBoxHeight = parseEnvFloat32Draw("HAILO_DEMO_MIN_LABEL_BOX_HEIGHT", MinLabelBoxHeight)
  result.minLabelBoxArea = parseEnvFloat32Draw("HAILO_DEMO_MIN_LABEL_BOX_AREA", MinLabelBoxArea)

proc resolveVideoDrawOptions(): OverlayDrawOptions =
  ## Video defaults are intentionally more conservative than still images.
  ## In crowded scenes, drawing every label makes the output noisy and dominates
  ## CPU time.  Environment variables can loosen or tighten this policy.
  result.maxBoxes = parseEnvIntDraw("HAILO_DEMO_VIDEO_MAX_BOXES", 12)
  result.maxLabels = max(0, parseEnvIntDraw("HAILO_DEMO_VIDEO_MAX_LABELS", 6))
  result.minBoxScore = parseEnvFloat32Draw("HAILO_DEMO_VIDEO_MIN_BOX_SCORE", 0.25.float32)
  result.minLabelScore = parseEnvFloat32Draw("HAILO_DEMO_VIDEO_MIN_LABEL_SCORE", 0.50.float32)
  result.minLabelBoxHeight = parseEnvFloat32Draw("HAILO_DEMO_VIDEO_MIN_LABEL_BOX_HEIGHT", 96.0.float32)
  result.minLabelBoxArea = parseEnvFloat32Draw("HAILO_DEMO_VIDEO_MIN_LABEL_BOX_AREA", 8000.0.float32)

proc resolveDrawOptionsFromJobOptions(options: JobOptions; video: bool): OverlayDrawOptions =
  let base = if video: resolveVideoDrawOptions() else: resolveStillDrawOptions()

  case options.overlayPreset
  of opLight:
    result = base
    result.maxBoxes = 8
    result.maxLabels = 3
    result.minBoxScore = 0.35.float32
    result.minLabelScore = 0.60.float32
    result.minLabelBoxHeight = if video: 120.0.float32 else: MinLabelBoxHeight
    result.minLabelBoxArea = if video: 12000.0.float32 else: MinLabelBoxArea
  of opBalanced:
    ## Preserve service-level environment defaults for the normal path.
    result = base
  of opRich:
    result = base
    result.maxBoxes = 24
    result.maxLabels = 12
    result.minBoxScore = 0.20.float32
    result.minLabelScore = 0.40.float32
    result.minLabelBoxHeight = if video: 64.0.float32 else: MinLabelBoxHeight
    result.minLabelBoxArea = if video: 3000.0.float32 else: MinLabelBoxArea
  of opBoxesOnly:
    result = base
    result.maxBoxes = 16
    result.maxLabels = 0
    result.minBoxScore = 0.25.float32
    result.minLabelScore = 1.0.float32
  of opManual:
    result = base
    result.maxBoxes = max(0, options.maxBoxes)
    result.maxLabels = max(0, options.maxLabels)
    result.minBoxScore = min(1.0.float32, max(0.0.float32, options.minBoxScore))
    result.minLabelScore = min(1.0.float32, max(0.0.float32, options.minLabelScore))

proc elapsedMs(start: float): int =
  result = int((epochTime() - start) * 1000.0 + 0.5)
  if result < 0:
    result = 0

proc verboseFrameTimings(): bool =
  let raw = getEnv("HAILO_DEMO_VERBOSE_TIMINGS", "0").toLowerAscii()
  result = raw in ["1", "true", "yes", "on"]

proc formatReadFramesMs(values: openArray[int]): string =
  if values.len == 0:
    return ""

  var parts: seq[string] = @[]
  for value in values:
    parts.add($value)

  result = parts.join("/")

proc formatFrameMsSummary(values: openArray[int]): string =
  ## Keep job result messages readable for real video jobs.  Per-frame timing
  ## arrays can easily contain hundreds of entries; summarize by default and
  ## allow the old verbose form only when explicitly requested.
  if values.len == 0:
    return ""
  if values.len <= 12 or verboseFrameTimings():
    return formatReadFramesMs(values)

  var
    sum = 0
    minValue = values[0]
    maxValue = values[0]

  for value in values:
    sum += value
    if value < minValue:
      minValue = value
    if value > maxValue:
      maxValue = value

  var firstParts: seq[string] = @[]
  let firstCount = min(values.len, 6)
  for i in 0 ..< firstCount:
    firstParts.add($values[i])

  let firstDetail = firstParts.join("/")
  result = &"n:{values.len}/sum:{sum}/avg:{sum div values.len}/min:{minValue}/max:{maxValue}/first:{firstDetail}"

proc notifyProgress(
    onProgress: OverlayProgressCallback;
    progressCtx: pointer;
    progress: int;
    message: string
  ) {.gcsafe.} =
  if onProgress != nil:
    onProgress(progressCtx, progress, message)


proc overlayStopRequested(
    shouldStop: OverlayStopCallback;
    stopCtx: pointer
  ): bool {.gcsafe.} =
  if shouldStop == nil:
    return false
  result = shouldStop(stopCtx)


proc formatBytes(value: int64): string =
  if value >= 1024'i64 * 1024'i64:
    result = &"{float(value) / (1024.0 * 1024.0):.2f}MiB"
  elif value >= 1024'i64:
    result = &"{float(value) / 1024.0:.1f}KiB"
  else:
    result = &"{value}B"


proc formatBitrate(value: int): string =
  if value >= 1_000_000:
    result = &"{float(value) / 1_000_000.0:.1f}Mbps"
  elif value >= 1_000:
    result = &"{float(value) / 1_000.0:.0f}kbps"
  else:
    result = &"{value}bps"


proc formatDurationMs(ms: int): string =
  if ms >= 1000:
    result = &"{float(ms) / 1000.0:.2f}s"
  else:
    result = &"{ms}ms"

proc formatSeconds(value: float64): string =
  if value >= 3600.0:
    let
      hours = int(value) div 3600
      minutes = (int(value) mod 3600) div 60
      seconds = int(value) mod 60
    result = &"{hours}:{minutes:02d}:{seconds:02d}"
  elif value >= 60.0:
    let
      minutes = int(value) div 60
      seconds = value - float64(minutes * 60)
    result = &"{minutes}:{seconds:04.1f}"
  else:
    result = &"{value:.1f}s"

proc formatSourceFps(value: float64): string =
  if value <= 0.0:
    return "n/a"

  var formatted = &"{value:.2f}"
  while formatted.len > 0 and formatted[^1] == '0':
    formatted.setLen(formatted.len - 1)
  if formatted.len > 0 and formatted[^1] == '.':
    formatted.setLen(formatted.len - 1)

  result = &"{formatted}fps"

proc formatOutputFps(value: float64): string =
  result = formatSourceFps(value)

proc gcdInt(a, b: int): int =
  var
    x = abs(a)
    y = abs(b)
  while y != 0:
    let next = x mod y
    x = y
    y = next
  if x <= 0:
    result = 1
  else:
    result = x

proc makeVideoOutputFpsInfo(num, den: int; source: string): VideoOutputFpsInfo =
  var
    n = num
    d = den

  if n <= 0 or d <= 0:
    n = 30
    d = 1

  let g = gcdInt(n, d)
  n = n div g
  d = d div g

  var fps = float64(n) / float64(d)
  if fps < 1.0:
    n = 30
    d = 1
    fps = 30.0
  elif fps > 120.0:
    n = 120
    d = 1
    fps = 120.0

  result.num = n
  result.den = d
  result.fps = fps
  result.fpsForBitrate = max(1, int(fps + 0.5))
  result.gopSize = result.fpsForBitrate
  result.source = source

proc fpsRationalFromFloat(value: float64; num, den: var int): bool =
  if value <= 0.0:
    return false

  ## Preserve the common NTSC rates when metadata has already been converted to
  ## a float.  Exact avg_frame_rate/r_frame_rate values are preferred when they
  ## are available from Mp4InputInfo.
  if abs(value - 23.976) < 0.02:
    num = 24000
    den = 1001
    return true
  if abs(value - 29.97) < 0.02:
    num = 30000
    den = 1001
    return true
  if abs(value - 59.94) < 0.03:
    num = 60000
    den = 1001
    return true

  if abs(value - round(value)) < 0.001:
    num = int(round(value))
    den = 1
    return num > 0

  den = 1000
  num = int(value * float64(den) + 0.5)
  let g = gcdInt(num, den)
  num = num div g
  den = den div g
  result = num > 0 and den > 0

proc parseFpsValue(rawValue: string; num, den: var int): bool =
  let raw = rawValue.strip().toLowerAscii()
  if raw.len == 0:
    return false

  if raw.contains("/"):
    let parts = raw.split("/", maxsplit = 1)
    if parts.len != 2:
      return false
    try:
      num = parseInt(parts[0].strip())
      den = parseInt(parts[1].strip())
      return num > 0 and den > 0
    except ValueError:
      return false

  try:
    let value = parseFloat(raw)
    result = fpsRationalFromFloat(value, num, den)
  except ValueError:
    result = false

proc resolveMp4VideoOutputFps(info: Mp4InputInfo): VideoOutputFpsInfo =
  ## HAILO_DEMO_MP4_FPS can be:
  ##   auto        : use input stream fps when available, otherwise 30fps
  ##   25          : fixed integer fps
  ##   30000/1001  : fixed rational fps
  ##   29.97       : fixed decimal fps, converted to a rational
  let raw = getEnv("HAILO_DEMO_MP4_FPS", "auto").strip().toLowerAscii()

  if raw.len == 0 or raw in ["auto", "adaptive", "source", "input"]:
    if info.hasSourceFps:
      if info.sourceFpsNum > 0 and info.sourceFpsDen > 0:
        return makeVideoOutputFpsInfo(info.sourceFpsNum, info.sourceFpsDen, info.fpsSource)

      var n, d: int
      if fpsRationalFromFloat(info.sourceFps, n, d):
        return makeVideoOutputFpsInfo(n, d, info.fpsSource)

    return makeVideoOutputFpsInfo(30, 1, "default")

  var n, d: int
  if parseFpsValue(raw, n, d):
    return makeVideoOutputFpsInfo(n, d, "env")

  result = makeVideoOutputFpsInfo(30, 1, "default")

proc resolveLiveVideoOutputFps(): VideoOutputFpsInfo =
  ## Live input does not have a reliable finite container duration.  For the
  ## bounded live-to-MP4 probe, keep output timing explicit and conservative.
  ##
  ## HAILO_DEMO_LIVE_FPS accepts the same forms as HAILO_DEMO_MP4_FPS:
  ##   20          : fixed integer fps
  ##   30000/1001  : fixed rational fps
  ##   29.97       : fixed decimal fps
  ##   auto/source  : use the live default of 20fps
  let raw = getEnv("HAILO_DEMO_LIVE_FPS", "20").strip().toLowerAscii()
  if raw.len == 0 or raw in ["auto", "adaptive", "source", "input", "default"]:
    return makeVideoOutputFpsInfo(20, 1, "live-default")

  var n, d: int
  if parseFpsValue(raw, n, d):
    return makeVideoOutputFpsInfo(n, d, "live-env")

  result = makeVideoOutputFpsInfo(20, 1, "live-default")

proc toLiveVideoProgressInfo(outputFps: VideoOutputFpsInfo; maxFrames: int): VideoProgressInfo =
  result.sourceFps = outputFps.fps
  result.sourceFpsNum = outputFps.num
  result.sourceFpsDen = outputFps.den
  result.hasSourceFps = outputFps.fps > 0.0
  if maxFrames > 0:
    result.estimatedTotalFrames = maxFrames
    result.hasEstimatedTotalFrames = true
    if outputFps.fps > 0.0:
      result.durationSeconds = float64(maxFrames) / outputFps.fps
      result.hasDuration = true

proc applyOutputFpsInfo(stats: var OverlayStats; info: VideoOutputFpsInfo) =
  stats.outputFps = info.fps
  stats.outputFpsNum = info.num
  stats.outputFpsDen = info.den
  stats.outputFpsSource = info.source

proc formatThroughputFps(frames, ms: int): string =
  if frames > 0 and ms > 0:
    result = &"{float(frames) * 1000.0 / float(ms):.1f}fps"
  else:
    result = "n/a"

proc formatInputVideoSummary(s: OverlayStats): string =
  var parts: seq[string] = @[]
  if s.sourceFps > 0.0:
    parts.add(formatSourceFps(s.sourceFps))
  if s.inputDurationSeconds > 0.0:
    parts.add(formatSeconds(s.inputDurationSeconds))
  if s.estimatedTotalFrames > 0:
    parts.add(&"~{s.estimatedTotalFrames} frames")

  if parts.len > 0:
    result = parts.join("/")

proc formatOutputVideoFpsSummary(s: OverlayStats): string =
  if s.outputFps <= 0.0:
    return ""

  result = formatOutputFps(s.outputFps)
  if s.outputFpsSource.len > 0:
    result.add(&"/{s.outputFpsSource}")

proc applyMp4InputInfo(stats: var OverlayStats; info: Mp4InputInfo) =
  if info.hasDuration:
    stats.inputDurationSeconds = info.durationSeconds
    stats.inputDurationSource = info.durationSource
  if info.hasSourceFps:
    stats.sourceFps = info.sourceFps
    stats.sourceFpsSource = info.fpsSource
  if info.hasEstimatedTotalFrames:
    stats.estimatedTotalFrames = info.estimatedTotalFrames

proc toVideoProgressInfo(info: Mp4InputInfo): VideoProgressInfo =
  ## Keep only scalar metadata for progress calculation.  This object is safe to
  ## pass to the overlay/encode worker thread; the full Mp4InputInfo contains
  ## GC-managed strings and is kept on the producer side only.
  result.durationSeconds = info.durationSeconds
  result.hasDuration = info.hasDuration
  result.sourceFps = info.sourceFps
  result.sourceFpsNum = info.sourceFpsNum
  result.sourceFpsDen = info.sourceFpsDen
  result.hasSourceFps = info.hasSourceFps
  result.estimatedTotalFrames = info.estimatedTotalFrames
  result.hasEstimatedTotalFrames = info.hasEstimatedTotalFrames

proc progressFrameDurationSeconds(info: VideoProgressInfo): float64 =
  if info.hasSourceFps and info.sourceFps > 0.0:
    result = 1.0 / info.sourceFps

proc progressTimestampSeconds(
    frameIndex: int;
    timestampSeconds: float64;
    hasTimestampSeconds: bool;
    info: VideoProgressInfo;
    seconds: var float64
  ): bool =
  ## Return the approximate *processed end time* of the frame.
  ##
  ## Frame PTS usually represents the start time of the decoded frame.  For a
  ## progress bar, however, users expect the bar to represent already-processed
  ## work.  Therefore add one nominal frame duration when fps is known.
  ##
  ## Hardware decode paths may still produce missing/flat timestamps, so fall
  ## back to (frameIndex + 1) / sourceFps.
  let frameDuration = progressFrameDurationSeconds(info)

  if hasTimestampSeconds and (timestampSeconds > 0.0 or frameIndex == 0):
    seconds = timestampSeconds
    if frameDuration > 0.0:
      seconds += frameDuration
    if info.hasDuration and info.durationSeconds > 0.0:
      seconds = min(seconds, info.durationSeconds)
    seconds = max(0.0, seconds)
    return true

  if info.hasSourceFps and info.sourceFps > 0.0 and frameIndex >= 0:
    seconds = float64(frameIndex + 1) / info.sourceFps
    if info.hasDuration and info.durationSeconds > 0.0:
      seconds = min(seconds, info.durationSeconds)
    seconds = max(0.0, seconds)
    return true

  result = false

proc detectionTimestampSeconds(
    frameIndex: int;
    timestampSeconds: float64;
    hasTimestampSeconds: bool;
    info: VideoProgressInfo
  ): float64 =
  ## Return the best timestamp for browser-side overlay synchronization.
  ## This should represent the displayed frame timestamp, not the processed end
  ## time used by the progress bar.
  if hasTimestampSeconds and (timestampSeconds > 0.0 or frameIndex == 0):
    return max(0.0, timestampSeconds)

  if info.hasSourceFps and info.sourceFps > 0.0 and frameIndex >= 0:
    return max(0.0, float64(frameIndex) / info.sourceFps)

  result = max(0.0, float64(frameIndex))

proc videoProgressPercent(
    processedFrames: int;
    maxFrames: int;
    info: VideoProgressInfo;
    timestampSeconds: float64;
    hasProgressSeconds: bool
  ): int =
  if processedFrames <= 0:
    return VideoProgressStart

  var ratio = -1.0

  if maxFrames > 0:
    ratio = float64(processedFrames) / float64(maxFrames)
  elif info.hasDuration and info.durationSeconds > 0.0 and hasProgressSeconds:
    ratio = timestampSeconds / info.durationSeconds
  elif info.hasEstimatedTotalFrames and info.estimatedTotalFrames > 0:
    ratio = float64(processedFrames) / float64(info.estimatedTotalFrames)

  if ratio >= 0.0:
    ratio = max(0.0, min(1.0, ratio))
    let span = VideoProgressEnd - VideoProgressStart
    return min(VideoProgressEnd, VideoProgressStart + int(ratio * float64(span) + 0.5))

  ## Last-resort fallback for containers without usable duration/fps metadata.
  ## Do not claim completion without a real total.
  result = min(VideoProgressEnd - 1, processedFrames div 10)

proc formatVideoProgressMessage(
    processedFrames: int;
    info: VideoProgressInfo;
    timestampSeconds: float64;
    hasProgressSeconds: bool
  ): string =
  let timeDetail =
    if info.hasDuration and info.durationSeconds > 0.0 and hasProgressSeconds:
      &" ({formatSeconds(min(timestampSeconds, info.durationSeconds))}/{formatSeconds(info.durationSeconds)})"
    elif info.hasEstimatedTotalFrames and info.estimatedTotalFrames > 0:
      &" / ~{info.estimatedTotalFrames}"
    else:
      ""

  result = &"processing video frame {processedFrames}{timeDetail}"

proc formatOverlaySummary*(s: OverlayStats): string =
  ## Short human-facing result text for the web UI.  The verbose timing detail
  ## remains available through formatOverlayStats() and is shown in a <details>
  ## block on the result page.
  if s.videoFrames > 0:
    let
      fps = formatThroughputFps(s.videoFrames, s.totalMs)
      duration = formatDurationMs(s.totalMs)
      outputDetail =
        if s.videoPacketBytes > 0:
          &", output={formatBytes(s.videoPacketBytes)}"
        else:
          ""
      bitrateDetail =
        if s.outputBitrate > 0:
          &", bitrate={formatBitrate(s.outputBitrate)}"
        else:
          ""
      outputFpsSummary = s.formatOutputVideoFpsSummary()
      outputFpsDetail =
        if outputFpsSummary.len > 0:
          &", out_fps={outputFpsSummary}"
        else:
          ""
      sourceSummary = s.formatInputVideoSummary()
      sourceDetail =
        if sourceSummary.len > 0:
          &", source={sourceSummary}"
        else:
          ""
    result = &"MP4 complete: {s.videoFrames} frames in {duration} ({fps}); detections={s.detections}, boxes={s.boxesDrawn}, labels={s.labelsDrawn}{outputDetail}{bitrateDetail}{outputFpsDetail}{sourceDetail}"
  else:
    let drawCountDetail =
      if s.boxesDrawn > 0 or s.labelsDrawn > 0:
        &", boxes={s.boxesDrawn}, labels={s.labelsDrawn}"
      else:
        ""
    result = &"complete: {s.imageWidth}x{s.imageHeight} in {formatDurationMs(s.totalMs)}; detections={s.detections}{drawCountDetail}"

proc formatInferStats(s: OverlayStats): string =
  if s.inferSubmitMs > 0 or s.inferWaitMs > 0:
    let hailoDetail =
      if s.hailoWriteUs > 0 or s.hailoReadUs > 0 or s.hailoParseUs > 0 or s.hailoSortUs > 0:
        &", hailo_us=write:{s.hailoWriteUs}/read:{s.hailoReadUs}/parse:{s.hailoParseUs}/sort:{s.hailoSortUs}"
      else:
        ""
    result = &"infer={s.inferMs}[submit={s.inferSubmitMs}, wait={s.inferWaitMs}, overlap={s.inferOverlapMs}{hailoDetail}]"
  else:
    result = &"infer={s.inferMs}"

proc formatPipelineStats(s: OverlayStats): string =
  if s.pipelineFrames <= 1:
    return ""

  let letterboxDetail =
    if s.letterboxFramesMs.len > 0:
      &", letterboxes={formatFrameMsSummary(s.letterboxFramesMs)}"
    else:
      ""
  let submitDetail =
    if s.inferSubmitFramesMs.len > 0:
      &", submits={formatFrameMsSummary(s.inferSubmitFramesMs)}"
    else:
      ""
  let waitDetail =
    if s.inferWaitFramesMs.len > 0:
      &", waits={formatFrameMsSummary(s.inferWaitFramesMs)}"
    else:
      ""
  let rgbxDetail =
    if s.rgbxFramesMs.len > 0:
      &", rgbx={formatFrameMsSummary(s.rgbxFramesMs)}"
    else:
      ""

  let inFlightDetail =
    if s.pipelineInFlight > 1:
      &"/inflight:{s.pipelineInFlight}"
    else:
      ""

  result = &", pipeline=frames:{s.pipelineFrames}/submitted:{s.pipelineSubmitted}/replies:{s.pipelineReplies}{inFlightDetail}{letterboxDetail}{submitDetail}{waitDetail}{rgbxDetail}"

proc formatOverlayStats*(s: OverlayStats): string =
  let drawCountDetail =
    if s.detections > 0 or s.boxesDrawn > 0 or s.labelsDrawn > 0:
      &", boxes={s.boxesDrawn}, labels={s.labelsDrawn}"
    else:
      ""
  let base = &"detections={s.detections}{drawCountDetail}, image={s.imageWidth}x{s.imageHeight}, total={s.totalMs} ms "
  let inferDetail = s.formatInferStats()
  let pipelineDetail = s.formatPipelineStats()

  if s.videoFrames > 0:
    let decoderLabel = if s.decoderName.len > 0: s.decoderName else: "auto"
    let sourceSummary = s.formatInputVideoSummary()
    let sourceDetail =
      if sourceSummary.len > 0:
        &"/source:{sourceSummary}"
      else:
        ""
    result = base &
      &"(video=frames:{s.videoFrames}/packets:{s.videoPackets}/bytes:{formatBytes(s.videoPacketBytes)}{sourceDetail}, " &
      &"decode={s.decodeMs}[decoder={decoderLabel}, open={s.decoderOpenMs}, reads={formatFrameMsSummary(s.readFramesMs)}], " &
      &"letterbox={s.letterboxMs}, {inferDetail}{pipelineDetail}, " &
      &"draw={s.drawMs}[rgbx={s.rgbxMs}, overlay={max(0, s.drawMs - s.rgbxMs)}], " &
      &"encode={s.encodeMs}[bitrate={formatBitrate(s.outputBitrate)}, fps={formatOutputVideoFpsSummary(s)}, open={s.encoderOpenMs}, writer={s.writerOpenMs}, flush={s.encoderFlushMs}, finish={s.writerFinishMs}])"
    return

  if s.decoderOpenMs > 0 or s.readFrameMs > 0 or s.rgbxMs > 0:
    let
      overlayMs = max(0, s.drawMs - s.rgbxMs)
      decoderLabel = if s.decoderName.len > 0: s.decoderName else: "auto"
      readDetail = if s.readFramesMs.len > 1:
          &"reads={formatReadFramesMs(s.readFramesMs)}, frame={s.previewFrameIndex}"
        else:
          &"read={s.readFrameMs}"
    result = base &
      &"(decode={s.decodeMs}[decoder={decoderLabel}, open={s.decoderOpenMs}, {readDetail}], " &
      &"letterbox={s.letterboxMs}, {inferDetail}{pipelineDetail}, " &
      &"draw={s.drawMs}[rgbx={s.rgbxMs}, overlay={overlayMs}], encode={s.encodeMs})"
  else:
    result = base &
      &"(decode={s.decodeMs}, letterbox={s.letterboxMs}, {inferDetail}{pipelineDetail}, " &
      &"draw={s.drawMs}, encode={s.encodeMs})"

proc clampf(v, lo, hi: float32): float32 =
  result = max(lo, min(v, hi))

proc clampDetection(d: Detection; imageW, imageH: int): Detection =
  let
    maxX = max(0.float32, imageW.float32 - 1.float32)
    maxY = max(0.float32, imageH.float32 - 1.float32)

  result = d
  result.x = clampf(d.x, 0, maxX)
  result.y = clampf(d.y, 0, maxY)
  result.w = clampf(d.w, 1, imageW.float32 - result.x)
  result.h = clampf(d.h, 1, imageH.float32 - result.y)

proc jsonEscapedString(value: string): string =
  result = "\""
  for ch in value:
    case ch
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\b': result.add("\\b")
    of '\f': result.add("\\f")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else:
      let code = ord(ch)
      if code < 0x20:
        result.add(&"\\u{code:04x}")
      else:
        result.add(ch)
  result.add('"')

proc writeJsonField(file: File; name: string; value: string; comma = true) =
  file.write(&"    \"{name}\": {value}")
  if comma:
    file.write(",")
  file.write("\n")

proc videoInfoJson(width, height: int; inputInfo: VideoProgressInfo): string =
  var parts: seq[string] = @[]
  parts.add(&"\"width\":{width}")
  parts.add(&"\"height\":{height}")
  if inputInfo.hasSourceFps:
    parts.add(&"\"sourceFps\":{inputInfo.sourceFps:.6f}")
    parts.add(&"\"sourceFpsNum\":{inputInfo.sourceFpsNum}")
    parts.add(&"\"sourceFpsDen\":{inputInfo.sourceFpsDen}")
  else:
    parts.add("\"sourceFps\":0.000000")
    parts.add("\"sourceFpsNum\":0")
    parts.add("\"sourceFpsDen\":0")
  if inputInfo.hasDuration:
    parts.add(&"\"durationSeconds\":{inputInfo.durationSeconds:.6f}")
  else:
    parts.add("\"durationSeconds\":0.000000")
  if inputInfo.hasEstimatedTotalFrames:
    parts.add(&"\"estimatedTotalFrames\":{inputInfo.estimatedTotalFrames}")
  else:
    parts.add("\"estimatedTotalFrames\":0")
  result = "{" & parts.join(",") & "}"

proc detectionToJson(raw: Detection; width, height: int): string =
  let d = raw.clampDetection(width, height)
  let
    nx = d.x / max(1.float32, width.float32)
    ny = d.y / max(1.float32, height.float32)
    nw = d.w / max(1.float32, width.float32)
    nh = d.h / max(1.float32, height.float32)

  result =
    &"{{\"classId\": {d.classId}, \"label\": {jsonEscapedString(d.label)}, " &
    &"\"score\": {d.score:.6f}, \"x\": {nx:.6f}, \"y\": {ny:.6f}, " &
    &"\"w\": {nw:.6f}, \"h\": {nh:.6f}}}"

proc moveDetectionJsonIntoPlace(writer: var DetectionJsonWriter) =
  try:
    moveFile(writer.tmpPath, writer.outputPath)
  except OSError:
    try:
      if fileExists(writer.outputPath):
        removeFile(writer.outputPath)
    except OSError:
      discard
    moveFile(writer.tmpPath, writer.outputPath)

proc openDetectionJsonWriter(
    outputPath: string;
    liveOutputPath: string;
    width, height: int;
    inputInfo: VideoProgressInfo
  ): DetectionJsonWriter =
  if outputPath.len == 0 and liveOutputPath.len == 0:
    return

  let primaryDir =
    if outputPath.len > 0: outputPath.splitFile.dir
    else: liveOutputPath.splitFile.dir
  if primaryDir.len > 0:
    createDir(primaryDir)

  result.outputPath = outputPath
  if outputPath.len > 0:
    result.tmpPath = outputPath & ".tmp"
  result.livePath = liveOutputPath
  result.width = width
  result.height = height
  result.firstFrame = true

  if outputPath.len > 0:
    result.file = open(result.tmpPath, fmWrite)
    result.opened = true

  if liveOutputPath.len > 0:
    if fileExists(liveOutputPath):
      removeFile(liveOutputPath)
    result.liveFile = open(liveOutputPath, fmWrite)
    result.liveOpened = true
    result.liveFile.write(&"{{\"type\":\"meta\",\"version\":1,\"video\":{videoInfoJson(width, height, inputInfo)}}}\n")
    result.liveFile.flushFile()

  if result.opened:
    result.file.write("{\n")
    result.file.write("  \"version\": 1,\n")
    result.file.write("  \"video\": {\n")
    result.file.writeJsonField("width", $width)
    result.file.writeJsonField("height", $height)
    if inputInfo.hasSourceFps:
      result.file.writeJsonField("sourceFps", &"{inputInfo.sourceFps:.6f}")
      result.file.writeJsonField("sourceFpsNum", $inputInfo.sourceFpsNum)
      result.file.writeJsonField("sourceFpsDen", $inputInfo.sourceFpsDen)
    else:
      result.file.writeJsonField("sourceFps", "0.000000")
      result.file.writeJsonField("sourceFpsNum", "0")
      result.file.writeJsonField("sourceFpsDen", "0")
    if inputInfo.hasDuration:
      result.file.writeJsonField("durationSeconds", &"{inputInfo.durationSeconds:.6f}")
    else:
      result.file.writeJsonField("durationSeconds", "0.000000")
    if inputInfo.hasEstimatedTotalFrames:
      result.file.writeJsonField("estimatedTotalFrames", $inputInfo.estimatedTotalFrames, comma = false)
    else:
      result.file.writeJsonField("estimatedTotalFrames", "0", comma = false)
    result.file.write("  },\n")
    result.file.write("  \"frames\": [\n")

proc isOpen(writer: DetectionJsonWriter): bool =
  writer.opened

proc writeFrameDetections(
    writer: var DetectionJsonWriter;
    frameIndex: int;
    timestampSeconds: float64;
    detections: openArray[Detection]
  ) =
  if not writer.opened and not writer.liveOpened:
    return

  if writer.opened:
    if not writer.firstFrame:
      writer.file.write(",\n")
    writer.firstFrame = false

    writer.file.write(&"    {{\"frame\": {frameIndex}, \"time\": {timestampSeconds:.6f}, \"detections\": [")

    for i, raw in detections:
      if i > 0:
        writer.file.write(",")
      writer.file.write(raw.detectionToJson(writer.width, writer.height))

    writer.file.write("]}")

  if writer.liveOpened:
    writer.liveFile.write(&"{{\"type\":\"frame\",\"frame\":{frameIndex},\"time\":{timestampSeconds:.6f},\"detections\":[")
    for i, raw in detections:
      if i > 0:
        writer.liveFile.write(",")
      writer.liveFile.write(raw.detectionToJson(writer.width, writer.height))
    writer.liveFile.write("]}\n")
    writer.liveFile.flushFile()

  inc writer.frameCount
  writer.detectionCount += detections.len

proc closeDetectionJsonWriter(writer: var DetectionJsonWriter) =
  if writer.opened:
    writer.file.write("\n  ],\n")
    writer.file.write(&"  \"frameCount\": {writer.frameCount},\n")
    writer.file.write(&"  \"detectionCount\": {writer.detectionCount}\n")
    writer.file.write("}\n")
    writer.file.close()
    writer.opened = false
    writer.moveDetectionJsonIntoPlace()

  if writer.liveOpened:
    writer.liveFile.write(&"{{\"type\":\"done\",\"frameCount\":{writer.frameCount},\"detectionCount\":{writer.detectionCount}}}\n")
    writer.liveFile.close()
    writer.liveOpened = false

proc abortDetectionJsonWriter(writer: var DetectionJsonWriter) =
  if writer.opened:
    try:
      writer.file.close()
    except IOError:
      discard
    writer.opened = false
  if writer.tmpPath.len > 0 and fileExists(writer.tmpPath):
    try:
      removeFile(writer.tmpPath)
    except OSError:
      discard
  if writer.liveOpened:
    try:
      writer.liveFile.close()
    except IOError:
      discard
    writer.liveOpened = false

proc setClassColor(ctx: Context; classId: int) =
  case classId mod 4
  of 0:
    ctx.fillStyle = rgba(31, 136, 61, 255)
  of 1:
    ctx.fillStyle = rgba(9, 105, 218, 255)
  of 2:
    ctx.fillStyle = rgba(191, 135, 0, 255)
  else:
    ctx.fillStyle = rgba(130, 80, 223, 255)

proc drawStrokeRect(ctx: Context; d: Detection) =
  let
    x = d.x
    y = d.y
    w = d.w
    h = d.h
    t = min(BoxThickness, min(w, h) / 3.float32)

  ctx.fillRect(rect(vec2(x, y), vec2(w, t)))
  ctx.fillRect(rect(vec2(x, y + h - t), vec2(w, t)))
  ctx.fillRect(rect(vec2(x, y), vec2(t, h)))
  ctx.fillRect(rect(vec2(x + w - t, y), vec2(t, h)))

proc drawLabel(image: Image; ctx: Context; font: Font; d: Detection) =
  let
    text = &"{d.label} {int(round(d.score * 100.float32))}%"
    labelW = max(72.float32, text.len.float32 * 9.float32 + LabelPadX * 2.float32)
    x = d.x
    y = if d.y >= LabelHeight + 2.float32: d.y - LabelHeight else: d.y

  ## Background uses the currently selected class color.
  ctx.fillRect(rect(vec2(x, y), vec2(labelW, LabelHeight)))

  var textFont = font
  textFont.size = LabelFontSize
  textFont.paint.color = color(1, 1, 1)
  image.fillText(
    textFont.typeset(text, vec2(labelW - LabelPadX * 2.float32, LabelHeight)),
    translate(vec2(x + LabelPadX, y + 2.float32))
  )

proc drawLiveDebugOverlay(image: Image; font: Font; hasFont: bool; frameIndex: int; detections: int; boxes: int; threshold: float32) =
  ## Draw an optional compact activity marker for the live AI preview.
  ## Keep it intentionally small: the goal is to show that frames are passing
  ## through the AI pipeline without covering too much of the camera image.
  const spinnerFrames = ["|", "/", "-", "\\"]
  let
    safeFrame = max(0, frameIndex)
    spinner = spinnerFrames[safeFrame mod spinnerFrames.len]
    text = &"AI {spinner} f={safeFrame}"
    panelX = 10.float32
    panelY = 10.float32
    panelH = 42.float32
    panelW = min(image.width.float32 - 20.float32, max(150.float32, text.len.float32 * 15.float32 + 48.float32))

  if panelW <= 40.float32 or image.height < 58:
    return

  let ctx = newContext(image)
  ctx.fillStyle = rgba(0, 0, 0, 172)
  ctx.fillRect(rect(vec2(panelX, panelY), vec2(panelW, panelH)))

  ## Blink a small square every frame.  It remains useful even when the preview
  ## is scaled down and the text is hard to read.
  if safeFrame mod 2 == 0:
    ctx.fillStyle = rgba(31, 136, 61, 255)
    ctx.fillRect(rect(vec2(panelX + 10.float32, panelY + 12.float32), vec2(16.float32, 16.float32)))
  else:
    ctx.fillStyle = rgba(31, 136, 61, 96)
    ctx.fillRect(rect(vec2(panelX + 13.float32, panelY + 15.float32), vec2(10.float32, 10.float32)))

  if hasFont:
    var textFont = font
    textFont.size = 26.float32
    textFont.paint.color = color(1, 1, 1)
    image.fillText(
      textFont.typeset(text, vec2(panelW - 44.float32, 34.float32)),
      translate(vec2(panelX + 34.float32, panelY + 5.float32))
    )
  else:
    ## Last-resort indicator when the font is missing.  It still shows that this
    ## frame passed through the AI overlay path.
    ctx.fillStyle = rgba(255, 255, 255, 230)
    ctx.fillRect(rect(vec2(panelX + 36.float32, panelY + 14.float32), vec2(72.float32, 5.float32)))
    ctx.fillRect(rect(vec2(panelX + 36.float32, panelY + 24.float32), vec2(48.float32, 5.float32)))

proc shouldDrawLabel(d: Detection; labelsDrawn: int; options: OverlayDrawOptions): bool =
  if labelsDrawn >= options.maxLabels:
    return false
  if d.score < options.minLabelScore:
    return false

  let area = d.w * d.h
  result = d.h >= options.minLabelBoxHeight and area >= options.minLabelBoxArea

proc shouldDrawBox(d: Detection; boxesDrawn: int; options: OverlayDrawOptions): bool =
  if options.maxBoxes > 0 and boxesDrawn >= options.maxBoxes:
    return false
  result = d.score >= options.minBoxScore

proc loadOverlayFont(fontPath: string): tuple[font: Font, hasFont: bool] =
  if fontPath.len > 0 and fileExists(fontPath):
    try:
      result.font = readFont(fontPath)
      result.hasFont = true
    except CatchableError:
      result.hasFont = false

proc drawDetectionsLoadedFont(
    image: Image;
    detections: openArray[Detection];
    font: Font;
    hasFont: bool;
    options: OverlayDrawOptions
  ): OverlayDrawResult =
  let ctx = newContext(image)
  var
    boxesDrawn = 0
    labelsDrawn = 0
    sorted: seq[Detection] = @[]

  for raw in detections:
    if raw.score >= options.minBoxScore:
      sorted.add(raw)

  sorted.sort(proc(a, b: Detection): int =
    if a.score < b.score:
      1
    elif a.score > b.score:
      -1
    else:
      0
  )

  for raw in sorted:
    let d = raw.clampDetection(image.width, image.height)
    if not d.shouldDrawBox(boxesDrawn, options):
      continue

    ctx.setClassColor(d.classId)
    ctx.drawStrokeRect(d)
    inc boxesDrawn

    if hasFont and d.shouldDrawLabel(labelsDrawn, options):
      ctx.setClassColor(d.classId)
      image.drawLabel(ctx, font, d)
      inc labelsDrawn

  result.boxes = boxesDrawn
  result.labels = labelsDrawn

proc drawDetectionsWithOptions(
    image: Image;
    detections: openArray[Detection];
    fontPath: string;
    options: OverlayDrawOptions
  ): OverlayDrawResult =
  let loaded = loadOverlayFont(fontPath)
  result = image.drawDetectionsLoadedFont(detections, loaded.font, loaded.hasFont, options)

proc drawDetections*(image: Image; detections: openArray[Detection]; fontPath: string): OverlayDrawResult =
  result = image.drawDetectionsWithOptions(detections, fontPath, resolveStillDrawOptions())

static:
  doAssert sizeof(PixelRGBX) == sizeof(ColorRGBX)

proc requirePackedRgbx(frame: OwnedRGBXFrame) =
  if not frame.isValid():
    raise newException(ValueError, "RGBX frame is invalid")
  if frame.stridePixels != frame.width:
    raise newException(
      ValueError,
      &"Pixie zero-copy adapter requires packed RGBX: stridePixels={frame.stridePixels} width={frame.width}"
    )
  if frame.data.len != frame.width * frame.height:
    raise newException(
      ValueError,
      &"Pixie zero-copy adapter requires exact data size: data.len={frame.data.len} expected={frame.width * frame.height}"
    )

proc moveRgbxDataToPixieImage(frame: var OwnedRGBXFrame): Image =
  ## Move OwnedRGBXFrame.data into a Pixie Image so bbox/label drawing can use
  ## the same Pixie overlay code as the JPEG preview path without a full-frame
  ## copy.  The frame must be moved back before it is passed to the encoder.
  frame.requirePackedRgbx()
  result = Image()
  result.width = frame.width
  result.height = frame.height
  result.data = move cast[ptr seq[ColorRGBX]](addr frame.data)[]

proc movePixieImageDataBack(image: var Image; frame: var OwnedRGBXFrame) =
  frame.data = move cast[ptr seq[PixelRGBX]](addr image.data)[]


proc drawLiveDebugOverlayOnRgbxFrame(
    frame: var OwnedRGBXFrame;
    font: Font;
    hasFont: bool;
    frameIndex: int;
    detections: int;
    boxes: int;
    threshold: float32
  ) =
  var image = moveRgbxDataToPixieImage(frame)
  try:
    image.drawLiveDebugOverlay(font, hasFont, frameIndex, detections, boxes, threshold)
  finally:
    movePixieImageDataBack(image, frame)



proc resolveVideoPreviewFrame(): int =
  ## Save one annotated JPEG preview frame during MP4 processing.  This is used
  ## by the wait page so users can see that the pipeline is really working.
  result = max(1, parseEnvIntDraw("HAILO_DEMO_VIDEO_PREVIEW_FRAME", 10))

proc saveRgbxFramePreviewJpeg(frame: var OwnedRGBXFrame; outputPath: string) =
  if outputPath.len == 0:
    return

  let tmpPath = outputPath & ".tmp"
  var image = moveRgbxDataToPixieImage(frame)
  try:
    image.encodeImageToJpeg(tmpPath)
  finally:
    movePixieImageDataBack(image, frame)

  try:
    moveFile(tmpPath, outputPath)
  except OSError:
    try:
      if fileExists(outputPath):
        removeFile(outputPath)
    except OSError:
      discard
    moveFile(tmpPath, outputPath)

proc drawDetectionsOnRgbxFrame(
    frame: var OwnedRGBXFrame;
    detections: openArray[Detection];
    font: Font;
    hasFont: bool;
    options: OverlayDrawOptions
  ): OverlayDrawResult =
  var image = moveRgbxDataToPixieImage(frame)
  try:
    result = image.drawDetectionsLoadedFont(detections, font, hasFont, options)
  finally:
    movePixieImageDataBack(image, frame)

proc finishOverlayWithDetections(
    image: var Image;
    detections: openArray[Detection];
    outputPath, fontPath: string;
    stats: var OverlayStats;
    totalStart: float;
    drawOptions: OverlayDrawOptions
  ) =
  stats.imageWidth = image.width
  stats.imageHeight = image.height
  stats.detections = detections.len

  var stageStart = epochTime()
  let drawResult = image.drawDetectionsWithOptions(detections, fontPath, drawOptions)
  stats.boxesDrawn = drawResult.boxes
  stats.labelsDrawn = drawResult.labels
  stats.drawMs += elapsedMs(stageStart)

  stageStart = epochTime()
  image.encodeImageToJpeg(outputPath)
  stats.encodeMs = elapsedMs(stageStart)

  stats.totalMs = elapsedMs(totalStart)

proc finishOverlay(
    image: var Image;
    yoloInput: YoloInputImage;
    outputPath, fontPath: string;
    stats: var OverlayStats;
    totalStart: float;
    drawOptions: OverlayDrawOptions
  ) =
  var stageStart = epochTime()
  let detections = yoloInput.detectYolo()
  stats.inferMs = elapsedMs(stageStart)

  image.finishOverlayWithDetections(detections, outputPath, fontPath, stats, totalStart, drawOptions)

proc drawHailoOverlay*(inputPath, outputPath, fontPath: string; options: JobOptions = defaultJobOptions()): OverlayStats =
  let totalStart = epochTime()

  var stageStart = epochTime()
  var image = readJpegToPixieImage(inputPath)
  result.decodeMs = elapsedMs(stageStart)

  ## yoloInput.rgb.data is the 640x640 packed RGB/NHWC3 buffer passed to HAILO.
  stageStart = epochTime()
  let yoloInput = image.prepareYoloInput()
  result.letterboxMs = elapsedMs(stageStart)

  image.finishOverlay(yoloInput, outputPath, fontPath, result, totalStart, resolveDrawOptionsFromJobOptions(options, false))

proc useMp4OverlapPipeline(): bool =
  let raw = getEnv("HAILO_DEMO_MP4_OVERLAP", "1").toLowerAscii()
  result = raw notin ["0", "false", "no", "off"]

proc useMp4PipelineProbe(): bool =
  ## Experimental multi-frame path.  It still writes one JPEG preview, but it
  ## submits each decoded frame to the HAILO worker with a frameNo/requestId.
  let raw = getEnv("HAILO_DEMO_MP4_PIPELINE_PROBE", "0").toLowerAscii()
  result = raw in ["1", "true", "yes", "on"]

proc drawMp4PreviewOverlayPipelined(inputPath, outputPath, fontPath: string): OverlayStats =
  ## Decode one representative MP4 frame, submit HAILO inference as soon as the
  ## 640x640 YOLO input is ready, then build the full-size RGBX preview while
  ## the HAILO worker is reading/parsing the output.
  ##
  ## Output remains one JPEG preview.  Only the internal scheduling changes.
  let totalStart = epochTime()

  var decoded = openMp4PreviewDecodedFrame(inputPath)
  defer: decoded.close()

  result.decodeMs = decoded.decodeMs
  result.decoderOpenMs = decoded.decoderOpenMs
  result.readFrameMs = decoded.readFrameMs
  result.readFramesMs = decoded.readFramesMs
  result.previewFrameIndex = decoded.frameIndex
  result.requestedProbeFrames = decoded.requestedProbeFrames
  result.decoderName = decoded.decoderName

  var stageStart = epochTime()
  var yoloInput = decoded.read.frame.prepareYoloInput()
  result.letterboxMs = elapsedMs(stageStart)

  let pending = yoloInput.submitYoloAsync(uint64(decoded.frameIndex))
  result.inferSubmitMs = pending.submitMs

  stageStart = epochTime()
  var image = decoded.read.frame.yuv420FrameToPixieImage()
  result.rgbxMs = elapsedMs(stageStart)
  result.drawMs = result.rgbxMs

  let yoloResult = pending.waitYoloAsync()
  result.inferMs = yoloResult.totalMs
  result.inferWaitMs = yoloResult.waitMs
  result.inferOverlapMs = max(0, yoloResult.totalMs - pending.submitMs - yoloResult.waitMs)
  result.hailoWriteUs = yoloResult.writeUs
  result.hailoReadUs = yoloResult.readUs
  result.hailoParseUs = yoloResult.parseUs
  result.hailoSortUs = yoloResult.sortUs

  image.finishOverlayWithDetections(
    yoloResult.detections,
    outputPath,
    fontPath,
    result,
    totalStart,
    resolveVideoDrawOptions()
  )

proc drawMp4PreviewOverlayPipelineProbe(inputPath, outputPath, fontPath: string): OverlayStats =
  ## Multi-frame MP4 preview probe.
  ##
  ## This still writes only one JPEG preview: the last decoded probe frame.
  ## Internally, however, each decoded frame is converted to a YOLO input and
  ## submitted to the HAILO threadtools worker with requestId=frameNo.  The full
  ## RGBX preview conversion is done after each submit so HAILO output read/parse
  ## can progress while the CPU prepares overlay frames.
  let totalStart = epochTime()

  var reader = openMp4PreviewDecoder(inputPath)
  defer: reader.close()

  result.decoderOpenMs = reader.decoderOpenMs
  result.decoderName = reader.decoderName
  result.requestedProbeFrames = mp4PreviewProbeFrames()
  result.pipelineFrames = result.requestedProbeFrames

  var
    pendings: seq[YoloAsyncPending] = @[]
    selectedImage: Image
    selectedFrameIndex = -1

  for _ in 0 ..< result.requestedProbeFrames:
    let frameRead = reader.readNextFrame()
    if frameRead.eof:
      if pendings.len == 0:
        raise newException(IOError, &"MP4 has no decodable video frame: {inputPath}")
      break

    result.readFramesMs.add(frameRead.readMs)
    result.readFrameMs += frameRead.readMs
    result.previewFrameIndex = frameRead.frameIndex
    result.imageWidth = frameRead.frameWidth
    result.imageHeight = frameRead.frameHeight

    var stageStart = epochTime()
    var yoloInput = frameRead.read.frame.prepareYoloInput()
    let letterboxMs = elapsedMs(stageStart)
    result.letterboxFramesMs.add(letterboxMs)
    result.letterboxMs += letterboxMs

    let pending = yoloInput.submitYoloAsync(uint64(frameRead.frameIndex))
    result.inferSubmitFramesMs.add(pending.submitMs)
    pendings.add(pending)
    inc result.pipelineSubmitted

    ## Keep only the newest preview image.  Replacing this Image drops the
    ## previous ref and mirrors the future video path: every decoded frame can
    ## become an overlay candidate, while this demo still publishes one JPEG.
    stageStart = epochTime()
    selectedImage = frameRead.read.frame.yuv420FrameToPixieImage()
    let rgbxMs = elapsedMs(stageStart)
    result.rgbxFramesMs.add(rgbxMs)
    result.rgbxMs += rgbxMs
    result.drawMs = result.rgbxMs
    selectedFrameIndex = frameRead.frameIndex

  if pendings.len == 0 or selectedImage.isNil or selectedFrameIndex < 0:
    raise newException(IOError, &"MP4 has no decodable video frame: {inputPath}")

  result.decodeMs = result.decoderOpenMs + result.readFrameMs
  result.pipelineFrames = pendings.len

  var selectedDetections: seq[Detection] = @[]
  var haveSelectedDetections = false

  for pending in pendings:
    let yoloResult = pending.waitYoloAsync()
    inc result.pipelineReplies
    result.inferWaitFramesMs.add(yoloResult.waitMs)

    if int(yoloResult.requestId) == selectedFrameIndex:
      result.inferMs = yoloResult.totalMs
      result.inferSubmitMs = pending.submitMs
      result.inferWaitMs = yoloResult.waitMs
      result.inferOverlapMs = max(0, yoloResult.totalMs - pending.submitMs - yoloResult.waitMs)
      result.hailoWriteUs = yoloResult.writeUs
      result.hailoReadUs = yoloResult.readUs
      result.hailoParseUs = yoloResult.parseUs
      result.hailoSortUs = yoloResult.sortUs
      selectedDetections = yoloResult.detections
      haveSelectedDetections = true

  if not haveSelectedDetections:
    raise newException(IOError, &"HAILO result for preview frame was not received: frame={selectedFrameIndex}")

  selectedImage.finishOverlayWithDetections(
    selectedDetections,
    outputPath,
    fontPath,
    result,
    totalStart,
    resolveVideoDrawOptions()
  )


proc alignUp(value, alignment: int): int =
  if alignment <= 0:
    return value
  result = ((value + alignment - 1) div alignment) * alignment

proc parseEnvInt(name: string; defaultValue: int): int =
  let raw = getEnv(name, "").strip()
  if raw.len == 0:
    return defaultValue

  try:
    result = parseInt(raw)
  except ValueError:
    result = defaultValue

proc resolveMp4VideoBitrateConfig(options: JobOptions): VideoBitrateConfig =
  ## A fixed bitrate keeps the old behavior.  Otherwise bitrate is selected from
  ## output size/fps and optionally scaled by the Web UI quality preset.
  result.fixedBitrate = 0
  result.autoMultiplierPercent = 100

  case options.mp4Quality
  of mpqSmall:
    result.autoMultiplierPercent = 65
  of mpqBalanced:
    result.autoMultiplierPercent = 100
  of mpqHigh:
    result.autoMultiplierPercent = 150
  of mpqManual:
    if options.manualBitrate > 0:
      result.fixedBitrate = options.manualBitrate
    else:
      result.autoMultiplierPercent = 100
  of mpqAuto:
    let raw = getEnv("HAILO_DEMO_MP4_BITRATE", "auto").strip().toLowerAscii()
    if raw.len > 0 and raw notin ["auto", "adaptive"]:
      try:
        result.fixedBitrate = max(1, parseInt(raw))
      except ValueError:
        result.fixedBitrate = 0

proc clampBitrate(value: int): int =
  result = value
  if result < 250_000:
    result = 250_000
  if result > 20_000_000:
    result = 20_000_000

proc autoMp4VideoBitrate(width, height, fps: int): int =
  ## Pick a conservative H.264 bitrate from output frame size.
  ##
  ## The coefficient is chosen so that common resolutions land around:
  ##   720p30  -> ~2Mbps
  ##   1080p30 -> ~4Mbps
  ##   4K30    -> ~15Mbps
  ## This keeps demo output small while avoiding the worst artifacts from using
  ## a fixed 2Mbps bitrate for Full-HD or 4K sources.
  let
    safeWidth = max(1, width)
    safeHeight = max(1, height)
    safeFps = max(1, fps)
    pixels = float(safeWidth) * float(safeHeight)
    bitsPerPixelFrame = 0.064
    raw = int(pixels * float(safeFps) * bitsPerPixelFrame + 0.5)
    minAuto = if safeWidth * safeHeight >= 1280 * 720: 2_000_000 else: 1_000_000

  result = raw
  if result < minAuto:
    result = minAuto
  if result > 20_000_000:
    result = 20_000_000

proc resolveMp4VideoBitrate(width, height, fps: int; config: VideoBitrateConfig): int =
  if config.fixedBitrate > 0:
    return config.fixedBitrate.clampBitrate()

  let base = autoMp4VideoBitrate(width, height, fps)
  result = int(float(base) * float(config.autoMultiplierPercent) / 100.0 + 0.5).clampBitrate()

proc resolveMp4VideoEncoderName(): string =
  result = getEnv("HAILO_DEMO_MP4_ENCODER", "h264_v4l2m2m").strip()
  if result.len == 0:
    result = "h264_v4l2m2m"

proc resolveMp4VideoInFlight(): int =
  ## Number of decoded/RGBX frames kept ahead of the oldest HAILO reply.
  ## A value of 2 matches the current HAILO worker slot count and is enough to
  ## hide one frame's letterbox/RGBX work behind the previous frame's output
  ## read.  Higher values are allowed for experiments, but each 1280x720 RGBX
  ## frame costs about 3.5 MiB.
  result = max(1, parseEnvInt("HAILO_DEMO_MP4_INFLIGHT", 2))
  result = min(result, 8)

proc checkFFmpeg[T](ret: FFmpegResult[T]; context: string): T =
  if ret.isErr:
    raise newException(IOError, &"{context}: {ret.error.message}")
  result = ret.value

proc checkFFmpegVoid(ret: FFmpegResult[void]; context: string) =
  if ret.isErr:
    raise newException(IOError, &"{context}: {ret.error.message}")

type
  PendingVideoFrame = object
    frameIndex: int
    pending: YoloAsyncPending
    rgbx: OwnedRGBXFrame
    frameTimestampSeconds: float64
    progressSeconds: float64
    hasProgressSeconds: bool

proc acquireRgbxFrame(
    pool: var seq[OwnedRGBXFrame];
    width, height: int
  ): FFmpegResult[OwnedRGBXFrame] =
  while pool.len > 0:
    var frame = move pool[pool.high]
    pool.setLen(pool.len - 1)
    if frame.isValid() and frame.width == width and frame.height == height:
      return ok(move frame)

  result = newOwnedRGBXFrame(width, height)

proc notifyVideoFrameProgress(
    onProgress: OverlayProgressCallback;
    progressCtx: pointer;
    stats: OverlayStats;
    maxFrames: int;
    inputInfo: VideoProgressInfo;
    force = false
  ) {.gcsafe.} =
  if stats.videoFrames <= 0:
    return
  if not force and not (stats.videoFrames == 1 or (stats.videoFrames mod 10) == 0):
    return

  let progress = videoProgressPercent(
    stats.videoFrames,
    maxFrames,
    inputInfo,
    stats.progressSeconds,
    stats.progressSeconds > 0.0 or stats.videoFrames == 1
  )

  notifyProgress(
    onProgress,
    progressCtx,
    progress,
    formatVideoProgressMessage(
      stats.videoFrames,
      inputInfo,
      stats.progressSeconds,
      stats.progressSeconds > 0.0 or stats.videoFrames == 1
    )
  )

proc drainEncoder(
    encoder: VideoEncoder;
    writer: Mp4VideoWriter;
    stats: var OverlayStats
  ) =
  while true:
    let packetRead = checkFFmpeg(encoder.receivePacket(), "receive encoded packet")
    if not packetRead.hasPacket:
      break

    inc stats.videoPackets
    stats.videoPacketBytes += packetRead.packet.size
    checkFFmpegVoid(writer.writePacket(packetRead), "write encoded packet")

proc encodeRgbxFrameNv12(
    encoder: VideoEncoder;
    writer: Mp4VideoWriter;
    rgbx: var OwnedRGBXFrame;
    frameIndex: int64;
    stats: var OverlayStats
  ) =
  let writable = checkFFmpeg(encoder.beginFrameNV12(frameIndex), "begin encoder NV12 frame")
  checkFFmpegVoid(copyRGBXToNV12Padded(rgbx, writable), "copy RGBX to padded NV12")
  checkFFmpegVoid(encoder.submitFrame(), "submit encoder frame")
  drainEncoder(encoder, writer, stats)

proc drainEncoderRtsp(
    encoder: VideoEncoder;
    writer: RtspVideoWriter;
    stats: var OverlayStats
  ) =
  while true:
    let packetRead = checkFFmpeg(encoder.receivePacket(), "receive encoded packet")
    if not packetRead.hasPacket:
      break

    inc stats.videoPackets
    stats.videoPacketBytes += packetRead.packet.size
    checkFFmpegVoid(writer.writePacket(packetRead), "write RTSP encoded packet")

proc encodeRgbxFrameNv12Rtsp(
    encoder: VideoEncoder;
    writer: RtspVideoWriter;
    rgbx: var OwnedRGBXFrame;
    frameIndex: int64;
    stats: var OverlayStats
  ) =
  let writable = checkFFmpeg(encoder.beginFrameNV12(frameIndex), "begin RTSP encoder NV12 frame")
  checkFFmpegVoid(copyRGBXToNV12Padded(rgbx, writable), "copy RGBX to padded NV12 for RTSP")
  checkFFmpegVoid(encoder.submitFrame(), "submit RTSP encoder frame")
  drainEncoderRtsp(encoder, writer, stats)

proc drainOldestPendingVideoFrame(
    pendingFrames: var seq[PendingVideoFrame];
    encoder: VideoEncoder;
    writer: Mp4VideoWriter;
    font: Font;
    hasFont: bool;
    drawOptions: OverlayDrawOptions;
    previewOutputPath: string;
    previewFrameNumber: int;
    previewSaved: var bool;
    rgbxPool: var seq[OwnedRGBXFrame];
    detectionsWriter: var DetectionJsonWriter;
    stats: var OverlayStats
  ) =
  if pendingFrames.len == 0:
    return

  var item = move pendingFrames[0]
  pendingFrames.delete(0)

  let yoloResult = item.pending.waitYoloAsync()
  inc stats.pipelineReplies
  stats.inferWaitFramesMs.add(yoloResult.waitMs)
  stats.inferWaitMs += yoloResult.waitMs
  stats.inferMs += yoloResult.totalMs
  stats.inferOverlapMs += max(0, yoloResult.totalMs - item.pending.submitMs - yoloResult.waitMs)
  stats.hailoWriteUs += yoloResult.writeUs
  stats.hailoReadUs += yoloResult.readUs
  stats.hailoParseUs += yoloResult.parseUs
  stats.hailoSortUs += yoloResult.sortUs

  if int(yoloResult.requestId) != item.frameIndex:
    raise newException(
      IOError,
      &"HAILO result frame mismatch: expected={item.frameIndex} actual={yoloResult.requestId}"
    )

  detectionsWriter.writeFrameDetections(
    item.frameIndex,
    item.frameTimestampSeconds,
    yoloResult.detections
  )

  var stageStart = epochTime()
  let drawResult = item.rgbx.drawDetectionsOnRgbxFrame(
    yoloResult.detections,
    font,
    hasFont,
    drawOptions
  )
  stats.boxesDrawn += drawResult.boxes
  stats.labelsDrawn += drawResult.labels
  stats.drawMs += elapsedMs(stageStart)
  stats.detections += yoloResult.detections.len

  let completedFrameNumber = stats.videoFrames + 1
  if not previewSaved and previewOutputPath.len > 0 and completedFrameNumber >= previewFrameNumber:
    saveRgbxFramePreviewJpeg(item.rgbx, previewOutputPath)
    previewSaved = true

  stageStart = epochTime()
  encodeRgbxFrameNv12(encoder, writer, item.rgbx, int64(stats.videoFrames), stats)
  stats.encodeMs += elapsedMs(stageStart)

  inc stats.videoFrames
  stats.pipelineFrames = stats.videoFrames
  if item.hasProgressSeconds:
    stats.progressSeconds = item.progressSeconds

  ## Return the large RGBX buffer to a tiny local pool.  This keeps the Step 5
  ## look-ahead pipeline from allocating a multi-megabyte frame for every input
  ## frame while still keeping ownership explicit.
  rgbxPool.add(move item.rgbx)


proc useMp4ThreadPipeline(): bool =
  ## Step 6 default path.  This keeps the web-facing MP4 output contract, but
  ## splits decode/preprocess from overlay/encode using threadtools queues.
  let raw = getEnv("HAILO_DEMO_MP4_THREAD_PIPELINE", "1").toLowerAscii()
  result = raw notin ["0", "false", "no", "off"]

proc resolveMp4VideoFramePoolCapacity(maxInFlight: int): int =
  ## RGBX frame buffers are large.  Keep a small threadtools Pool so producer
  ## and consumer can move ownership without allocating one frame per input.
  let defaultValue = max(3, maxInFlight + 2)
  result = max(1, parseEnvInt("HAILO_DEMO_MP4_FRAME_POOL", defaultValue))
  result = min(result, 16)

type
  SharedCString = object
    ## Raw shared-memory string for data passed to a Nim OS thread.
    ##
    ## Do not pass GC-managed string fields through a ptr state object to a
    ## {.thread.} proc.  The worker thread converts this shared byte buffer into
    ## its own local string before using libav/pixie APIs.
    data: ptr UncheckedArray[char]
    len: int

  VideoPipelineItemKind = enum
    vpiFrame
    vpiDone
    vpiError

  VideoPipelineItem = object
    kind: VideoPipelineItemKind
    frameIndex: int
    pending: YoloAsyncPending
    rgbx: Pooled[OwnedRGBXFrame]
    frameTimestampSeconds: float64
    progressSeconds: float64
    hasProgressSeconds: bool
    message: string

  VideoPipelineResultKind = enum
    vprDone
    vprError

  VideoPipelineWorkerResult = object
    kind: VideoPipelineResultKind
    stats: OverlayStats
    message: string

  VideoPipelineProgress = object
    ## Scalar-only progress notification sent from the overlay/encode consumer
    ## thread back to the job worker thread.
    ##
    ## Do not put GC-managed strings/seqs here.  The job worker thread converts
    ## these scalar values into the WebUI message and updates JobStore itself.
    processedFrames: int
    timestampSeconds: float64
    hasProgressSeconds: bool
    force: bool

  VideoPipelineWorkerState = object
    frameQ: ThreadQueue[VideoPipelineItem]
    resultQ: ThreadQueue[VideoPipelineWorkerResult]
    progressQ: ThreadQueue[VideoPipelineProgress]
    outputPath: SharedCString
    previewOutputPath: SharedCString
    detectionsOutputPath: SharedCString
    liveDetectionsOutputPath: SharedCString
    fontPath: SharedCString
    fpsNum: int
    fpsDen: int
    fpsForBitrate: int
    gopSize: int
    bitrateConfig: VideoBitrateConfig
    previewFrameNumber: int
    encoderName: SharedCString
    maxFrames: int
    progressInfo: VideoProgressInfo
    options: JobOptions

proc `=destroy`(self: var VideoPipelineItem) {.raises: [].} =
  ## VideoPipelineItem can carry an active Pooled[OwnedRGBXFrame].  Make the
  ## destructor explicitly no-raise so it remains acceptable for ThreadQueue
  ## isolation checks, mirroring hailort_nim's pooled worker request type.
  try:
    case self.kind
    of vpiFrame:
      `=destroy`(self.rgbx)
      `=destroy`(self.message)
    of vpiDone, vpiError:
      `=destroy`(self.rgbx)
      `=destroy`(self.message)
  except Exception:
    discard

proc initSharedCString(value: string): SharedCString =
  result.len = value.len
  let mem = allocShared0(result.len + 1)
  if mem == nil:
    raise newException(IOError, "allocShared0 failed for thread string")

  result.data = cast[ptr UncheckedArray[char]](mem)
  for i in 0 ..< value.len:
    result.data[i] = value[i]
  result.data[value.len] = '\0'

proc toLocalString(self: SharedCString): string {.gcsafe.} =
  if self.data == nil or self.len <= 0:
    return ""

  result = newString(self.len)
  for i in 0 ..< self.len:
    result[i] = self.data[i]

proc freeSharedCString(self: var SharedCString) =
  if self.data != nil:
    deallocShared(cast[pointer](self.data))
    self.data = nil
    self.len = 0

proc sendVideoPipelineItem(
    q: ThreadQueue[VideoPipelineItem];
    item: sink VideoPipelineItem;
    context: string
  ) =
  var owned = move item
  let sendRes = q.sendMove(move owned)
  if sendRes.isErr:
    raise newException(IOError, &"{context}: {sendRes.error}")

proc sendVideoPipelineResult(
    q: ThreadQueue[VideoPipelineWorkerResult];
    resultItem: sink VideoPipelineWorkerResult
  ) {.gcsafe.} =
  var owned = move resultItem
  let sendRes = q.sendMove(move owned)
  if sendRes.isErr:
    echo &"warning: failed to send video pipeline result: {sendRes.error}"

proc sendVideoPipelineProgress(
    q: ThreadQueue[VideoPipelineProgress];
    update: sink VideoPipelineProgress
  ) {.gcsafe.} =
  var owned = move update
  let sendRes = q.sendMove(move owned)
  if sendRes.isErr:
    ## Progress is advisory.  Dropping it is better than crashing the demo.
    echo &"warning: failed to send video pipeline progress: {sendRes.error}"

proc receiveVideoPipelineResult(q: ThreadQueue[VideoPipelineWorkerResult]): VideoPipelineWorkerResult =
  ## receiveResult() returns a MoveResult.  The installed move_results helper
  ## exposes isOk/take(), but not isErr, so keep this path compatible with that
  ## API surface.
  var recvRes = q.receiveResult()
  if not recvRes.isOk:
    raise newException(IOError, &"receive video pipeline result failed: {recvRes.error}")
  result = recvRes.take()

proc sendEncodedVideoFrameProgress(
    progressQ: ThreadQueue[VideoPipelineProgress];
    processedFrames: int;
    timestampSeconds: float64;
    hasProgressSeconds: bool;
    force = false
  ) {.gcsafe.} =
  ## The consumer thread must not call JobStore.updateJob() directly.  JobStore
  ## contains GC-managed strings and a Table owned by the job worker thread;
  ## updating it from this overlay/encode thread can leave strings allocated on
  ## the wrong thread-local heap and crash later during setDone().
  ##
  ## Send only scalar progress information back to the job worker thread.
  ## The job worker thread formats the message and updates the WebUI state.
  if processedFrames <= 0:
    return
  if not force and not (processedFrames == 1 or (processedFrames mod 10) == 0):
    return

  var update = VideoPipelineProgress(
    processedFrames: processedFrames,
    timestampSeconds: timestampSeconds,
    hasProgressSeconds: hasProgressSeconds,
    force: force
  )
  progressQ.sendVideoPipelineProgress(move update)

proc applyVideoPipelineProgress(
    onProgress: OverlayProgressCallback;
    progressCtx: pointer;
    update: VideoPipelineProgress;
    maxFrames: int;
    inputInfo: VideoProgressInfo
  ) =
  let progress = videoProgressPercent(
    update.processedFrames,
    maxFrames,
    inputInfo,
    update.timestampSeconds,
    update.hasProgressSeconds
  )

  notifyProgress(
    onProgress,
    progressCtx,
    progress,
    formatVideoProgressMessage(
      update.processedFrames,
      inputInfo,
      update.timestampSeconds,
      update.hasProgressSeconds
    )
  )

proc drainVideoPipelineProgress(
    progressQ: ThreadQueue[VideoPipelineProgress];
    onProgress: OverlayProgressCallback;
    progressCtx: pointer;
    maxFrames: int;
    inputInfo: VideoProgressInfo
  ) =
  while true:
    var update: VideoPipelineProgress
    let recvRes = progressQ.tryReceive(update)
    if recvRes.isErr:
      raise newException(IOError, &"receive video pipeline progress failed: {recvRes.error}")
    if not recvRes.get():
      break

    applyVideoPipelineProgress(onProgress, progressCtx, update, maxFrames, inputInfo)

proc waitVideoPipelineResultWithProgress(
    resultQ: ThreadQueue[VideoPipelineWorkerResult];
    progressQ: ThreadQueue[VideoPipelineProgress];
    onProgress: OverlayProgressCallback;
    progressCtx: pointer;
    maxFrames: int;
    inputInfo: VideoProgressInfo
  ): VideoPipelineWorkerResult =
  ## Wait for the consumer result while continuing to publish progress updates
  ## from the job worker thread.  This keeps JobStore ownership on one thread
  ## while the progress bar still reflects overlay/encode completion.
  while true:
    drainVideoPipelineProgress(progressQ, onProgress, progressCtx, maxFrames, inputInfo)

    var workerResult: VideoPipelineWorkerResult
    let recvRes = resultQ.tryReceive(workerResult)
    if recvRes.isErr:
      raise newException(IOError, &"receive video pipeline result failed: {recvRes.error}")
    if recvRes.get():
      ## Drain any final progress update that may have been queued immediately
      ## before the result.
      drainVideoPipelineProgress(progressQ, onProgress, progressCtx, maxFrames, inputInfo)
      return workerResult

    sleep(10)




proc rtspPublisherLogPath(): string =
  result = getEnv("HAILO_DEMO_RTSP_PUBLISHER_LOG", "/tmp/hailo-live-rtsp-publisher.log")

proc writeRtspPublisherLog(path, content: string) =
  if path.len == 0:
    return
  try:
    writeFile(path, content)
  except CatchableError:
    discard

proc appendRtspPublisherLog(path, content: string) =
  if path.len == 0 or content.len == 0:
    return
  try:
    var f = open(path, fmAppend)
    try:
      f.write(content)
    finally:
      f.close()
  except CatchableError:
    discard


proc processThreadedVideoPipelineFrame(
    item: var VideoPipelineItem;
    encoder: VideoEncoder;
    writer: Mp4VideoWriter;
    font: Font;
    hasFont: bool;
    drawOptions: OverlayDrawOptions;
    previewOutputPath: string;
    previewFrameNumber: int;
    previewSaved: var bool;
    detectionsWriter: var DetectionJsonWriter;
    maxFrames: int;
    progressInfo: VideoProgressInfo;
    progressQ: ThreadQueue[VideoPipelineProgress];
    stats: var OverlayStats
  ) =
  var yoloResult: YoloAsyncResult
  {.cast(gcsafe).}:
    yoloResult = item.pending.waitYoloAsync()
  inc stats.pipelineReplies
  ## Do not store per-frame wait timings in the consumer thread.
  ## Those seq buffers would be allocated on the consumer thread and later moved
  ## back to the producer thread as part of OverlayStats, which is unsafe with
  ## Nim's thread-local GC/ORC heaps and can crash during deallocation.  Keep only
  ## scalar totals on the consumer side; producer-side timing seqs remain safe.
  stats.inferWaitMs += yoloResult.waitMs
  stats.inferMs += yoloResult.totalMs
  stats.inferOverlapMs += max(0, yoloResult.totalMs - item.pending.submitMs - yoloResult.waitMs)
  stats.hailoWriteUs += yoloResult.writeUs
  stats.hailoReadUs += yoloResult.readUs
  stats.hailoParseUs += yoloResult.parseUs
  stats.hailoSortUs += yoloResult.sortUs

  if int(yoloResult.requestId) != item.frameIndex:
    raise newException(
      IOError,
      &"HAILO result frame mismatch: expected={item.frameIndex} actual={yoloResult.requestId}"
    )

  detectionsWriter.writeFrameDetections(
    item.frameIndex,
    item.frameTimestampSeconds,
    yoloResult.detections
  )

  var stageStart = epochTime()
  let drawResult = item.rgbx.value.drawDetectionsOnRgbxFrame(
    yoloResult.detections,
    font,
    hasFont,
    drawOptions
  )
  stats.boxesDrawn += drawResult.boxes
  stats.labelsDrawn += drawResult.labels
  stats.drawMs += elapsedMs(stageStart)
  stats.detections += yoloResult.detections.len

  let completedFrameNumber = stats.videoFrames + 1
  if not previewSaved and previewOutputPath.len > 0 and completedFrameNumber >= previewFrameNumber:
    {.cast(gcsafe).}:
      saveRgbxFramePreviewJpeg(item.rgbx.value, previewOutputPath)
    previewSaved = true

  stageStart = epochTime()
  encodeRgbxFrameNv12(encoder, writer, item.rgbx.value, int64(stats.videoFrames), stats)
  stats.encodeMs += elapsedMs(stageStart)

  inc stats.videoFrames
  stats.pipelineFrames = stats.videoFrames
  if item.hasProgressSeconds:
    stats.progressSeconds = item.progressSeconds

  sendEncodedVideoFrameProgress(
    progressQ,
    stats.videoFrames,
    item.progressSeconds,
    item.hasProgressSeconds,
    false
  )

proc processThreadedVideoPipelineFrameRtsp(
    item: var VideoPipelineItem;
    encoder: VideoEncoder;
    writer: RtspVideoWriter;
    font: Font;
    hasFont: bool;
    drawOptions: OverlayDrawOptions;
    liveDebugOverlay: bool;
    previewOutputPath: string;
    previewFrameNumber: int;
    previewSaved: var bool;
    detectionsWriter: var DetectionJsonWriter;
    maxFrames: int;
    progressInfo: VideoProgressInfo;
    progressQ: ThreadQueue[VideoPipelineProgress];
    stats: var OverlayStats
  ) =
  var yoloResult: YoloAsyncResult
  {.cast(gcsafe).}:
    yoloResult = item.pending.waitYoloAsync()
  inc stats.pipelineReplies
  ## Do not store per-frame wait timings in the consumer thread.
  ## Those seq buffers would be allocated on the consumer thread and later moved
  ## back to the producer thread as part of OverlayStats, which is unsafe with
  ## Nim's thread-local GC/ORC heaps and can crash during deallocation.  Keep only
  ## scalar totals on the consumer side; producer-side timing seqs remain safe.
  stats.inferWaitMs += yoloResult.waitMs
  stats.inferMs += yoloResult.totalMs
  stats.inferOverlapMs += max(0, yoloResult.totalMs - item.pending.submitMs - yoloResult.waitMs)
  stats.hailoWriteUs += yoloResult.writeUs
  stats.hailoReadUs += yoloResult.readUs
  stats.hailoParseUs += yoloResult.parseUs
  stats.hailoSortUs += yoloResult.sortUs

  if int(yoloResult.requestId) != item.frameIndex:
    raise newException(
      IOError,
      &"HAILO result frame mismatch: expected={item.frameIndex} actual={yoloResult.requestId}"
    )

  detectionsWriter.writeFrameDetections(
    item.frameIndex,
    item.frameTimestampSeconds,
    yoloResult.detections
  )

  var stageStart = epochTime()
  let drawResult = item.rgbx.value.drawDetectionsOnRgbxFrame(
    yoloResult.detections,
    font,
    hasFont,
    drawOptions
  )
  if liveDebugOverlay:
    item.rgbx.value.drawLiveDebugOverlayOnRgbxFrame(
      font,
      hasFont,
      stats.videoFrames + 1,
      yoloResult.detections.len,
      drawResult.boxes,
      drawOptions.minBoxScore
    )
  stats.boxesDrawn += drawResult.boxes
  stats.labelsDrawn += drawResult.labels
  stats.drawMs += elapsedMs(stageStart)
  stats.detections += yoloResult.detections.len

  let completedFrameNumber = stats.videoFrames + 1
  if not previewSaved and previewOutputPath.len > 0 and completedFrameNumber >= previewFrameNumber:
    {.cast(gcsafe).}:
      saveRgbxFramePreviewJpeg(item.rgbx.value, previewOutputPath)
    previewSaved = true

  stageStart = epochTime()
  encodeRgbxFrameNv12Rtsp(encoder, writer, item.rgbx.value, int64(stats.videoFrames), stats)
  stats.encodeMs += elapsedMs(stageStart)

  inc stats.videoFrames
  stats.pipelineFrames = stats.videoFrames
  if item.hasProgressSeconds:
    stats.progressSeconds = item.progressSeconds

  sendEncodedVideoFrameProgress(
    progressQ,
    stats.videoFrames,
    item.progressSeconds,
    item.hasProgressSeconds,
    false
  )

proc videoPipelineConsumerMain(state: VideoPipelineWorkerState) {.thread.} =
  var workerResult = VideoPipelineWorkerResult(kind: vprDone)

  try:
    let
      outputPath = state.outputPath.toLocalString()
      previewOutputPath = state.previewOutputPath.toLocalString()
      detectionsOutputPath = state.detectionsOutputPath.toLocalString()
      liveDetectionsOutputPath = state.liveDetectionsOutputPath.toLocalString()
      fontPath = state.fontPath.toLocalString()
      encoderName = state.encoderName.toLocalString()
      loadedFont = loadOverlayFont(fontPath)
      drawOptions = resolveDrawOptionsFromJobOptions(state.options, true)
    var
      encoder: VideoEncoder
      writer: Mp4VideoWriter
      detectionsWriter: DetectionJsonWriter
      encoderReady = false
      previewSaved = false

    try:
      while true:
        var item = state.frameQ.receive()

        case item.kind
        of vpiDone:
          break
        of vpiError:
          raise newException(IOError, item.message)
        of vpiFrame:
          if not encoderReady:
            let
              frameW = item.rgbx.value.width
              frameH = item.rgbx.value.height
              encoderHeight = alignUp(frameH, 16)

            let actualBitrate = resolveMp4VideoBitrate(frameW, frameH, state.fpsForBitrate, state.bitrateConfig)
            workerResult.stats.outputBitrate = actualBitrate

            var stageStart = epochTime()
            encoder = checkFFmpeg(openVideoEncoder(VideoEncoderOptions(
              encoderName: encoderName,
              width: frameW,
              height: encoderHeight,
              pixelFormat: pfNv12,
              timeBase: Rational(num: int32(state.fpsDen), den: int32(state.fpsNum)),
              framerate: Rational(num: int32(state.fpsNum), den: int32(state.fpsDen)),
              bitRate: int64(actualBitrate),
              gopSize: state.gopSize,
              maxBFrames: 0,
              globalHeader: true
            )), &"open video encoder {encoderName}")
            workerResult.stats.encoderOpenMs = elapsedMs(stageStart)

            stageStart = epochTime()
            writer = checkFFmpeg(openMp4VideoWriter(outputPath, encoder), "open MP4 writer")
            workerResult.stats.writerOpenMs = elapsedMs(stageStart)
            detectionsWriter = openDetectionJsonWriter(
              detectionsOutputPath,
              liveDetectionsOutputPath,
              frameW,
              frameH,
              state.progressInfo
            )
            encoderReady = true

          processThreadedVideoPipelineFrame(
            item,
            encoder,
            writer,
            loadedFont.font,
            loadedFont.hasFont,
            drawOptions,
            previewOutputPath,
            state.previewFrameNumber,
            previewSaved,
            detectionsWriter,
            state.maxFrames,
            state.progressInfo,
            state.progressQ,
            workerResult.stats
          )

      if workerResult.stats.videoFrames <= 0:
        raise newException(IOError, "MP4 has no decodable video frame")

      sendEncodedVideoFrameProgress(
        state.progressQ,
        workerResult.stats.videoFrames,
        workerResult.stats.progressSeconds,
        workerResult.stats.progressSeconds > 0.0 or workerResult.stats.videoFrames == 1,
        true
      )

      var stageStart = epochTime()
      checkFFmpegVoid(encoder.flush(), "flush encoder")
      drainEncoder(encoder, writer, workerResult.stats)
      workerResult.stats.encoderFlushMs = elapsedMs(stageStart)
      workerResult.stats.encodeMs += workerResult.stats.encoderFlushMs

      stageStart = epochTime()
      checkFFmpegVoid(writer.finish(), "finish MP4 writer")
      workerResult.stats.writerFinishMs = elapsedMs(stageStart)
      workerResult.stats.encodeMs += workerResult.stats.writerFinishMs

      closeDetectionJsonWriter(detectionsWriter)

    finally:
      abortDetectionJsonWriter(detectionsWriter)
      if not writer.isNil:
        writer.close()
      if not encoder.isNil:
        encoder.close()

  except CatchableError as e:
    workerResult.kind = vprError
    workerResult.message = e.msg

  sendVideoPipelineResult(state.resultQ, move workerResult)

proc videoPipelineLibavRtspConsumerMain(state: VideoPipelineWorkerState) {.thread.} =
  ## Library-backed RTSP publisher probe.
  ##
  ## This deliberately reuses the same encoder/write path as the stable MP4
  ## worker, but points the libav writer at an RTSP URL.  The first goal is to
  ## verify whether libav_nim's current writer can mux/publish to MediaMTX
  ## without the ffmpeg subprocess bridge.
  var workerResult = VideoPipelineWorkerResult(kind: vprDone)

  try:
    let
      outputRtsp = state.outputPath.toLocalString()
      previewOutputPath = state.previewOutputPath.toLocalString()
      detectionsOutputPath = state.detectionsOutputPath.toLocalString()
      liveDetectionsOutputPath = state.liveDetectionsOutputPath.toLocalString()
      fontPath = state.fontPath.toLocalString()
      encoderName = state.encoderName.toLocalString()
      loadedFont = loadOverlayFont(fontPath)
      drawOptions = resolveDrawOptionsFromJobOptions(state.options, true)
    var
      encoder: VideoEncoder
      writer: RtspVideoWriter
      detectionsWriter: DetectionJsonWriter
      encoderReady = false
      previewSaved = false

    try:
      while true:
        var item = state.frameQ.receive()

        case item.kind
        of vpiDone:
          break
        of vpiError:
          raise newException(IOError, item.message)
        of vpiFrame:
          if not encoderReady:
            let
              frameW = item.rgbx.value.width
              frameH = item.rgbx.value.height
              encoderHeight = alignUp(frameH, 16)

            let actualBitrate = resolveMp4VideoBitrate(frameW, frameH, state.fpsForBitrate, state.bitrateConfig)
            workerResult.stats.outputBitrate = actualBitrate

            var stageStart = epochTime()
            encoder = checkFFmpeg(openVideoEncoder(VideoEncoderOptions(
              encoderName: encoderName,
              width: frameW,
              height: encoderHeight,
              pixelFormat: pfNv12,
              timeBase: Rational(num: int32(state.fpsDen), den: int32(state.fpsNum)),
              framerate: Rational(num: int32(state.fpsNum), den: int32(state.fpsDen)),
              bitRate: int64(actualBitrate),
              gopSize: state.gopSize,
              maxBFrames: 0,
              globalHeader: false
            )), &"open RTSP video encoder {encoderName}")
            workerResult.stats.encoderOpenMs = elapsedMs(stageStart)

            stageStart = epochTime()
            writer = checkFFmpeg(openRtspVideoWriter(outputRtsp, encoder, rtspTransport = "tcp"), "open RTSP writer via libav")
            workerResult.stats.writerOpenMs = elapsedMs(stageStart)
            detectionsWriter = openDetectionJsonWriter(
              detectionsOutputPath,
              liveDetectionsOutputPath,
              frameW,
              frameH,
              state.progressInfo
            )
            encoderReady = true

          processThreadedVideoPipelineFrameRtsp(
            item,
            encoder,
            writer,
            loadedFont.font,
            loadedFont.hasFont,
            drawOptions,
            state.options.liveDebugOverlay,
            previewOutputPath,
            state.previewFrameNumber,
            previewSaved,
            detectionsWriter,
            state.maxFrames,
            state.progressInfo,
            state.progressQ,
            workerResult.stats
          )

      if workerResult.stats.videoFrames <= 0:
        raise newException(IOError, "RTSP publisher received no video frame")

      sendEncodedVideoFrameProgress(
        state.progressQ,
        workerResult.stats.videoFrames,
        workerResult.stats.progressSeconds,
        workerResult.stats.progressSeconds > 0.0 or workerResult.stats.videoFrames == 1,
        true
      )

      var stageStart = epochTime()
      checkFFmpegVoid(encoder.flush(), "flush RTSP encoder")
      drainEncoderRtsp(encoder, writer, workerResult.stats)
      workerResult.stats.encoderFlushMs = elapsedMs(stageStart)
      workerResult.stats.encodeMs += workerResult.stats.encoderFlushMs

      stageStart = epochTime()
      checkFFmpegVoid(writer.finish(), "finish RTSP writer via libav")
      workerResult.stats.writerFinishMs = elapsedMs(stageStart)
      workerResult.stats.encodeMs += workerResult.stats.writerFinishMs

      closeDetectionJsonWriter(detectionsWriter)

    finally:
      abortDetectionJsonWriter(detectionsWriter)
      if not writer.isNil:
        writer.close()
      if not encoder.isNil:
        encoder.close()

  except CatchableError as e:
    workerResult.kind = vprError
    workerResult.message = e.msg

  sendVideoPipelineResult(state.resultQ, move workerResult)

proc addRgbxFrameToPool(
    pool: Pool[OwnedRGBXFrame];
    width, height: int
  ) =
  var frame = checkFFmpeg(newOwnedRGBXFrame(width, height), "new pooled RGBX frame")
  let addRes = pool.addMove(move frame)
  if addRes.isErr:
    raise newException(IOError, &"add RGBX frame to pool failed: {addRes.error}")

proc notifyPreparedVideoFrameProgress(
    onProgress: OverlayProgressCallback;
    progressCtx: pointer;
    submitted: int;
    maxFrames: int;
    inputInfo: VideoProgressInfo;
    timestampSeconds: float64;
    hasProgressSeconds: bool
  ) {.gcsafe.} =
  if submitted <= 0:
    return
  if not (submitted == 1 or (submitted mod 10) == 0):
    return

  let progress = videoProgressPercent(
    submitted,
    maxFrames,
    inputInfo,
    timestampSeconds,
    hasProgressSeconds
  )

  notifyProgress(
    onProgress,
    progressCtx,
    progress,
    formatVideoProgressMessage(submitted, inputInfo, timestampSeconds, hasProgressSeconds)
  )


proc submitDecodedFrameToVideoPipeline[T](
    frameRead: T;
    progressInfo: VideoProgressInfo;
    framePoolCapacity: int;
    framePool: var Pool[OwnedRGBXFrame];
    poolReady: var bool;
    pooledWidth: var int;
    pooledHeight: var int;
    frameQ: ThreadQueue[VideoPipelineItem];
    stats: var OverlayStats
  ) =
  ## Convert one borrowed decoded frame into owned pipeline work.
  ##
  ## This is the shared producer-side seam for the MP4 path and the upcoming
  ## live path.  The source-specific reader owns the borrowed libav frame; this
  ## proc copies everything needed by later stages into owned YOLO/RGBX buffers
  ## before the caller reads the next decoded frame.
  stats.readFramesMs.add(frameRead.readMs)
  stats.readFrameMs += frameRead.readMs
  stats.imageWidth = frameRead.frameWidth
  stats.imageHeight = frameRead.frameHeight
  stats.previewFrameIndex = frameRead.frameIndex

  let frameTimestampSeconds = detectionTimestampSeconds(
    frameRead.frameIndex,
    frameRead.timestampSeconds,
    frameRead.hasTimestampSeconds,
    progressInfo
  )
  var progressSeconds = 0.0
  let hasProgressSeconds = progressTimestampSeconds(
    frameRead.frameIndex,
    frameRead.timestampSeconds,
    frameRead.hasTimestampSeconds,
    progressInfo,
    progressSeconds
  )
  if hasProgressSeconds:
    stats.progressSeconds = progressSeconds

  if not poolReady:
    let poolRes = newPool[OwnedRGBXFrame](framePoolCapacity)
    if poolRes.isErr:
      raise newException(IOError, &"new RGBX frame pool failed: {poolRes.error}")
    framePool = poolRes.get()
    pooledWidth = frameRead.frameWidth
    pooledHeight = frameRead.frameHeight
    for _ in 0 ..< framePoolCapacity:
      framePool.addRgbxFrameToPool(pooledWidth, pooledHeight)
    poolReady = true
  elif frameRead.frameWidth != pooledWidth or frameRead.frameHeight != pooledHeight:
    raise newException(
      IOError,
      &"video frame size changed: expected={pooledWidth}x{pooledHeight} actual={frameRead.frameWidth}x{frameRead.frameHeight}"
    )

  var stageStart = epochTime()
  var yoloInput = frameRead.read.frame.prepareYoloInput()
  let letterboxMs = elapsedMs(stageStart)
  stats.letterboxFramesMs.add(letterboxMs)
  stats.letterboxMs += letterboxMs

  let pending = yoloInput.submitYoloAsync(uint64(frameRead.frameIndex))
  stats.inferSubmitFramesMs.add(pending.submitMs)
  stats.inferSubmitMs += pending.submitMs
  inc stats.pipelineSubmitted

  stageStart = epochTime()
  var rgbxItem = framePool.acquire()
  checkFFmpegVoid(copyI420ToRGBX(frameRead.read.frame, rgbxItem.value), "copy decoded I420 to pooled RGBX")
  let rgbxMs = elapsedMs(stageStart)
  stats.rgbxFramesMs.add(rgbxMs)
  stats.rgbxMs += rgbxMs

  var item = VideoPipelineItem(
    kind: vpiFrame,
    frameIndex: frameRead.frameIndex,
    pending: pending,
    rgbx: move rgbxItem,
    frameTimestampSeconds: frameTimestampSeconds,
    progressSeconds: progressSeconds,
    hasProgressSeconds: hasProgressSeconds
  )
  frameQ.sendVideoPipelineItem(move item, "send video pipeline frame")
  stats.pipelineFrames = stats.pipelineSubmitted

proc mergeThreadedVideoStats(result: var OverlayStats; workerStats: OverlayStats) =
  result.pipelineReplies = workerStats.pipelineReplies
  result.inferWaitFramesMs = workerStats.inferWaitFramesMs
  result.inferWaitMs = workerStats.inferWaitMs
  result.inferMs = workerStats.inferMs
  result.inferOverlapMs = workerStats.inferOverlapMs
  result.hailoWriteUs = workerStats.hailoWriteUs
  result.hailoReadUs = workerStats.hailoReadUs
  result.hailoParseUs = workerStats.hailoParseUs
  result.hailoSortUs = workerStats.hailoSortUs

  result.detections = workerStats.detections
  result.boxesDrawn = workerStats.boxesDrawn
  result.labelsDrawn = workerStats.labelsDrawn
  result.videoFrames = workerStats.videoFrames
  result.videoPackets = workerStats.videoPackets
  result.videoPacketBytes = workerStats.videoPacketBytes
  result.outputBitrate = workerStats.outputBitrate

  result.encoderOpenMs = workerStats.encoderOpenMs
  result.writerOpenMs = workerStats.writerOpenMs
  result.encoderFlushMs = workerStats.encoderFlushMs
  result.writerFinishMs = workerStats.writerFinishMs
  result.encodeMs = workerStats.encodeMs

  ## workerStats.drawMs contains overlay drawing only.  Producer-side rgbxMs is
  ## kept separately so the formatted output still reports draw=[rgbx, overlay].
  result.drawMs = result.rgbxMs + workerStats.drawMs
  result.pipelineFrames = result.videoFrames

proc drawMp4VideoOverlayThreaded(
    inputPath, outputPath, fontPath: string;
    previewOutputPath = "";
    options: JobOptions = defaultJobOptions();
    onProgress: OverlayProgressCallback = nil;
    progressCtx: pointer = nil;
    detectionsOutputPath = "";
    liveDetectionsOutputPath = ""
  ): OverlayStats =
  ## Step 6 video pipeline.
  ##
  ## The job worker thread now acts as the decode/preprocess producer.  It reads
  ## frames, creates YOLO input, submits HAILO work immediately, converts the
  ## full-size RGBX frame, and moves a pooled RGBX buffer to an overlay/encode
  ## consumer thread.  The consumer waits for the matching HAILO result, draws,
  ## and encodes.  This hides overlay/encode work behind the next frame's decode
  ## and preprocessing, while keeping the HAILO worker itself unchanged.
  let totalStart = epochTime()
  let bitrateConfig = resolveMp4VideoBitrateConfig(options)
  let maxFrames = parseEnvInt("HAILO_DEMO_MP4_VIDEO_MAX_FRAMES", 90)
  let encoderName = resolveMp4VideoEncoderName()
  let maxInFlight = resolveMp4VideoInFlight()
  let previewFrameNumber = resolveVideoPreviewFrame()
  let framePoolCapacity = resolveMp4VideoFramePoolCapacity(maxInFlight)
  let queueCapacity = maxInFlight

  result.pipelineInFlight = maxInFlight

  let frameQRes = newThreadQueue[VideoPipelineItem](queueCapacity)
  if frameQRes.isErr:
    raise newException(IOError, &"new video pipeline frame queue failed: {frameQRes.error}")
  let frameQ = frameQRes.get()

  let resultQRes = newThreadQueue[VideoPipelineWorkerResult](1)
  if resultQRes.isErr:
    raise newException(IOError, &"new video pipeline result queue failed: {resultQRes.error}")
  let resultQ = resultQRes.get()

  let progressQRes = newThreadQueue[VideoPipelineProgress](32)
  if progressQRes.isErr:
    raise newException(IOError, &"new video pipeline progress queue failed: {progressQRes.error}")
  let progressQ = progressQRes.get()

  var
    sharedOutputPath = initSharedCString(outputPath)
    sharedPreviewOutputPath = initSharedCString(previewOutputPath)
    sharedDetectionsOutputPath = initSharedCString(detectionsOutputPath)
    sharedLiveDetectionsOutputPath = initSharedCString(liveDetectionsOutputPath)
    sharedFontPath = initSharedCString(fontPath)
    sharedEncoderName = initSharedCString(encoderName)

  var consumerThread: Thread[VideoPipelineWorkerState]
  var consumerStarted = false
  var terminalSent = false

  try:
    var reader = openMp4PreviewDecoder(inputPath)
    defer: reader.close()

    result.decoderOpenMs = reader.decoderOpenMs
    result.decoderName = reader.decoderName
    result.applyMp4InputInfo(reader.inputInfo)
    let progressInfo = reader.inputInfo.toVideoProgressInfo()
    let outputFps = resolveMp4VideoOutputFps(reader.inputInfo)
    result.applyOutputFpsInfo(outputFps)

    var workerState = VideoPipelineWorkerState(
      frameQ: frameQ,
      resultQ: resultQ,
      progressQ: progressQ,
      outputPath: sharedOutputPath,
      previewOutputPath: sharedPreviewOutputPath,
      detectionsOutputPath: sharedDetectionsOutputPath,
      liveDetectionsOutputPath: sharedLiveDetectionsOutputPath,
      fontPath: sharedFontPath,
      fpsNum: outputFps.num,
      fpsDen: outputFps.den,
      fpsForBitrate: outputFps.fpsForBitrate,
      gopSize: outputFps.gopSize,
      bitrateConfig: bitrateConfig,
      previewFrameNumber: previewFrameNumber,
      encoderName: sharedEncoderName,
      maxFrames: maxFrames,
      progressInfo: progressInfo,
      options: options
    )
    createThread(consumerThread, videoPipelineConsumerMain, workerState)
    consumerStarted = true

    var
      poolReady = false
      framePool: Pool[OwnedRGBXFrame]
      pooledWidth = 0
      pooledHeight = 0

    while maxFrames <= 0 or result.pipelineSubmitted < maxFrames:
      let frameRead = reader.readNextFrame()
      if frameRead.eof:
        break

      submitDecodedFrameToVideoPipeline(
        frameRead,
        progressInfo,
        framePoolCapacity,
        framePool,
        poolReady,
        pooledWidth,
        pooledHeight,
        frameQ,
        result
      )

      ## Progress is produced by the consumer thread after overlay/encode.
      ## Drain it from this job worker thread so JobStore is never updated from
      ## the consumer thread, and so the progress queue cannot fill on long
      ## videos.
      drainVideoPipelineProgress(progressQ, onProgress, progressCtx, maxFrames, progressInfo)

    var doneItem = VideoPipelineItem(kind: vpiDone)
    frameQ.sendVideoPipelineItem(move doneItem, "send video pipeline done")
    terminalSent = true

    let workerResult = waitVideoPipelineResultWithProgress(
      resultQ,
      progressQ,
      onProgress,
      progressCtx,
      maxFrames,
      progressInfo
    )
    joinThread(consumerThread)
    consumerStarted = false

    sharedOutputPath.freeSharedCString()
    sharedPreviewOutputPath.freeSharedCString()
    sharedDetectionsOutputPath.freeSharedCString()
    sharedLiveDetectionsOutputPath.freeSharedCString()
    sharedFontPath.freeSharedCString()
    sharedEncoderName.freeSharedCString()

    case workerResult.kind
    of vprError:
      raise newException(IOError, workerResult.message)
    of vprDone:
      result.mergeThreadedVideoStats(workerResult.stats)

    if result.videoFrames <= 0:
      raise newException(IOError, &"MP4 has no decodable video frame: {inputPath}")

    result.decodeMs = result.decoderOpenMs + result.readFrameMs
    result.totalMs = elapsedMs(totalStart)

  except CatchableError as e:
    if consumerStarted and not terminalSent:
      var errItem = VideoPipelineItem(kind: vpiError, message: e.msg)
      try:
        frameQ.sendVideoPipelineItem(move errItem, "send video pipeline error")
        discard resultQ.receiveVideoPipelineResult()
      except CatchableError:
        discard
      joinThread(consumerThread)
      sharedOutputPath.freeSharedCString()
      sharedPreviewOutputPath.freeSharedCString()
      sharedDetectionsOutputPath.freeSharedCString()
      sharedLiveDetectionsOutputPath.freeSharedCString()
      sharedFontPath.freeSharedCString()
      sharedEncoderName.freeSharedCString()
    raise


proc drawLiveRtspVideoOverlayToMp4*(
    inputRtsp, outputPath, fontPath: string;
    decoderName = "";
    maxFrames = 90;
    previewOutputPath = "";
    options: JobOptions = defaultJobOptions();
    onProgress: OverlayProgressCallback = nil;
    progressCtx: pointer = nil;
    detectionsOutputPath = "";
    liveDetectionsOutputPath = ""
  ): OverlayStats =
  ## Bounded live RTSP -> decoded frame source -> MP4-proven threaded overlay
  ## pipeline probe.
  ##
  ## This is intentionally not the final /cam-ai publisher yet.  It validates
  ## that live decoded frames can enter the same producer/consumer seam used by
  ## the stable file path, while keeping the output as a finite MP4 artifact.
  let totalStart = epochTime()
  let bitrateConfig = resolveMp4VideoBitrateConfig(options)
  let actualMaxFrames = max(1, maxFrames)
  let encoderName = resolveMp4VideoEncoderName()
  let maxInFlight = resolveMp4VideoInFlight()
  let previewFrameNumber = resolveVideoPreviewFrame()
  let framePoolCapacity = resolveMp4VideoFramePoolCapacity(maxInFlight)
  let queueCapacity = maxInFlight

  result.pipelineInFlight = maxInFlight

  let frameQRes = newThreadQueue[VideoPipelineItem](queueCapacity)
  if frameQRes.isErr:
    raise newException(IOError, &"new live video pipeline frame queue failed: {frameQRes.error}")
  let frameQ = frameQRes.get()

  let resultQRes = newThreadQueue[VideoPipelineWorkerResult](1)
  if resultQRes.isErr:
    raise newException(IOError, &"new live video pipeline result queue failed: {resultQRes.error}")
  let resultQ = resultQRes.get()

  let progressQRes = newThreadQueue[VideoPipelineProgress](32)
  if progressQRes.isErr:
    raise newException(IOError, &"new live video pipeline progress queue failed: {progressQRes.error}")
  let progressQ = progressQRes.get()

  var
    sharedOutputPath = initSharedCString(outputPath)
    sharedPreviewOutputPath = initSharedCString(previewOutputPath)
    sharedDetectionsOutputPath = initSharedCString(detectionsOutputPath)
    sharedLiveDetectionsOutputPath = initSharedCString(liveDetectionsOutputPath)
    sharedFontPath = initSharedCString(fontPath)
    sharedEncoderName = initSharedCString(encoderName)

  var consumerThread: Thread[VideoPipelineWorkerState]
  var consumerStarted = false
  var terminalSent = false

  try:
    var source = openLiveDecodedVideoSource(inputRtsp, decoderName)
    defer: source.close()

    result.decoderOpenMs = source.decoderOpenMs
    result.decoderName = source.decoderLabel

    let outputFps = resolveLiveVideoOutputFps()
    result.applyOutputFpsInfo(outputFps)
    result.sourceFps = outputFps.fps
    result.sourceFpsSource = outputFps.source
    result.estimatedTotalFrames = actualMaxFrames
    if outputFps.fps > 0.0:
      result.inputDurationSeconds = float64(actualMaxFrames) / outputFps.fps
      result.inputDurationSource = "live-bounded"

    let progressInfo = toLiveVideoProgressInfo(outputFps, actualMaxFrames)

    var workerState = VideoPipelineWorkerState(
      frameQ: frameQ,
      resultQ: resultQ,
      progressQ: progressQ,
      outputPath: sharedOutputPath,
      previewOutputPath: sharedPreviewOutputPath,
      detectionsOutputPath: sharedDetectionsOutputPath,
      liveDetectionsOutputPath: sharedLiveDetectionsOutputPath,
      fontPath: sharedFontPath,
      fpsNum: outputFps.num,
      fpsDen: outputFps.den,
      fpsForBitrate: outputFps.fpsForBitrate,
      gopSize: outputFps.gopSize,
      bitrateConfig: bitrateConfig,
      previewFrameNumber: previewFrameNumber,
      encoderName: sharedEncoderName,
      maxFrames: actualMaxFrames,
      progressInfo: progressInfo,
      options: options
    )
    createThread(consumerThread, videoPipelineConsumerMain, workerState)
    consumerStarted = true

    var
      poolReady = false
      framePool: Pool[OwnedRGBXFrame]
      pooledWidth = 0
      pooledHeight = 0

    while result.pipelineSubmitted < actualMaxFrames:
      let frameRead = source.readDecodedFrame()
      case frameRead.status
      of dvrsFrame:
        submitDecodedFrameToVideoPipeline(
          frameRead,
          progressInfo,
          framePoolCapacity,
          framePool,
          poolReady,
          pooledWidth,
          pooledHeight,
          frameQ,
          result
        )
        drainVideoPipelineProgress(progressQ, onProgress, progressCtx, actualMaxFrames, progressInfo)
      of dvrsEof:
        break
      of dvrsStopRequested, dvrsInputTimeout:
        break

    var doneItem = VideoPipelineItem(kind: vpiDone)
    frameQ.sendVideoPipelineItem(move doneItem, "send live video pipeline done")
    terminalSent = true

    let workerResult = waitVideoPipelineResultWithProgress(
      resultQ,
      progressQ,
      onProgress,
      progressCtx,
      actualMaxFrames,
      progressInfo
    )
    joinThread(consumerThread)
    consumerStarted = false

    sharedOutputPath.freeSharedCString()
    sharedPreviewOutputPath.freeSharedCString()
    sharedDetectionsOutputPath.freeSharedCString()
    sharedLiveDetectionsOutputPath.freeSharedCString()
    sharedFontPath.freeSharedCString()
    sharedEncoderName.freeSharedCString()

    case workerResult.kind
    of vprError:
      raise newException(IOError, workerResult.message)
    of vprDone:
      result.mergeThreadedVideoStats(workerResult.stats)

    if result.videoFrames <= 0:
      raise newException(IOError, &"live RTSP input produced no decodable video frame: {inputRtsp}")

    result.decodeMs = result.decoderOpenMs + result.readFrameMs
    result.totalMs = elapsedMs(totalStart)

  except CatchableError as e:
    if consumerStarted and not terminalSent:
      var errItem = VideoPipelineItem(kind: vpiError, message: e.msg)
      try:
        frameQ.sendVideoPipelineItem(move errItem, "send live video pipeline error")
        discard resultQ.receiveVideoPipelineResult()
      except CatchableError:
        discard
      joinThread(consumerThread)
    sharedOutputPath.freeSharedCString()
    sharedPreviewOutputPath.freeSharedCString()
    sharedDetectionsOutputPath.freeSharedCString()
    sharedLiveDetectionsOutputPath.freeSharedCString()
    sharedFontPath.freeSharedCString()
    sharedEncoderName.freeSharedCString()
    raise



proc drawLiveRtspVideoOverlayToRtsp*(
    inputRtsp, outputRtsp, fontPath: string;
    decoderName = "";
    maxFrames = 300;
    previewOutputPath = "";
    options: JobOptions = defaultJobOptions();
    onProgress: OverlayProgressCallback = nil;
    progressCtx: pointer = nil;
    detectionsOutputPath = "";
    liveDetectionsOutputPath = "";
    shouldStop: OverlayStopCallback = nil;
    stopCtx: pointer = nil
  ): OverlayStats =
  ## Bounded live RTSP -> decoded frame source -> MP4-proven overlay pipeline
  ## -> RTSP publish probe.
  ##
  ## This keeps the proven file-style HAILO/overlay pipeline, but replaces the
  ## finite MP4 writer with a libav RTSP publisher.  It is still bounded by
  ## maxFrames so the publish edge can be tested without introducing Stop/timeout
  ## lifetime handling yet.
  let totalStart = epochTime()
  writeRtspPublisherLog(rtspPublisherLogPath(), &"drawLiveRtspVideoOverlayToRtsp entry input={inputRtsp} output={outputRtsp} maxFrames={maxFrames}\n")
  let bitrateConfig = resolveMp4VideoBitrateConfig(options)
  let actualMaxFrames = max(1, maxFrames)
  let encoderName = resolveMp4VideoEncoderName()
  let maxInFlight = resolveMp4VideoInFlight()
  let previewFrameNumber = resolveVideoPreviewFrame()
  let framePoolCapacity = resolveMp4VideoFramePoolCapacity(maxInFlight)
  let queueCapacity = maxInFlight

  result.pipelineInFlight = maxInFlight

  let frameQRes = newThreadQueue[VideoPipelineItem](queueCapacity)
  if frameQRes.isErr:
    raise newException(IOError, &"new live RTSP publish frame queue failed: {frameQRes.error}")
  let frameQ = frameQRes.get()

  let resultQRes = newThreadQueue[VideoPipelineWorkerResult](1)
  if resultQRes.isErr:
    raise newException(IOError, &"new live RTSP publish result queue failed: {resultQRes.error}")
  let resultQ = resultQRes.get()

  let progressQRes = newThreadQueue[VideoPipelineProgress](32)
  if progressQRes.isErr:
    raise newException(IOError, &"new live RTSP publish progress queue failed: {progressQRes.error}")
  let progressQ = progressQRes.get()

  var
    sharedOutputPath = initSharedCString(outputRtsp)
    sharedPreviewOutputPath = initSharedCString(previewOutputPath)
    sharedDetectionsOutputPath = initSharedCString(detectionsOutputPath)
    sharedLiveDetectionsOutputPath = initSharedCString(liveDetectionsOutputPath)
    sharedFontPath = initSharedCString(fontPath)
    sharedEncoderName = initSharedCString(encoderName)

  var consumerThread: Thread[VideoPipelineWorkerState]
  var consumerStarted = false
  var terminalSent = false

  try:
    appendRtspPublisherLog(rtspPublisherLogPath(), "opening live decoded source for RTSP publish\n")
    var source = openLiveDecodedVideoSource(inputRtsp, decoderName)
    defer: source.close()

    appendRtspPublisherLog(rtspPublisherLogPath(), &"opened live decoded source for RTSP publish decoder={source.decoderLabel} openMs={source.decoderOpenMs}\n")
    result.decoderOpenMs = source.decoderOpenMs
    result.decoderName = source.decoderLabel

    let outputFps = resolveLiveVideoOutputFps()
    result.applyOutputFpsInfo(outputFps)
    result.sourceFps = outputFps.fps
    result.sourceFpsSource = outputFps.source
    result.estimatedTotalFrames = actualMaxFrames
    if outputFps.fps > 0.0:
      result.inputDurationSeconds = float64(actualMaxFrames) / outputFps.fps
      result.inputDurationSource = "live-rtsp-bounded"

    let progressInfo = toLiveVideoProgressInfo(outputFps, actualMaxFrames)

    var workerState = VideoPipelineWorkerState(
      frameQ: frameQ,
      resultQ: resultQ,
      progressQ: progressQ,
      outputPath: sharedOutputPath,
      previewOutputPath: sharedPreviewOutputPath,
      detectionsOutputPath: sharedDetectionsOutputPath,
      liveDetectionsOutputPath: sharedLiveDetectionsOutputPath,
      fontPath: sharedFontPath,
      fpsNum: outputFps.num,
      fpsDen: outputFps.den,
      fpsForBitrate: outputFps.fpsForBitrate,
      gopSize: outputFps.gopSize,
      bitrateConfig: bitrateConfig,
      previewFrameNumber: previewFrameNumber,
      encoderName: sharedEncoderName,
      maxFrames: actualMaxFrames,
      progressInfo: progressInfo,
      options: options
    )
    appendRtspPublisherLog(rtspPublisherLogPath(), "creating RTSP consumer thread\n")
    createThread(consumerThread, videoPipelineLibavRtspConsumerMain, workerState)
    consumerStarted = true
    appendRtspPublisherLog(rtspPublisherLogPath(), "created RTSP consumer thread\n")

    var
      poolReady = false
      framePool: Pool[OwnedRGBXFrame]
      pooledWidth = 0
      pooledHeight = 0

    while result.pipelineSubmitted < actualMaxFrames:
      if overlayStopRequested(shouldStop, stopCtx):
        appendRtspPublisherLog(rtspPublisherLogPath(), &"producer stop requested submitted={result.pipelineSubmitted}\n")
        break
      if result.pipelineSubmitted < 5 or (result.pipelineSubmitted mod 30) == 0:
        appendRtspPublisherLog(rtspPublisherLogPath(), &"producer reading frame submitted={result.pipelineSubmitted}\n")
      let frameRead = source.readDecodedFrame()
      if result.pipelineSubmitted < 5 or (result.pipelineSubmitted mod 30) == 0:
        appendRtspPublisherLog(rtspPublisherLogPath(), &"producer read status={frameRead.status} submitted={result.pipelineSubmitted}\n")
      if overlayStopRequested(shouldStop, stopCtx):
        appendRtspPublisherLog(rtspPublisherLogPath(), &"producer stop requested after read submitted={result.pipelineSubmitted}\n")
        break
      case frameRead.status
      of dvrsFrame:
        if result.pipelineSubmitted < 5 or (result.pipelineSubmitted mod 30) == 0:
          appendRtspPublisherLog(rtspPublisherLogPath(), &"producer submit start nextFrame={result.pipelineSubmitted}\n")
        submitDecodedFrameToVideoPipeline(
          frameRead,
          progressInfo,
          framePoolCapacity,
          framePool,
          poolReady,
          pooledWidth,
          pooledHeight,
          frameQ,
          result
        )
        if result.pipelineSubmitted <= 5 or (result.pipelineSubmitted mod 30) == 0:
          appendRtspPublisherLog(rtspPublisherLogPath(), &"producer submit done submitted={result.pipelineSubmitted}\n")
        drainVideoPipelineProgress(progressQ, onProgress, progressCtx, actualMaxFrames, progressInfo)
      of dvrsEof:
        break
      of dvrsStopRequested, dvrsInputTimeout:
        break

    var doneItem = VideoPipelineItem(kind: vpiDone)
    frameQ.sendVideoPipelineItem(move doneItem, "send live RTSP publish pipeline done")
    terminalSent = true
    appendRtspPublisherLog(rtspPublisherLogPath(), &"producer sent done submitted={result.pipelineSubmitted}\n")

    let workerResult = waitVideoPipelineResultWithProgress(
      resultQ,
      progressQ,
      onProgress,
      progressCtx,
      actualMaxFrames,
      progressInfo
    )
    joinThread(consumerThread)
    consumerStarted = false

    sharedOutputPath.freeSharedCString()
    sharedPreviewOutputPath.freeSharedCString()
    sharedDetectionsOutputPath.freeSharedCString()
    sharedLiveDetectionsOutputPath.freeSharedCString()
    sharedFontPath.freeSharedCString()
    sharedEncoderName.freeSharedCString()

    case workerResult.kind
    of vprError:
      raise newException(IOError, workerResult.message)
    of vprDone:
      result.mergeThreadedVideoStats(workerResult.stats)

    if result.videoFrames <= 0:
      raise newException(IOError, &"live RTSP input produced no decodable video frame: {inputRtsp}")

    result.decodeMs = result.decoderOpenMs + result.readFrameMs
    result.totalMs = elapsedMs(totalStart)

  except CatchableError as e:
    if consumerStarted and not terminalSent:
      var errItem = VideoPipelineItem(kind: vpiError, message: e.msg)
      try:
        frameQ.sendVideoPipelineItem(move errItem, "send live RTSP publish pipeline error")
        discard resultQ.receiveVideoPipelineResult()
      except CatchableError:
        discard
      joinThread(consumerThread)
    sharedOutputPath.freeSharedCString()
    sharedPreviewOutputPath.freeSharedCString()
    sharedDetectionsOutputPath.freeSharedCString()
    sharedLiveDetectionsOutputPath.freeSharedCString()
    sharedFontPath.freeSharedCString()
    sharedEncoderName.freeSharedCString()
    raise

proc drawMp4VideoOverlayLookahead(
    inputPath, outputPath, fontPath: string;
    previewOutputPath = "";
    options: JobOptions = defaultJobOptions();
    onProgress: OverlayProgressCallback = nil;
    progressCtx: pointer = nil;
    detectionsOutputPath = "";
    liveDetectionsOutputPath = ""
  ): OverlayStats =
  ## Decode the uploaded MP4, run YOLO on each decoded frame, draw bbox/labels,
  ## and encode the result as H.264 MP4.
  ##
  ## This is intentionally still a single job-worker pipeline.  It establishes
  ## the actual video-output path first; later steps can split decode/infer/
  ## overlay/encode into independent threadtools queues without changing the
  ## web-facing job contract.
  let totalStart = epochTime()
  let bitrateConfig = resolveMp4VideoBitrateConfig(options)
  let maxFrames = parseEnvInt("HAILO_DEMO_MP4_VIDEO_MAX_FRAMES", 90)
  let encoderName = resolveMp4VideoEncoderName()
  let maxInFlight = resolveMp4VideoInFlight()
  let previewFrameNumber = resolveVideoPreviewFrame()
  let loadedFont = loadOverlayFont(fontPath)
  let drawOptions = resolveDrawOptionsFromJobOptions(options, true)
  result.pipelineInFlight = maxInFlight

  var reader = openMp4PreviewDecoder(inputPath)
  defer: reader.close()

  result.decoderOpenMs = reader.decoderOpenMs
  result.decoderName = reader.decoderName
  result.applyMp4InputInfo(reader.inputInfo)
  let progressInfo = reader.inputInfo.toVideoProgressInfo()
  let outputFps = resolveMp4VideoOutputFps(reader.inputInfo)
  result.applyOutputFpsInfo(outputFps)

  var
    encoder: VideoEncoder
    writer: Mp4VideoWriter
    detectionsWriter: DetectionJsonWriter
    encoderReady = false
    pendingFrames: seq[PendingVideoFrame] = @[]
    rgbxPool: seq[OwnedRGBXFrame] = @[]
    previewSaved = false

  defer:
    abortDetectionJsonWriter(detectionsWriter)
    if not writer.isNil:
      writer.close()
    if not encoder.isNil:
      encoder.close()

  while maxFrames <= 0 or result.pipelineSubmitted < maxFrames:
    let frameRead = reader.readNextFrame()
    if frameRead.eof:
      break

    result.readFramesMs.add(frameRead.readMs)
    result.readFrameMs += frameRead.readMs
    result.imageWidth = frameRead.frameWidth
    result.imageHeight = frameRead.frameHeight
    result.previewFrameIndex = frameRead.frameIndex
    let frameTimestampSeconds = detectionTimestampSeconds(
      frameRead.frameIndex,
      frameRead.timestampSeconds,
      frameRead.hasTimestampSeconds,
      progressInfo
    )
    var progressSeconds = 0.0
    let hasProgressSeconds = progressTimestampSeconds(
      frameRead.frameIndex,
      frameRead.timestampSeconds,
      frameRead.hasTimestampSeconds,
      progressInfo,
      progressSeconds
    )
    if hasProgressSeconds:
      result.progressSeconds = progressSeconds

    if not encoderReady:
      let encoderHeight = alignUp(frameRead.frameHeight, 16)

      let actualBitrate = resolveMp4VideoBitrate(frameRead.frameWidth, frameRead.frameHeight, outputFps.fpsForBitrate, bitrateConfig)
      result.outputBitrate = actualBitrate

      var stageStart = epochTime()
      encoder = checkFFmpeg(openVideoEncoder(VideoEncoderOptions(
        encoderName: encoderName,
        width: frameRead.frameWidth,
        height: encoderHeight,
        pixelFormat: pfNv12,
        timeBase: Rational(num: int32(outputFps.den), den: int32(outputFps.num)),
        framerate: Rational(num: int32(outputFps.num), den: int32(outputFps.den)),
        bitRate: int64(actualBitrate),
        gopSize: outputFps.gopSize,
        maxBFrames: 0,
        globalHeader: true
      )), &"open video encoder {encoderName}")
      result.encoderOpenMs = elapsedMs(stageStart)

      stageStart = epochTime()
      writer = checkFFmpeg(openMp4VideoWriter(outputPath, encoder), "open MP4 writer")
      result.writerOpenMs = elapsedMs(stageStart)
      detectionsWriter = openDetectionJsonWriter(
        detectionsOutputPath,
        liveDetectionsOutputPath,
        frameRead.frameWidth,
        frameRead.frameHeight,
        progressInfo
      )
      encoderReady = true

    var stageStart = epochTime()
    var yoloInput = frameRead.read.frame.prepareYoloInput()
    let letterboxMs = elapsedMs(stageStart)
    result.letterboxFramesMs.add(letterboxMs)
    result.letterboxMs += letterboxMs

    let pending = yoloInput.submitYoloAsync(uint64(frameRead.frameIndex))
    result.inferSubmitFramesMs.add(pending.submitMs)
    result.inferSubmitMs += pending.submitMs
    inc result.pipelineSubmitted

    stageStart = epochTime()
    var rgbx = checkFFmpeg(
      acquireRgbxFrame(rgbxPool, frameRead.frameWidth, frameRead.frameHeight),
      "allocate RGBX frame"
    )
    checkFFmpegVoid(copyI420ToRGBX(frameRead.read.frame, rgbx), "copy decoded I420 to RGBX")
    let rgbxMs = elapsedMs(stageStart)
    result.rgbxFramesMs.add(rgbxMs)
    result.rgbxMs += rgbxMs
    result.drawMs += rgbxMs

    pendingFrames.add PendingVideoFrame(
      frameIndex: frameRead.frameIndex,
      pending: pending,
      rgbx: move rgbx,
      frameTimestampSeconds: frameTimestampSeconds,
      progressSeconds: progressSeconds,
      hasProgressSeconds: hasProgressSeconds
    )
    result.pipelineFrames = result.videoFrames + pendingFrames.len

    while pendingFrames.len >= maxInFlight:
      drainOldestPendingVideoFrame(
        pendingFrames,
        encoder,
        writer,
        loadedFont.font,
        loadedFont.hasFont,
        drawOptions,
        previewOutputPath,
        previewFrameNumber,
        previewSaved,
        rgbxPool,
        detectionsWriter,
        result
      )
      notifyVideoFrameProgress(onProgress, progressCtx, result, maxFrames, progressInfo)

  while pendingFrames.len > 0:
    drainOldestPendingVideoFrame(
      pendingFrames,
      encoder,
      writer,
      loadedFont.font,
      loadedFont.hasFont,
      drawOptions,
      previewOutputPath,
      previewFrameNumber,
      previewSaved,
      rgbxPool,
      detectionsWriter,
      result
    )
    notifyVideoFrameProgress(onProgress, progressCtx, result, maxFrames, progressInfo)

  if result.videoFrames <= 0:
    raise newException(IOError, &"MP4 has no decodable video frame: {inputPath}")

  notifyVideoFrameProgress(onProgress, progressCtx, result, maxFrames, progressInfo, true)

  var stageStart = epochTime()
  checkFFmpegVoid(encoder.flush(), "flush encoder")
  drainEncoder(encoder, writer, result)
  result.encoderFlushMs = elapsedMs(stageStart)
  result.encodeMs += result.encoderFlushMs

  stageStart = epochTime()
  checkFFmpegVoid(writer.finish(), "finish MP4 writer")
  result.writerFinishMs = elapsedMs(stageStart)
  result.encodeMs += result.writerFinishMs

  closeDetectionJsonWriter(detectionsWriter)

  result.decodeMs = result.decoderOpenMs + result.readFrameMs
  result.totalMs = elapsedMs(totalStart)


proc drawMp4VideoOverlay*(
    inputPath, outputPath, fontPath: string;
    previewOutputPath = "";
    options: JobOptions = defaultJobOptions();
    onProgress: OverlayProgressCallback = nil;
    progressCtx: pointer = nil;
    detectionsOutputPath = "";
    liveDetectionsOutputPath = ""
  ): OverlayStats =
  if useMp4ThreadPipeline():
    return drawMp4VideoOverlayThreaded(
      inputPath,
      outputPath,
      fontPath,
      previewOutputPath,
      options,
      onProgress,
      progressCtx,
      detectionsOutputPath,
      liveDetectionsOutputPath
    )

  result = drawMp4VideoOverlayLookahead(
    inputPath,
    outputPath,
    fontPath,
    previewOutputPath,
    options,
    onProgress,
    progressCtx,
    detectionsOutputPath,
    liveDetectionsOutputPath
  )

proc drawMp4PreviewOverlay*(inputPath, outputPath, fontPath: string): OverlayStats =
  ## Decode one MP4 frame with libav_nim and render it as a JPEG preview with
  ## HAILO detections.
  ##
  ## Timing mapping:
  ##   decode    : libav open/read first decoded I420 frame
  ##   letterbox : I420 -> 640x640 RGB24 YOLO input
  ##   draw      : I420 -> full-size RGBX preview + bbox/label drawing
  if useMp4PipelineProbe():
    return drawMp4PreviewOverlayPipelineProbe(inputPath, outputPath, fontPath)

  if useMp4OverlapPipeline():
    return drawMp4PreviewOverlayPipelined(inputPath, outputPath, fontPath)

  let totalStart = epochTime()

  let preview = decodeMp4PreviewFrame(inputPath)
  var image = preview.image
  result.decodeMs = preview.decodeMs
  result.decoderOpenMs = preview.decoderOpenMs
  result.readFrameMs = preview.readFrameMs
  result.readFramesMs = preview.readFramesMs
  result.previewFrameIndex = preview.frameIndex
  result.requestedProbeFrames = preview.requestedProbeFrames
  result.decoderName = preview.decoderName
  result.letterboxMs = preview.letterboxMs
  result.rgbxMs = preview.rgbxMs
  result.drawMs = preview.rgbxMs

  image.finishOverlay(preview.yoloInput, outputPath, fontPath, result, totalStart, resolveVideoDrawOptions())
