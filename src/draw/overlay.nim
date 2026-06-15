## Pixie based drawing helpers.
##
## JPEG jobs generate the 640x640 RGB/NHWC YOLO input buffer from TurboJPEG
## decoded RGBX pixels. MP4 preview jobs decode one I420 frame via libav_nim and
## build the YOLO input directly from that I420 frame.

import pixie
import std/[algorithm, math, os, strformat, strutils, times]

import libav_nim
import threadtools

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
    boxesDrawn*: int
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
    inferSubmitMs*: int
    inferWaitMs*: int
    inferOverlapMs*: int
    hailoWriteUs*: int64
    hailoReadUs*: int64
    hailoParseUs*: int64
    hailoSortUs*: int64
    pipelineFrames*: int
    pipelineSubmitted*: int
    pipelineReplies*: int
    pipelineInFlight*: int
    letterboxFramesMs*: seq[int]
    inferSubmitFramesMs*: seq[int]
    inferWaitFramesMs*: seq[int]
    rgbxFramesMs*: seq[int]
    rgbxMs*: int
    drawMs*: int
    encodeMs*: int
    encoderOpenMs*: int
    writerOpenMs*: int
    encoderFlushMs*: int
    writerFinishMs*: int
    videoFrames*: int
    videoPackets*: int
    videoPacketBytes*: int64
    totalMs*: int

  OverlayProgressCallback* = proc(ctx: pointer; progress: int; message: string) {.gcsafe.}

  OverlayDrawOptions* = object
    maxBoxes: int
    maxLabels: int
    minBoxScore: float32
    minLabelScore: float32
    minLabelBoxHeight: float32
    minLabelBoxArea: float32

  OverlayDrawResult* = object
    boxes*: int
    labels*: int

proc parseEnvIntDraw(name: string; defaultValue: int): int =
  let raw = getEnv(name, "").strip()
  if raw.len == 0:
    return defaultValue

  try:
    result = parseInt(raw)
  except ValueError:
    result = defaultValue

proc parseEnvFloat32Draw(name: string; defaultValue: float32): float32 =
  let raw = getEnv(name, "").strip()
  if raw.len == 0:
    return defaultValue

  try:
    result = parseFloat(raw).float32
  except ValueError:
    result = defaultValue

proc resolveStillDrawOptions(): OverlayDrawOptions =
  ## Still image/JPEG preview defaults keep the existing behavior: draw all
  ## boxes, but cap labels so crowded images remain readable.
  result.maxBoxes = parseEnvIntDraw("HAILO_DEMO_MAX_BOXES", 0)
  result.maxLabels = max(0, parseEnvIntDraw("HAILO_DEMO_MAX_LABELS", MaxLabels))
  result.minBoxScore = parseEnvFloat32Draw("HAILO_DEMO_MIN_BOX_SCORE", 0.0.float32)
  result.minLabelScore = parseEnvFloat32Draw("HAILO_DEMO_MIN_LABEL_SCORE", 0.0.float32)
  result.minLabelBoxHeight = parseEnvFloat32Draw("HAILO_DEMO_MIN_LABEL_BOX_HEIGHT", MinLabelBoxHeight)
  result.minLabelBoxArea = parseEnvFloat32Draw("HAILO_DEMO_MIN_LABEL_BOX_AREA", MinLabelBoxArea)

proc resolveVideoDrawOptions(): OverlayDrawOptions =
  ## Video defaults are intentionally more conservative than still images.
  ## In crowded scenes, drawing every label makes the output noisy and dominates
  ## CPU time.  Environment variables can loosen or tighten this policy.
  result.maxBoxes = parseEnvIntDraw("HAILO_DEMO_VIDEO_MAX_BOXES", 12)
  result.maxLabels = max(0, parseEnvIntDraw("HAILO_DEMO_VIDEO_MAX_LABELS", 6))
  result.minBoxScore = parseEnvFloat32Draw("HAILO_DEMO_VIDEO_MIN_BOX_SCORE", 0.25.float32)
  result.minLabelScore = parseEnvFloat32Draw("HAILO_DEMO_VIDEO_MIN_LABEL_SCORE", 0.50.float32)
  result.minLabelBoxHeight = parseEnvFloat32Draw("HAILO_DEMO_VIDEO_MIN_LABEL_BOX_HEIGHT", 96.0.float32)
  result.minLabelBoxArea = parseEnvFloat32Draw("HAILO_DEMO_VIDEO_MIN_LABEL_BOX_AREA", 8000.0.float32)

proc elapsedMs(start: float): int =
  result = int((epochTime() - start) * 1000.0 + 0.5)
  if result < 0:
    result = 0

proc verboseFrameTimings(): bool =
  let raw = getEnv("HAILO_DEMO_VERBOSE_TIMINGS", "0").toLowerAscii()
  result = raw in ["1", "true", "yes", "on"]

proc formatReadFramesMs(values: openArray[int]): string =
  if values.len == 0:
    return ""

  var parts: seq[string] = @[]
  for value in values:
    parts.add($value)

  result = parts.join("/")

proc formatFrameMsSummary(values: openArray[int]): string =
  ## Keep job result messages readable for real video jobs.  Per-frame timing
  ## arrays can easily contain hundreds of entries; summarize by default and
  ## allow the old verbose form only when explicitly requested.
  if values.len == 0:
    return ""
  if values.len <= 12 or verboseFrameTimings():
    return formatReadFramesMs(values)

  var
    sum = 0
    minValue = values[0]
    maxValue = values[0]

  for value in values:
    sum += value
    if value < minValue:
      minValue = value
    if value > maxValue:
      maxValue = value

  var firstParts: seq[string] = @[]
  let firstCount = min(values.len, 6)
  for i in 0 ..< firstCount:
    firstParts.add($values[i])

  let firstDetail = firstParts.join("/")
  result = &"n:{values.len}/sum:{sum}/avg:{sum div values.len}/min:{minValue}/max:{maxValue}/first:{firstDetail}"

proc notifyProgress(
    onProgress: OverlayProgressCallback;
    progressCtx: pointer;
    progress: int;
    message: string
  ) {.gcsafe.} =
  if onProgress != nil:
    onProgress(progressCtx, progress, message)


proc formatBytes(value: int64): string =
  if value >= 1024'i64 * 1024'i64:
    result = &"{float(value) / (1024.0 * 1024.0):.2f}MiB"
  elif value >= 1024'i64:
    result = &"{float(value) / 1024.0:.1f}KiB"
  else:
    result = &"{value}B"

proc formatInferStats(s: OverlayStats): string =
  if s.inferSubmitMs > 0 or s.inferWaitMs > 0:
    let hailoDetail =
      if s.hailoWriteUs > 0 or s.hailoReadUs > 0 or s.hailoParseUs > 0 or s.hailoSortUs > 0:
        &", hailo_us=write:{s.hailoWriteUs}/read:{s.hailoReadUs}/parse:{s.hailoParseUs}/sort:{s.hailoSortUs}"
      else:
        ""
    result = &"infer={s.inferMs}[submit={s.inferSubmitMs}, wait={s.inferWaitMs}, overlap={s.inferOverlapMs}{hailoDetail}]"
  else:
    result = &"infer={s.inferMs}"

