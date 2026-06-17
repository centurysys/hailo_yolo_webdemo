## Small RTSP decode probe for the in-process live pipeline bring-up.
##
## The current /cam-ai output is still produced by the temporary ffmpeg-copy
## backend.  This module lets the same in-process worker also open the selected
## RTSP input through libav_nim and read a bounded number of decoded frames.
## That validates the native RTSP/decode side before replacing the relay backend
## with the real decode -> infer -> overlay -> encode pipeline.

import std/[os, strformat, strutils, times]

import libav_nim

const
  DefaultLiveDecoderName = "h264_v4l2m2m"
  DefaultProbeFrames = 0
  MaxProbeFrames = 300

type
  LiveDecodeProbeStats* = object
    attempted*: bool
    ok*: bool
    frames*: int
    width*: int
    height*: int
    decoderName*: string
    elapsedMs*: int
    openMs*: int
    readMs*: int
    message*: string

proc elapsedMs(start: float): int =
  result = int((epochTime() - start) * 1000.0 + 0.5)
  if result < 0:
    result = 0

proc checkAv[T](ret: FFmpegResult[T]; context: string): T =
  if ret.isErr:
    raise newException(IOError, &"{context}: {ret.error.message}")
  result = ret.value

proc parseEnvInt(name: string; defaultValue, lo, hi: int): int =
  let raw = getEnv(name, $defaultValue).strip()
  try:
    result = parseInt(raw)
  except ValueError:
    result = defaultValue

  if result < lo:
    result = lo
  if result > hi:
    result = hi

proc getLiveDecodeProbeFrames*(): int =
  ## Number of frames to read for the live RTSP decode probe.
  ##
  ## The default is disabled because this probe opens and closes libav/HW decoder
  ## state inside the web demo process.  Set HAILO_DEMO_LIVE_DECODE_PROBE_FRAMES
  ## to a positive value only for bring-up diagnostics.
  result = parseEnvInt(
    "HAILO_DEMO_LIVE_DECODE_PROBE_FRAMES",
    DefaultProbeFrames,
    0,
    MaxProbeFrames
  )

proc getLiveDecoderName*(): string =
  ## Decoder used by the native RTSP decode probe.
  ##
  ## Use "auto" to let FFmpeg choose the decoder.
  let raw = getEnv("HAILO_DEMO_LIVE_DECODER", DefaultLiveDecoderName).strip()
  if raw.len == 0 or raw == "auto":
    result = ""
  else:
    result = raw

proc runLiveDecodeProbe*(inputRtsp: string; decoderName = ""; maxFrames = DefaultProbeFrames): LiveDecodeProbeStats =
  result.attempted = maxFrames > 0
  result.decoderName = decoderName

  if maxFrames <= 0:
    result.ok = true
    result.message = "live decode probe is disabled"
    return

  let totalStart = epochTime()
  var decoder: VideoDecoder

  try:
    let openStart = epochTime()
    decoder = checkAv(
      openVideoDecoder(inputRtsp, DecoderOptions(decoderName: decoderName)),
      &"openVideoDecoder input={inputRtsp}"
    )
    result.openMs = elapsedMs(openStart)

    for i in 0 ..< maxFrames:
      let readStart = epochTime()
      let read = checkAv(decoder.readFrame(), &"readFrame#{i}")
      result.readMs += elapsedMs(readStart)

      if read.eof:
        break

      inc result.frames
      result.width = read.frame.width
      result.height = read.frame.height

    result.elapsedMs = elapsedMs(totalStart)
    result.ok = result.frames > 0
    if result.ok:
      let decoderLabel = if decoderName.len > 0: decoderName else: "auto"
      result.message = &"live decode probe read {result.frames} frame(s) {result.width}x{result.height} with decoder={decoderLabel} in {result.elapsedMs} ms"
    else:
      result.message = &"live decode probe opened input but read no video frame in {result.elapsedMs} ms"

  except CatchableError as e:
    result.elapsedMs = elapsedMs(totalStart)
    result.ok = false
    result.message = &"live decode probe failed: {e.msg}"

  finally:
    if not decoder.isNil:
      try:
        decoder.close()
      except CatchableError:
        discard
