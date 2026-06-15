## Pixie based drawing helpers.
##
## JPEG jobs generate the real 640x640 RGB/NHWC YOLO input buffer, run
## HAILO YOLOv11s inference, restore boxes to original image coordinates, and
## draw bbox/label overlays.
##
## This module also measures the expensive stages so the web demo can show
## whether time is spent in JPEG decode/encode, preprocessing, HAILO inference,
## or drawing.

import pixie
import std/[math, os, strformat, times]

import ../infer/hailo_worker
import ../media/[convert, jpeg]
import ../types

const
  LabelFontSize = 18.float32
  LabelHeight = 24.float32
  LabelPadX = 6.float32
  BoxThickness = 4.float32

type
  OverlayStats* = object
    imageWidth*: int
    imageHeight*: int
    detections*: int
    decodeMs*: int
    letterboxMs*: int
    inferMs*: int
    drawMs*: int
    encodeMs*: int
    totalMs*: int

proc elapsedMs(start: float): int =
  result = int((epochTime() - start) * 1000.0 + 0.5)
  if result < 0:
    result = 0

proc formatOverlayStats*(s: OverlayStats): string =
  &"detections={s.detections}, image={s.imageWidth}x{s.imageHeight}, total={s.totalMs} ms " &
  &"(decode={s.decodeMs}, letterbox={s.letterboxMs}, infer={s.inferMs}, draw={s.drawMs}, encode={s.encodeMs})"

proc clampf(v, lo, hi: float32): float32 =
  result = max(lo, min(v, hi))

proc clampDetection(d: Detection; imageW, imageH: int): Detection =
  let
    maxX = max(0.float32, imageW.float32 - 1.float32)
    maxY = max(0.float32, imageH.float32 - 1.float32)

  result = d
  result.x = clampf(d.x, 0, maxX)
  result.y = clampf(d.y, 0, maxY)
  result.w = clampf(d.w, 1, imageW.float32 - result.x)
  result.h = clampf(d.h, 1, imageH.float32 - result.y)

proc setClassColor(ctx: Context; classId: int) =
  case classId mod 4
  of 0:
    ctx.fillStyle = rgba(31, 136, 61, 255)
  of 1:
    ctx.fillStyle = rgba(9, 105, 218, 255)
  of 2:
    ctx.fillStyle = rgba(191, 135, 0, 255)
  else:
    ctx.fillStyle = rgba(130, 80, 223, 255)

proc drawStrokeRect(ctx: Context; d: Detection) =
  let
    x = d.x
    y = d.y
    w = d.w
    h = d.h
    t = min(BoxThickness, min(w, h) / 3.float32)

  ctx.fillRect(rect(vec2(x, y), vec2(w, t)))
  ctx.fillRect(rect(vec2(x, y + h - t), vec2(w, t)))
  ctx.fillRect(rect(vec2(x, y), vec2(t, h)))
  ctx.fillRect(rect(vec2(x + w - t, y), vec2(t, h)))

proc drawLabel(image: Image; ctx: Context; font: Font; d: Detection) =
  let
    text = &"{d.label} {int(round(d.score * 100.float32))}%"
    labelW = max(72.float32, text.len.float32 * 9.float32 + LabelPadX * 2.float32)
    x = d.x
    y = if d.y >= LabelHeight + 2.float32: d.y - LabelHeight else: d.y

  ## Background uses the currently selected class color.
  ctx.fillRect(rect(vec2(x, y), vec2(labelW, LabelHeight)))

  var textFont = font
  textFont.size = LabelFontSize
  textFont.paint.color = color(1, 1, 1)
  image.fillText(
    textFont.typeset(text, vec2(labelW - LabelPadX * 2.float32, LabelHeight)),
    translate(vec2(x + LabelPadX, y + 2.float32))
  )

proc drawDetections*(image: Image; detections: openArray[Detection]; fontPath: string) =
  let ctx = newContext(image)

  var font: Font
  var hasFont = false
  if fontPath.len > 0 and fileExists(fontPath):
    try:
      font = readFont(fontPath)
      hasFont = true
    except CatchableError:
      hasFont = false

  for raw in detections:
    let d = raw.clampDetection(image.width, image.height)
    ctx.setClassColor(d.classId)
    ctx.drawStrokeRect(d)
    if hasFont:
      ctx.setClassColor(d.classId)
      image.drawLabel(ctx, font, d)

proc drawHailoOverlay*(inputPath, outputPath, fontPath: string): OverlayStats =
  let totalStart = epochTime()

  var stageStart = epochTime()
  var image = readImage(inputPath)
  result.decodeMs = elapsedMs(stageStart)
  result.imageWidth = image.width
  result.imageHeight = image.height

  ## yoloInput.rgb.data is the 640x640 packed RGB/NHWC3 buffer passed to HAILO.
  stageStart = epochTime()
  let yoloInput = image.prepareYoloInput()
  result.letterboxMs = elapsedMs(stageStart)

  stageStart = epochTime()
  let detections = yoloInput.detectYolo()
  result.inferMs = elapsedMs(stageStart)
  result.detections = detections.len

  stageStart = epochTime()
  image.drawDetections(detections, fontPath)
  result.drawMs = elapsedMs(stageStart)

  stageStart = epochTime()
  image.encodeImageToJpeg(outputPath)
  result.encodeMs = elapsedMs(stageStart)

  result.totalMs = elapsedMs(totalStart)
