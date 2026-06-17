## Decoded video frame source abstraction.
##
## This is the first small seam between input-specific code and the existing
## MP4-proven frame pipeline.  File inputs and live RTSP inputs both become a
## stream of borrowed YUV420 frames; callers must copy/convert the returned
## frame before reading the next one, exactly like the existing MP4 reader does.

import std/[strformat, strutils, times]

import libav_nim

const
  DefaultLiveDecoderName* = "h264_v4l2m2m"


type
  DecodedVideoSourceKind* = enum
    dvskFile
    dvskLiveRtsp

  DecodedVideoReadStatus* = enum
    dvrsFrame
    dvrsEof
    dvrsStopRequested
    dvrsInputTimeout

  DecodedVideoSource* = object
    ## Owns the libav decoder.  Returned frames borrow storage from this decoder
    ## and remain valid only until the next readDecodedFrame() call or close().
    kind*: DecodedVideoSourceKind
    input*: string
    decoderName*: string
    decoderLabel*: string
    decoderOpenMs*: int
    nextFrameIndex*: int
    decoder*: VideoDecoder

  DecodedVideoFrameRead* = object
    status*: DecodedVideoReadStatus
    read*: ReadFrame
    readMs*: int
    frameIndex*: int
    frameWidth*: int
    frameHeight*: int
    timestampSeconds*: float64
    hasTimestampSeconds*: bool

proc elapsedMs(start: float): int =
  result = int((epochTime() - start) * 1000.0 + 0.5)
  if result < 0:
    result = 0

proc checkAv[T](ret: FFmpegResult[T]; context: string): T =
  if ret.isErr:
    raise newException(IOError, &"{context}: {ret.error.message}")
  result = ret.value

proc normalizeDecoderName*(requested: string; defaultName = ""): string =
  let raw = requested.strip()
  if raw.len > 0:
    if raw == "auto":
      return ""
    return raw

  let fallback = defaultName.strip()
  if fallback.len == 0 or fallback == "auto":
    result = ""
  else:
    result = fallback

proc decoderLabel*(decoderName: string): string =
  if decoderName.len > 0: decoderName else: "auto"

proc openDecodedVideoSource*(
    input: string;
    kind: DecodedVideoSourceKind;
    decoderName = "";
    defaultDecoderName = ""
  ): DecodedVideoSource =
  let actualDecoderName = normalizeDecoderName(decoderName, defaultDecoderName)
  let label = actualDecoderName.decoderLabel()

  let openStart = epochTime()
  result.decoder = checkAv(
    openVideoDecoder(input, DecoderOptions(decoderName: actualDecoderName)),
    &"openVideoDecoder input={input} decoder={label}"
  )
  result.decoderOpenMs = elapsedMs(openStart)
  result.kind = kind
  result.input = input
  result.decoderName = actualDecoderName
  result.decoderLabel = label
  result.nextFrameIndex = 0

proc openFileDecodedVideoSource*(inputPath: string; decoderName = ""): DecodedVideoSource =
  result = openDecodedVideoSource(inputPath, dvskFile, decoderName)

proc openLiveDecodedVideoSource*(inputRtsp: string; decoderName = ""): DecodedVideoSource =
  result = openDecodedVideoSource(
    inputRtsp,
    dvskLiveRtsp,
    decoderName,
    DefaultLiveDecoderName
  )

proc isOpen*(source: DecodedVideoSource): bool =
  result = not source.decoder.isNil

proc close*(source: var DecodedVideoSource) =
  if not source.decoder.isNil:
    source.decoder.close()
    source.decoder = nil

proc readDecodedFrame*(source: var DecodedVideoSource): DecodedVideoFrameRead =
  ## Read one decoded frame.
  ##
  ## EOF is reported as dvrsEof.  Stop/timeout statuses are reserved for the
  ## live pipeline once libav_nim exposes interrupt/read-timeout controls; the
  ## caller-side state machine can already treat them the same as UI Stop.
  if source.decoder.isNil:
    raise newException(IOError, "decoded video source is not open")

  let index = source.nextFrameIndex
  let readStart = epochTime()
  let read = checkAv(source.decoder.readFrame(), &"readFrame#{index}")

  result.readMs = elapsedMs(readStart)
  result.frameIndex = index

  if read.eof:
    result.status = dvrsEof
    return

  result.status = dvrsFrame
  result.read = read
  result.frameWidth = read.frame.width
  result.frameHeight = read.frame.height
  var seconds = 0.0
  if read.frame.timestamp.timestampSeconds(seconds):
    result.timestampSeconds = seconds
    result.hasTimestampSeconds = true
  inc source.nextFrameIndex

proc eof*(read: DecodedVideoFrameRead): bool =
  result = read.status == dvrsEof

proc hasFrame*(read: DecodedVideoFrameRead): bool =
  result = read.status == dvrsFrame
