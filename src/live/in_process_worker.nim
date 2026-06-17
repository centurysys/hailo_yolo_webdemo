## In-process live worker media-output scaffold.
##
## The compact demo keeps live-session control inside the main
## hailo_yolo_webdemo process.  This worker still uses ffmpeg as a temporary
## copy-relay media backend, but the process is owned by the internal live
## worker thread instead of by live_session.nim directly.
##
## This revision adds a small worker status snapshot so the session controller
## can detect ffmpeg start, normal exit, and unexpected exit while the UI is
## polling /api/live/session.

import std/[locks, os, osproc, strformat, strutils]

const
  DefaultPollIntervalMs = 200


type
  InProcessWorkerSnapshot* = object
    started*: bool
    running*: bool
    finished*: bool
    stopRequested*: bool
    relayPid*: int
    exitCode*: int
    message*: string

  InProcessWorkerState = object
    lock: Lock
    stopRequested: bool
    snapshot: InProcessWorkerSnapshot
    ffmpegPath: string
    inputRtsp: string
    outputRtsp: string
    cameraId: string
    cameraName: string

  InProcessLiveWorker* = ref object
    thread: Thread[ptr InProcessWorkerState]
    state: InProcessWorkerState
    joined: bool
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

proc setWorkerSnapshot(
    state: ptr InProcessWorkerState;
    started, running, finished: bool;
    relayPid, exitCode: int;
    message: string
  ) =
  withLock state.lock:
    state.snapshot.started = started
    state.snapshot.running = running
    state.snapshot.finished = finished
    state.snapshot.stopRequested = state.stopRequested
    state.snapshot.relayPid = relayPid
    state.snapshot.exitCode = exitCode
    state.snapshot.message = message

proc setWorkerMessage(state: ptr InProcessWorkerState; message: string) =
  withLock state.lock:
    state.snapshot.stopRequested = state.stopRequested
    state.snapshot.message = message

proc workerStopRequested(state: ptr InProcessWorkerState): bool =
  withLock state.lock:
    result = state.stopRequested

proc requestStop(worker: InProcessLiveWorker) =
  if worker.isNil or worker.closed:
    return
  withLock worker.state.lock:
    worker.state.stopRequested = true
    worker.state.snapshot.stopRequested = true
    if worker.state.snapshot.running:
      worker.state.snapshot.message = &"stop requested for in-process live worker on /{worker.state.cameraId}"

proc startCopyRelay(state: ptr InProcessWorkerState): Process =
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

proc stopCopyRelay(process: var Process): int =
  result = 0
  if process.isNil:
    return

  try:
    if process.running():
      process.terminate()
      result = process.waitForExit()
    else:
      result = process.waitForExit()
  except CatchableError:
    try:
      process.kill()
      result = process.waitForExit()
    except CatchableError:
      result = -1

  try:
    process.close()
  except CatchableError:
    discard
  process = nil