proc formatPipelineStats(s: OverlayStats): string =
  if s.pipelineFrames <= 1:
    return ""

  let letterboxDetail =
    if s.letterboxFramesMs.len > 0:
      &", letterboxes={formatFrameMsSummary(s.letterboxFramesMs)}"
    else:
      ""
  let submitDetail =
    if s.inferSubmitFramesMs.len > 0:
      &", submits={formatFrameMsSummary(s.inferSubmitFramesMs)}"
    else:
      ""
  let waitDetail =
    if s.inferWaitFramesMs.len > 0:
      &", waits={formatFrameMsSummary(s.inferWaitFramesMs)}"
    else:
      ""
  let rgbxDetail =
    if s.rgbxFramesMs.len > 0:
      &", rgbx={formatFrameMsSummary(s.rgbxFramesMs)}"
    else:
      ""

  let inFlightDetail =
    if s.pipelineInFlight > 1:
      &"/inflight:{s.pipelineInFlight}"
    else:
      ""

  result = &", pipeline=frames:{s.pipelineFrames}/submitted:{s.pipelineSubmitted}/replies:{s.pipelineReplies}{inFlightDetail}{letterboxDetail}{submitDetail}{waitDetail}{rgbxDetail}"

proc formatOverlayStats*(s: OverlayStats): string =
  let drawCountDetail =
    if s.detections > 0 or s.boxesDrawn > 0 or s.labelsDrawn > 0:
      &", boxes={s.boxesDrawn}, labels={s.labelsDrawn}"
    else:
      ""
  let base = &"detections={s.detections}{drawCountDetail}, image={s.imageWidth}x{s.imageHeight}, total={s.totalMs} ms "
  let inferDetail = s.formatInferStats()
  let pipelineDetail = s.formatPipelineStats()

  if s.videoFrames > 0:
    let decoderLabel = if s.decoderName.len > 0: s.decoderName else: "auto"
    result = base &
      &"(video=frames:{s.videoFrames}/packets:{s.videoPackets}/bytes:{formatBytes(s.videoPacketBytes)}, " &
      &"decode={s.decodeMs}[decoder={decoderLabel}, open={s.decoderOpenMs}, reads={formatFrameMsSummary(s.readFramesMs)}], " &
      &"letterbox={s.letterboxMs}, {inferDetail}{pipelineDetail}, " &
      &"draw={s.drawMs}[rgbx={s.rgbxMs}, overlay={max(0, s.drawMs - s.rgbxMs)}], " &
      &"encode={s.encodeMs}[open={s.encoderOpenMs}, writer={s.writerOpenMs}, flush={s.encoderFlushMs}, finish={s.writerFinishMs}])"
    return

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
      &"letterbox={s.letterboxMs}, {inferDetail}{pipelineDetail}, " &
      &"draw={s.drawMs}[rgbx={s.rgbxMs}, overlay={overlayMs}], encode={s.encodeMs})"
  else:
    result = base &
      &"(decode={s.decodeMs}, letterbox={s.letterboxMs}, {inferDetail}{pipelineDetail}, " &
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

proc shouldDrawLabel(d: Detection; labelsDrawn: int; options: OverlayDrawOptions): bool =
  if labelsDrawn >= options.maxLabels:
    return false
  if d.score < options.minLabelScore:
    return false

  let area = d.w * d.h
  result = d.h >= options.minLabelBoxHeight and area >= options.minLabelBoxArea

proc shouldDrawBox(d: Detection; boxesDrawn: int; options: OverlayDrawOptions): bool =
  if options.maxBoxes > 0 and boxesDrawn >= options.maxBoxes:
    return false
  result = d.score >= options.minBoxScore

proc loadOverlayFont(fontPath: string): tuple[font: Font, hasFont: bool] =
  if fontPath.len > 0 and fileExists(fontPath):
    try:
      result.font = readFont(fontPath)
      result.hasFont = true
    except CatchableError:
      result.hasFont = false

proc drawDetectionsLoadedFont(
    image: Image;
    detections: openArray[Detection];
    font: Font;
    hasFont: bool;
    options: OverlayDrawOptions
  ): OverlayDrawResult =
  let ctx = newContext(image)
  var
    boxesDrawn = 0
    labelsDrawn = 0
    sorted: seq[Detection] = @[]

  for raw in detections:
    if raw.score >= options.minBoxScore:
      sorted.add(raw)

  sorted.sort(proc(a, b: Detection): int =
    if a.score < b.score:
      1
    elif a.score > b.score:
      -1
    else:
      0
  )

  for raw in sorted:
    let d = raw.clampDetection(image.width, image.height)
    if not d.shouldDrawBox(boxesDrawn, options):
      continue

    ctx.setClassColor(d.classId)
    ctx.drawStrokeRect(d)
    inc boxesDrawn

    if hasFont and d.shouldDrawLabel(labelsDrawn, options):
      ctx.setClassColor(d.classId)
      image.drawLabel(ctx, font, d)
      inc labelsDrawn

  result.boxes = boxesDrawn
  result.labels = labelsDrawn

proc drawDetectionsWithOptions(
    image: Image;
    detections: openArray[Detection];
    fontPath: string;
    options: OverlayDrawOptions
  ): OverlayDrawResult =
  let loaded = loadOverlayFont(fontPath)
  result = image.drawDetectionsLoadedFont(detections, loaded.font, loaded.hasFont, options)

proc drawDetections*(image: Image; detections: openArray[Detection]; fontPath: string): OverlayDrawResult =
  result = image.drawDetectionsWithOptions(detections, fontPath, resolveStillDrawOptions())

static:
  doAssert sizeof(PixelRGBX) == sizeof(ColorRGBX)

proc requirePackedRgbx(frame: OwnedRGBXFrame) =
  if not frame.isValid():
    raise newException(ValueError, "RGBX frame is invalid")
  if frame.stridePixels != frame.width:
    raise newException(
      ValueError,
      &"Pixie zero-copy adapter requires packed RGBX: stridePixels={frame.stridePixels} width={frame.width}"
    )
  if frame.data.len != frame.width * frame.height:
    raise newException(
      ValueError,
      &"Pixie zero-copy adapter requires exact data size: data.len={frame.data.len} expected={frame.width * frame.height}"
    )

proc moveRgbxDataToPixieImage(frame: var OwnedRGBXFrame): Image =
  ## Move OwnedRGBXFrame.data into a Pixie Image so bbox/label drawing can use
  ## the same Pixie overlay code as the JPEG preview path without a full-frame
  ## copy.  The frame must be moved back before it is passed to the encoder.
  frame.requirePackedRgbx()
  result = Image()
  result.width = frame.width
  result.height = frame.height
  result.data = move cast[ptr seq[ColorRGBX]](addr frame.data)[]

