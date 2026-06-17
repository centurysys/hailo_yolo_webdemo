## Standalone live RTSP inference probe.
##
## This diagnostic tool verifies the native live path without putting the Web
## Demo service at risk:
##
##   RTSP input -> libav_nim decode -> prepareYoloInput() -> HAILO inference
##
## It supports both a simple synchronous mode and an async mode that mirrors the
## MP4 threaded pipeline's HAILO side:
##
##   producer: decode/read + prepareYoloInput() + submitYoloAsync()
##   consumer: waitYoloAsync()
##
## The async mode is meant to show HAILO throughput headroom even when the
## attached camera itself is only 20fps.

import std/[json, os, strformat, strutils, times]

import libav_nim

import infer/hailo_worker
import live/live_frame_processor
import media/convert

type
  ProbeMode = enum
    pmSync
    pmAsync

  InferProbeOptions = object
    inputRtsp: string
    decoderName: string
    frames: int
    warmupFrames: int
    inFlight: int
    mode: ProbeMode
    stressReuse: bool
    jsonOutput: bool
    verbose: bool

  InferProbeSummary = object
    ok: bool
    inputRtsp: string
    decoderName: string
    mode: string
    stressReuse: bool
    requestedFrames: int
    warmupFrames: int
    decodedFrames: int
    submittedFrames: int
    inferredFrames: int
    width: int
    height: int
    inFlight: int
    openMs: int
    hailoOpenMs: int
    readMs: int
    letterboxMs: int
    submitMs: int
    inferMs: int
    waitMs: int
    hailoWriteUs: int64
    hailoReadUs: int64
    hailoParseUs: int64
    hailoSortUs: int64
    processingMs: int
    totalMs: int
    throughputFps: float64
    detections: int
    maxScorePercent: int
    message: string

  AsyncPendingItem = object
    pending: YoloAsyncPending
    frameIndex: int
    width: int
    height: int
    letterboxMs: int
    submitMs: int
    measured: bool

const
  DefaultFrames = 10
  DefaultWarmupFrames = 2
  DefaultDecoder = "h264_v4l2m2m"
  DefaultInFlight = 4
  MaxFrames = 1000
  MaxWarmupFrames = 300
  MaxInFlight = 16

proc usage() =
  echo """
hailo-live-infer-probe - standalone RTSP decode + HAILO inference probe

Usage:
  hailo-live-infer-probe --input <rtsp-url> [options]

Options:
  -i, --input <url>       RTSP input URL. Required.
      --decoder <name>    Decoder name. Default: h264_v4l2m2m. Use "auto" for FFmpeg auto selection.
      --frames <n>        Number of measured frames. Default: 10.
      --warmup <n>        Warmup frames before measurement. Default: 2.
      --mode <sync|async> Inference mode. Default: async.
      --inflight <n>      Async max in-flight HAILO requests. Default: 4.
      --stress            Decode one frame, then reuse it to stress HAILO throughput.
      --json              Print JSON result.
      --verbose           Print selected options and per-frame messages.
  -h, --help              Show this help.

Examples:
  hailo-live-infer-probe --input rtsp://127.0.0.1:8554/cam1 --verbose
  hailo-live-infer-probe --input rtsp://127.0.0.1:8554/cam1 --mode async --inflight 4 --frames 60
  hailo-live-infer-probe --input rtsp://127.0.0.1:8554/cam1 --stress --frames 120 --json
  hailo-live-infer-probe --input rtsp://127.0.0.1:8554/cam1 --mode sync --frames 10
"""

proc elapsedMs(start: float): int =
  result = int((epochTime() - start) * 1000.0 + 0.5)
  if result < 0:
    result = 0

proc checkAv[T](ret: FFmpegResult[T]; context: string): T =
  if ret.isErr:
    raise newException(IOError, &"{context}: {ret.error.message}")
  result = ret.value

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
  result = result.clampInt(lo, hi)

