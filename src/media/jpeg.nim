## JPEG helpers.
##
## Pixie is used for image drawing, but Pixie does not encode JPEG output.
## Keep JPEG output behind this small wrapper so the drawing layer does not
## depend on encoder details.

import std/strformat

import hyper_jpeg
import pixie

const DefaultJpegQuality* = 90

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
