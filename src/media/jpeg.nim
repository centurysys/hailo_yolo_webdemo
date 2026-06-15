## JPEG helpers.
##
## TurboJPEG/libjpeg-turbo is used for JPEG input decode because Pixie's
## readImage() path is too slow for the single-image inference demo.  Output is
## still handled by hyper_jpeg, which is already fast on the target platform.

import std/strformat

import hyper_jpeg
import libturbojpeg_nim
import pixie

const DefaultJpegQuality* = 90

type
  PixelSeqHolder = ref object
    data: seq[PixelRGBX]

  ColorSeqHolder = ref object
    data: seq[ColorRGBX]

proc movePixelsToColorSeq(data: sink seq[PixelRGBX]): seq[ColorRGBX] =
  ## PixelRGBX and Pixie ColorRGBX are both 4-byte RGBX layouts.
  ## Move ownership of the decoded TurboJPEG buffer into Pixie without copying.
  static:
    doAssert sizeof(PixelRGBX) == 4
    doAssert sizeof(ColorRGBX) == 4

  var src = PixelSeqHolder(data: data)
  var dst = cast[ColorSeqHolder](src)
  result = move dst.data

proc readJpegToPixieImage*(inputPath: string): Image =
  let readRes = readJpegRgbx(inputPath)
  if readRes.isErr:
    raise newException(IOError, &"failed to decode JPEG with TurboJPEG: {readRes.error.msg}")

  var rgbx = readRes.get()
  if not rgbx.isValid:
    raise newException(IOError, &"decoded JPEG image is invalid: {inputPath}")

  result = Image()
  result.width = rgbx.width
  result.height = rgbx.height
  result.data = movePixelsToColorSeq(move rgbx.data)

proc encodeImageToJpeg*(image: Image; outputPath: string; quality = DefaultJpegQuality) =
  if image.isNil:
    raise newException(ValueError, "image is nil")
  if image.width <= 0 or image.height <= 0:
    raise newException(ValueError, &"invalid image size: {image.width}x{image.height}")
  if image.data.len == 0:
    raise newException(ValueError, "image has no pixel data")

  let stride = image.width * 4

  var enc = block:
    let openResult = JpegEncoder.open(image.width, image.height, backend = jbAuto, quality = quality)
    if openResult.isErr:
      raise newException(IOError, &"failed to open JPEG encoder: {openResult.error}")
    openResult.get()

  try:
    let jpegResult = enc.encodeRgba(
      cast[pointer](addr image.data[0]),
      image.width,
      image.height,
      stride,
      quality = quality
    )
    if jpegResult.isErr:
      raise newException(IOError, &"failed to encode JPEG: {jpegResult.error}")

    writeFile(outputPath, jpegResult.get())
  finally:
    let closeResult = enc.close()
    if closeResult.isErr:
      raise newException(IOError, &"failed to close JPEG encoder: {closeResult.error}")
