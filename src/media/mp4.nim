## MP4 preview helpers backed by libav_nim.
##
## This first video step decodes one representative frame from an uploaded MP4,
## converts the borrowed I420 frame directly into the 640x640 YOLO RGB input,
## and also converts the same frame into a Pixie RGBX image for overlay drawing.

import pixie
import std/[strformat, times]

import libav_nim

import ./convert

type
  PixelSeqHolder = ref object
    data: seq[PixelRGBX]

  ColorSeqHolder = ref object
    data: seq[ColorRGBX]

  Mp4PreviewFrame* = object
    image*: Image
    yoloInput*: YoloInputImage
    decodeMs*: int
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

  var decoder = checkAv(
    openVideoDecoder(inputPath, DecoderOptions(decoderName: decoderName)),
    "openVideoDecoder"
  )
  defer: decoder.close()

  let read = checkAv(decoder.readFrame(), "readFrame")
  if read.eof:
    raise newException(IOError, &"MP4 has no decodable video frame: {inputPath}")

  result.decodeMs = elapsedMs(totalStart)
  result.decoderName = decoderName
  result.frameIndex = 0
  result.frameWidth = read.frame.width
  result.frameHeight = read.frame.height

  var stageStart = epochTime()
  result.yoloInput = read.frame.prepareYoloInput()
  result.letterboxMs = elapsedMs(stageStart)

  stageStart = epochTime()
  result.image = read.frame.yuv420FrameToPixieImage()
  result.rgbxMs = elapsedMs(stageStart)
