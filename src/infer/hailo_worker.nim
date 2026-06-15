## Thin HailoRT detector wrapper.
##
## Detector open / HEF load is now exposed through preloadHailoWorker().
## The background job runner calls it once in its own worker thread before
## waiting for jobs, so the first upload does not pay the HEF loading cost.

import hailort_nim
import std/[locks, os, strformat]

import ../config
import ../media/convert
import ../types as appTypes
import ./yolo

const
  DefaultAppScoreThreshold = 0.25'f32
  DefaultHailoNmsScoreThreshold = 0.20'f32

var
  gLock: Lock
  gLockReady = false
  gDetector: hailort_nim.Detector
  gOutputBuf: seq[byte]
  gRawDetections: seq[hailort_nim.Detection]

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
