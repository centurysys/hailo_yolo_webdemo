## Thin HailoRT detector wrapper.
##
## Detector open / HEF load is now exposed through preloadHailoWorker().
## The background job runner calls it once in its own worker thread before
## waiting for jobs, so the first upload does not pay the HEF loading cost.

import hailort_nim
import std/[locks, os, strformat, times]

import ../config
import ../media/convert
import ../types as appTypes
import ./yolo

const
  DefaultAppScoreThreshold = 0.25'f32
  DefaultHailoNmsScoreThreshold = 0.20'f32

type

  YoloAsyncPending* = object
    ## Correlation and letterbox metadata for one submitted HAILO request.
    requestId*: uint64
    info*: YoloLetterboxInfo
    startedAt*: float
    submitMs*: int

  YoloAsyncResult* = object
    ## Application-space detections and HAILO worker timing for one reply.
    requestId*: uint64
    detections*: seq[appTypes.Detection]
    totalMs*: int
    waitMs*: int
    writeUs*: int64
    readUs*: int64
    parseUs*: int64
    sortUs*: int64
    slotIndex*: int

var
  gLock: Lock
  gLockReady = false
  gDetector: hailort_nim.Detector
  gOutputBuf: seq[byte]
  gRawDetections: seq[hailort_nim.Detection]
  gThreadtoolsWorker: hailort_nim.ThreadtoolsDetectorWorker

proc initHailoWorker*() =
  ## Keep this idempotent.  The lock can be initialized by main or by the
  ## background worker thread.
  if not gLockReady:
    initLock(gLock)
    gLockReady = true

proc ensureDetector() =
  if not gLockReady:
    initHailoWorker()

  if gDetector.isNil:
    if not fileExists(hefPath):
      raise newException(IOError, &"HEF file not found: {hefPath}")

    let openRes = hailort_nim.Detector.open(
      hefPath,
      hailoNmsScoreThreshold = DefaultHailoNmsScoreThreshold,
      profiling = true
    )
    if openRes.isErr:
      raise newException(IOError, &"Detector.open failed: {openRes.error}")

    gDetector = openRes.get()
    gOutputBuf = newSeq[byte](gDetector.outputSize())
    gRawDetections = @[]

    echo &"HAILO detector opened: inputSize={gDetector.inputSize()} outputSize={gDetector.outputSize()} hef={hefPath}"

proc elapsedMs(start: float): int =
  result = int((epochTime() - start) * 1000.0 + 0.5)
  if result < 0:
    result = 0

proc ensureThreadtoolsWorker() =
  ## Lazily start the HAILO threadtools worker on top of the preloaded Detector.
  ## The job runner is still single-threaded at the control level, but this
  ## worker lets output read/parse proceed while the caller prepares the full
  ## RGBX preview frame.
  ensureDetector()

  if gThreadtoolsWorker.isNil or gThreadtoolsWorker.isClosed():
    let workerRes = gDetector.startThreadtoolsDetectorWorker(
      slotCount = 2,
      requestQueueSize = 4
    )
    if workerRes.isErr:
      raise newException(IOError, &"startThreadtoolsDetectorWorker failed: {workerRes.error}")

    gThreadtoolsWorker = workerRes.get()
    echo &"HAILO threadtools detector worker started: inputSize={gThreadtoolsWorker.inputSize()} outputSize={gThreadtoolsWorker.outputSize()}"

proc preloadHailoWorker*() =
  ## Open the detector and allocate reusable buffers before the first job.
  ##
  ## This should be called from the same thread that will later run detectYolo()
  ## so HailoRT/vstream ownership stays local to the job worker thread.
  if not gLockReady:
    initHailoWorker()

  withLock gLock:
    ensureDetector()

proc closeHailoWorker*() =
  if not gLockReady:
    return

  withLock gLock:
    if not gThreadtoolsWorker.isNil:
      let closeWorkerRes = gThreadtoolsWorker.close()
      if closeWorkerRes.isErr:
        echo &"warning: failed to close HAILO threadtools worker: {closeWorkerRes.error}"
      else:
        echo "HAILO threadtools detector worker closed"
      gThreadtoolsWorker = nil

    if not gDetector.isNil:
      let closeRes = gDetector.close()
      if closeRes.isErr:
        echo &"warning: failed to close HAILO detector: {closeRes.error}"
      else:
        echo "HAILO detector closed"
      gDetector = nil
      gOutputBuf.setLen(0)
      gRawDetections.setLen(0)

