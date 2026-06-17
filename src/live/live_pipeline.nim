## Live media pipeline backend interface.
##
## The current demo backend is still an ffmpeg copy relay.  Keeping it behind
## this small interface lets in_process_worker.nim own the lifecycle in one
## place, while the temporary media backend can later be replaced by the real
## RTSP decode -> HAILO infer -> overlay -> encode -> RTSP publish pipeline.

import std/[os, osproc, strformat, strutils]

type
  LivePipelineBackend* = enum
    lpbFfmpegCopy

  LivePipelineStartConfig* = object
    backend*: LivePipelineBackend
    ffmpegPath*: string
    inputRtsp*: string
    outputRtsp*: string
    cameraId*: string
    cameraName*: string

  LivePipelinePollResult* = object
    running*: bool
    finished*: bool
    exitCode*: int
    relayPid*: int
    message*: string

  LivePipelineHandle* = ref object
    backend*: LivePipelineBackend
    command*: string
    args*: seq[string]
    relayPid*: int
    process: Process
    closed: bool
    exitCode: int
    finalMessage: string

proc backendName*(backend: LivePipelineBackend): string =
  case backend
  of lpbFfmpegCopy:
    "ffmpeg-copy"

proc ffmpegCopyArgs*(inputRtsp, outputRtsp: string): seq[string] =
  @[
    "-nostdin",
    "-hide_banner",
    "-loglevel", "warning",
    "-rtsp_transport", "tcp",
    "-fflags", "nobuffer",
    "-flags", "low_delay",
    "-i", inputRtsp,
    "-an",
    "-c:v", "copy",
    "-rtsp_transport", "tcp",
    "-f", "rtsp",
    outputRtsp
  ]

proc validateFfmpegPath(ffmpegPath: string) =
  if ffmpegPath.len == 0:
    raise newException(IOError, "ffmpeg path is empty")
  if ffmpegPath.contains("/") and not fileExists(ffmpegPath):
    raise newException(IOError, &"ffmpeg not found: {ffmpegPath}")

proc startFfmpegCopy(config: LivePipelineStartConfig): LivePipelineHandle =
  validateFfmpegPath(config.ffmpegPath)

  result = LivePipelineHandle(
    backend: lpbFfmpegCopy,
    command: config.ffmpegPath,
    args: ffmpegCopyArgs(config.inputRtsp, config.outputRtsp),
    relayPid: 0,
    process: nil,
    closed: false,
    exitCode: 0,
    finalMessage: ""
  )

  echo "live pipeline exec: ", result.command, " ", result.args.join(" ")
  result.process = startProcess(
    result.command,
    args = result.args,
    options = {poUsePath, poParentStreams}
  )
  result.relayPid = result.process.processID()

proc startLivePipeline*(config: LivePipelineStartConfig): LivePipelineHandle =
  case config.backend
  of lpbFfmpegCopy:
    result = startFfmpegCopy(config)

proc poll*(handle: LivePipelineHandle): LivePipelinePollResult =
  if handle.isNil:
    return LivePipelinePollResult(
      running: false,
      finished: true,
      exitCode: -1,
      relayPid: 0,
      message: "live pipeline handle is nil"
    )

  if handle.closed:
    return LivePipelinePollResult(
      running: false,
      finished: true,
      exitCode: handle.exitCode,
      relayPid: handle.relayPid,
      message: handle.finalMessage
    )

  if handle.process.isNil:
    handle.closed = true
    handle.exitCode = -1
    handle.finalMessage = &"{handle.backend.backendName} pipeline process is missing"
    return LivePipelinePollResult(
      running: false,
      finished: true,
      exitCode: handle.exitCode,
      relayPid: handle.relayPid,
      message: handle.finalMessage
    )

  if handle.process.running():
    return LivePipelinePollResult(
      running: true,
      finished: false,
      exitCode: 0,
      relayPid: handle.relayPid,
      message: &"{handle.backend.backendName} pipeline is running"
    )

  handle.exitCode = handle.process.waitForExit()
  try:
    handle.process.close()
  except CatchableError:
    discard
  handle.process = nil
  handle.closed = true

  if handle.exitCode == 0:
    handle.finalMessage = &"{handle.backend.backendName} pipeline exited"
  else:
    handle.finalMessage = &"{handle.backend.backendName} pipeline exited with code {handle.exitCode}"

  result = LivePipelinePollResult(
    running: false,
    finished: true,
    exitCode: handle.exitCode,
    relayPid: handle.relayPid,
    message: handle.finalMessage
  )

proc stop*(handle: LivePipelineHandle): LivePipelinePollResult =
  if handle.isNil:
    return LivePipelinePollResult(
      running: false,
      finished: true,
      exitCode: 0,
      relayPid: 0,
      message: "live pipeline was not running"
    )

  if handle.closed:
    return handle.poll()

  if handle.process.isNil:
    handle.closed = true
    handle.exitCode = -1
    handle.finalMessage = &"{handle.backend.backendName} pipeline process is missing"
    return handle.poll()

  try:
    if handle.process.running():
      handle.process.terminate()
      handle.exitCode = handle.process.waitForExit()
    else:
      handle.exitCode = handle.process.waitForExit()
  except CatchableError:
    try:
      handle.process.kill()
      handle.exitCode = handle.process.waitForExit()
    except CatchableError:
      handle.exitCode = -1

  try:
    handle.process.close()
  except CatchableError:
    discard
  handle.process = nil
  handle.closed = true
  handle.finalMessage = &"{handle.backend.backendName} pipeline stopped"

  result = LivePipelinePollResult(
    running: false,
    finished: true,
    exitCode: handle.exitCode,
    relayPid: handle.relayPid,
    message: handle.finalMessage
  )

proc close*(handle: LivePipelineHandle) =
  discard handle.stop()