proc movePixieImageDataBack(image: var Image; frame: var OwnedRGBXFrame) =
  frame.data = move cast[ptr seq[PixelRGBX]](addr image.data)[]

proc drawDetectionsOnRgbxFrame(
    frame: var OwnedRGBXFrame;
    detections: openArray[Detection];
    font: Font;
    hasFont: bool;
    options: OverlayDrawOptions
  ): OverlayDrawResult =
  var image = moveRgbxDataToPixieImage(frame)
  try:
    result = image.drawDetectionsLoadedFont(detections, font, hasFont, options)
  finally:
    movePixieImageDataBack(image, frame)

proc finishOverlayWithDetections(
    image: var Image;
    detections: openArray[Detection];
    outputPath, fontPath: string;
    stats: var OverlayStats;
    totalStart: float
  ) =
  stats.imageWidth = image.width
  stats.imageHeight = image.height
  stats.detections = detections.len

  var stageStart = epochTime()
  let drawResult = image.drawDetections(detections, fontPath)
  stats.boxesDrawn = drawResult.boxes
  stats.labelsDrawn = drawResult.labels
  stats.drawMs += elapsedMs(stageStart)

  stageStart = epochTime()
  image.encodeImageToJpeg(outputPath)
  stats.encodeMs = elapsedMs(stageStart)

  stats.totalMs = elapsedMs(totalStart)

proc finishOverlay(
    image: var Image;
    yoloInput: YoloInputImage;
    outputPath, fontPath: string;
    stats: var OverlayStats;
    totalStart: float
  ) =
  var stageStart = epochTime()
  let detections = yoloInput.detectYolo()
  stats.inferMs = elapsedMs(stageStart)

  image.finishOverlayWithDetections(detections, outputPath, fontPath, stats, totalStart)

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

proc useMp4OverlapPipeline(): bool =
  let raw = getEnv("HAILO_DEMO_MP4_OVERLAP", "1").toLowerAscii()
  result = raw notin ["0", "false", "no", "off"]

proc useMp4PipelineProbe(): bool =
  ## Experimental multi-frame path.  It still writes one JPEG preview, but it
  ## submits each decoded frame to the HAILO worker with a frameNo/requestId.
  let raw = getEnv("HAILO_DEMO_MP4_PIPELINE_PROBE", "0").toLowerAscii()
  result = raw in ["1", "true", "yes", "on"]

proc drawMp4PreviewOverlayPipelined(inputPath, outputPath, fontPath: string): OverlayStats =
  ## Decode one representative MP4 frame, submit HAILO inference as soon as the
  ## 640x640 YOLO input is ready, then build the full-size RGBX preview while
  ## the HAILO worker is reading/parsing the output.
  ##
  ## Output remains one JPEG preview.  Only the internal scheduling changes.
  let totalStart = epochTime()

  var decoded = openMp4PreviewDecodedFrame(inputPath)
  defer: decoded.close()

  result.decodeMs = decoded.decodeMs
  result.decoderOpenMs = decoded.decoderOpenMs
  result.readFrameMs = decoded.readFrameMs
  result.readFramesMs = decoded.readFramesMs
  result.previewFrameIndex = decoded.frameIndex
  result.requestedProbeFrames = decoded.requestedProbeFrames
  result.decoderName = decoded.decoderName

  var stageStart = epochTime()
  var yoloInput = decoded.read.frame.prepareYoloInput()
  result.letterboxMs = elapsedMs(stageStart)

  let pending = yoloInput.submitYoloAsync(uint64(decoded.frameIndex))
  result.inferSubmitMs = pending.submitMs

  stageStart = epochTime()
  var image = decoded.read.frame.yuv420FrameToPixieImage()
  result.rgbxMs = elapsedMs(stageStart)
  result.drawMs = result.rgbxMs

  let yoloResult = pending.waitYoloAsync()
  result.inferMs = yoloResult.totalMs
  result.inferWaitMs = yoloResult.waitMs
  result.inferOverlapMs = max(0, yoloResult.totalMs - pending.submitMs - yoloResult.waitMs)
  result.hailoWriteUs = yoloResult.writeUs
  result.hailoReadUs = yoloResult.readUs
  result.hailoParseUs = yoloResult.parseUs
  result.hailoSortUs = yoloResult.sortUs

  image.finishOverlayWithDetections(
    yoloResult.detections,
    outputPath,
    fontPath,
    result,
    totalStart
  )

proc drawMp4PreviewOverlayPipelineProbe(inputPath, outputPath, fontPath: string): OverlayStats =
  ## Multi-frame MP4 preview probe.
  ##
  ## This still writes only one JPEG preview: the last decoded probe frame.
  ## Internally, however, each decoded frame is converted to a YOLO input and
  ## submitted to the HAILO threadtools worker with requestId=frameNo.  The full
  ## RGBX preview conversion is done after each submit so HAILO output read/parse
  ## can progress while the CPU prepares overlay frames.
  let totalStart = epochTime()

  var reader = openMp4PreviewDecoder(inputPath)
  defer: reader.close()

  result.decoderOpenMs = reader.decoderOpenMs
  result.decoderName = reader.decoderName
  result.requestedProbeFrames = mp4PreviewProbeFrames()
  result.pipelineFrames = result.requestedProbeFrames

  var
    pendings: seq[YoloAsyncPending] = @[]
    selectedImage: Image
    selectedFrameIndex = -1

  for _ in 0 ..< result.requestedProbeFrames:
    let frameRead = reader.readNextFrame()
    if frameRead.eof:
      if pendings.len == 0:
        raise newException(IOError, &"MP4 has no decodable video frame: {inputPath}")
      break

    result.readFramesMs.add(frameRead.readMs)
    result.readFrameMs += frameRead.readMs
    result.previewFrameIndex = frameRead.frameIndex
    result.imageWidth = frameRead.frameWidth
    result.imageHeight = frameRead.frameHeight

    var stageStart = epochTime()
    var yoloInput = frameRead.read.frame.prepareYoloInput()
    let letterboxMs = elapsedMs(stageStart)
    result.letterboxFramesMs.add(letterboxMs)
    result.letterboxMs += letterboxMs

    let pending = yoloInput.submitYoloAsync(uint64(frameRead.frameIndex))
    result.inferSubmitFramesMs.add(pending.submitMs)
    pendings.add(pending)
    inc result.pipelineSubmitted

    ## Keep only the newest preview image.  Replacing this Image drops the
    ## previous ref and mirrors the future video path: every decoded frame can
    ## become an overlay candidate, while this demo still publishes one JPEG.
    stageStart = epochTime()
    selectedImage = frameRead.read.frame.yuv420FrameToPixieImage()
    let rgbxMs = elapsedMs(stageStart)
    result.rgbxFramesMs.add(rgbxMs)
    result.rgbxMs += rgbxMs
    result.drawMs = result.rgbxMs
    selectedFrameIndex = frameRead.frameIndex

  if pendings.len == 0 or selectedImage.isNil or selectedFrameIndex < 0:
    raise newException(IOError, &"MP4 has no decodable video frame: {inputPath}")

  result.decodeMs = result.decoderOpenMs + result.readFrameMs
  result.pipelineFrames = pendings.len

  var selectedDetections: seq[Detection] = @[]
  var haveSelectedDetections = false

  for pending in pendings:
    let yoloResult = pending.waitYoloAsync()
    inc result.pipelineReplies
    result.inferWaitFramesMs.add(yoloResult.waitMs)

    if int(yoloResult.requestId) == selectedFrameIndex:
      result.inferMs = yoloResult.totalMs
      result.inferSubmitMs = pending.submitMs
      result.inferWaitMs = yoloResult.waitMs
      result.inferOverlapMs = max(0, yoloResult.totalMs - pending.submitMs - yoloResult.waitMs)
      result.hailoWriteUs = yoloResult.writeUs
      result.hailoReadUs = yoloResult.readUs
      result.hailoParseUs = yoloResult.parseUs
      result.hailoSortUs = yoloResult.sortUs
      selectedDetections = yoloResult.detections
      haveSelectedDetections = true

  if not haveSelectedDetections:
    raise newException(IOError, &"HAILO result for preview frame was not received: frame={selectedFrameIndex}")

  selectedImage.finishOverlayWithDetections(
    selectedDetections,
    outputPath,
    fontPath,
    result,
    totalStart
  )


