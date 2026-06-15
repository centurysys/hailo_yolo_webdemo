## MP4 preview helpers backed by libav_nim.
##
## This first video step decodes one representative frame from an uploaded MP4,
## converts the borrowed I420 frame directly into the 640x640 YOLO RGB input,
## and also converts the same frame into a Pixie RGBX image for overlay drawing.

import pixie
import std/[os, strformat, strutils, times]

import libav_nim

import ./convert

const
  DefaultMp4DecoderName = "h264_v4l2m2m"
  DefaultMp4ProbeFrames = 3

type
  PixelSeqHolder = ref object
    data: seq[PixelRGBX]

  ColorSeqHolder = ref object
    data: seq[ColorRGBX]

  Mp4PreviewFrame* = object
    image*: Image
    yoloInput*: YoloInputImage
    decodeMs*: int
    decoderOpenMs*: int
    readFrameMs*: int
    readFramesMs*: seq[int]
    requestedProbeFrames*: int
    actualProbeFrames*: int
    letterboxMs*: int
    rgbxMs*: int
    frameWidth*: int
    frameHeight*: int
    decoderName*: string
    frameIndex*: int

  Mp4DecodedFrame* = object
    ## Borrowed decoded video frame plus the decoder that owns it.
    ##
    ## The Yuv420FrameView inside `read.frame` remains valid only while
    ## `decoder` stays open and before another frame is read from that decoder.
    ## Call close() after all conversions for the selected frame are complete.
    decoder*: VideoDecoder
    read*: ReadFrame
    decodeMs*: int
    decoderOpenMs*: int
    readFrameMs*: int
    readFramesMs*: seq[int]
    requestedProbeFrames*: int
    actualProbeFrames*: int
    frameWidth*: int
    frameHeight*: int
    decoderName*: string
    frameIndex*: int

  Mp4PreviewDecoder* = object
    ## Streaming-style decoder handle used by the pipeline probe.
    ##
    ## Each ReadFrame returned by readNextFrame() borrows storage from this
    ## decoder.  Convert the frame to owned YOLO/RGBX buffers before calling
    ## readNextFrame() again.
    decoder*: VideoDecoder
    decoderOpenMs*: int
    decoderName*: string
    nextFrameIndex*: int

  Mp4FrameRead* = object
    ## One decoded frame read from Mp4PreviewDecoder.
    ##
    ## The frame is borrowed from the decoder.  It stays valid until the next
    ## readNextFrame() call on the same decoder, or until close().
    eof*: bool
    read*: ReadFrame
    readMs*: int
    frameIndex*: int
    frameWidth*: int
    frameHeight*: int

proc elapsedMs(start: float): int =
  result = int((epochTime() - start) * 1000.0 + 0.5)
  if result < 0:
    result = 0

proc resolveMp4DecoderName(requested: string): string =
  ## Use the SoC hardware decoder by default.
  ##
  ## Set HAILO_DEMO_MP4_DECODER=auto to let libav choose a decoder, or set it
  ## to hevc_v4l2m2m for HEVC test files.
  if requested.len > 0:
    return requested

  let envName = getEnv("HAILO_DEMO_MP4_DECODER", DefaultMp4DecoderName)
  if envName == "auto":
    result = ""
  else:
    result = envName

proc resolveMp4ProbeFrames(): int =
  ## Read a few frames with the same decoder instance so one-time setup cost and
  ## steady-state read/decode cost can be seen separately.
  ##
  ## HAILO_DEMO_MP4_PROBE_FRAMES=1 restores the old first-frame-only behavior.
  let raw = getEnv("HAILO_DEMO_MP4_PROBE_FRAMES", $DefaultMp4ProbeFrames)
  try:
    result = parseInt(raw)
  except ValueError:
    result = DefaultMp4ProbeFrames

  if result < 1:
    result = 1
  if result > 30:
    result = 30

proc mp4PreviewProbeFrames*(): int =
  ## Public wrapper for callers that need to drive a multi-frame preview probe.
  result = resolveMp4ProbeFrames()

proc checkAv[T](ret: FFmpegResult[T]; context: string): T =
  if ret.isErr:
    raise newException(IOError, &"{context}: {ret.error.message}")
  result = ret.value

proc checkAv(ret: FFmpegResult[void]; context: string) =
  if ret.isErr:
    raise newException(IOError, &"{context}: {ret.error.message}")

proc movePixelsToColorSeq(data: sink seq[PixelRGBX]): seq[ColorRGBX] =
  ## libav_nim PixelRGBX and Pixie ColorRGBX are both 4-byte RGBX layouts.
  ## Move ownership of the converted full-frame RGBX buffer into Pixie without a
  ## full-frame copy.
  static:
    doAssert sizeof(PixelRGBX) == 4
    doAssert sizeof(ColorRGBX) == 4

  var src = PixelSeqHolder(data: data)
  var dst = cast[ColorSeqHolder](src)
  result = move dst.data

proc yuv420FrameToPixieImage*(frame: Yuv420FrameView): Image =
  var rgbx = checkAv(
    newOwnedRGBXFrame(frame.width, frame.height),
    "newOwnedRGBXFrame"
  )
  checkAv(copyI420ToRGBX(frame, rgbx), "copyI420ToRGBX")

  result = Image()
  result.width = rgbx.width
  result.height = rgbx.height
  result.data = movePixelsToColorSeq(move rgbx.data)

