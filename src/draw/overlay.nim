## Pixie based drawing helpers.
##
## JPEG jobs generate the 640x640 RGB/NHWC YOLO input buffer from TurboJPEG
## decoded RGBX pixels. MP4 preview jobs decode one I420 frame via libav_nim and
## build the YOLO input directly from that I420 frame.

import pixie
import std/[math, os, strformat, strutils, times]

import ../infer/hailo_worker
import ../media/[convert, jpeg, mp4]
import ../types

const
  LabelFontSize = 18.float32
  LabelHeight = 24.float32
  LabelPadX = 6.float32
  BoxThickness = 4.float32

  ## Keep small and crowded detections readable: draw all boxes, but only
  ## annotate boxes large enough for a useful label.
  MinLabelBoxHeight = 64.float32
  MinLabelBoxArea = 3000.float32
  MaxLabels = 12

type
  OverlayStats* = object
    imageWidth*: int
    imageHeight*: int
    detections*: int
    labelsDrawn*: int
    decodeMs*: int
    decoderOpenMs*: int
    readFrameMs*: int
    readFramesMs*: seq[int]
    previewFrameIndex*: int
    requestedProbeFrames*: int
    decoderName*: string
    letterboxMs*: int
    inferMs*: int
    rgbxMs*: int
    drawMs*: int
    encodeMs*: int
    totalMs*: int

proc elapsedMs(start: float): int =
  result = int((epochTime() - start) * 1000.0 + 0.5)
  if result < 0:
    result = 0

proc formatReadFramesMs(values: openArray[int]): string =
  if values.len == 0:
    return ""

  var parts: seq[string] = @[]
  for value in values:
    parts.add($value)

  result = parts.join("/")

proc formatOverlayStats*(s: OverlayStats): string =
  let base = &"detections={s.detections}, labels={s.labelsDrawn}, image={s.imageWidth}x{s.imageHeight}, total={s.totalMs} ms "

  if s.decoderOpenMs > 0 or s.readFrameMs > 0 or s.rgbxMs > 0:
    let
      overlayMs = max(0, s.drawMs - s.rgbxMs)
      decoderLabel = if s.decoderName.len > 0: s.decoderName else: "auto"
      readDetail = if s.readFramesMs.len > 1:
          &"reads={formatReadFramesMs(s.readFramesMs)}, frame={s.previewFrameIndex}"
        else:
          &"read={s.readFrameMs}"
    result = base &
      &"(decode={s.decodeMs}[decoder={decoderLabel}, open={s.decoderOpenMs}, {readDetail}], " &
      &"letterbox={s.letterboxMs}, infer={s.inferMs}, " &
      &"draw={s.drawMs}[rgbx={s.rgbxMs}, overlay={overlayMs}], encode={s.encodeMs})"
  else:
    result = base &
      &"(decode={s.decodeMs}, letterbox={s.letterboxMs}, infer={s.inferMs}, " &
      &"draw={s.drawMs}, encode={s.encodeMs})"

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

proc shouldDrawLabel(d: Detection; labelsDrawn: int): bool =
  if labelsDrawn >= MaxLabels:
    return false

  let area = d.w * d.h
  result = d.h >= MinLabelBoxHeight and area >= MinLabelBoxArea

proc drawDetections*(image: Image; detections: openArray[Detection]; fontPath: string): int =
  let ctx = newContext(image)

  var font: Font
  var hasFont = false
  if fontPath.len > 0 and fileExists(fontPath):
    try:
      font = readFont(fontPath)
      hasFont = true
    except CatchableError:
      hasFont = false

  var labelsDrawn = 0

  for raw in detections:
    let d = raw.clampDetection(image.width, image.height)
    ctx.setClassColor(d.classId)
    ctx.drawStrokeRect(d)
    if hasFont and d.shouldDrawLabel(labelsDrawn):
      ctx.setClassColor(d.classId)
      image.drawLabel(ctx, font, d)
      inc labelsDrawn

  result = labelsDrawn

proc finishOverlay(
    image: var Image;
    yoloInput: YoloInputImage;
    outputPath, fontPath: string;
    stats: var OverlayStats;
    totalStart: float
  ) =
  stats.imageWidth = image.width
  stats.imageHeight = image.height

  var stageStart = epochTime()
  let detections = yoloInput.detectYolo()
  stats.inferMs = elapsedMs(stageStart)
  stats.detections = detections.len

  stageStart = epochTime()
  stats.labelsDrawn = image.drawDetections(detections, fontPath)
  stats.drawMs += elapsedMs(stageStart)

  stageStart = epochTime()
  image.encodeImageToJpeg(outputPath)
  stats.encodeMs = elapsedMs(stageStart)

  stats.totalMs = elapsedMs(totalStart)

proc drawHailoOverlay*(inputPath, outputPath, fontPath: string): OverlayStats =
  let totalStart = epochTime()

  var stageStart = epochTime()
  var image = readJpegToPixieImage(inputPath)
  result.decodeMs = elapsedMs(stageStart)

  ## yoloInput.rgb.data is the 640x640 packed RGB/NHWC3 buffer passed to HAILO.
  stageStart = epochTime()
  let yoloInput = image.prepareYoloInput()
  result.letterboxMs = elapsedMs(stageStart)

  image.finishOverlay(yoloInput, outputPath, fontPath, result, totalStart)

proc drawMp4PreviewOverlay*(inputPath, outputPath, fontPath: string): OverlayStats =
  ## Decode one MP4 frame with libav_nim and render it as a JPEG preview with
  ## HAILO detections.
  ##
  ## Timing mapping:
  ##   decode    : libav open/read first decoded I420 frame
  ##   letterbox : I420 -> 640x640 RGB24 YOLO input
  ##   draw      : I420 -> full-size RGBX preview + bbox/label drawing
  let totalStart = epochTime()

  let preview = decodeMp4PreviewFrame(inputPath)
  var image = preview.image
  result.decodeMs = preview.decodeMs
  result.decoderOpenMs = preview.decoderOpenMs
  result.readFrameMs = preview.readFrameMs
  result.readFramesMs = preview.readFramesMs
  result.previewFrameIndex = preview.frameIndex
  result.requestedProbeFrames = preview.requestedProbeFrames
  result.decoderName = preview.decoderName
  result.letterboxMs = preview.letterboxMs
  result.rgbxMs = preview.rgbxMs
  result.drawMs = preview.rgbxMs

  image.finishOverlay(preview.yoloInput, outputPath, fontPath, result, totalStart)