proc alignUp(value, alignment: int): int =
  if alignment <= 0:
    return value
  result = ((value + alignment - 1) div alignment) * alignment

proc parseEnvInt(name: string; defaultValue: int): int =
  let raw = getEnv(name, "").strip()
  if raw.len == 0:
    return defaultValue

  try:
    result = parseInt(raw)
  except ValueError:
    result = defaultValue

proc resolveMp4VideoEncoderName(): string =
  result = getEnv("HAILO_DEMO_MP4_ENCODER", "h264_v4l2m2m").strip()
  if result.len == 0:
    result = "h264_v4l2m2m"

proc resolveMp4VideoInFlight(): int =
  ## Number of decoded/RGBX frames kept ahead of the oldest HAILO reply.
  ## A value of 2 matches the current HAILO worker slot count and is enough to
  ## hide one frame's letterbox/RGBX work behind the previous frame's output
  ## read.  Higher values are allowed for experiments, but each 1280x720 RGBX
  ## frame costs about 3.5 MiB.
  result = max(1, parseEnvInt("HAILO_DEMO_MP4_INFLIGHT", 2))
  result = min(result, 8)

proc checkFFmpeg[T](ret: FFmpegResult[T]; context: string): T =
  if ret.isErr:
    raise newException(IOError, &"{context}: {ret.error.message}")
  result = ret.value

proc checkFFmpegVoid(ret: FFmpegResult[void]; context: string) =
  if ret.isErr:
    raise newException(IOError, &"{context}: {ret.error.message}")

type
  PendingVideoFrame = object
    frameIndex: int
    pending: YoloAsyncPending
    rgbx: OwnedRGBXFrame

proc acquireRgbxFrame(
    pool: var seq[OwnedRGBXFrame];
    width, height: int
  ): FFmpegResult[OwnedRGBXFrame] =
  while pool.len > 0:
    var frame = move pool[pool.high]
    pool.setLen(pool.len - 1)
    if frame.isValid() and frame.width == width and frame.height == height:
      return ok(move frame)

  result = newOwnedRGBXFrame(width, height)

proc notifyVideoFrameProgress(
    onProgress: OverlayProgressCallback;
    progressCtx: pointer;
    stats: OverlayStats;
    maxFrames: int
  ) {.gcsafe.} =
  if stats.videoFrames <= 0:
    return
  if not (stats.videoFrames == 1 or (stats.videoFrames mod 10) == 0):
    return

  let progress =
    if maxFrames > 0:
      min(95, 30 + (stats.videoFrames * 60 div maxFrames))
    else:
      min(95, 30 + (stats.videoFrames div 10))

  notifyProgress(
    onProgress,
    progressCtx,
    progress,
    &"processing video frame {stats.videoFrames}"
  )

proc drainEncoder(
    encoder: VideoEncoder;
    writer: Mp4VideoWriter;
    stats: var OverlayStats
  ) =
  while true:
    let packetRead = checkFFmpeg(encoder.receivePacket(), "receive encoded packet")
    if not packetRead.hasPacket:
      break

    inc stats.videoPackets
    stats.videoPacketBytes += packetRead.packet.size
    checkFFmpegVoid(writer.writePacket(packetRead), "write encoded packet")

proc encodeRgbxFrameNv12(
    encoder: VideoEncoder;
    writer: Mp4VideoWriter;
    rgbx: var OwnedRGBXFrame;
    frameIndex: int64;
    stats: var OverlayStats
  ) =
  let writable = checkFFmpeg(encoder.beginFrameNV12(frameIndex), "begin encoder NV12 frame")
  checkFFmpegVoid(copyRGBXToNV12Padded(rgbx, writable), "copy RGBX to padded NV12")
  checkFFmpegVoid(encoder.submitFrame(), "submit encoder frame")
  drainEncoder(encoder, writer, stats)

proc drainOldestPendingVideoFrame(
    pendingFrames: var seq[PendingVideoFrame];
    encoder: VideoEncoder;
    writer: Mp4VideoWriter;
    font: Font;
    hasFont: bool;
    drawOptions: OverlayDrawOptions;
    rgbxPool: var seq[OwnedRGBXFrame];
    stats: var OverlayStats
  ) =
  if pendingFrames.len == 0:
    return

  var item = move pendingFrames[0]
  pendingFrames.delete(0)

  let yoloResult = item.pending.waitYoloAsync()
  inc stats.pipelineReplies
  stats.inferWaitFramesMs.add(yoloResult.waitMs)
  stats.inferWaitMs += yoloResult.waitMs
  stats.inferMs += yoloResult.totalMs
  stats.inferOverlapMs += max(0, yoloResult.totalMs - item.pending.submitMs - yoloResult.waitMs)
  stats.hailoWriteUs += yoloResult.writeUs
  stats.hailoReadUs += yoloResult.readUs
  stats.hailoParseUs += yoloResult.parseUs
  stats.hailoSortUs += yoloResult.sortUs

  if int(yoloResult.requestId) != item.frameIndex:
    raise newException(
      IOError,
      &"HAILO result frame mismatch: expected={item.frameIndex} actual={yoloResult.requestId}"
    )

  var stageStart = epochTime()
  let drawResult = item.rgbx.drawDetectionsOnRgbxFrame(
    yoloResult.detections,
    font,
    hasFont,
    drawOptions
  )
  stats.boxesDrawn += drawResult.boxes
  stats.labelsDrawn += drawResult.labels
  stats.drawMs += elapsedMs(stageStart)
  stats.detections += yoloResult.detections.len

  stageStart = epochTime()
  encodeRgbxFrameNv12(encoder, writer, item.rgbx, int64(stats.videoFrames), stats)
  stats.encodeMs += elapsedMs(stageStart)

  inc stats.videoFrames
  stats.pipelineFrames = stats.videoFrames

  ## Return the large RGBX buffer to a tiny local pool.  This keeps the Step 5
  ## look-ahead pipeline from allocating a multi-megabyte frame for every input
  ## frame while still keeping ownership explicit.
  rgbxPool.add(move item.rgbx)


