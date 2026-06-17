## Long-lived live inference owner thread.
##
## The live session worker is intentionally short-lived: it owns the temporary
## /cam-ai preview relay and exits when the user stops the live session.
## HAILO async inference is different.  The async worker and the seq buffers it
## moves through threadtools are sensitive to thread ownership and teardown
## order, so they are owned by this long-lived thread instead.
##
## A live session can request a bounded inference monitor run.  Stop only asks
## the owner to return to idle; the owner thread itself remains alive until the
## Web Demo service exits.

import std/[locks, strformat]

import threadtools

import ./live_infer_monitor

type
  LiveInferOwnerSnapshot* = object
    started*: bool
    running*: bool
    stopRequested*: bool
    shutdownRequested*: bool
    generation*: uint64

    attempted*: bool
    ok*: bool
    inputRtsp*: string
    cameraId*: string
    cameraName*: string
    decoderName*: string
    requestedFrames*: int
    warmupFrames*: int
    inFlight*: int
    decodedFrames*: int
    submittedFrames*: int
    inferredFrames*: int
    width*: int
    height*: int
    detections*: int
    maxScorePercent*: int
    throughputFps*: float64
    processingMs*: int
    readMs*: int
    letterboxMs*: int
    waitMs*: int
    hailoWriteUs*: int64
    hailoReadUs*: int64
    message*: string

  LiveInferOwnerCommandKind = enum
    liocStartMonitor,
    liocStopSession,
    liocShutdown

  LiveInferOwnerCommand = object
    kind: LiveInferOwnerCommandKind
    generation: uint64
    inputRtsp: string
    cameraId: string
    cameraName: string
    decoderName: string
    frames: int
    warmupFrames: int
    inFlight: int
    verbose: bool

  LiveInferOwnerState = object
    lock: Lock
    queue: ThreadQueue[LiveInferOwnerCommand]
    snapshot: LiveInferOwnerSnapshot
    nextGeneration: uint64

  LiveInferOwner* = ref object
    queue: ThreadQueue[LiveInferOwnerCommand]
    thread: Thread[ptr LiveInferOwnerState]
    state: LiveInferOwnerState
    running: bool
    closed: bool

const
  DefaultQueueSize = 8

proc blankSnapshot(message: string): LiveInferOwnerSnapshot =
  LiveInferOwnerSnapshot(
    started: false,
    running: false,
    stopRequested: false,
    shutdownRequested: false,
    generation: 0,
    attempted: false,
    ok: false,
    inputRtsp: "",
    cameraId: "",
    cameraName: "",
    decoderName: "",
    requestedFrames: 0,
    warmupFrames: 0,
    inFlight: 0,
    decodedFrames: 0,
    submittedFrames: 0,
    inferredFrames: 0,
    width: 0,
    height: 0,
    detections: 0,
    maxScorePercent: 0,
    throughputFps: 0.0,
    processingMs: 0,
    readMs: 0,
    letterboxMs: 0,
    waitMs: 0,
    hailoWriteUs: 0,
    hailoReadUs: 0,
    message: message
  )

proc setIdle(state: ptr LiveInferOwnerState; message: string) =
  withLock state.lock:
    state.snapshot.running = false
    state.snapshot.stopRequested = false
    state.snapshot.message = message

proc setStart(state: ptr LiveInferOwnerState; cmd: LiveInferOwnerCommand) =
  withLock state.lock:
    state.snapshot = blankSnapshot(
      &"live inference owner is running monitor for /{cmd.cameraId}"
    )
    state.snapshot.started = true
    state.snapshot.running = true
    state.snapshot.stopRequested = false
    state.snapshot.generation = cmd.generation
    state.snapshot.inputRtsp = cmd.inputRtsp
    state.snapshot.cameraId = cmd.cameraId
    state.snapshot.cameraName = cmd.cameraName
    state.snapshot.decoderName = cmd.decoderName
    state.snapshot.requestedFrames = cmd.frames
    state.snapshot.warmupFrames = cmd.warmupFrames
    state.snapshot.inFlight = cmd.inFlight

proc applySummary(
    state: ptr LiveInferOwnerState;
    cmd: LiveInferOwnerCommand;
    summary: LiveInferMonitorSummary
  ) =
  withLock state.lock:
    ## If a newer generation was already announced, do not overwrite it with an
    ## old monitor result.  This keeps stale completion messages from appearing
    ## after a quick stop/start sequence.
    if state.snapshot.generation != cmd.generation:
      return

    state.snapshot.running = false
    state.snapshot.stopRequested = false
    state.snapshot.attempted = summary.attempted
    state.snapshot.ok = summary.ok
    state.snapshot.inputRtsp = summary.inputRtsp
    state.snapshot.decoderName = summary.decoderName
    state.snapshot.requestedFrames = summary.requestedFrames
    state.snapshot.warmupFrames = summary.warmupFrames
    state.snapshot.inFlight = summary.inFlight
    state.snapshot.decodedFrames = summary.decodedFrames
    state.snapshot.submittedFrames = summary.submittedFrames
    state.snapshot.inferredFrames = summary.inferredFrames
    state.snapshot.width = summary.width
    state.snapshot.height = summary.height
    state.snapshot.detections = summary.detections
    state.snapshot.maxScorePercent = summary.maxScorePercent
    state.snapshot.throughputFps = summary.throughputFps
    state.snapshot.processingMs = summary.processingMs
    state.snapshot.readMs = summary.readMs
    state.snapshot.letterboxMs = summary.letterboxMs
    state.snapshot.waitMs = summary.waitMs
    state.snapshot.hailoWriteUs = summary.hailoWriteUs
    state.snapshot.hailoReadUs = summary.hailoReadUs
    state.snapshot.message = summary.message

