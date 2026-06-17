## Bounded live RTSP inference monitor for in-process live sessions.
##
## This is intentionally not the final /cam-ai media pipeline.  The preview path
## can keep using ffmpeg-copy while this monitor verifies that the selected live
## RTSP input can be decoded and processed through the same async HAILO worker
## style used by the MP4 threaded pipeline.

import std/[strformat, strutils, times]

import libav_nim

import ../infer/hailo_worker
import ../media/convert
import ./live_frame_processor

type
  LiveInferMonitorOptions* = object
    inputRtsp*: string
    decoderName*: string
    frames*: int
    warmupFrames*: int
    inFlight*: int
    verbose*: bool

  LiveInferMonitorSummary* = object
    attempted*: bool
    ok*: bool
    inputRtsp*: string
    decoderName*: string
    requestedFrames*: int
    warmupFrames*: int
    inFlight*: int
    decodedFrames*: int
    submittedFrames*: int
    inferredFrames*: int
    width*: int
    height*: int
    readMs*: int
    letterboxMs*: int
    submitMs*: int
    inferTotalMs*: int
    waitMs*: int
    hailoWriteUs*: int64
    hailoReadUs*: int64
    hailoParseUs*: int64
    hailoSortUs*: int64
    processingMs*: int
    totalMs*: int
    throughputFps*: float64
    detections*: int
    maxScorePercent*: int
    message*: string

  AsyncPendingItem = object
    pending: YoloAsyncPending
    frameIndex: int
    width: int
    height: int
    letterboxMs: int
    submitMs: int
    measured: bool

const
  DefaultDecoder* = "h264_v4l2m2m"
  DefaultFrames* = 60
  DefaultWarmupFrames* = 2
  DefaultInFlight* = 4

proc elapsedMs(start: float): int =
  result = int((epochTime() - start) * 1000.0 + 0.5)
  if result < 0:
    result = 0

proc checkAv[T](ret: FFmpegResult[T]; context: string): T =
  if ret.isErr:
    raise newException(IOError, &"{context}: {ret.error.message}")
  result = ret.value

proc normalizedDecoderName(value: string): string =
  let v = value.strip()
  if v.len == 0 or v == "auto":
    result = ""
  else:
    result = v

proc accountYoloResult(
    summary: var LiveInferMonitorSummary;
    item: AsyncPendingItem;
    yoloResult: YoloAsyncResult;
    verbose: bool
  ) =
  if not item.measured:
    return

  inc summary.inferredFrames
  summary.width = item.width
  summary.height = item.height
  summary.letterboxMs += item.letterboxMs
  summary.submitMs += item.submitMs
  summary.inferTotalMs += yoloResult.totalMs
  summary.waitMs += yoloResult.waitMs
  summary.hailoWriteUs += yoloResult.writeUs
  summary.hailoReadUs += yoloResult.readUs
  summary.hailoParseUs += yoloResult.parseUs
  summary.hailoSortUs += yoloResult.sortUs
  summary.detections += yoloResult.detections.len

  let maxScore = yoloResult.detections.maxScorePercent()
  if maxScore > summary.maxScorePercent:
    summary.maxScorePercent = maxScore

  if verbose:
    echo &"live infer frame#{item.frameIndex}: {item.width}x{item.height}, detections={yoloResult.detections.len}, letterbox={item.letterboxMs} ms, submit={item.submitMs} ms, wait={yoloResult.waitMs} ms, totalInfer={yoloResult.totalMs} ms, write={yoloResult.writeUs} us, read={yoloResult.readUs} us, parse={yoloResult.parseUs} us, slot={yoloResult.slotIndex}"

proc waitOldestPending(
    pendings: var seq[AsyncPendingItem];
    summary: var LiveInferMonitorSummary;
    measuredEnd: var float;
    verbose: bool
  ) =
  if pendings.len == 0:
    return

  var item = pendings[0]
  pendings.delete(0)
  let yoloResult = item.pending.waitYoloAsync()
  if int(yoloResult.requestId) != item.frameIndex:
    raise newException(IOError, &"HAILO result frame mismatch: expected={item.frameIndex} actual={yoloResult.requestId}")

  summary.accountYoloResult(item, yoloResult, verbose)
  if item.measured:
    measuredEnd = epochTime()