proc detectYolo*(input: YoloInputImage): seq[appTypes.Detection] =
  if input.rgb.data.len == 0:
    raise newException(ValueError, "YOLO input buffer is empty")

  if not gLockReady:
    initHailoWorker()

  withLock gLock:
    ensureDetector()

    let detectRes = gDetector.detectNmsByClassAutoInto(
      input.rgb.data,
      gOutputBuf,
      gRawDetections,
      appScoreThreshold = DefaultAppScoreThreshold
    )
    if detectRes.isErr:
      raise newException(IOError, &"detectNmsByClassAutoInto failed: {detectRes.error}")

    result = hailoDetectionsToApp(gRawDetections, input.info)


proc submitYoloAsync*(input: var YoloInputImage; requestId: uint64 = 0'u64): YoloAsyncPending =
  ## Submit the owned YOLO input buffer to the HAILO threadtools worker.
  ##
  ## The RGB byte seq is moved into the worker queue.  The letterbox metadata is
  ## copied into the pending token so the reply can still be restored into the
  ## original image coordinate space after the input buffer has moved away.
  if input.rgb.data.len == 0:
    raise newException(ValueError, "YOLO input buffer is empty")

  if not gLockReady:
    initHailoWorker()

  let startedAt = epochTime()
  var ownedInput = move input.rgb.data

  withLock gLock:
    ensureThreadtoolsWorker()

    let submitRes = gThreadtoolsWorker.submit(
      move ownedInput,
      requestId = requestId,
      appScoreThreshold = DefaultAppScoreThreshold,
      userData = requestId
    )
    if submitRes.isErr:
      raise newException(IOError, &"threadtools detector submit failed: {submitRes.error}")

  result = YoloAsyncPending(
    requestId: requestId,
    info: input.info,
    startedAt: startedAt,
    submitMs: elapsedMs(startedAt)
  )

proc waitYoloAsync*(pending: YoloAsyncPending): YoloAsyncResult =
  ## Wait for the HAILO threadtools worker reply corresponding to `pending`.
  ##
  ## The current app submits one MP4 preview request at a time, so a blocking
  ## wait is enough for Step 1.  Later video pipeline probes can keep multiple
  ## requestIds in flight and dispatch replies through a small frameNo ring.
  if not gLockReady:
    initHailoWorker()

  var reply: hailort_nim.ThreadtoolsDetectorWorkerReply
  let waitStarted = epochTime()

  ## Do not hold gLock while blocking in waitReply().  Step 6 submits new
  ## frames from the decode/preprocess side while the overlay/encode side waits
  ## for older replies.  Holding this lock across waitReply() would serialize
  ## submit and wait again, defeating the pipeline.  ThreadtoolsDetectorWorker
  ## request/reply queues are thread-safe, so the lock is only needed to take a
  ## stable worker reference and validate its lifetime.
  var worker: hailort_nim.ThreadtoolsDetectorWorker
  withLock gLock:
    if gThreadtoolsWorker.isNil or gThreadtoolsWorker.isClosed():
      raise newException(IOError, "HAILO threadtools worker is not running")
    worker = gThreadtoolsWorker

  let waitRes = worker.waitReply(reply)
  if waitRes.isErr:
    raise newException(IOError, &"threadtools detector waitReply failed: {waitRes.error}")

  if reply.requestId != pending.requestId:
    raise newException(
      IOError,
      &"threadtools detector reply id mismatch: expected={pending.requestId} actual={reply.requestId}"
    )

  case reply.kind
  of tdwrkError:
    raise newException(IOError, &"threadtools detector reply error: {reply.error.msg}")
  of tdwrkResult:
    let timing = reply.result.timing
    result = YoloAsyncResult(
      requestId: reply.requestId,
      detections: hailoDetectionsToApp(reply.result.detections, pending.info),
      totalMs: elapsedMs(pending.startedAt),
      waitMs: elapsedMs(waitStarted),
      writeUs: timing.writeUs,
      readUs: timing.readUs,
      parseUs: timing.parseUs,
      sortUs: timing.sortUs,
      slotIndex: timing.slotIndex
    )
