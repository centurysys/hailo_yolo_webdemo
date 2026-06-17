import std/[os, strformat, strutils]

proc cExecvp(file: cstring, argv: cstringArray): cint {.importc: "execvp", header: "<unistd.h>".}

const
  DefaultFfmpeg = "/usr/bin/ffmpeg"
  DefaultLogLevel = "warning"

type
  WorkerConfig = object
    inputRtsp: string
    outputRtsp: string
    ffmpeg: string
    logLevel: string
    dryRun: bool
    verbose: bool

proc usage(): string =
  result = """
hailo-live-worker - live inference worker placeholder

Usage:
  hailo-live-worker --input <rtsp-url> --output <rtsp-url> [options]

Options:
  --input <url>        Input RTSP URL, for example rtsp://127.0.0.1:8554/cam1
  --output <url>       Output RTSP URL, for example rtsp://127.0.0.1:8554/cam-ai
  --ffmpeg <path>      ffmpeg executable path. Default: /usr/bin/ffmpeg
  --log-level <level>  ffmpeg log level. Default: warning
  --dry-run            Print the command instead of executing it
  --verbose            Print the command before executing it
  -h, --help           Show this help

Current implementation:
  This worker is a process/lifecycle placeholder. It replaces itself with
  ffmpeg and relays the selected RTSP stream to the output RTSP URL without
  decoding or inference. The final implementation will replace this internal
  relay with decode -> infer -> overlay -> encode -> RTSP publish.
"""

proc takeValue(params: seq[string], i: var int, optName: string): string =
  let arg = params[i]
  let prefix = optName & ":"
  if arg.startsWith(prefix):
    result = arg[prefix.len .. ^1]
  else:
    if i + 1 >= params.len:
      raise newException(ValueError, &"missing value for {optName}")
    inc i
    result = params[i]

proc parseArgs(params: seq[string]): WorkerConfig =
  result.ffmpeg = getEnv("HAILO_LIVE_WORKER_FFMPEG", DefaultFfmpeg)
  result.logLevel = getEnv("HAILO_LIVE_WORKER_FFMPEG_LOG_LEVEL", DefaultLogLevel)

  var i = 0
  while i < params.len:
    let arg = params[i]
    case arg
    of "-h", "--help":
      echo usage()
      quit 0
    of "--input":
      result.inputRtsp = takeValue(params, i, "--input")
    of "--output":
      result.outputRtsp = takeValue(params, i, "--output")
    of "--ffmpeg":
      result.ffmpeg = takeValue(params, i, "--ffmpeg")
    of "--log-level":
      result.logLevel = takeValue(params, i, "--log-level")
    of "--dry-run":
      result.dryRun = true
    of "--verbose":
      result.verbose = true
    else:
      if arg.startsWith("--input:"):
        result.inputRtsp = takeValue(params, i, "--input")
      elif arg.startsWith("--output:"):
        result.outputRtsp = takeValue(params, i, "--output")
      elif arg.startsWith("--ffmpeg:"):
        result.ffmpeg = takeValue(params, i, "--ffmpeg")
      elif arg.startsWith("--log-level:"):
        result.logLevel = takeValue(params, i, "--log-level")
      else:
        raise newException(ValueError, &"unknown argument: {arg}")
    inc i

proc validateConfig(cfg: WorkerConfig) =
  if cfg.inputRtsp.len == 0:
    raise newException(ValueError, "--input is required")
  if cfg.outputRtsp.len == 0:
    raise newException(ValueError, "--output is required")
  if not cfg.inputRtsp.startsWith("rtsp://"):
    raise newException(ValueError, &"input URL must be rtsp://: {cfg.inputRtsp}")
  if not cfg.outputRtsp.startsWith("rtsp://"):
    raise newException(ValueError, &"output URL must be rtsp://: {cfg.outputRtsp}")
  if cfg.ffmpeg.len == 0:
    raise newException(ValueError, "ffmpeg path is empty")
  if not fileExists(cfg.ffmpeg):
    raise newException(ValueError, &"ffmpeg executable was not found: {cfg.ffmpeg}")

proc buildFfmpegArgs(cfg: WorkerConfig): seq[string] =
  result = @[
    cfg.ffmpeg,
    "-nostdin",
    "-hide_banner",
    "-loglevel", cfg.logLevel,
    "-rtsp_transport", "tcp",
    "-fflags", "nobuffer",
    "-flags", "low_delay",
    "-i", cfg.inputRtsp,
    "-an",
    "-c:v", "copy",
    "-rtsp_transport", "tcp",
    "-f", "rtsp",
    cfg.outputRtsp,
  ]

proc quoteForDisplay(s: string): string =
  if s.len == 0:
    return "''"
  if s.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.', '/', ':', '@', '[', ']', '+'}):
    return s
  result = "'"
  for ch in s:
    if ch == '\'':
      result.add("'\\''")
    else:
      result.add(ch)
  result.add("'")

proc formatCommand(args: seq[string]): string =
  result = ""
  for i, arg in args:
    if i > 0:
      result.add(" ")
    result.add(quoteForDisplay(arg))

proc execReplace(args: seq[string]) =
  var cargs = allocCStringArray(args)
  defer: deallocCStringArray(cargs)

  let rc = cExecvp(args[0].cstring, cargs)
  raise newException(OSError, &"execvp failed for {args[0]}: rc={rc}, osError={osLastError()}")

when isMainModule:
  try:
    let cfg = parseArgs(commandLineParams())
    validateConfig(cfg)

    let ffmpegArgs = buildFfmpegArgs(cfg)
    if cfg.verbose or cfg.dryRun:
      stderr.writeLine(&"hailo-live-worker: exec {formatCommand(ffmpegArgs)}")

    if cfg.dryRun:
      quit 0

    execReplace(ffmpegArgs)
  except CatchableError as e:
    stderr.writeLine(&"hailo-live-worker: error: {e.msg}")
    quit 1
