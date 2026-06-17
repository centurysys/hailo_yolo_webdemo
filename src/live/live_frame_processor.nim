## Shared live frame processing helpers.
##
## This module is the small bridge between the existing MP4 frame path and the
## live RTSP path.  It operates on an already decoded YUV420 frame and uses the
## same conversion and HAILO inference helpers that the MP4 overlay pipeline uses.
##
## The synchronous helper is kept for correctness checks.  Throughput-oriented
## live probes should use submitYoloAsync()/waitYoloAsync() directly, matching
## the MP4 threaded pipeline.

import std/[strformat, times]

import libav_nim

import ../infer/hailo_worker
import ../media/convert
import ../types

type
  LiveFrameProcessStats* = object
    ok*: bool
    frameIndex*: int
    width*: int
    height*: int
    letterboxMs*: int
    inferMs*: int
    totalMs*: int
    detections*: int
    boxesOverThreshold*: int
    maxScorePercent*: int
    message*: string

proc elapsedMs*(start: float): int =
  result = int((epochTime() - start) * 1000.0 + 0.5)
  if result < 0:
    result = 0

proc countBoxesOverThreshold*(detections: openArray[Detection]; threshold: float32): int =
  for d in detections:
    if d.score >= threshold:
      inc result

proc maxScorePercent*(detections: openArray[Detection]): int =
  var maxScore = 0.0'f32
  for d in detections:
    if d.score > maxScore:
      maxScore = d.score
  result = int(maxScore * 100.0'f32 + 0.5'f32)

proc processLiveYuv420Frame*(frame: Yuv420FrameView; frameIndex: int): LiveFrameProcessStats =
  ## Convert one decoded live frame to YOLO input and run the synchronous HAILO
  ## detector path.
  ##
  ## This is useful as a simple correctness probe, but it does not match the
  ## high-throughput MP4 video path because detectYolo() exposes the full
  ## write/read/parse latency to the caller.
  let totalStart = epochTime()

  result.frameIndex = frameIndex
  result.width = frame.width
  result.height = frame.height

  try:
    var stageStart = epochTime()
    var yoloInput = frame.prepareYoloInput()
    result.letterboxMs = elapsedMs(stageStart)

    stageStart = epochTime()
    let detections = yoloInput.detectYolo()
    result.inferMs = elapsedMs(stageStart)

    result.totalMs = elapsedMs(totalStart)
    result.detections = detections.len
    result.boxesOverThreshold = detections.countBoxesOverThreshold(0.25'f32)
    result.maxScorePercent = detections.maxScorePercent()
    result.ok = true
    result.message = &"frame#{frameIndex}: {frame.width}x{frame.height}, detections={detections.len}, letterbox={result.letterboxMs} ms, infer={result.inferMs} ms"

  except CatchableError as e:
    result.totalMs = elapsedMs(totalStart)
    result.ok = false
    result.message = &"frame#{frameIndex}: live frame processing failed: {e.msg}"
