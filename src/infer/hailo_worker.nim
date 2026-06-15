## Thin HailoRT detector wrapper.
##
## This is still a synchronous worker-facing API.  It opens Detector once and
## reuses output/detection buffers across JPEG jobs.  A later step can move this
## behind a dedicated threadtools queue without changing draw/overlay.nim.

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
  ## Main calls this during startup.  Keep it idempotent so tests and future
  ## service reload paths can call it safely.
  if not gLockReady:
    initLock(gLock)
    gLockReady = true

proc closeHailoWorker*() =
  if not gLockReady:
    return

  withLock gLock:
    if not gDetector.isNil:
      let closeRes = gDetector.close()
      if closeRes.isErr:
        echo &"warning: failed to close HAILO detector: {closeRes.error}"
      gDetector = nil
      gOutputBuf.setLen(0)
      gRawDetections.setLen(0)

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
