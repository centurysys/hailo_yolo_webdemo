## Standalone bounded live RTSP -> HAILO overlay -> RTSP publish probe.
##
## This is Step 4: keep the file-proven HAILO/overlay producer/consumer seam,
## but replace the MP4 artifact writer with a bounded RTSP publisher for /cam-ai.

import std/[os, strformat, strutils]

import argparse
import sunny

import config
import draw/overlay
import types

type
  RtspPublishProbeOptions = object
    inputRtsp: string
    outputRtsp: string
    previewPath: string
    detectionsPath: string
    liveDetectionsPath: string
    fontPath: string
    decoderName: string
    frames: int
    jsonOutput: bool
    verbose: bool
    overlayPreset: OverlayPreset
    mp4Quality: Mp4QualityPreset

  RtspPublishProbeJson = object
    ok: bool
    inputRtsp {.json: "inputRtsp".}: string
    outputRtsp {.json: "outputRtsp".}: string
    previewPath {.json: "previewPath,omitempty".}: string
    detectionsPath {.json: "detectionsPath,omitempty".}: string
    requestedFrames {.json: "requestedFrames".}: int
    videoFrames {.json: "videoFrames".}: int
    width: int
    height: int
    decoderName {.json: "decoderName".}: string
    decoderOpenMs {.json: "decoderOpenMs".}: int
    readFrameMs {.json: "readFrameMs".}: int
    letterboxMs {.json: "letterboxMs".}: int
    inferSubmitMs {.json: "inferSubmitMs".}: int
    inferWaitMs {.json: "inferWaitMs".}: int
    inferMs {.json: "inferMs".}: int
    rgbxMs {.json: "rgbxMs".}: int
    drawMs {.json: "drawMs".}: int
    publishMs {.json: "publishMs".}: int
    totalMs {.json: "totalMs".}: int
    detections: int
    boxesDrawn {.json: "boxesDrawn".}: int
    labelsDrawn {.json: "labelsDrawn".}: int
    outputBitrate {.json: "outputBitrate".}: int
    outputFps {.json: "outputFps".}: float64
    outputFpsNum {.json: "outputFpsNum".}: int
    outputFpsDen {.json: "outputFpsDen".}: int
    message: string

  RtspPublishProbeErrorJson = object
    ok: bool
    inputRtsp {.json: "inputRtsp".}: string
    outputRtsp {.json: "outputRtsp".}: string
    message: string

const
  DefaultFrames = 300
  MaxFrames = 30000

proc clampInt(value, lo, hi: int): int =
  result = value
  if result < lo:
    result = lo
  if result > hi:
    result = hi

proc parseBoundedInt(value: string; defaultValue, lo, hi: int): int =
  try:
    result = parseInt(value.strip())
  except ValueError:
    result = defaultValue
  result = clampInt(result, lo, hi)

proc normalizedDecoderName(value: string): string =
  let v = value.strip()
  if v.len == 0 or v == "auto":
    result = ""
  else:
    result = v

proc parseOverlayPreset(value: string): OverlayPreset =
  case value.strip().toLowerAscii()
  of "light": opLight
  of "", "balanced", "default": opBalanced
  of "rich": opRich
  of "boxes", "box", "boxes-only", "boxesonly": opBoxesOnly
  else:
    stderr.writeLine(&"invalid overlay preset: {value}")
    quit(2)

proc parseMp4Quality(value: string): Mp4QualityPreset =
  case value.strip().toLowerAscii()
  of "small", "fast", "low": mpqSmall
  of "", "balanced", "default", "auto": mpqBalanced
  of "high", "large": mpqHigh
  else:
    stderr.writeLine(&"invalid quality: {value}")
    quit(2)