proc markStopRequested(state: ptr LiveInferOwnerState; generation: uint64) =
  withLock state.lock:
    state.snapshot.stopRequested = true
    if generation != 0 and state.snapshot.generation == generation:
      state.snapshot.message = &"stop requested for live inference owner generation {generation}"
    elif state.snapshot.running:
      state.snapshot.message = "stop requested for live inference owner"
    else:
      state.snapshot.message = "live inference owner is idle"

proc ownerMain(state: ptr LiveInferOwnerState) {.thread.} =
  echo "live inference owner thread started"

  try:
    while true:
      var recvRes = state.queue.receiveResult()
      if recvRes.isErr:
        break

      var cmd = recvRes.take()
      case cmd.kind
      of liocShutdown:
        withLock state.lock:
          state.snapshot.shutdownRequested = true
          state.snapshot.running = false
          state.snapshot.message = "live inference owner shutdown requested"
        break

      of liocStopSession:
        ## The current bounded monitor cannot be interrupted safely from another
        ## thread.  Stop is recorded and the owner returns to idle after the
        ## current bounded monitor drains all pending HAILO results.  This is the
        ## same idea as the MP4 path: do not discard submitted pending work.
        state.markStopRequested(cmd.generation)

      of liocStartMonitor:
        state.setStart(cmd)
        var summary: LiveInferMonitorSummary
        try:
          ## runLiveInferMonitor uses the shared HAILO async worker path, whose
          ## implementation reaches process-global worker state.  The ownership
          ## discipline is the same as the already-tested file threaded pipeline:
          ## submitted work is drained before returning to idle.  Limit the
          ## GC-safe assertion to this owner-thread monitor call rather than
          ## widening it to the whole thread procedure.
          {.cast(gcsafe).}:
            summary = runLiveInferMonitor(LiveInferMonitorOptions(
              inputRtsp: cmd.inputRtsp,
              decoderName: cmd.decoderName,
              frames: cmd.frames,
              warmupFrames: cmd.warmupFrames,
              inFlight: cmd.inFlight,
              verbose: cmd.verbose
            ))
        except CatchableError as e:
          summary = LiveInferMonitorSummary(
            attempted: true,
            ok: false,
            inputRtsp: cmd.inputRtsp,
            decoderName: cmd.decoderName,
            requestedFrames: cmd.frames,
            warmupFrames: cmd.warmupFrames,
            inFlight: cmd.inFlight,
            message: &"live inference owner monitor failed: {e.msg}"
          )
        state.applySummary(cmd, summary)
  finally:
    withLock state.lock:
      state.snapshot.running = false
      state.snapshot.shutdownRequested = true
      if state.snapshot.message.len == 0:
        state.snapshot.message = "live inference owner thread stopped"
    echo "live inference owner thread stopped"

proc startLiveInferOwner*(queueSize = DefaultQueueSize): LiveInferOwner =
  let qRes = newThreadQueue[LiveInferOwnerCommand](queueSize)
  if qRes.isErr:
    raise newException(IOError, &"failed to create live inference owner queue: {qRes.error}")

  result = LiveInferOwner()
  result.queue = qRes.get()
  initLock(result.state.lock)
  result.state.queue = result.queue
  result.state.nextGeneration = 1
  result.state.snapshot = blankSnapshot("live inference owner is idle")
  result.running = true
  result.closed = false

  createThread(result.thread, ownerMain, addr result.state)

proc snapshot*(owner: LiveInferOwner): LiveInferOwnerSnapshot {.gcsafe.} =
  if owner.isNil:
    return blankSnapshot("live inference owner is not available")

  {.cast(gcsafe).}:
    withLock owner.state.lock:
      result = owner.state.snapshot

proc requestMonitor*(
    owner: LiveInferOwner;
    inputRtsp: string;
    cameraId: string;
    cameraName: string;
    decoderName: string;
    frames: int;
    warmupFrames: int;
    inFlight: int;
    verbose: bool
  ): uint64 {.gcsafe.} =
  if owner.isNil or owner.closed or not owner.running or owner.queue.isNil:
    return 0'u64
  if frames <= 0:
    return 0'u64

  {.cast(gcsafe).}:
    withLock owner.state.lock:
      result = owner.state.nextGeneration
      inc owner.state.nextGeneration

    var cmd = LiveInferOwnerCommand(
      kind: liocStartMonitor,
      generation: result,
      inputRtsp: inputRtsp,
      cameraId: cameraId,
      cameraName: cameraName,
      decoderName: decoderName,
      frames: frames,
      warmupFrames: warmupFrames,
      inFlight: inFlight,
      verbose: verbose
    )
    let sendRes = owner.queue.sendMove(cmd)
    if sendRes.isErr:
      result = 0'u64

proc requestStopSession*(owner: LiveInferOwner; generation: uint64 = 0'u64) {.gcsafe.} =
  if owner.isNil or owner.closed or not owner.running or owner.queue.isNil:
    return

  {.cast(gcsafe).}:
    markStopRequested(addr owner.state, generation)
    var cmd = LiveInferOwnerCommand(kind: liocStopSession, generation: generation)
    let sendRes = owner.queue.sendMove(cmd)
    if sendRes.isErr:
      discard

proc close*(owner: LiveInferOwner) =
  if owner.isNil or owner.closed:
    return

  if owner.running and not owner.queue.isNil:
    var cmd = LiveInferOwnerCommand(kind: liocShutdown)
    let sendRes = owner.queue.sendMove(cmd)
    if sendRes.isErr:
      owner.queue.close()

    joinThread(owner.thread)
    owner.running = false

  if not owner.queue.isNil:
    owner.queue.close()
    owner.queue = nil

  owner.closed = true
  deinitLock(owner.state.lock)