proc useMp4ThreadPipeline(): bool =
  ## Step 6 default path.  This keeps the web-facing MP4 output contract, but
  ## splits decode/preprocess from overlay/encode using threadtools queues.
  let raw = getEnv("HAILO_DEMO_MP4_THREAD_PIPELINE", "1").toLowerAscii()
  result = raw notin ["0", "false", "no", "off"]

proc resolveMp4VideoFramePoolCapacity(maxInFlight: int): int =
  ## RGBX frame buffers are large.  Keep a small threadtools Pool so producer
  ## and consumer can move ownership without allocating one frame per input.
  let defaultValue = max(3, maxInFlight + 2)
  result = max(1, parseEnvInt("HAILO_DEMO_MP4_FRAME_POOL", defaultValue))
  result = min(result, 16)

type
  SharedCString = object
    ## Raw shared-memory string for data passed to a Nim OS thread.
    ##
    ## Do not pass GC-managed string fields through a ptr state object to a
    ## {.thread.} proc.  The worker thread converts this shared byte buffer into
    ## its own local string before using libav/pixie APIs.
    data: ptr UncheckedArray[char]
    len: int

  VideoPipelineItemKind = enum
    vpiFrame
    vpiDone
    vpiError

  VideoPipelineItem = object
    kind: VideoPipelineItemKind
    frameIndex: int
    pending: YoloAsyncPending
    rgbx: Pooled[OwnedRGBXFrame]
    message: string

  VideoPipelineResultKind = enum
    vprDone
    vprError

  VideoPipelineWorkerResult = object
    kind: VideoPipelineResultKind
    stats: OverlayStats
    message: string

  VideoPipelineWorkerState = object
    frameQ: ThreadQueue[VideoPipelineItem]
    resultQ: ThreadQueue[VideoPipelineWorkerResult]
    outputPath: SharedCString
    fontPath: SharedCString
    fps: int
    bitrate: int
    encoderName: SharedCString

proc `=destroy`(self: var VideoPipelineItem) {.raises: [].} =
  ## VideoPipelineItem can carry an active Pooled[OwnedRGBXFrame].  Make the
  ## destructor explicitly no-raise so it remains acceptable for ThreadQueue
  ## isolation checks, mirroring hailort_nim's pooled worker request type.
  try:
    case self.kind
    of vpiFrame:
      `=destroy`(self.rgbx)
      `=destroy`(self.message)
    of vpiDone, vpiError:
      `=destroy`(self.rgbx)
      `=destroy`(self.message)
  except Exception:
    discard

proc initSharedCString(value: string): SharedCString =
  result.len = value.len
  let mem = allocShared0(result.len + 1)
  if mem == nil:
    raise newException(IOError, "allocShared0 failed for thread string")

  result.data = cast[ptr UncheckedArray[char]](mem)
  for i in 0 ..< value.len:
    result.data[i] = value[i]
  result.data[value.len] = '\0'

proc toLocalString(self: SharedCString): string {.gcsafe.} =
  if self.data == nil or self.len <= 0:
    return ""

  result = newString(self.len)
  for i in 0 ..< self.len:
    result[i] = self.data[i]

proc freeSharedCString(self: var SharedCString) =
  if self.data != nil:
    deallocShared(cast[pointer](self.data))
    self.data = nil
    self.len = 0

proc sendVideoPipelineItem(
    q: ThreadQueue[VideoPipelineItem];
    item: sink VideoPipelineItem;
    context: string
  ) =
  var owned = move item
  let sendRes = q.sendMove(move owned)
  if sendRes.isErr:
    raise newException(IOError, &"{context}: {sendRes.error}")

proc sendVideoPipelineResult(
    q: ThreadQueue[VideoPipelineWorkerResult];
    resultItem: sink VideoPipelineWorkerResult
  ) {.gcsafe.} =
  var owned = move resultItem
  let sendRes = q.sendMove(move owned)
  if sendRes.isErr:
    echo &"warning: failed to send video pipeline result: {sendRes.error}"

proc receiveVideoPipelineResult(q: ThreadQueue[VideoPipelineWorkerResult]): VideoPipelineWorkerResult =
  ## receiveResult() returns a MoveResult.  The installed move_results helper
  ## exposes isOk/take(), but not isErr, so keep this path compatible with that
  ## API surface.
  var recvRes = q.receiveResult()
  if not recvRes.isOk:
    raise newException(IOError, &"receive video pipeline result failed: {recvRes.error}")
  result = recvRes.take()

proc processThreadedVideoPipelineFrame(
    item: var VideoPipelineItem;
    encoder: VideoEncoder;
    writer: Mp4VideoWriter;
    font: Font;
    hasFont: bool;
    drawOptions: OverlayDrawOptions;
    stats: var OverlayStats
  ) =
  var yoloResult: YoloAsyncResult
  {.cast(gcsafe).}:
    yoloResult = item.pending.waitYoloAsync()
  inc stats.pipelineReplies
  ## Do not store per-frame wait timings in the consumer thread.
  ## Those seq buffers would be allocated on the consumer thread and later moved
  ## back to the producer thread as part of OverlayStats, which is unsafe with
  ## Nim's thread-local GC/ORC heaps and can crash during deallocation.  Keep only
  ## scalar totals on the consumer side; producer-side timing seqs remain safe.
  stats.inferWaitMs += yoloResult.waitMs
  stats.inferMs += yoloResult.totalMs
  stats.inferOverlapMs += max(0, yoloResult.totalMs - item.pending.submitMs - yoloResult.waitMs)
  stats.hailoWriteUs += yoloResult.writeUs
  stats.hailoReadUs += yoloResult.readUs
  stats.hailoParseUs += yoloResult.parseUs
  stats.hailoSortUs += yoloResult.sortUs

  if int(yoloResult.requestId) != item.frameIndex:
    raise newException(
      IOError,
      &"HAILO result frame mismatch: expected={item.frameIndex} actual={yoloResult.requestId}"
    )

  var stageStart = epochTime()
  let drawResult = item.rgbx.value.drawDetectionsOnRgbxFrame(
    yoloResult.detections,
    font,
    hasFont,
    drawOptions
  )
  stats.boxesDrawn += drawResult.boxes
  stats.labelsDrawn += drawResult.labels
  stats.drawMs += elapsedMs(stageStart)
  stats.detections += yoloResult.detections.len

  stageStart = epochTime()
  encodeRgbxFrameNv12(encoder, writer, item.rgbx.value, int64(stats.videoFrames), stats)
  stats.encodeMs += elapsedMs(stageStart)

  inc stats.videoFrames
  stats.pipelineFrames = stats.videoFrames

