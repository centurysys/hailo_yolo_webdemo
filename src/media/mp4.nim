## MP4 preview helpers backed by libav_nim.
##
## This first video step decodes one representative frame from an uploaded MP4,
## converts the borrowed I420 frame directly into the 640x640 YOLO RGB input,
## and also converts the same frame into a Pixie RGBX image for overlay drawing.

import pixie
import std/[os, strformat, times]

import libav_nim

import ./convert

const
  DefaultMp4DecoderName = "h264_v4l2m2m"

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
    letterboxMs*: int
    rgbxMs*: int
    frameWidth*: int
    frameHeight*: int
    decoderName*: string
    frameIndex*: int

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

proc decodeMp4PreviewFrame*(inputPath: string; decoderName = ""): Mp4PreviewFrame =
  ## Decode the first video frame and build both outputs needed by the existing
  ## overlay pipeline.
  ##
  ## The Yuv420FrameView returned by libav_nim is borrowed from FFmpeg.  For that
  ## reason, both the YOLO input and Pixie preview image are produced before the
  ## decoder is closed or reused.
  let totalStart = epochTime()

  let
    actualDecoderName = resolveMp4DecoderName(decoderName)
    actualDecoderLabel = if actualDecoderName.len > 0: actualDecoderName else: "auto"

  var stageStart = epochTime()
  var decoder = checkAv(
    openVideoDecoder(inputPath, DecoderOptions(decoderName: actualDecoderName)),
    &"openVideoDecoder decoder={actualDecoderLabel}"
  )
  result.decoderOpenMs = elapsedMs(stageStart)
  defer: decoder.close()

  stageStart = epochTime()
  let read = checkAv(decoder.readFrame(), "readFrame")
  result.readFrameMs = elapsedMs(stageStart)
  if read.eof:
    raise newException(IOError, &"MP4 has no decodable video frame: {inputPath}")

  result.decodeMs = elapsedMs(totalStart)
  result.decoderName = actualDecoderName
  result.frameIndex = 0
  result.frameWidth = read.frame.width
  result.frameHeight = read.frame.height

  stageStart = epochTime()
  result.yoloInput = read.frame.prepareYoloInput()
  result.letterboxMs = elapsedMs(stageStart)

  stageStart = epochTime()
  result.image = read.frame.yuv420FrameToPixieImage()
  result.rgbxMs = elapsedMs(stageStart)
