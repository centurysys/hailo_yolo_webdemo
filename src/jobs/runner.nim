## Background job runner.
##
## /upload handlers should only create a job and enqueue its id.  JPEG inference
## and image writing run on this dedicated worker thread, so Mummy worker threads
## are not occupied by HAILO / image processing work.
##
## The queue itself is threadtools.ThreadQueue.  This keeps the demo's control
## plane aligned with the same move-oriented infrastructure used by hailort_nim's
## internal detector worker.

import std/[options, os, strformat]

import threadtools

import ../config
import ../draw/overlay
import ../infer/hailo_worker
import ../types
import ./store

const DefaultJobQueueSize = 16

type
  JobRequestKind = enum
    jrkRun
    jrkStop

  JobRequest = object
    kind: JobRequestKind
    jobId: string

  JobRunnerState = object
    storePtr: pointer
    queue: ThreadQueue[JobRequest]

  JobRunner* = ref object
    queue: ThreadQueue[JobRequest]
    thread: Thread[ptr JobRunnerState]
    state: JobRunnerState
    running: bool
    closed: bool

var gRunnerPtr: pointer

proc currentRunner(): JobRunner {.gcsafe.} =
  {.cast(gcsafe).}:
    result = cast[JobRunner](gRunnerPtr)

proc cleanupOldJobDirs(store: JobStore) {.gcsafe.} =
  let removedJobs = store.pruneOldFinishedJobs(maxJobsToKeep)
  if removedJobs.len == 0:
    return

  for job in removedJobs:
    let dir = jobsDir / job.id
    try:
      if dirExists(dir):
        removeDir(dir)
        echo &"removed old job directory: {dir}"
    except OSError as e:
      echo &"warning: failed to remove old job directory {dir}: {e.msg}"

proc processJob(store: JobStore; jobId: string) {.gcsafe.} =
  let maybeJob = store.getJob(jobId)
  if maybeJob.isNone:
    return

  let job = maybeJob.get
  store.setRunning(jobId, "processing")

  try:
    if not fileExists(job.inputPath):
      raise newException(IOError, "input file is missing")

    case job.kind
    of jkJpeg:
      store.updateJob(jobId, jsRunning, 35, "running HAILO YOLOv11s inference")

      var stats: OverlayStats
      {.cast(gcsafe).}:
        stats = drawHailoOverlay(job.inputPath, job.outputPath, fontPath)

      let message = "complete: " & stats.formatOverlayStats()
      echo &"job {jobId}: {message}"
      store.setDone(jobId, message)

    of jkMp4:
      store.updateJob(jobId, jsRunning, 20, "decoding MP4 preview frame with libav_nim")

      var stats: OverlayStats
      {.cast(gcsafe).}:
        stats = drawMp4PreviewOverlay(job.inputPath, job.outputPath, fontPath)

      let message = "complete: mp4 preview via libav_nim; " & stats.formatOverlayStats()
      echo &"job {jobId}: {message}"
      store.setDone(jobId, message)

  except CatchableError as e:
    store.setFailed(jobId, e.msg)

proc jobRunnerMain(state: ptr JobRunnerState) {.thread.} =
  let store = cast[JobStore](state.storePtr)

  try:
    try:
      {.cast(gcsafe).}:
        preloadHailoWorker()
      echo "HAILO detector preloaded in job worker thread"
    except CatchableError as e:
      ## Keep the web UI usable in development environments without HAILO.
      ## The first JPEG job will retry Detector.open() and then fail with a
      ## job-specific error if the device/HEF is still unavailable.
      echo &"warning: failed to preload HAILO detector: {e.msg}"

    while true:
      var recvRes = state.queue.receiveResult()
      if recvRes.isErr:
        break

      var req = recvRes.take()
      case req.kind
      of jrkStop:
        break
      of jrkRun:
        store.processJob(req.jobId)
        store.cleanupOldJobDirs()
  finally:
    {.cast(gcsafe).}:
      closeHailoWorker()

proc startJobRunner*(store: JobStore; queueSize = DefaultJobQueueSize): JobRunner =
  if store.isNil:
    raise newException(ValueError, "job store is nil")
  if queueSize <= 0:
    raise newException(ValueError, &"invalid job queue size: {queueSize}")

  let qRes = newThreadQueue[JobRequest](queueSize)
  if qRes.isErr:
    raise newException(IOError, &"failed to create job queue: {qRes.error}")

  result = JobRunner()
  result.queue = qRes.get()
  result.state.storePtr = cast[pointer](store)
  result.state.queue = result.queue

  createThread(result.thread, jobRunnerMain, addr result.state)
  result.running = true

  gRunnerPtr = cast[pointer](result)

proc enqueueJob*(store: JobStore, jobId: string) {.gcsafe.} =
  ## Keep this signature so existing handlers stay simple.
  ##
  ## The store argument is still useful for marking a job failed if the runner
  ## has not been started or the queue is already closed/full.
  let runner = currentRunner()
  if runner.isNil or runner.closed or not runner.running or runner.queue.isNil:
    store.setFailed(jobId, "job runner is not running")
    return

  var req = JobRequest(kind: jrkRun, jobId: jobId)
  let sendRes = runner.queue.sendMove(req)
  if sendRes.isErr:
    store.setFailed(jobId, &"failed to enqueue job: {sendRes.error}")

proc close*(runner: JobRunner) =
  if runner.isNil or runner.closed:
    return

  if runner.running and not runner.queue.isNil:
    var req = JobRequest(kind: jrkStop)
    let sendRes = runner.queue.sendMove(req)
    if sendRes.isErr:
      runner.queue.close()

    joinThread(runner.thread)
    runner.running = false

  if not runner.queue.isNil:
    runner.queue.close()
    runner.queue = nil

  runner.closed = true

  if currentRunner() == runner:
    gRunnerPtr = nil