proc parseProbeMode(value: string): ProbeMode =
  case value.strip().toLowerAscii()
  of "sync", "synchronous":
    result = pmSync
  of "async", "pipeline", "pipelined":
    result = pmAsync
  else:
    stderr.writeLine(&"invalid mode: {value}")
    usage()
    quit(2)

proc modeName(mode: ProbeMode): string =
  case mode
  of pmSync: "sync"
  of pmAsync: "async"

proc normalizedDecoderName(value: string): string =
  let v = value.strip()
  if v.len == 0 or v == "auto":
    result = ""
  else:
    result = v

proc takeOptionValue(args: seq[string]; index: var int; optionName: string): string =
  if index + 1 >= args.len:
    stderr.writeLine(&"{optionName} requires a value")
    usage()
    quit(2)
  inc index
  result = args[index].strip()

proc parseLongValue(arg, prefixEq, prefixColon: string; value: var string): bool =
  if arg.startsWith(prefixEq):
    value = arg[prefixEq.len .. ^1].strip()
    result = true
  elif arg.startsWith(prefixColon):
    value = arg[prefixColon.len .. ^1].strip()
    result = true
  else:
    result = false

proc parseOptions(): InferProbeOptions =
  result = InferProbeOptions(
    inputRtsp: "",
    decoderName: DefaultDecoder,
    frames: DefaultFrames,
    warmupFrames: DefaultWarmupFrames,
    inFlight: DefaultInFlight,
    mode: pmAsync,
    stressReuse: false,
    jsonOutput: false,
    verbose: false
  )

  let args = commandLineParams()
  var i = 0
  while i < args.len:
    let arg = args[i]
    var value = ""

    if arg == "--":
      inc i
      while i < args.len:
        if result.inputRtsp.len == 0:
          result.inputRtsp = args[i].strip()
        else:
          stderr.writeLine(&"unexpected argument: {args[i]}")
          usage()
          quit(2)
        inc i
      break

    elif arg == "-h" or arg == "--help":
      usage()
      quit(0)

    elif arg == "--json":
      result.jsonOutput = true

    elif arg == "-v" or arg == "--verbose":
      result.verbose = true

    elif arg == "--stress":
      result.stressReuse = true

    elif arg == "-i" or arg == "--input":
      result.inputRtsp = takeOptionValue(args, i, arg)

    elif parseLongValue(arg, "--input=", "--input:", value):
      result.inputRtsp = value

    elif arg == "--decoder":
      result.decoderName = takeOptionValue(args, i, arg)

    elif parseLongValue(arg, "--decoder=", "--decoder:", value):
      result.decoderName = value

    elif arg == "--frames":
      result.frames = parseBoundedInt(takeOptionValue(args, i, arg), DefaultFrames, 1, MaxFrames)

    elif parseLongValue(arg, "--frames=", "--frames:", value):
      result.frames = parseBoundedInt(value, DefaultFrames, 1, MaxFrames)

    elif arg == "--warmup":
      result.warmupFrames = parseBoundedInt(takeOptionValue(args, i, arg), DefaultWarmupFrames, 0, MaxWarmupFrames)

    elif parseLongValue(arg, "--warmup=", "--warmup:", value):
      result.warmupFrames = parseBoundedInt(value, DefaultWarmupFrames, 0, MaxWarmupFrames)

    elif arg == "--inflight":
      result.inFlight = parseBoundedInt(takeOptionValue(args, i, arg), DefaultInFlight, 1, MaxInFlight)

    elif parseLongValue(arg, "--inflight=", "--inflight:", value):
      result.inFlight = parseBoundedInt(value, DefaultInFlight, 1, MaxInFlight)

    elif arg == "--mode":
      result.mode = parseProbeMode(takeOptionValue(args, i, arg))

    elif parseLongValue(arg, "--mode=", "--mode:", value):
      result.mode = parseProbeMode(value)

    elif arg.startsWith("-"):
      stderr.writeLine(&"unknown option: {arg}")
      usage()
      quit(2)

    else:
      if result.inputRtsp.len == 0:
        result.inputRtsp = arg.strip()
      else:
        stderr.writeLine(&"unexpected argument: {arg}")
        usage()
        quit(2)

    inc i

  if result.inputRtsp.len == 0:
    stderr.writeLine("--input is required")
    usage()
    quit(2)