proc videoPipelineConsumerMain(state: VideoPipelineWorkerState) {.thread.} =
  var workerResult = VideoPipelineWorkerResult(kind: vprDone)

  try:
    let
      outputPath = state.outputPath.toLocalString()
      fontPath = state.fontPath.toLocalString()
      encoderName = state.encoderName.toLocalString()
      loadedFont = loadOverlayFont(fontPath)
      drawOptions = resolveVideoDrawOptions()
    var
      encoder: VideoEncoder
      writer: Mp4VideoWriter
      encoderReady = false

    try:
      while true:
        var item = state.frameQ.receive()

        case item.kind
        of vpiDone:
          break
        of vpiError:
          raise newException(IOError, item.message)
        of vpiFrame:
          if not encoderReady:
            let
              frameW = item.rgbx.value.width
              frameH = item.rgbx.value.height
              encoderHeight = alignUp(frameH, 16)

            var stageStart = epochTime()
            encoder = checkFFmpeg(openVideoEncoder(VideoEncoderOptions(
              encoderName: encoderName,
              width: frameW,
              height: encoderHeight,
              pixelFormat: pfNv12,
              timeBase: Rational(num: 1, den: int32(state.fps)),
              framerate: Rational(num: int32(state.fps), den: 1),
              bitRate: int64(state.bitrate),
              gopSize: state.fps,
              maxBFrames: 0,
              globalHeader: true
            )), &"open video encoder {encoderName}")
            workerResult.stats.encoderOpenMs = elapsedMs(stageStart)

            stageStart = epochTime()
            writer = checkFFmpeg(openMp4VideoWriter(outputPath, encoder), "open MP4 writer")
            workerResult.stats.writerOpenMs = elapsedMs(stageStart)
            encoderReady = true

          processThreadedVideoPipelineFrame(
            item,
            encoder,
            writer,
            loadedFont.font,
            loadedFont.hasFont,
            drawOptions,
            workerResult.stats
          )

      if workerResult.stats.videoFrames <= 0:
        raise newException(IOError, "MP4 has no decodable video frame")

      var stageStart = epochTime()
      checkFFmpegVoid(encoder.flush(), "flush encoder")
      drainEncoder(encoder, writer, workerResult.stats)
      workerResult.stats.encoderFlushMs = elapsedMs(stageStart)
      workerResult.stats.encodeMs += workerResult.stats.encoderFlushMs

      stageStart = epochTime()
      checkFFmpegVoid(writer.finish(), "finish MP4 writer")
      workerResult.stats.writerFinishMs = elapsedMs(stageStart)
      workerResult.stats.encodeMs += workerResult.stats.writerFinishMs

    finally:
      if not writer.isNil:
        writer.close()
      if not encoder.isNil:
        encoder.close()

  except CatchableError as e:
    workerResult.kind = vprError
    workerResult.message = e.msg

  sendVideoPipelineResult(state.resultQ, move workerResult)

proc addRgbxFrameToPool(
    pool: Pool[OwnedRGBXFrame];
    width, height: int
  ) =
  var frame = checkFFmpeg(newOwnedRGBXFrame(width, height), "new pooled RGBX frame")
  let addRes = pool.addMove(move frame)
  if addRes.isErr:
    raise newException(IOError, &"add RGBX frame to pool failed: {addRes.error}")

proc notifyPreparedVideoFrameProgress(
    onProgress: OverlayProgressCallback;
    progressCtx: pointer;
    submitted: int;
    maxFrames: int
  ) {.gcsafe.} =
  if submitted <= 0:
    return
  if not (submitted == 1 or (submitted mod 10) == 0):
    return

  let progress =
    if maxFrames > 0:
      min(95, 30 + (submitted * 60 div maxFrames))
    else:
      min(95, 30 + (submitted div 10))

  notifyProgress(
    onProgress,
    progressCtx,
    progress,
    &"processing video frame {submitted}"
  )

proc mergeThreadedVideoStats(result: var OverlayStats; workerStats: OverlayStats) =
  result.pipelineReplies = workerStats.pipelineReplies
  result.inferWaitFramesMs = workerStats.inferWaitFramesMs
  result.inferWaitMs = workerStats.inferWaitMs
  result.inferMs = workerStats.inferMs
  result.inferOverlapMs = workerStats.inferOverlapMs
  result.hailoWriteUs = workerStats.hailoWriteUs
  result.hailoReadUs = workerStats.hailoReadUs
  result.hailoParseUs = workerStats.hailoParseUs
  result.hailoSortUs = workerStats.hailoSortUs

  result.detections = workerStats.detections
  result.boxesDrawn = workerStats.boxesDrawn
  result.labelsDrawn = workerStats.labelsDrawn
  result.videoFrames = workerStats.videoFrames
  result.videoPackets = workerStats.videoPackets
  result.videoPacketBytes = workerStats.videoPacketBytes

  result.encoderOpenMs = workerStats.encoderOpenMs
  result.writerOpenMs = workerStats.writerOpenMs
  result.encoderFlushMs = workerStats.encoderFlushMs
  result.writerFinishMs = workerStats.writerFinishMs
  result.encodeMs = workerStats.encodeMs

  ## workerStats.drawMs contains overlay drawing only.  Producer-side rgbxMs is
  ## kept separately so the formatted output still reports draw=[rgbx, overlay].
  result.drawMs = result.rgbxMs + workerStats.drawMs
  result.pipelineFrames = result.videoFrames