proc inProcessWorkerMain(state: ptr InProcessWorkerState) {.thread.} =
  echo &"in-process live worker thread started for {state.cameraId} ({state.cameraName})"

  var relayProcess: Process = nil
  var relayPid = 0
  var finalExitCode = 0
  var finalMessage = ""

  setWorkerSnapshot(
    state,
    started = true,
    running = false,
    finished = false,
    relayPid = 0,
    exitCode = 0,
    message = &"in-process live worker is starting ffmpeg copy relay for /{state.cameraId}"
  )

  try:
    try:
      relayProcess = startCopyRelay(state)
      relayPid = relayProcess.processID()
      finalMessage = &"in-process live worker is publishing {state.inputRtsp} -> {state.outputRtsp}"
      setWorkerSnapshot(
        state,
        started = true,
        running = true,
        finished = false,
        relayPid = relayPid,
        exitCode = 0,
        message = finalMessage
      )
      echo finalMessage
    except CatchableError as e:
      finalExitCode = -1
      finalMessage = &"in-process live worker failed to start copy relay: {e.msg}"
      echo finalMessage
      setWorkerSnapshot(
        state,
        started = true,
        running = false,
        finished = true,
        relayPid = 0,
        exitCode = finalExitCode,
        message = finalMessage
      )
      return

    while true:
      if workerStopRequested(state):
        setWorkerMessage(state, &"stopping in-process live worker copy relay for /{state.cameraId}")
        finalExitCode = stopCopyRelay(relayProcess)
        finalMessage = &"in-process live worker stopped copy relay for /{state.cameraId}"
        break

      if relayProcess.isNil:
        finalExitCode = -1
        finalMessage = "in-process live worker copy relay disappeared"
        break

      if not relayProcess.running():
        finalExitCode = relayProcess.waitForExit()
        try:
          relayProcess.close()
        except CatchableError:
          discard
        relayProcess = nil
        if finalExitCode == 0:
          finalMessage = &"in-process live worker copy relay exited for /{state.cameraId}"
        else:
          finalMessage = &"in-process live worker copy relay exited with code {finalExitCode} for /{state.cameraId}"
        break

      sleep(DefaultPollIntervalMs)

  finally:
    if relayProcess != nil:
      let code = stopCopyRelay(relayProcess)
      if finalMessage.len == 0:
        finalExitCode = code
        finalMessage = &"in-process live worker stopped copy relay for /{state.cameraId}"

    if finalMessage.len == 0:
      finalMessage = &"in-process live worker stopped for /{state.cameraId}"

    setWorkerSnapshot(
      state,
      started = true,
      running = false,
      finished = true,
      relayPid = relayPid,
      exitCode = finalExitCode,
      message = finalMessage
    )
    echo &"in-process live worker thread stopped for {state.cameraId}: {finalMessage}"

proc startInProcessLiveWorker*(
    inputRtsp: string;
    outputRtsp: string;
    cameraId: string;
    cameraName: string;
    ffmpegPath: string
  ): InProcessLiveWorker =
  ## Start the internal live worker thread.
  ##
  ## This step connects a temporary ffmpeg copy relay inside the worker thread.
  ## The external process is an implementation detail of this scaffold; the
  ## session controller still treats this as the in-process worker path.
  if ffmpegPath.len == 0:
    raise newException(IOError, "ffmpeg path is empty")
  if ffmpegPath.contains("/") and not fileExists(ffmpegPath):
    raise newException(IOError, &"ffmpeg not found: {ffmpegPath}")

  echo &"starting in-process live worker for {cameraId} ({cameraName}): {inputRtsp} -> {outputRtsp}"

  result = InProcessLiveWorker()
  initLock(result.state.lock)
  result.state.stopRequested = false
  result.state.snapshot = InProcessWorkerSnapshot(
    started: false,
    running: false,
    finished: false,
    stopRequested: false,
    relayPid: 0,
    exitCode: 0,
    message: &"in-process live worker has not started yet for /{cameraId}"
  )
  result.state.ffmpegPath = ffmpegPath
  result.state.inputRtsp = inputRtsp
  result.state.outputRtsp = outputRtsp
  result.state.cameraId = cameraId
  result.state.cameraName = cameraName
  result.joined = false
  result.closed = false

  createThread(result.thread, inProcessWorkerMain, addr result.state)

proc snapshot*(worker: InProcessLiveWorker): InProcessWorkerSnapshot {.gcsafe.} =
  if worker.isNil:
    return InProcessWorkerSnapshot(
      started: false,
      running: false,
      finished: true,
      stopRequested: false,
      relayPid: 0,
      exitCode: 0,
      message: "in-process live worker is not running"
    )

  {.cast(gcsafe).}:
    withLock worker.state.lock:
      result = worker.state.snapshot
      result.stopRequested = worker.state.stopRequested

proc isRunning*(worker: InProcessLiveWorker): bool {.gcsafe.} =
  let snap = worker.snapshot()
  result = worker != nil and snap.running and not snap.finished and not worker.closed

proc close*(worker: InProcessLiveWorker) =
  if worker.isNil or worker.closed:
    return

  worker.requestStop()

  if not worker.joined:
    joinThread(worker.thread)
    worker.joined = true

  worker.closed = true