proc summaryToJson(summary: InferProbeSummary): JsonNode =
  result = newJObject()
  result["ok"] = %summary.ok
  result["input"] = %summary.inputRtsp
  result["decoder"] = %summary.decoderName
  result["mode"] = %summary.mode
  result["stressReuse"] = %summary.stressReuse
  result["requestedFrames"] = %summary.requestedFrames
  result["warmupFrames"] = %summary.warmupFrames
  result["decodedFrames"] = %summary.decodedFrames
  result["submittedFrames"] = %summary.submittedFrames
  result["inferredFrames"] = %summary.inferredFrames
  result["width"] = %summary.width
  result["height"] = %summary.height
  result["inFlight"] = %summary.inFlight
  result["openMs"] = %summary.openMs
  result["hailoOpenMs"] = %summary.hailoOpenMs
  result["readMs"] = %summary.readMs
  result["letterboxMs"] = %summary.letterboxMs
  result["submitMs"] = %summary.submitMs
  result["inferMs"] = %summary.inferMs
  result["waitMs"] = %summary.waitMs
  result["hailoWriteUs"] = %summary.hailoWriteUs
  result["hailoReadUs"] = %summary.hailoReadUs
  result["hailoParseUs"] = %summary.hailoParseUs
  result["hailoSortUs"] = %summary.hailoSortUs
  result["processingMs"] = %summary.processingMs
  result["totalMs"] = %summary.totalMs
  result["throughputFps"] = %summary.throughputFps
  result["detections"] = %summary.detections
  result["maxScorePercent"] = %summary.maxScorePercent
  result["message"] = %summary.message

proc accountYoloResult(
    summary: var InferProbeSummary;
    item: AsyncPendingItem;
    yoloResult: YoloAsyncResult;
    verbose: bool;
    jsonOutput: bool
  ) =
  if not item.measured:
    return

  inc summary.inferredFrames
  summary.width = item.width
  summary.height = item.height
  summary.letterboxMs += item.letterboxMs
  summary.submitMs += item.submitMs
  summary.inferMs += yoloResult.totalMs
  summary.waitMs += yoloResult.waitMs
  summary.hailoWriteUs += yoloResult.writeUs
  summary.hailoReadUs += yoloResult.readUs
  summary.hailoParseUs += yoloResult.parseUs
  summary.hailoSortUs += yoloResult.sortUs
  summary.detections += yoloResult.detections.len
  let maxScore = yoloResult.detections.maxScorePercent()
  if maxScore > summary.maxScorePercent:
    summary.maxScorePercent = maxScore

  if verbose and not jsonOutput:
    echo &"frame#{item.frameIndex}: {item.width}x{item.height}, detections={yoloResult.detections.len}, letterbox={item.letterboxMs} ms, submit={item.submitMs} ms, wait={yoloResult.waitMs} ms, totalInfer={yoloResult.totalMs} ms, write={yoloResult.writeUs} us, read={yoloResult.readUs} us, parse={yoloResult.parseUs} us, slot={yoloResult.slotIndex}"

proc waitOldestPending(
    pendings: var seq[AsyncPendingItem];
    summary: var InferProbeSummary;
    measuredEnd: var float;
    verbose: bool;
    jsonOutput: bool
  ) =
  if pendings.len == 0:
    return

  var item = pendings[0]
  pendings.delete(0)
  let yoloResult = item.pending.waitYoloAsync()
  if int(yoloResult.requestId) != item.frameIndex:
    raise newException(IOError, &"HAILO result frame mismatch: expected={item.frameIndex} actual={yoloResult.requestId}")
  summary.accountYoloResult(item, yoloResult, verbose, jsonOutput)
  if item.measured:
    measuredEnd = epochTime()

