## In-process live worker media-output scaffold.
##
## The preview path still uses the temporary ffmpeg-copy backend.  The attempted
## in-process async inference monitor is intentionally disabled here because the
## HAILO worker must be owned by a long-lived thread, not by this transient live
## session worker.

import std/[locks, os, strformat, strutils]

import ./live_infer_monitor
import ./live_infer_owner
import ./live_pipeline

const
  DefaultPollIntervalMs = 200
  EnvInferFrames = "HAILO_DEMO_LIVE_INFER_MONITOR_FRAMES"
  EnvInferWarmup = "HAILO_DEMO_LIVE_INFER_MONITOR_WARMUP"
  EnvInferInflight = "HAILO_DEMO_LIVE_INFER_INFLIGHT"
  EnvInferDecoder = "HAILO_DEMO_LIVE_DECODER"
  EnvInferVerbose = "HAILO_DEMO_LIVE_INFER_VERBOSE"

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

    liveInferAttempted*: bool
    liveInferOk*: bool
    liveInferFrames*: int
    liveInferWidth*: int
    liveInferHeight*: int
    liveInferDetections*: int
    liveInferMaxScorePercent*: int
    liveInferThroughputFps*: float64
    liveInferProcessingMs*: int
    liveInferReadMs*: int
    liveInferLetterboxMs*: int
    liveInferWaitMs*: int
    liveInferHailoWriteUs*: int64
    liveInferHailoReadUs*: int64
    liveInferMessage*: string

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
    inferDecoderName: string
    inferFrames: int
    inferWarmupFrames: int
    inferInFlight: int
    inferVerbose: bool
    inferOwner: LiveInferOwner
    inferOwnerGeneration: uint64

  InProcessLiveWorker* = ref object
    thread: Thread[ptr InProcessWorkerState]
    state: InProcessWorkerState
    joined: bool
    closed: bool

proc parseEnvInt(name: string; defaultValue, minValue, maxValue: int): int =
  result = defaultValue
  let raw = getEnv(name, "").strip()
  if raw.len > 0:
    try:
      result = parseInt(raw)
    except ValueError:
      result = defaultValue
  if result < minValue:
    result = minValue
  if result > maxValue:
    result = maxValue

proc parseEnvBool(name: string; defaultValue = false): bool =
  let raw = getEnv(name, "").strip().toLowerAscii()
  if raw.len == 0:
    return defaultValue
  result = raw in ["1", "true", "yes", "on", "verbose"]

proc defaultInferDecoderName(): string =
  result = getEnv(EnvInferDecoder, DefaultDecoder).strip()
  if result.len == 0:
    result = DefaultDecoder

proc defaultInferFrames(): int =
  ## Keep this disabled by default in service builds until explicitly enabled.
  ## The standalone hailo-live-infer-probe remains the safest diagnostic tool.
  result = parseEnvInt(EnvInferFrames, 0, 0, 1000)

proc defaultInferWarmupFrames(): int =
  result = parseEnvInt(EnvInferWarmup, DefaultWarmupFrames, 0, 300)

proc defaultInferInFlight(): int =
  result = parseEnvInt(EnvInferInflight, DefaultInFlight, 1, 16)

proc defaultInferVerbose(): bool =
  result = parseEnvBool(EnvInferVerbose, false)

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

proc applyInferSummary(state: ptr InProcessWorkerState; summary: LiveInferMonitorSummary) =
  withLock state.lock:
    state.snapshot.liveInferAttempted = summary.attempted
    state.snapshot.liveInferOk = summary.ok
    state.snapshot.liveInferFrames = summary.inferredFrames
    state.snapshot.liveInferWidth = summary.width
    state.snapshot.liveInferHeight = summary.height
    state.snapshot.liveInferDetections = summary.detections
    state.snapshot.liveInferMaxScorePercent = summary.maxScorePercent
    state.snapshot.liveInferThroughputFps = summary.throughputFps
    state.snapshot.liveInferProcessingMs = summary.processingMs
    state.snapshot.liveInferReadMs = summary.readMs
    state.snapshot.liveInferLetterboxMs = summary.letterboxMs
    state.snapshot.liveInferWaitMs = summary.waitMs
    state.snapshot.liveInferHailoWriteUs = summary.hailoWriteUs
    state.snapshot.liveInferHailoReadUs = summary.hailoReadUs
    state.snapshot.liveInferMessage = summary.message
    state.snapshot.stopRequested = state.stopRequested

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

