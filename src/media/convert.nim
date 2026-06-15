## Image conversion and coordinate mapping helpers.
##
## This module owns the YOLOv11s input image preparation path:
##
##   JPEG path:
##     Pixie RGBX image
##       -> libyuv_nim RGBA/RGBX view
##       -> 640x640 packed RGB input buffer
##
##   MP4 path:
##     libav_nim borrowed I420/YUV420P frame
##       -> libyuv_nim I420 view
##       -> 640x640 packed RGB input buffer
##
## The returned LetterboxInfo is also used to restore YOLO input-space bboxes
## back into the original image coordinate space.

import pixie
import std/strformat

import libav_nim
import libyuv_nim

import ../types

const
  YoloInputW* = 640
  YoloInputH* = 640
  YoloPadValue* = 114'u8

type
  YoloLetterboxInfo* = object
    origW*: int
    origH*: int
    inputW*: int
    inputH*: int
    resizedW*: int
    resizedH*: int
    offsetX*: int
    offsetY*: int
    scaleX*: float32
    scaleY*: float32

  YoloInputImage* = object
    ## Packed RGB24, NHWC, width=640, height=640.
    ##
    ## HAILO YOLOv11s input expects UINT8 NHWC3, so rgb.data is the buffer that
    ## can later be passed to hailort_nim.
    rgb*: RgbImage
    info*: YoloLetterboxInfo

proc toYoloInfo(info: libyuv_nim.LetterboxInfo): YoloLetterboxInfo =
  result = YoloLetterboxInfo(
    origW: info.srcWidth,
    origH: info.srcHeight,
    inputW: info.dstWidth,
    inputH: info.dstHeight,
    resizedW: info.resizedWidth,
    resizedH: info.resizedHeight,
    offsetX: info.offsetX,
    offsetY: info.offsetY,
    scaleX: info.scaleX,
    scaleY: info.scaleY
  )

proc computeLetterbox*(
    origW, origH: int;
    inputW = YoloInputW;
    inputH = YoloInputH
  ): YoloLetterboxInfo =
  let res = computeLetterboxInfo(origW, origH, inputW, inputH)
  if res.isErr:
    raise newException(ValueError, $res.error)
  result = res.get().toYoloInfo()

proc restoreDetectionFromInput*(d: Detection; info: YoloLetterboxInfo): Detection =
  ## Convert a bbox from YOLO input coordinates back to the original image
  ## coordinate space.  Clamping is intentionally left to the draw layer so
  ## callers can inspect raw restored values when debugging letterbox math.
  result = d
  result.x = (d.x - info.offsetX.float32) / info.scaleX
  result.y = (d.y - info.offsetY.float32) / info.scaleY
  result.w = d.w / info.scaleX
  result.h = d.h / info.scaleY

proc describe*(info: YoloLetterboxInfo): string =
  &"orig={info.origW}x{info.origH} input={info.inputW}x{info.inputH} " &
    &"resized={info.resizedW}x{info.resizedH} " &
    &"offset=({info.offsetX},{info.offsetY}) " &
    &"scale=({info.scaleX:.6f},{info.scaleY:.6f})"

proc pixieToLibyuvRgbaView*(image: Image): RgbaView =
  ## Borrow Pixie's RGBX/RGBA memory as a libyuv_nim RGBA view.
  ##
  ## The view does not own memory.  The caller must keep `image` alive while
  ## libyuv operates on this view.
  if image.isNil:
    raise newException(ValueError, "image is nil")
  if image.width <= 0 or image.height <= 0:
    raise newException(ValueError, &"invalid image size: {image.width}x{image.height}")
  if image.data.len == 0:
    raise newException(ValueError, "image has no pixel data")

  result = RgbaView(
    width: image.width,
    height: image.height,
    stride: image.width * 4,
    data: cast[ptr uint8](unsafeAddr image.data[0])
  )

proc yuv420ToLibyuvI420View*(frame: Yuv420FrameView): I420View =
  ## Borrow libav_nim's decoded I420/YUV420P frame as a libyuv_nim I420 view.
  ##
  ## No image data is copied here. The caller must keep the decoder frame alive
  ## while libyuv operates on this view.
  if not frame.hasUsableYuv420Planes():
    raise newException(
      ValueError,
      &"decoded frame is not usable I420: {frame.width}x{frame.height} {frame.format.pixelFormatName()}"
    )

  result = I420View(
    width: frame.width,
    height: frame.height,
    strideY: frame.yStride,
    strideU: frame.uStride,
    strideV: frame.vStride,
    y: cast[ptr uint8](frame.y),
    u: cast[ptr uint8](frame.u),
    v: cast[ptr uint8](frame.v)
  )

proc rgbImageView(image: var RgbImage): RgbView =
  result = RgbView(
    width: image.width,
    height: image.height,
    stride: image.stride,
    data: if image.data.len == 0: nil else: addr image.data[0]
  )

proc prepareYoloInput*(image: Image): YoloInputImage =
  ## Generate a 640x640 RGB24/NHWC3 YOLO input image from a Pixie RGBX image.
  let srcView = image.pixieToLibyuvRgbaView()

  let allocRes = allocRgbImage(YoloInputW, YoloInputH)
  if allocRes.isErr:
    raise newException(ValueError, $allocRes.error)

  var dst = allocRes.get()
  var dstView = dst.rgbImageView()
  let lbRes = srcView.toRgbLetterboxInto(
    dstView,
    RgbPadColor(r: YoloPadValue, g: YoloPadValue, b: YoloPadValue)
  )
  if lbRes.isErr:
    raise newException(ValueError, $lbRes.error)

  result = YoloInputImage(
    rgb: dst,
    info: lbRes.get().toYoloInfo()
  )

proc prepareYoloInput*(frame: Yuv420FrameView): YoloInputImage =
  ## Generate a 640x640 RGB24/NHWC3 YOLO input image directly from a decoded
  ## I420/YUV420P video frame.
  ##
  ## This avoids MP4 -> JPEG -> TurboJPEG -> RGBX round-tripping and uses
  ## libyuv's I420 scaling/conversion path directly.
  let srcView = frame.yuv420ToLibyuvI420View()

  let allocRes = allocRgbImage(YoloInputW, YoloInputH)
  if allocRes.isErr:
    raise newException(ValueError, $allocRes.error)

  var dst = allocRes.get()
  var dstView = dst.rgbImageView()
  var scratch: I420Image
  let lbRes = toRgbLetterboxInto(
    srcView,
    dstView,
    scratch,
    RgbPadColor(r: YoloPadValue, g: YoloPadValue, b: YoloPadValue)
  )
  if lbRes.isErr:
    raise newException(ValueError, $lbRes.error)

  result = YoloInputImage(
    rgb: dst,
    info: lbRes.get().toYoloInfo()
  )

proc inputBufferLen*(input: YoloInputImage): int =
  input.rgb.data.len

proc inputBufferPtr*(input: var YoloInputImage): ptr uint8 =
  if input.rgb.data.len == 0:
    return nil
  result = addr input.rgb.data[0]