proc submitFrame(
    frame: Yuv420FrameView;
    frameIndex: int;
    measured: bool;
    pendings: var seq[AsyncPendingItem];
    summary: var InferProbeSummary;
    measuredStart: var float
  ) =
  let letterboxStart = epochTime()
  var yoloInput = frame.prepareYoloInput()
  let letterboxMs = elapsedMs(letterboxStart)

  let pending = yoloInput.submitYoloAsync(uint64(frameIndex))
  inc summary.submittedFrames

  if measured and measuredStart <= 0.0:
    measuredStart = letterboxStart

  pendings.add(AsyncPendingItem(
    pending: pending,
    frameIndex: frameIndex,
    width: frame.width,
    height: frame.height,
    letterboxMs: letterboxMs,
    submitMs: pending.submitMs,
    measured: measured
  ))

proc runSyncProbe(options: InferProbeOptions; decoder: VideoDecoder; summary: var InferProbeSummary) =
  var frameIndex = 0
  while summary.inferredFrames < options.frames:
    let readStart = epochTime()
    let read = checkAv(decoder.readFrame(), &"readFrame#{frameIndex}")
    summary.readMs += elapsedMs(readStart)

    if read.eof:
      break

    inc summary.decodedFrames

    if frameIndex < options.warmupFrames:
      discard processLiveYuv420Frame(read.frame, frameIndex)
    else:
      let stats = processLiveYuv420Frame(read.frame, frameIndex)
      if options.verbose and not options.jsonOutput:
        echo stats.message
      if not stats.ok:
        raise newException(IOError, stats.message)

      inc summary.inferredFrames
      summary.width = stats.width
      summary.height = stats.height
      summary.letterboxMs += stats.letterboxMs
      summary.inferMs += stats.inferMs
      summary.detections += stats.detections
      if stats.maxScorePercent > summary.maxScorePercent:
        summary.maxScorePercent = stats.maxScorePercent

    inc frameIndex

proc runAsyncProbe(options: InferProbeOptions; decoder: VideoDecoder; summary: var InferProbeSummary) =
  var
    pendings: seq[AsyncPendingItem] = @[]
    measuredStart = 0.0
    measuredEnd = 0.0
    frameIndex = 0
    measuredSubmitted = 0
    totalToSubmit = options.warmupFrames + options.frames

  if options.stressReuse:
    let readStart = epochTime()
    let read = checkAv(decoder.readFrame(), "readFrame#0")
    summary.readMs += elapsedMs(readStart)
    if read.eof:
      raise newException(IOError, "input reached EOF before the stress frame")
    inc summary.decodedFrames

    while frameIndex < totalToSubmit:
      let measured = frameIndex >= options.warmupFrames
      submitFrame(read.frame, frameIndex, measured, pendings, summary, measuredStart)
      if measured:
        inc measuredSubmitted
      while pendings.len >= options.inFlight:
        waitOldestPending(pendings, summary, measuredEnd, options.verbose, options.jsonOutput)
      inc frameIndex
  else:
    while measuredSubmitted < options.frames:
      let readStart = epochTime()
      let read = checkAv(decoder.readFrame(), &"readFrame#{frameIndex}")
      summary.readMs += elapsedMs(readStart)

      if read.eof:
        break

      inc summary.decodedFrames
      let measured = frameIndex >= options.warmupFrames
      submitFrame(read.frame, frameIndex, measured, pendings, summary, measuredStart)
      if measured:
        inc measuredSubmitted

      while pendings.len >= options.inFlight:
        waitOldestPending(pendings, summary, measuredEnd, options.verbose, options.jsonOutput)

      inc frameIndex

  while pendings.len > 0:
    waitOldestPending(pendings, summary, measuredEnd, options.verbose, options.jsonOutput)

  if measuredStart > 0.0 and measuredEnd >= measuredStart:
    summary.processingMs = int((measuredEnd - measuredStart) * 1000.0 + 0.5)
    if summary.processingMs > 0 and summary.inferredFrames > 0:
      summary.throughputFps = float64(summary.inferredFrames) * 1000.0 / float64(summary.processingMs)