proc applyOwnerSnapshot(state: ptr InProcessWorkerState) {.gcsafe.} =
  if state.inferOwner.isNil:
    withLock state.lock:
      state.snapshot.liveInferAttempted = false
      state.snapshot.liveInferOk = false
      state.snapshot.liveInferFrames = 0
      state.snapshot.liveInferWidth = 0
      state.snapshot.liveInferHeight = 0
      state.snapshot.liveInferDetections = 0
      state.snapshot.liveInferMaxScorePercent = 0
      state.snapshot.liveInferThroughputFps = 0.0
      state.snapshot.liveInferProcessingMs = 0
      state.snapshot.liveInferReadMs = 0
      state.snapshot.liveInferLetterboxMs = 0
      state.snapshot.liveInferWaitMs = 0
      state.snapshot.liveInferHailoWriteUs = 0
      state.snapshot.liveInferHailoReadUs = 0
      state.snapshot.liveInferMessage = "live inference owner is not available"
      state.snapshot.stopRequested = state.stopRequested
    return

  let ownerSnap = state.inferOwner.snapshot()
  withLock state.lock:
    state.snapshot.liveInferAttempted = ownerSnap.attempted or ownerSnap.running
    state.snapshot.liveInferOk = ownerSnap.ok
    state.snapshot.liveInferFrames = ownerSnap.inferredFrames
    state.snapshot.liveInferWidth = ownerSnap.width
    state.snapshot.liveInferHeight = ownerSnap.height
    state.snapshot.liveInferDetections = ownerSnap.detections
    state.snapshot.liveInferMaxScorePercent = ownerSnap.maxScorePercent
    state.snapshot.liveInferThroughputFps = ownerSnap.throughputFps
    state.snapshot.liveInferProcessingMs = ownerSnap.processingMs
    state.snapshot.liveInferReadMs = ownerSnap.readMs
    state.snapshot.liveInferLetterboxMs = ownerSnap.letterboxMs
    state.snapshot.liveInferWaitMs = ownerSnap.waitMs
    state.snapshot.liveInferHailoWriteUs = ownerSnap.hailoWriteUs
    state.snapshot.liveInferHailoReadUs = ownerSnap.hailoReadUs
    state.snapshot.liveInferMessage = ownerSnap.message
    state.snapshot.stopRequested = state.stopRequested

proc runOptionalInferMonitor(state: ptr InProcessWorkerState) {.gcsafe.} =
  ## Ask the long-lived live inference owner thread to run the bounded monitor.
  ##
  ## This transient live session worker never opens/closes HAILO directly.  It
  ## only starts/stops the preview publisher and mirrors owner status into the
  ## live session JSON.  This follows the file pipeline's safe pattern: submit
  ## work to the owner, let the owner drain pending HAILO results, and avoid
  ## tearing down seq-owning worker state from the wrong thread.
  if state.inferFrames <= 0:
    withLock state.lock:
      state.snapshot.liveInferAttempted = false
      state.snapshot.liveInferOk = false
      state.snapshot.liveInferFrames = 0
      state.snapshot.liveInferWidth = 0
      state.snapshot.liveInferHeight = 0
      state.snapshot.liveInferDetections = 0
      state.snapshot.liveInferMaxScorePercent = 0
      state.snapshot.liveInferThroughputFps = 0.0
      state.snapshot.liveInferProcessingMs = 0
      state.snapshot.liveInferReadMs = 0
      state.snapshot.liveInferLetterboxMs = 0
      state.snapshot.liveInferWaitMs = 0
      state.snapshot.liveInferHailoWriteUs = 0
      state.snapshot.liveInferHailoReadUs = 0
      state.snapshot.liveInferMessage = "live inference monitor is disabled"
      state.snapshot.stopRequested = state.stopRequested
    return

  if state.inferOwner.isNil:
    withLock state.lock:
      state.snapshot.liveInferAttempted = false
      state.snapshot.liveInferOk = false
      state.snapshot.liveInferMessage = "live inference owner is not available; use hailo-live-infer-probe for diagnostics"
      state.snapshot.stopRequested = state.stopRequested
    echo "live inference owner is not available; monitor request skipped"
    return

  let gen = state.inferOwner.requestMonitor(
    inputRtsp = state.inputRtsp,
    cameraId = state.cameraId,
    cameraName = state.cameraName,
    decoderName = state.inferDecoderName,
    frames = state.inferFrames,
    warmupFrames = state.inferWarmupFrames,
    inFlight = state.inferInFlight,
    verbose = state.inferVerbose
  )

  state.inferOwnerGeneration = gen
  if gen == 0'u64:
    let msg = "failed to enqueue live inference monitor request"
    withLock state.lock:
      state.snapshot.liveInferAttempted = false
      state.snapshot.liveInferOk = false
      state.snapshot.liveInferMessage = msg
      state.snapshot.stopRequested = state.stopRequested
    echo msg
  else:
    let msg = &"live inference owner request queued: generation={gen}, frames={state.inferFrames}, inflight={state.inferInFlight}"
    withLock state.lock:
      state.snapshot.liveInferAttempted = true
      state.snapshot.liveInferOk = false
      state.snapshot.liveInferMessage = msg
      state.snapshot.stopRequested = state.stopRequested
    echo msg

