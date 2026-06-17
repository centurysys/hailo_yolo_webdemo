## In-process live worker media-output scaffold.
##
## The compact demo keeps live-session control inside the main
## hailo_yolo_webdemo process.  The current media backend is still an ffmpeg
## copy-relay, but it is now routed through live_pipeline.nim so this worker can
## later switch to a real decode -> infer -> overlay -> encode pipeline without
## changing the session controller.

import std/[locks, os, strformat]

import ./live_pipeline
import ./live_decode_probe

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
    decodeProbeAttempted*: bool
    decodeProbeOk*: bool
    decodeProbeFrames*: int
    decodeProbeWidth*: int
    decodeProbeHeight*: int
    decodeProbeMs*: int
    decodeProbeMessage*: string
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
    liveDecoderName: string
    decodeProbeFrames: int

  InProcessLiveWorker* = ref object
    thread: Thread[ptr InProcessWorkerState]
    state: InProcessWorkerState
    joined: bool
    closed: bool

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

proc setDecodeProbeSnapshot(state: ptr InProcessWorkerState; stats: LiveDecodeProbeStats) =
  withLock state.lock:
    state.snapshot.stopRequested = state.stopRequested
    state.snapshot.decodeProbeAttempted = stats.attempted
    state.snapshot.decodeProbeOk = stats.ok
    state.snapshot.decodeProbeFrames = stats.frames
    state.snapshot.decodeProbeWidth = stats.width
    state.snapshot.decodeProbeHeight = stats.height
    state.snapshot.decodeProbeMs = stats.elapsedMs
    state.snapshot.decodeProbeMessage = stats.message
    if stats.message.len > 0:
      state.snapshot.message = stats.message

proc workerStopRequested(state: ptr InProcessWorkerState): bool =
  withLock state.lock:
    result = state.stopRequested

proc workerRunningMessage(state: ptr InProcessWorkerState): string =
  var probeAttempted = false
  var probeMessage = ""
  withLock state.lock:
    probeAttempted = state.snapshot.decodeProbeAttempted
    probeMessage = state.snapshot.decodeProbeMessage

  if probeAttempted and probeMessage.len > 0:
    result = &"in-process live worker is publishing /{state.cameraId} to /cam-ai via ffmpeg-copy pipeline; {probeMessage}; inference stage is not connected yet"
  else:
    result = &"in-process live worker is publishing /{state.cameraId} to /cam-ai via ffmpeg-copy pipeline; inference stage is not connected yet"

proc requestStop(worker: InProcessLiveWorker) =
  if worker.isNil or worker.closed:
    return
  withLock worker.state.lock:
    worker.state.stopRequested = true
    worker.state.snapshot.stopRequested = true
    if worker.state.snapshot.running:
      worker.state.snapshot.message = &"stop requested for in-process live worker on /{worker.state.cameraId}"

proc inProcessWorkerMain(state: ptr InProcessWorkerState) {.thread.} =
  echo &"in-process live worker thread started for {state.cameraId} ({state.cameraName})"

  var pipeline: LivePipelineHandle = nil
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
    message = &"in-process live worker is starting ffmpeg-copy pipeline for /{state.cameraId}"
  )

  try:
    try:
      pipeline = startLivePipeline(LivePipelineStartConfig(
        backend: lpbFfmpegCopy,
        ffmpegPath: state.ffmpegPath,
        inputRtsp: state.inputRtsp,
        outputRtsp: state.outputRtsp,
        cameraId: state.cameraId,
        cameraName: state.cameraName
      ))
      relayPid = pipeline.relayPid
      finalMessage = &"in-process live worker is publishing {state.inputRtsp} -> {state.outputRtsp} via ffmpeg-copy pipeline"
      setWorkerSnapshot(
        state,
        started = true,
        running = true,
        finished = false,
        relayPid = relayPid,
        exitCode = 0,
        message = finalMessage
      )
      if state.decodeProbeFrames > 0:
        setWorkerMessage(state, &"probing native RTSP decode for /{state.cameraId}")
        let probe = runLiveDecodeProbe(
          state.inputRtsp,
          decoderName = state.liveDecoderName,
          maxFrames = state.decodeProbeFrames
        )
        setDecodeProbeSnapshot(state, probe)
        echo probe.message
      else:
        setDecodeProbeSnapshot(state, LiveDecodeProbeStats(
          attempted: false,
          ok: true,
          frames: 0,
          width: 0,
          height: 0,
          decoderName: state.liveDecoderName,
          elapsedMs: 0,
          openMs: 0,
          readMs: 0,
          message: "live decode probe is disabled"
        ))

      echo finalMessage
    except CatchableError as e:
      finalExitCode = -1
      finalMessage = &"in-process live worker failed to start pipeline: {e.msg}"
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
        setWorkerMessage(state, &"stopping in-process live worker pipeline for /{state.cameraId}")
        let stopped = pipeline.stop()
        finalExitCode = stopped.exitCode
        finalMessage = &"in-process live worker stopped pipeline for /{state.cameraId}"
        break

      if pipeline.isNil:
        finalExitCode = -1
        finalMessage = "in-process live worker pipeline disappeared"
        break

      let pollRes = pipeline.poll()
      relayPid = pollRes.relayPid
      if pollRes.finished:
        finalExitCode = pollRes.exitCode
        if pollRes.message.len > 0:
          finalMessage = pollRes.message
        elif finalExitCode == 0:
          finalMessage = &"in-process live worker pipeline exited for /{state.cameraId}"
        else:
          finalMessage = &"in-process live worker pipeline exited with code {finalExitCode} for /{state.cameraId}"
        break

      setWorkerSnapshot(
        state,
        started = true,
        running = true,
        finished = false,
        relayPid = pollRes.relayPid,
        exitCode = pollRes.exitCode,
        message = workerRunningMessage(state)
      )

      sleep(DefaultPollIntervalMs)

  finally:
    if pipeline != nil:
      let stopped = pipeline.stop()
      if finalMessage.len == 0:
        finalExitCode = stopped.exitCode
        finalMessage = &"in-process live worker stopped pipeline for /{state.cameraId}"
      pipeline = nil

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
  ## This step still uses the ffmpeg-copy live pipeline backend, but the worker
  ## now talks to it through live_pipeline.nim.  The next media step can add a
  ## second backend without changing live_session.nim.
  if ffmpegPath.len == 0:
    raise newException(IOError, "ffmpeg path is empty")

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
  result.state.liveDecoderName = getLiveDecoderName()
  result.state.decodeProbeFrames = getLiveDecodeProbeFrames()
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