proc runProbe(options: InferProbeOptions): InferProbeSummary =
  let totalStart = epochTime()
  let decoderForLibav = normalizedDecoderName(options.decoderName)
  let decoderLabel = if decoderForLibav.len > 0: decoderForLibav else: "auto"

  result = InferProbeSummary(
    ok: false,
    inputRtsp: options.inputRtsp,
    decoderName: decoderLabel,
    mode: modeName(options.mode),
    stressReuse: options.stressReuse,
    requestedFrames: options.frames,
    warmupFrames: options.warmupFrames,
    inFlight: if options.mode == pmAsync: options.inFlight else: 1,
    message: "not started"
  )

  var decoder: VideoDecoder

  try:
    let openStart = epochTime()
    decoder = checkAv(
      openVideoDecoder(options.inputRtsp, DecoderOptions(decoderName: decoderForLibav)),
      &"openVideoDecoder input={options.inputRtsp}"
    )
    result.openMs = elapsedMs(openStart)

    let hailoOpenStart = epochTime()
    preloadHailoWorker()
    result.hailoOpenMs = elapsedMs(hailoOpenStart)

    case options.mode
    of pmSync:
      runSyncProbe(options, decoder, result)
      result.processingMs = result.letterboxMs + result.inferMs
      if result.processingMs > 0 and result.inferredFrames > 0:
        result.throughputFps = float64(result.inferredFrames) * 1000.0 / float64(result.processingMs)
    of pmAsync:
      runAsyncProbe(options, decoder, result)

    result.totalMs = elapsedMs(totalStart)
    result.ok = result.inferredFrames > 0
    if result.ok:
      result.message = &"mode={result.mode}, decoded={result.decodedFrames}, submitted={result.submittedFrames}, inferred={result.inferredFrames} frame(s) {result.width}x{result.height} with decoder={decoderLabel}; read={result.readMs} ms, letterbox={result.letterboxMs} ms, submit={result.submitMs} ms, inferTotal={result.inferMs} ms, wait={result.waitMs} ms, processing={result.processingMs} ms, throughput={result.throughputFps:.2f} fps, total={result.totalMs} ms"
    else:
      result.message = &"opened input but inferred no measured frame with decoder={decoderLabel}; total={result.totalMs} ms"

  except CatchableError as e:
    result.totalMs = elapsedMs(totalStart)
    result.ok = false
    result.message = &"live inference probe failed: {e.msg}"

  finally:
    if not decoder.isNil:
      try:
        decoder.close()
      except CatchableError:
        discard
    try:
      closeHailoWorker()
    except CatchableError:
      discard

proc main() =
  let options = parseOptions()
  let decoderForLibav = normalizedDecoderName(options.decoderName)
  let decoderLabel = if decoderForLibav.len > 0: decoderForLibav else: "auto"

  if options.verbose and not options.jsonOutput:
    echo &"input   : {options.inputRtsp}"
    echo &"decoder : {decoderLabel}"
    echo &"mode    : {modeName(options.mode)}"
    echo &"frames  : {options.frames}"
    echo &"warmup  : {options.warmupFrames}"
    if options.mode == pmAsync:
      echo &"inflight: {options.inFlight}"
      echo &"stress  : {options.stressReuse}"

  let summary = runProbe(options)

  if options.jsonOutput:
    echo summary.summaryToJson().pretty()
  else:
    if summary.ok:
      echo &"ok: {summary.message}"
    else:
      stderr.writeLine(&"failed: {summary.message}")

  if not summary.ok:
    quit(1)

when isMainModule:
  main()