proc parseOptions(): RtspPublishProbeOptions =
  var parser = newParser("hailo-live-rtsp-publish-probe"):
    help("Bounded RTSP -> HAILO overlay -> RTSP publish probe")
    option("-i", "--input", required = true, help = "RTSP input URL")
    option("-o", "--output", required = true, help = "RTSP output URL")
    option("--preview", default = some(""), help = "Optional JPEG preview output path")
    option("--detections", default = some(""), help = "Optional detection JSON output path")
    option("--live-detections", default = some(""), help = "Optional rolling live detection JSON output path")
    option("--decoder", default = some("h264_v4l2m2m"), help = "Decoder name. Use auto for FFmpeg auto selection")
    option("--frames", default = some("300"), help = "Number of live frames to publish")
    option("--font", default = some(""), help = "Font path")
    option("--preset", default = some("boxes-only"), choices = @["light", "balanced", "default", "rich", "boxes", "box", "boxes-only", "boxesonly"], help = "Overlay preset")
    option("--quality", default = some("balanced"), choices = @["small", "fast", "low", "balanced", "default", "auto", "high", "large"], help = "Output bitrate preset")
    flag("--json", help = "Print JSON result")
    flag("-v", "--verbose", help = "Print selected options and detailed timing")

  try:
    let opts = parser.parse()
    result = RtspPublishProbeOptions(
      inputRtsp: opts.input.strip(),
      outputRtsp: opts.output.strip(),
      previewPath: opts.preview.strip(),
      detectionsPath: opts.detections.strip(),
      liveDetectionsPath: opts.live_detections.strip(),
      fontPath: opts.font.strip(),
      decoderName: opts.decoder.strip(),
      frames: parseBoundedInt(opts.frames, DefaultFrames, 1, MaxFrames),
      jsonOutput: opts.json,
      verbose: opts.verbose,
      overlayPreset: parseOverlayPreset(opts.preset),
      mp4Quality: parseMp4Quality(opts.quality)
    )
  except ShortCircuit as err:
    if err.flag == "argparse_help":
      echo err.help
      quit(0)
    raise
  except UsageError:
    stderr.writeLine getCurrentExceptionMsg()
    quit(2)

  if result.inputRtsp.len == 0:
    stderr.writeLine("--input is required")
    quit(2)
  if result.outputRtsp.len == 0:
    stderr.writeLine("--output is required")
    quit(2)
  if result.fontPath.len == 0:
    result.fontPath = config.fontPath

proc statsToJson(stats: OverlayStats; options: RtspPublishProbeOptions): string =
  RtspPublishProbeJson(
    ok: true,
    inputRtsp: options.inputRtsp,
    outputRtsp: options.outputRtsp,
    previewPath: options.previewPath,
    detectionsPath: options.detectionsPath,
    requestedFrames: options.frames,
    videoFrames: stats.videoFrames,
    width: stats.imageWidth,
    height: stats.imageHeight,
    decoderName: stats.decoderName,
    decoderOpenMs: stats.decoderOpenMs,
    readFrameMs: stats.readFrameMs,
    letterboxMs: stats.letterboxMs,
    inferSubmitMs: stats.inferSubmitMs,
    inferWaitMs: stats.inferWaitMs,
    inferMs: stats.inferMs,
    rgbxMs: stats.rgbxMs,
    drawMs: stats.drawMs,
    publishMs: stats.encodeMs,
    totalMs: stats.totalMs,
    detections: stats.detections,
    boxesDrawn: stats.boxesDrawn,
    labelsDrawn: stats.labelsDrawn,
    outputBitrate: stats.outputBitrate,
    outputFps: stats.outputFps,
    outputFpsNum: stats.outputFpsNum,
    outputFpsDen: stats.outputFpsDen,
    message: formatOverlaySummary(stats)
  ).toJson()

proc errorToJson(options: RtspPublishProbeOptions; message: string): string =
  RtspPublishProbeErrorJson(
    ok: false,
    inputRtsp: options.inputRtsp,
    outputRtsp: options.outputRtsp,
    message: message
  ).toJson()

proc main() =
  let options = parseOptions()

  if options.verbose and not options.jsonOutput:
    let decoderLabel = if normalizedDecoderName(options.decoderName).len > 0: normalizedDecoderName(options.decoderName) else: "auto"
    echo &"input          : {options.inputRtsp}"
    echo &"output         : {options.outputRtsp}"
    echo &"preview        : {options.previewPath}"
    echo &"detections     : {options.detectionsPath}"
    echo &"liveDetections : {options.liveDetectionsPath}"
    echo &"decoder        : {decoderLabel}"
    echo &"frames         : {options.frames}"
    echo &"font           : {options.fontPath}"

  try:
    var jobOptions = defaultJobOptions()
    jobOptions.overlayPreset = options.overlayPreset
    jobOptions.mp4Quality = options.mp4Quality

    let stats = drawLiveRtspVideoOverlayToRtsp(
      options.inputRtsp,
      options.outputRtsp,
      options.fontPath,
      decoderName = normalizedDecoderName(options.decoderName),
      maxFrames = options.frames,
      previewOutputPath = options.previewPath,
      options = jobOptions,
      detectionsOutputPath = options.detectionsPath,
      liveDetectionsOutputPath = options.liveDetectionsPath
    )

    if options.jsonOutput:
      echo statsToJson(stats, options)
    else:
      echo formatOverlaySummary(stats)
      if options.verbose:
        echo formatOverlayStats(stats)
  except CatchableError as e:
    if options.jsonOutput:
      echo errorToJson(options, e.msg)
    else:
      stderr.writeLine(&"live RTSP publish probe failed: {e.msg}")
    quit(1)

when isMainModule:
  main()
