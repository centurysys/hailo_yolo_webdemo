## Image conversion and coordinate mapping helpers.
##
## This module owns the YOLOv11s input image preparation path:
##
##   Pixie RGBA image
##     -> libyuv_nim RgbaImage view/copy
##     -> libyuv_nim toRgbLetterbox()
##     -> 640x640 packed RGB input buffer
##
## The returned LetterboxInfo is also used to restore YOLO input-space bboxes
## back into the original image coordinate space.

import pixie
import std/strformat

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

  YoloPreprocessWorkspace* = object
    ## Reusable buffers for the worker-thread preprocessing path.
    ##
    ## `rgb` is the fixed 640x640 RGB24 HAILO input image.
    ## `scratchRgba` is resized to the current letterbox image area, for example
    ## 640x360 for a 1920x1080 input image.
    rgb*: RgbImage
    scratchRgba*: RgbaImage

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

proc rgbImageView(image: var RgbImage): RgbView =
  result = RgbView(
    width: image.width,
    height: image.height,
    stride: image.stride,
    data: if image.data.len == 0: nil else: addr image.data[0]
  )

proc ensureYoloPreprocessWorkspace*(workspace: var YoloPreprocessWorkspace) =
  if workspace.rgb.isValid and
      workspace.rgb.width == YoloInputW and
      workspace.rgb.height == YoloInputH:
    return

  let allocRes = allocRgbImage(YoloInputW, YoloInputH)
  if allocRes.isErr:
    raise newException(ValueError, $allocRes.error)

  workspace.rgb = allocRes.get()

proc prepareYoloInput*(image: Image; workspace: var YoloPreprocessWorkspace): YoloInputImage =
  ## Generate a 640x640 RGB24/NHWC3 YOLO input image using reusable buffers.
  ##
  ## This avoids allocating the destination HAILO input buffer and the libyuv
  ## RGBA scratch image for every uploaded JPEG.  The scratch image is still
  ## resized automatically if the input aspect ratio changes.
  let srcView = image.pixieToLibyuvRgbaView()
  workspace.ensureYoloPreprocessWorkspace()

  var dstView = workspace.rgb.rgbImageView()
  let lbRes = srcView.toRgbLetterboxInto(
    dstView,
    workspace.scratchRgba,
    RgbPadColor(r: YoloPadValue, g: YoloPadValue, b: YoloPadValue)
  )
  if lbRes.isErr:
    raise newException(ValueError, $lbRes.error)

  result = YoloInputImage(
    rgb: workspace.rgb,
    info: lbRes.get().toYoloInfo()
  )

proc prepareYoloInput*(image: Image): YoloInputImage =
  ## Compatibility helper for one-shot callers.
  ##
  ## Worker-thread code should prefer the overload that accepts
  ## YoloPreprocessWorkspace so buffers are reused across jobs.
  var workspace: YoloPreprocessWorkspace
  result = image.prepareYoloInput(workspace)

proc inputBufferLen*(input: YoloInputImage): int =
  input.rgb.data.len

proc inputBufferPtr*(input: var YoloInputImage): ptr uint8 =
  if input.rgb.data.len == 0:
    return nil
  result = addr input.rgb.data[0]