proc submitFrame(
    frame: Yuv420FrameView;
    frameIndex: int;
    measured: bool;
    pendings: var seq[AsyncPendingItem];
    summary: var LiveInferMonitorSummary;
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

proc runLiveInferMonitor*(options: LiveInferMonitorOptions): LiveInferMonitorSummary =
  ## Decode a bounded number of live RTSP frames and run them through the async
  ## HAILO path.  This does not publish frames and does not close the shared
  ## HAILO worker when it finishes; the Web Demo process owns that lifecycle.
  let totalStart = epochTime()
  let decoderForLibav = normalizedDecoderName(options.decoderName)
  let decoderLabel = if decoderForLibav.len > 0: decoderForLibav else: "auto"

  result = LiveInferMonitorSummary(
    attempted: true,
    ok: false,
    inputRtsp: options.inputRtsp,
    decoderName: decoderLabel,
    requestedFrames: options.frames,
    warmupFrames: options.warmupFrames,
    inFlight: options.inFlight,
    message: "live inference monitor not started"
  )

  if options.frames <= 0:
    result.ok = true
    result.message = "live inference monitor is disabled"
    return

  var decoder: VideoDecoder

  try:
    decoder = checkAv(
      openVideoDecoder(options.inputRtsp, DecoderOptions(decoderName: decoderForLibav)),
      &"openVideoDecoder input={options.inputRtsp}"
    )

    ## Make HAILO open errors visible here.  The caller must close the HAILO
    ## worker from the same live worker thread when the live session stops.
    preloadHailoWorker()

    var
      pendings: seq[AsyncPendingItem] = @[]
      measuredStart = 0.0
      measuredEnd = 0.0
      frameIndex = 0
      measuredSubmitted = 0
      maxInFlight = options.inFlight

    if maxInFlight <= 0:
      maxInFlight = DefaultInFlight

    while measuredSubmitted < options.frames:
      let readStart = epochTime()
      let read = checkAv(decoder.readFrame(), &"readFrame#{frameIndex}")
      result.readMs += elapsedMs(readStart)

      if read.eof:
        break

      inc result.decodedFrames
      let measured = frameIndex >= options.warmupFrames
      submitFrame(read.frame, frameIndex, measured, pendings, result, measuredStart)
      if measured:
        inc measuredSubmitted

      while pendings.len >= maxInFlight:
        waitOldestPending(pendings, result, measuredEnd, options.verbose)

      inc frameIndex

    while pendings.len > 0:
      waitOldestPending(pendings, result, measuredEnd, options.verbose)

    if measuredStart > 0.0 and measuredEnd >= measuredStart:
      result.processingMs = int((measuredEnd - measuredStart) * 1000.0 + 0.5)
      if result.processingMs > 0 and result.inferredFrames > 0:
        result.throughputFps = float64(result.inferredFrames) * 1000.0 / float64(result.processingMs)

    result.totalMs = elapsedMs(totalStart)
    result.ok = result.inferredFrames > 0
    if result.ok:
      result.message = &"live async inference monitor inferred {result.inferredFrames}/{result.requestedFrames} frame(s) {result.width}x{result.height}; throughput={result.throughputFps:.2f} fps, read={result.readMs} ms, letterbox={result.letterboxMs} ms, wait={result.waitMs} ms, processing={result.processingMs} ms"
    else:
      result.message = &"live async inference monitor inferred no measured frame; decoded={result.decodedFrames}, submitted={result.submittedFrames}, total={result.totalMs} ms"

  except CatchableError as e:
    result.totalMs = elapsedMs(totalStart)
    result.ok = false
    result.message = &"live async inference monitor failed: {e.msg}"

  finally:
    if not decoder.isNil:
      try:
        decoder.close()
      except CatchableError:
        discard
