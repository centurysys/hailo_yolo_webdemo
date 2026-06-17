## Standalone RTSP decode probe for live camera bring-up.
##
## The same decode code can be used from the web demo for diagnostics, but this
## executable is safer for investigating libav/HW-decoder open/read/close
## behavior because a crash only terminates this probe process, not the web UI.

import std/[json, parseopt, strformat, strutils]

import live/live_decode_probe

const
  DefaultFrames = 10
  DefaultRepeat = 1
  MaxFrames = 300
  MaxRepeat = 1000

type
  ProbeCliOptions = object
    inputRtsp: string
    decoderName: string
    frames: int
    repeatCount: int
    jsonOutput: bool
    verbose: bool

proc usage() =
  echo """
hailo-live-decode-probe - standalone RTSP decode probe

Usage:
  hailo-live-decode-probe --input <rtsp-url> [options]

Options:
  -i, --input <url>       RTSP input URL. Required.
      --decoder <name>    Decoder name. Default: h264_v4l2m2m. Use "auto" for FFmpeg auto selection.
      --frames <n>        Number of decoded frames to read per run. Default: 10.
      --repeat <n>        Repeat open/read/close cycle. Default: 1.
      --json              Print JSON result.
      --verbose           Print selected options before running.
  -h, --help              Show this help.

Examples:
  hailo-live-decode-probe --input rtsp://127.0.0.1:8554/cam1
  hailo-live-decode-probe --input rtsp://127.0.0.1:8554/cam1 --frames 10 --repeat 5 --json
  hailo-live-decode-probe --input rtsp://127.0.0.1:8554/cam1 --decoder auto
"""

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

proc statsToJson(stats: LiveDecodeProbeStats; iteration: int): JsonNode =
  result = newJObject()
  result["iteration"] = %iteration
  result["attempted"] = %stats.attempted
  result["ok"] = %stats.ok
  result["frames"] = %stats.frames
  result["width"] = %stats.width
  result["height"] = %stats.height
  result["decoderName"] = %stats.decoderName
  result["elapsedMs"] = %stats.elapsedMs
  result["openMs"] = %stats.openMs
  result["readMs"] = %stats.readMs
  result["message"] = %stats.message

proc parseOptions(): ProbeCliOptions =
  result = ProbeCliOptions(
    inputRtsp: "",
    decoderName: "h264_v4l2m2m",
    frames: DefaultFrames,
    repeatCount: DefaultRepeat,
    jsonOutput: false,
    verbose: false
  )

  var parser = initOptParser()
  for kind, key, value in parser.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "i", "input":
        result.inputRtsp = value.strip()
      of "decoder":
        result.decoderName = value.strip()
      of "frames":
        result.frames = parseBoundedInt(value, DefaultFrames, 1, MaxFrames)
      of "repeat":
        result.repeatCount = parseBoundedInt(value, DefaultRepeat, 1, MaxRepeat)
      of "json":
        result.jsonOutput = true
      of "verbose", "v":
        result.verbose = true
      of "help", "h":
        usage()
        quit(0)
      else:
        stderr.writeLine(&"unknown option: {key}")
        usage()
        quit(2)
    of cmdArgument:
      if result.inputRtsp.len == 0:
        result.inputRtsp = key.strip()
      else:
        stderr.writeLine(&"unexpected argument: {key}")
        usage()
        quit(2)
    of cmdEnd:
      discard

  if result.inputRtsp.len == 0:
    stderr.writeLine("--input is required")
    usage()
    quit(2)

proc main() =
  let options = parseOptions()
  let decoderForLibav = normalizedDecoderName(options.decoderName)
  let decoderLabel = if decoderForLibav.len > 0: decoderForLibav else: "auto"

  if options.verbose and not options.jsonOutput:
    echo &"input   : {options.inputRtsp}"
    echo &"decoder : {decoderLabel}"
    echo &"frames  : {options.frames}"
    echo &"repeat  : {options.repeatCount}"

  var overallOk = true
  let runs = newJArray()

  for i in 1 .. options.repeatCount:
    let stats = runLiveDecodeProbe(
      options.inputRtsp,
      decoderName = decoderForLibav,
      maxFrames = options.frames
    )

    runs.add(statsToJson(stats, i))

    if options.jsonOutput:
      discard
    else:
      let status = if stats.ok: "ok" else: "failed"
      echo &"[{i}/{options.repeatCount}] {status}: {stats.message}"

    if not stats.ok:
      overallOk = false
      break

  if options.jsonOutput:
    let root = newJObject()
    root["ok"] = %overallOk
    root["input"] = %options.inputRtsp
    root["decoder"] = %decoderLabel
    root["framesPerRun"] = %options.frames
    root["requestedRepeat"] = %options.repeatCount
    root["completedRuns"] = %runs.len
    root["runs"] = runs
    echo root.pretty()

  if overallOk:
    quit(0)
  else:
    quit(1)

when isMainModule:
  main()