proc buildRunningMessage(state: ptr InProcessWorkerState): string =
  var inferPart = "inference monitor is disabled"
  withLock state.lock:
    if state.snapshot.liveInferAttempted:
      if state.snapshot.liveInferOk:
        inferPart = &"live async inference monitor: {state.snapshot.liveInferFrames} frame(s), {state.snapshot.liveInferThroughputFps:.2f} fps"
      else:
        inferPart = state.snapshot.liveInferMessage
  result = &"in-process live worker is publishing /{state.cameraId} to /cam-ai via ffmpeg-copy pipeline; {inferPart}"

proc inProcessWorkerMain(state: ptr InProcessWorkerState) {.thread.} =
  echo &"in-process live worker thread started for {state.cameraId} ({state.cameraName})"

  var pipeline: LivePipelineHandle = nil
  var relayPid = 0
  var finalExitCode = 0
  var finalMessage = ""
  var inferMonitorDone = false

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

    ## Run a bounded monitor once after the preview publisher is up.  Keep the
    ## preview path alive afterwards; this step only observes HAILO throughput.
    if not inferMonitorDone and not workerStopRequested(state):
      inferMonitorDone = true
      runOptionalInferMonitor(state)

    while true:
      if workerStopRequested(state):
        setWorkerMessage(state, &"stopping in-process live worker pipeline for /{state.cameraId}")
        if not state.inferOwner.isNil and state.inferOwnerGeneration != 0'u64:
          state.inferOwner.requestStopSession(state.inferOwnerGeneration)
          applyOwnerSnapshot(state)
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

      applyOwnerSnapshot(state)
      setWorkerSnapshot(
        state,
        started = true,
        running = true,
        finished = false,
        relayPid = pollRes.relayPid,
        exitCode = pollRes.exitCode,
        message = buildRunningMessage(state)
      )

      sleep(DefaultPollIntervalMs)

  finally:
    if not state.inferOwner.isNil and state.inferOwnerGeneration != 0'u64:
      state.inferOwner.requestStopSession(state.inferOwnerGeneration)
      applyOwnerSnapshot(state)

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
    ffmpegPath: string;
    inferDecoderName = "";
    inferFrames = -1;
    inferWarmupFrames = -1;
    inferInFlight = -1;
    inferVerbose = false;
    liveInferOwner: LiveInferOwner = nil
  ): InProcessLiveWorker =
  ## Start the internal live worker thread.
  ##
  ## The ffmpeg-copy preview path remains the output path.  Optional live
  ## inference monitoring is delegated to a long-lived LiveInferOwner thread.
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
    liveInferAttempted: false,
    liveInferOk: false,
    liveInferMessage: "live inference monitor has not started yet",
    message: &"in-process live worker has not started yet for /{cameraId}"
  )
  result.state.ffmpegPath = ffmpegPath
  result.state.inputRtsp = inputRtsp
  result.state.outputRtsp = outputRtsp
  result.state.cameraId = cameraId
  result.state.cameraName = cameraName
  result.state.inferDecoderName = if inferDecoderName.strip().len > 0: inferDecoderName.strip() else: defaultInferDecoderName()
  result.state.inferFrames = if inferFrames >= 0: inferFrames else: defaultInferFrames()
  result.state.inferWarmupFrames = if inferWarmupFrames >= 0: inferWarmupFrames else: defaultInferWarmupFrames()
  result.state.inferInFlight = if inferInFlight > 0: inferInFlight else: defaultInferInFlight()
  result.state.inferVerbose = inferVerbose or defaultInferVerbose()
  result.state.inferOwner = liveInferOwner
  result.state.inferOwnerGeneration = 0'u64
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
      liveInferAttempted: false,
      liveInferOk: false,
      liveInferMessage: "in-process live worker is not running",
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