proc drawMp4VideoOverlayThreaded(
    inputPath, outputPath, fontPath: string;
    onProgress: OverlayProgressCallback = nil;
    progressCtx: pointer = nil
  ): OverlayStats =
  ## Step 6 video pipeline.
  ##
  ## The job worker thread now acts as the decode/preprocess producer.  It reads
  ## frames, creates YOLO input, submits HAILO work immediately, converts the
  ## full-size RGBX frame, and moves a pooled RGBX buffer to an overlay/encode
  ## consumer thread.  The consumer waits for the matching HAILO result, draws,
  ## and encodes.  This hides overlay/encode work behind the next frame's decode
  ## and preprocessing, while keeping the HAILO worker itself unchanged.
  let totalStart = epochTime()
  let fps = max(1, parseEnvInt("HAILO_DEMO_MP4_FPS", 30))
  let bitrate = max(1, parseEnvInt("HAILO_DEMO_MP4_BITRATE", 2_000_000))
  let maxFrames = parseEnvInt("HAILO_DEMO_MP4_VIDEO_MAX_FRAMES", 90)
  let encoderName = resolveMp4VideoEncoderName()
  let maxInFlight = resolveMp4VideoInFlight()
  let framePoolCapacity = resolveMp4VideoFramePoolCapacity(maxInFlight)
  let queueCapacity = maxInFlight

  result.pipelineInFlight = maxInFlight

  let frameQRes = newThreadQueue[VideoPipelineItem](queueCapacity)
  if frameQRes.isErr:
    raise newException(IOError, &"new video pipeline frame queue failed: {frameQRes.error}")
  let frameQ = frameQRes.get()

  let resultQRes = newThreadQueue[VideoPipelineWorkerResult](1)
  if resultQRes.isErr:
    raise newException(IOError, &"new video pipeline result queue failed: {resultQRes.error}")
  let resultQ = resultQRes.get()

  var
    sharedOutputPath = initSharedCString(outputPath)
    sharedFontPath = initSharedCString(fontPath)
    sharedEncoderName = initSharedCString(encoderName)

  var workerState = VideoPipelineWorkerState(
    frameQ: frameQ,
    resultQ: resultQ,
    outputPath: sharedOutputPath,
    fontPath: sharedFontPath,
    fps: fps,
    bitrate: bitrate,
    encoderName: sharedEncoderName
  )
  var consumerThread: Thread[VideoPipelineWorkerState]
  createThread(consumerThread, videoPipelineConsumerMain, workerState)
  var consumerStarted = true
  var terminalSent = false

  notifyProgress(onProgress, progressCtx, 20, "opening MP4 decoder")

  try:
    var reader = openMp4PreviewDecoder(inputPath)
    defer: reader.close()

    result.decoderOpenMs = reader.decoderOpenMs
    result.decoderName = reader.decoderName
    notifyProgress(onProgress, progressCtx, 25, "decoding video frames")

    var
      poolReady = false
      framePool: Pool[OwnedRGBXFrame]
      pooledWidth = 0
      pooledHeight = 0

    while maxFrames <= 0 or result.pipelineSubmitted < maxFrames:
      let frameRead = reader.readNextFrame()
      if frameRead.eof:
        break

      result.readFramesMs.add(frameRead.readMs)
      result.readFrameMs += frameRead.readMs
      result.imageWidth = frameRead.frameWidth
      result.imageHeight = frameRead.frameHeight
      result.previewFrameIndex = frameRead.frameIndex

      if not poolReady:
        let poolRes = newPool[OwnedRGBXFrame](framePoolCapacity)
        if poolRes.isErr:
          raise newException(IOError, &"new RGBX frame pool failed: {poolRes.error}")
        framePool = poolRes.get()
        pooledWidth = frameRead.frameWidth
        pooledHeight = frameRead.frameHeight
        for _ in 0 ..< framePoolCapacity:
          framePool.addRgbxFrameToPool(pooledWidth, pooledHeight)
        poolReady = true
        notifyProgress(onProgress, progressCtx, 30, &"processing video frames ({pooledWidth}x{pooledHeight})")
      elif frameRead.frameWidth != pooledWidth or frameRead.frameHeight != pooledHeight:
        raise newException(
          IOError,
          &"video frame size changed: expected={pooledWidth}x{pooledHeight} actual={frameRead.frameWidth}x{frameRead.frameHeight}"
        )

      var stageStart = epochTime()
      var yoloInput = frameRead.read.frame.prepareYoloInput()
      let letterboxMs = elapsedMs(stageStart)
      result.letterboxFramesMs.add(letterboxMs)
      result.letterboxMs += letterboxMs

      let pending = yoloInput.submitYoloAsync(uint64(frameRead.frameIndex))
      result.inferSubmitFramesMs.add(pending.submitMs)
      result.inferSubmitMs += pending.submitMs
      inc result.pipelineSubmitted

      stageStart = epochTime()
      var rgbxItem = framePool.acquire()
      checkFFmpegVoid(copyI420ToRGBX(frameRead.read.frame, rgbxItem.value), "copy decoded I420 to pooled RGBX")
      let rgbxMs = elapsedMs(stageStart)
      result.rgbxFramesMs.add(rgbxMs)
      result.rgbxMs += rgbxMs

      var item = VideoPipelineItem(
        kind: vpiFrame,
        frameIndex: frameRead.frameIndex,
        pending: pending,
        rgbx: move rgbxItem
      )
      frameQ.sendVideoPipelineItem(move item, "send video pipeline frame")
      result.pipelineFrames = result.pipelineSubmitted

      notifyPreparedVideoFrameProgress(
        onProgress,
        progressCtx,
        result.pipelineSubmitted,
        maxFrames
      )

    var doneItem = VideoPipelineItem(kind: vpiDone)
    frameQ.sendVideoPipelineItem(move doneItem, "send video pipeline done")
    terminalSent = true

    notifyProgress(onProgress, progressCtx, 96, &"finalizing video ({result.pipelineSubmitted} submitted frames)")

    let workerResult = resultQ.receiveVideoPipelineResult()
    joinThread(consumerThread)
    consumerStarted = false

    sharedOutputPath.freeSharedCString()
    sharedFontPath.freeSharedCString()
    sharedEncoderName.freeSharedCString()

    case workerResult.kind
    of vprError:
      raise newException(IOError, workerResult.message)
    of vprDone:
      result.mergeThreadedVideoStats(workerResult.stats)

    if result.videoFrames <= 0:
      raise newException(IOError, &"MP4 has no decodable video frame: {inputPath}")

    result.decodeMs = result.decoderOpenMs + result.readFrameMs
    result.totalMs = elapsedMs(totalStart)

  except CatchableError as e:
    if consumerStarted and not terminalSent:
      var errItem = VideoPipelineItem(kind: vpiError, message: e.msg)
      try:
        frameQ.sendVideoPipelineItem(move errItem, "send video pipeline error")
        discard resultQ.receiveVideoPipelineResult()
      except CatchableError:
        discard
      joinThread(consumerThread)
      sharedOutputPath.freeSharedCString()
      sharedFontPath.freeSharedCString()
      sharedEncoderName.freeSharedCString()
    raise

