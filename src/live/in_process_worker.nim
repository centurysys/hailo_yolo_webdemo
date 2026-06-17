## In-process live worker scaffold.
##
## This module provides the process-internal worker thread that will later own
## the live RTSP decode -> HAILO infer -> overlay -> encode -> RTSP publish
## pipeline.  This step intentionally keeps the worker as a lifecycle scaffold:
## it starts a dedicated thread and stops it cleanly, but it does not connect the
## media pipeline yet.

import std/strformat

import threadtools

const DefaultControlQueueSize = 4

type
  InProcessWorkerCommandKind = enum
    iwcStop

  InProcessWorkerCommand = object
    kind: InProcessWorkerCommandKind

  InProcessWorkerState = object
    queue: ThreadQueue[InProcessWorkerCommand]

  InProcessLiveWorker* = ref object
    queue: ThreadQueue[InProcessWorkerCommand]
    thread: Thread[ptr InProcessWorkerState]
    state: InProcessWorkerState
    running: bool
    closed: bool

proc inProcessWorkerMain(state: ptr InProcessWorkerState) {.thread.} =
  echo "in-process live worker thread started"
  try:
    while true:
      var recvRes = state.queue.receiveResult()
      if recvRes.isErr:
        break

      var cmd = recvRes.take()
      case cmd.kind
      of iwcStop:
        break
  finally:
    echo "in-process live worker thread stopped"

proc startInProcessLiveWorker*(
    inputRtsp: string;
    outputRtsp: string;
    cameraId: string;
    cameraName: string;
    queueSize = DefaultControlQueueSize
  ): InProcessLiveWorker =
  ## Start the internal live worker thread.
  ##
  ## The arguments are kept in the public contract now even though this scaffold
  ## does not use them inside the worker thread yet.  The real media pipeline can
  ## be connected without changing live_session.nim again.
  if queueSize <= 0:
    raise newException(ValueError, &"invalid in-process worker queue size: {queueSize}")

  let qRes = newThreadQueue[InProcessWorkerCommand](queueSize)
  if qRes.isErr:
    raise newException(IOError, &"failed to create in-process worker queue: {qRes.error}")

  echo &"starting in-process live worker for {cameraId} ({cameraName}): {inputRtsp} -> {outputRtsp}"

  result = InProcessLiveWorker()
  result.queue = qRes.get()
  result.state.queue = result.queue

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