proc openMp4PreviewDecoder*(inputPath: string; decoderName = ""): Mp4PreviewDecoder =
  ## Open an MP4 decoder for step-by-step frame reads.
  let
    actualDecoderName = resolveMp4DecoderName(decoderName)
    actualDecoderLabel = if actualDecoderName.len > 0: actualDecoderName else: "auto"

  let stageStart = epochTime()
  result.decoder = checkAv(
    openVideoDecoder(inputPath, DecoderOptions(decoderName: actualDecoderName)),
    &"openVideoDecoder decoder={actualDecoderLabel}"
  )
  result.decoderOpenMs = elapsedMs(stageStart)
  result.decoderName = actualDecoderName
  result.nextFrameIndex = 0

proc close*(reader: var Mp4PreviewDecoder) =
  if not reader.decoder.isNil:
    reader.decoder.close()
    reader.decoder = nil

proc readNextFrame*(reader: var Mp4PreviewDecoder): Mp4FrameRead =
  ## Read one decoded frame from an already-open MP4 decoder.
  ##
  ## The returned frame is borrowed.  Generate owned YOLO/RGBX buffers before
  ## reading the next frame from the same reader.
  if reader.decoder.isNil:
    raise newException(IOError, "MP4 decoder is not open")

  let stageStart = epochTime()
  let read = checkAv(reader.decoder.readFrame(), &"readFrame#{reader.nextFrameIndex}")

  result.readMs = elapsedMs(stageStart)
  result.frameIndex = reader.nextFrameIndex
  result.eof = read.eof

  if read.eof:
    return

  result.read = read
  result.frameWidth = read.frame.width
  result.frameHeight = read.frame.height
  inc reader.nextFrameIndex

proc close*(decoded: var Mp4DecodedFrame) =
  if not decoded.decoder.isNil:
    decoded.decoder.close()
    decoded.decoder = nil

proc openMp4PreviewDecodedFrame*(inputPath: string; decoderName = ""): Mp4DecodedFrame =
  ## Decode the representative MP4 frame, but keep the decoder open so callers
  ## can decide the order of YOLO-input generation, HAILO submit, RGBX preview
  ## conversion, and HAILO reply wait.
  let totalStart = epochTime()

  let
    actualDecoderName = resolveMp4DecoderName(decoderName)
    actualDecoderLabel = if actualDecoderName.len > 0: actualDecoderName else: "auto"

  var stageStart = epochTime()
  result.decoder = checkAv(
    openVideoDecoder(inputPath, DecoderOptions(decoderName: actualDecoderName)),
    &"openVideoDecoder decoder={actualDecoderLabel}"
  )
  result.decoderOpenMs = elapsedMs(stageStart)

  try:
    let requestedProbeFrames = resolveMp4ProbeFrames()
    result.requestedProbeFrames = requestedProbeFrames
    result.readFramesMs = @[]

    var
      selectedRead: ReadFrame
      selectedFrameIndex = -1

    for i in 0 ..< requestedProbeFrames:
      stageStart = epochTime()
      let read = checkAv(result.decoder.readFrame(), &"readFrame#{i}")
      let readMs = elapsedMs(stageStart)

      if read.eof:
        if selectedFrameIndex < 0:
          raise newException(IOError, &"MP4 has no decodable video frame: {inputPath}")
        break

      result.readFramesMs.add(readMs)
      result.readFrameMs += readMs
      selectedRead = read
      selectedFrameIndex = i

    if selectedFrameIndex < 0:
      raise newException(IOError, &"MP4 has no decodable video frame: {inputPath}")

    result.decodeMs = elapsedMs(totalStart)
    result.decoderName = actualDecoderName
    result.frameIndex = selectedFrameIndex
    result.actualProbeFrames = result.readFramesMs.len
    result.frameWidth = selectedRead.frame.width
    result.frameHeight = selectedRead.frame.height
    result.read = selectedRead
  except CatchableError:
    result.close()
    raise

proc decodeMp4PreviewFrame*(inputPath: string; decoderName = ""): Mp4PreviewFrame =
  ## Decode the first video frame and build both outputs needed by the existing
  ## overlay pipeline.
  ##
  ## The Yuv420FrameView returned by libav_nim is borrowed from FFmpeg.  For that
  ## reason, both the YOLO input and Pixie preview image are produced before the
  ## decoder is closed or reused.
  var decoded = openMp4PreviewDecodedFrame(inputPath, decoderName)
  defer: decoded.close()

  result.decodeMs = decoded.decodeMs
  result.decoderOpenMs = decoded.decoderOpenMs
  result.readFrameMs = decoded.readFrameMs
  result.readFramesMs = decoded.readFramesMs
  result.requestedProbeFrames = decoded.requestedProbeFrames
  result.actualProbeFrames = decoded.actualProbeFrames
  result.frameWidth = decoded.frameWidth
  result.frameHeight = decoded.frameHeight
  result.decoderName = decoded.decoderName
  result.frameIndex = decoded.frameIndex

  var stageStart = epochTime()
  result.yoloInput = decoded.read.frame.prepareYoloInput()
  result.letterboxMs = elapsedMs(stageStart)

  stageStart = epochTime()
  result.image = decoded.read.frame.yuv420FrameToPixieImage()
  result.rgbxMs = elapsedMs(stageStart)
