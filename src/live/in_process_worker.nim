## In-process live worker media-output scaffold.
##
## The compact demo now keeps live-session control inside the main
## hailo_yolo_webdemo process.  This worker still uses ffmpeg as a temporary
## copy-relay media backend, but the process is owned by the internal live
## worker thread instead of by live_session.nim directly.
##
## Next steps can replace the ffmpeg copy relay in this module with the real
## RTSP decode -> HAILO infer -> overlay -> encode -> RTSP publish pipeline
## without changing the WebUI/session API contract again.

import std/[os, osproc, strformat, strutils]

import threadtools

const DefaultControlQueueSize = 4

type
  InProcessWorkerCommandKind = enum
    iwcStop

  InProcessWorkerCommand = object
    kind: InProcessWorkerCommandKind

  InProcessWorkerState = object
    queue: ThreadQueue[InProcessWorkerCommand]
    ffmpegPath: string
    inputRtsp: string
    outputRtsp: string
    cameraId: string
    cameraName: string

  InProcessLiveWorker* = ref object
    queue: ThreadQueue[InProcessWorkerCommand]
    thread: Thread[ptr InProcessWorkerState]
    state: InProcessWorkerState
    running: bool
    closed: bool

proc ffmpegCopyArgs(inputRtsp, outputRtsp: string): seq[string] =
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

proc startCopyRelay(state: InProcessWorkerState): Process =
  if state.ffmpegPath.len == 0:
    raise newException(IOError, "ffmpeg path is empty")
  if state.ffmpegPath.contains("/") and not fileExists(state.ffmpegPath):
    raise newException(IOError, &"ffmpeg not found: {state.ffmpegPath}")

  let args = ffmpegCopyArgs(state.inputRtsp, state.outputRtsp)
  echo "in-process live worker exec: ", state.ffmpegPath, " ", args.join(" ")
  result = startProcess(
    state.ffmpegPath,
    args = args,
    options = {poUsePath, poParentStreams}
  )

proc stopCopyRelay(process: var Process) =
  if process.isNil:
    return

  try:
    if process.running():
      process.terminate()
      discard process.waitForExit()
    else:
      discard process.waitForExit()
  except CatchableError:
    try:
      process.kill()
      discard process.waitForExit()
    except CatchableError:
      discard

  try:
    process.close()
  except CatchableError:
    discard
  process = nil

proc inProcessWorkerMain(state: ptr InProcessWorkerState) {.thread.} =
  echo &"in-process live worker thread started for {state.cameraId} ({state.cameraName})"

  var relayProcess: Process = nil
  try:
    try:
      relayProcess = startCopyRelay(state[])
      echo &"in-process live worker publishing {state.inputRtsp} -> {state.outputRtsp}"
    except CatchableError as e:
      echo &"in-process live worker failed to start copy relay: {e.msg}"
      return

    while true:
      var recvRes = state.queue.receiveResult()
      if recvRes.isErr:
        break

      var cmd = recvRes.take()
      case cmd.kind
      of iwcStop:
        break
  finally:
    stopCopyRelay(relayProcess)
    echo &"in-process live worker thread stopped for {state.cameraId}"

proc startInProcessLiveWorker*(
    inputRtsp: string;
    outputRtsp: string;
    cameraId: string;
    cameraName: string;
    ffmpegPath: string;
    queueSize = DefaultControlQueueSize
  ): InProcessLiveWorker =
  ## Start the internal live worker thread.
  ##
  ## This step connects a temporary ffmpeg copy relay inside the worker thread.
  ## The external process is an implementation detail of this scaffold; the
  ## session controller still treats this as the in-process worker path.
  if queueSize <= 0:
    raise newException(ValueError, &"invalid in-process worker queue size: {queueSize}")
  if ffmpegPath.len == 0:
    raise newException(IOError, "ffmpeg path is empty")
  if ffmpegPath.contains("/") and not fileExists(ffmpegPath):
    raise newException(IOError, &"ffmpeg not found: {ffmpegPath}")

  let qRes = newThreadQueue[InProcessWorkerCommand](queueSize)
  if qRes.isErr:
    raise newException(IOError, &"failed to create in-process worker queue: {qRes.error}")

  echo &"starting in-process live worker for {cameraId} ({cameraName}): {inputRtsp} -> {outputRtsp}"

  result = InProcessLiveWorker()
  result.queue = qRes.get()
  result.state.queue = result.queue
  result.state.ffmpegPath = ffmpegPath
  result.state.inputRtsp = inputRtsp
  result.state.outputRtsp = outputRtsp
  result.state.cameraId = cameraId
  result.state.cameraName = cameraName

  createThread(result.thread, inProcessWorkerMain, addr result.state)
  result.running = true

proc isRunning*(worker: InProcessLiveWorker): bool {.gcsafe.} =
  result = worker != nil and worker.running and not worker.closed

proc close*(worker: InProcessLiveWorker) =
  if worker.isNil or worker.closed:
    return

  if worker.running and not worker.queue.isNil:
    var req = InProcessWorkerCommand(kind: iwcStop)
    let sendRes = worker.queue.sendMove(req)
    if sendRes.isErr:
      worker.queue.close()

    joinThread(worker.thread)
    worker.running = false

  if not worker.queue.isNil:
    worker.queue.close()
    worker.queue = nil

  worker.closed = true
