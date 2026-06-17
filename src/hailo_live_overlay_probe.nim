## Standalone bounded live RTSP -> HAILO overlay -> MP4 probe.
##
## This is the Step 3 bridge between the stable MP4 file pipeline and the future
## /cam-ai live publisher:
##
##   RTSP input -> libav_nim decode -> existing threaded overlay pipeline -> MP4
##
## Keeping the output as a finite MP4 makes it safe to validate the live source
## seam before replacing /cam-ai with encoded overlay publishing.

import std/[json, os, strformat, strutils, options]

import argparse

import config
import draw/overlay
import types

type
  OverlayProbeOptions = object
    inputRtsp: string
    outputPath: string
    previewPath: string
    detectionsPath: string
    fontPath: string
    decoderName: string
    frames: int
    jsonOutput: bool
    verbose: bool
    overlayPreset: OverlayPreset
    mp4Quality: Mp4QualityPreset

const
  DefaultFrames = 60
  MaxFrames = 3000

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

proc parseOptions(): OverlayProbeOptions =
  var parser = newParser("hailo-live-overlay-probe"):
    help("Bounded RTSP -> HAILO overlay -> MP4 probe")
    option("-i", "--input", required = true, help = "RTSP input URL")
    option("-o", "--output", required = true, help = "Output MP4 path")
    option("--preview", default = some(""), help = "Optional JPEG preview output path")
    option("--detections", default = some(""), help = "Optional detection JSON output path")
    option("--decoder", default = some("h264_v4l2m2m"), help = "Decoder name. Use auto for FFmpeg auto selection")
    option("--frames", default = some("60"), help = "Number of live frames to process")
    option("--font", default = some(""), help = "Font path")
    option("--preset", default = some("boxes-only"), choices = @["light", "balanced", "default", "rich", "boxes", "box", "boxes-only", "boxesonly"], help = "Overlay preset")
    option("--quality", default = some("balanced"), choices = @["small", "fast", "low", "balanced", "default", "auto", "high", "large"], help = "MP4 quality")
    flag("--json", help = "Print JSON result")
    flag("-v", "--verbose", help = "Print selected options and detailed timing")

  try:
    let opts = parser.parse()
    result = OverlayProbeOptions(
      inputRtsp: opts.input.strip(),
      outputPath: opts.output.strip(),
      previewPath: opts.preview.strip(),
      detectionsPath: opts.detections.strip(),
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
  if result.outputPath.len == 0:
    stderr.writeLine("--output is required")
    quit(2)
  if result.fontPath.len == 0:
    result.fontPath = config.fontPath

proc statsToJson(stats: OverlayStats; options: OverlayProbeOptions): JsonNode =
  result = newJObject()
  result["ok"] = %true
  result["inputRtsp"] = %options.inputRtsp
  result["outputPath"] = %options.outputPath
  result["previewPath"] = %options.previewPath
  result["detectionsPath"] = %options.detectionsPath
  result["requestedFrames"] = %options.frames
  result["videoFrames"] = %stats.videoFrames
  result["videoPackets"] = %stats.videoPackets
  result["videoPacketBytes"] = %stats.videoPacketBytes
  result["width"] = %stats.imageWidth
  result["height"] = %stats.imageHeight
  result["decoderName"] = %stats.decoderName
  result["decoderOpenMs"] = %stats.decoderOpenMs
  result["readFrameMs"] = %stats.readFrameMs
  result["letterboxMs"] = %stats.letterboxMs
  result["inferSubmitMs"] = %stats.inferSubmitMs
  result["inferWaitMs"] = %stats.inferWaitMs
  result["inferMs"] = %stats.inferMs
  result["rgbxMs"] = %stats.rgbxMs
  result["drawMs"] = %stats.drawMs
  result["encodeMs"] = %stats.encodeMs
  result["totalMs"] = %stats.totalMs
  result["detections"] = %stats.detections
  result["boxesDrawn"] = %stats.boxesDrawn
  result["labelsDrawn"] = %stats.labelsDrawn
  result["outputBitrate"] = %stats.outputBitrate
  result["outputFps"] = %stats.outputFps
  result["outputFpsNum"] = %stats.outputFpsNum
  result["outputFpsDen"] = %stats.outputFpsDen
  result["message"] = %formatOverlaySummary(stats)

proc main() =
  let options = parseOptions()

  if options.verbose and not options.jsonOutput:
    let decoderLabel = if normalizedDecoderName(options.decoderName).len > 0: normalizedDecoderName(options.decoderName) else: "auto"
    echo &"input      : {options.inputRtsp}"
    echo &"output     : {options.outputPath}"
    echo &"preview    : {options.previewPath}"
    echo &"detections : {options.detectionsPath}"
    echo &"decoder    : {decoderLabel}"
    echo &"frames     : {options.frames}"
    echo &"font       : {options.fontPath}"

  try:
    var jobOptions = defaultJobOptions()
    jobOptions.overlayPreset = options.overlayPreset
    jobOptions.mp4Quality = options.mp4Quality

    let stats = drawLiveRtspVideoOverlayToMp4(
      options.inputRtsp,
      options.outputPath,
      options.fontPath,
      decoderName = normalizedDecoderName(options.decoderName),
      maxFrames = options.frames,
      previewOutputPath = options.previewPath,
      options = jobOptions,
      detectionsOutputPath = options.detectionsPath
    )

    if options.jsonOutput:
      echo pretty(statsToJson(stats, options))
    else:
      echo formatOverlaySummary(stats)
      if options.verbose:
        echo formatOverlayStats(stats)
  except CatchableError as e:
    if options.jsonOutput:
      let obj = newJObject()
      obj["ok"] = %false
      obj["inputRtsp"] = %options.inputRtsp
      obj["outputPath"] = %options.outputPath
      obj["message"] = %e.msg
      echo pretty(obj)
    else:
      stderr.writeLine(&"live overlay probe failed: {e.msg}")
    quit(1)

when isMainModule:
  main()
