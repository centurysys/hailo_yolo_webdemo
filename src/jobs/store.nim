## Thread-safe in-memory job store.
##
## This is intentionally simple.  Jobs live under /var/tmp and disappear on
## reboot, which matches the demo appliance design.

import std/[locks, options, tables, times]

import ../types

type
  JobStore* = ref object
    lock: Lock
    jobs: Table[string, JobInfo]

proc nowUnix(): int64 = int64(epochTime())

proc newJobStore*(): JobStore =
  new(result)
  initLock(result.lock)
  result.jobs = initTable[string, JobInfo]()

proc close*(store: JobStore) =
  if store != nil:
    deinitLock(store.lock)

proc createJob*(
  store: JobStore,
  id: string,
  kind: JobKind,
  inputPath: string,
  outputPath: string,
  originalName: string
): JobInfo =
  let t = nowUnix()
  result = JobInfo(
    id: id,
    kind: kind,
    status: jsQueued,
    inputPath: inputPath,
    outputPath: outputPath,
    originalName: originalName,
    message: "queued",
    progress: 0,
    createdAtUnix: t,
    updatedAtUnix: t
  )

  withLock store.lock:
    store.jobs[id] = result

proc getJob*(store: JobStore, id: string): Option[JobInfo] =
  withLock store.lock:
    if id in store.jobs:
      return some(store.jobs[id])
  none(JobInfo)

proc updateJob*(
  store: JobStore,
  id: string,
  status: JobStatus,
  progress: int,
  message: string
) =
  withLock store.lock:
    if id in store.jobs:
      var job = store.jobs[id]
      job.status = status
      if progress < 0:
        job.progress = 0
      elif progress > 100:
        job.progress = 100
      else:
        job.progress = progress
      job.message = message
      job.updatedAtUnix = nowUnix()
      store.jobs[id] = job

proc setRunning*(store: JobStore, id: string, message = "running") =
  store.updateJob(id, jsRunning, 10, message)

proc setDone*(store: JobStore, id: string, message = "done") =
  store.updateJob(id, jsDone, 100, message)

proc setFailed*(store: JobStore, id: string, message: string) =
  store.updateJob(id, jsFailed, 100, message)

proc listJobs*(store: JobStore): seq[JobInfo] =
  withLock store.lock:
    for _, job in store.jobs:
      result.add(job)