proc drawMp4VideoOverlayLookahead(
    inputPath, outputPath, fontPath: string;
    onProgress: OverlayProgressCallback = nil;
    progressCtx: pointer = nil
  ): OverlayStats =
  ## Decode the uploaded MP4, run YOLO on each decoded frame, draw bbox/labels,
  ## and encode the result as H.264 MP4.
  ##
  ## This is intentionally still a single job-worker pipeline.  It establishes
  ## the actual video-output path first; later steps can split decode/infer/
  ## overlay/encode into independent threadtools queues without changing the
  ## web-facing job contract.
  let totalStart = epochTime()
  let fps = max(1, parseEnvInt("HAILO_DEMO_MP4_FPS", 30))
  let bitrate = max(1, parseEnvInt("HAILO_DEMO_MP4_BITRATE", 2_000_000))
  let maxFrames = parseEnvInt("HAILO_DEMO_MP4_VIDEO_MAX_FRAMES", 90)
  let encoderName = resolveMp4VideoEncoderName()
  let maxInFlight = resolveMp4VideoInFlight()
  let loadedFont = loadOverlayFont(fontPath)
  let drawOptions = resolveVideoDrawOptions()
  result.pipelineInFlight = maxInFlight

  notifyProgress(onProgress, progressCtx, 20, "opening MP4 decoder")

  var reader = openMp4PreviewDecoder(inputPath)
  defer: reader.close()

  result.decoderOpenMs = reader.decoderOpenMs
  result.decoderName = reader.decoderName
  notifyProgress(onProgress, progressCtx, 25, "decoding video frames")

  var
    encoder: VideoEncoder
    writer: Mp4VideoWriter
    encoderReady = false
    pendingFrames: seq[PendingVideoFrame] = @[]
    rgbxPool: seq[OwnedRGBXFrame] = @[]

  defer:
    if not writer.isNil:
      writer.close()
    if not encoder.isNil:
      encoder.close()

  while maxFrames <= 0 or result.pipelineSubmitted < maxFrames:
    let frameRead = reader.readNextFrame()
    if frameRead.eof:
      break

    result.readFramesMs.add(frameRead.readMs)
    result.readFrameMs += frameRead.readMs
    result.imageWidth = frameRead.frameWidth
    result.imageHeight = frameRead.frameHeight
    result.previewFrameIndex = frameRead.frameIndex

    if not encoderReady:
      let encoderHeight = alignUp(frameRead.frameHeight, 16)

      var stageStart = epochTime()
      encoder = checkFFmpeg(openVideoEncoder(VideoEncoderOptions(
        encoderName: encoderName,
        width: frameRead.frameWidth,
        height: encoderHeight,
        pixelFormat: pfNv12,
        timeBase: Rational(num: 1, den: int32(fps)),
        framerate: Rational(num: int32(fps), den: 1),
        bitRate: int64(bitrate),
        gopSize: fps,
        maxBFrames: 0,
        globalHeader: true
      )), &"open video encoder {encoderName}")
      result.encoderOpenMs = elapsedMs(stageStart)

      stageStart = epochTime()
      writer = checkFFmpeg(openMp4VideoWriter(outputPath, encoder), "open MP4 writer")
      result.writerOpenMs = elapsedMs(stageStart)
      encoderReady = true
      notifyProgress(onProgress, progressCtx, 30, &"processing video frames ({frameRead.frameWidth}x{frameRead.frameHeight})")

    var stageStart = epochTime()
    var yoloInput = frameRead.read.frame.prepareYoloInput()
    let letterboxMs = elapsedMs(stageStart)
    result.letterboxFramesMs.add(letterboxMs)
    result.letterboxMs += letterboxMs

    let pending = yoloInput.submitYoloAsync(uint64(frameRead.frameIndex))
    result.inferSubmitFramesMs.add(pending.submitMs)
    result.inferSubmitMs += pending.submitMs
    inc result.pipelineSubmitted

    stageStart = epochTime()
    var rgbx = checkFFmpeg(
      acquireRgbxFrame(rgbxPool, frameRead.frameWidth, frameRead.frameHeight),
      "allocate RGBX frame"
    )
    checkFFmpegVoid(copyI420ToRGBX(frameRead.read.frame, rgbx), "copy decoded I420 to RGBX")
    let rgbxMs = elapsedMs(stageStart)
    result.rgbxFramesMs.add(rgbxMs)
    result.rgbxMs += rgbxMs
    result.drawMs += rgbxMs

    pendingFrames.add PendingVideoFrame(
      frameIndex: frameRead.frameIndex,
      pending: pending,
      rgbx: move rgbx
    )
    result.pipelineFrames = result.videoFrames + pendingFrames.len

    while pendingFrames.len >= maxInFlight:
      drainOldestPendingVideoFrame(
        pendingFrames,
        encoder,
        writer,
        loadedFont.font,
        loadedFont.hasFont,
        drawOptions,
        rgbxPool,
        result
      )
      notifyVideoFrameProgress(onProgress, progressCtx, result, maxFrames)

  while pendingFrames.len > 0:
    drainOldestPendingVideoFrame(
      pendingFrames,
      encoder,
      writer,
      loadedFont.font,
      loadedFont.hasFont,
      drawOptions,
      rgbxPool,
      result
    )
    notifyVideoFrameProgress(onProgress, progressCtx, result, maxFrames)

  if result.videoFrames <= 0:
    raise newException(IOError, &"MP4 has no decodable video frame: {inputPath}")

  notifyProgress(onProgress, progressCtx, 96, &"finalizing video ({result.videoFrames} frames)")

  var stageStart = epochTime()
  checkFFmpegVoid(encoder.flush(), "flush encoder")
  drainEncoder(encoder, writer, result)
  result.encoderFlushMs = elapsedMs(stageStart)
  result.encodeMs += result.encoderFlushMs

  stageStart = epochTime()
  checkFFmpegVoid(writer.finish(), "finish MP4 writer")
  result.writerFinishMs = elapsedMs(stageStart)
  result.encodeMs += result.writerFinishMs

  result.decodeMs = result.decoderOpenMs + result.readFrameMs
  result.totalMs = elapsedMs(totalStart)


proc drawMp4VideoOverlay*(
    inputPath, outputPath, fontPath: string;
    onProgress: OverlayProgressCallback = nil;
    progressCtx: pointer = nil
  ): OverlayStats =
  if useMp4ThreadPipeline():
    return drawMp4VideoOverlayThreaded(
      inputPath,
      outputPath,
      fontPath,
      onProgress,
      progressCtx
    )

  result = drawMp4VideoOverlayLookahead(
    inputPath,
    outputPath,
    fontPath,
    onProgress,
    progressCtx
  )

proc drawMp4PreviewOverlay*(inputPath, outputPath, fontPath: string): OverlayStats =
  ## Decode one MP4 frame with libav_nim and render it as a JPEG preview with
  ## HAILO detections.
  ##
  ## Timing mapping:
  ##   decode    : libav open/read first decoded I420 frame
  ##   letterbox : I420 -> 640x640 RGB24 YOLO input
  ##   draw      : I420 -> full-size RGBX preview + bbox/label drawing
  if useMp4PipelineProbe():
    return drawMp4PreviewOverlayPipelineProbe(inputPath, outputPath, fontPath)

  if useMp4OverlapPipeline():
    return drawMp4PreviewOverlayPipelined(inputPath, outputPath, fontPath)

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
