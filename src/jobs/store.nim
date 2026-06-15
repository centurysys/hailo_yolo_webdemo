## Thread-safe in-memory job store.
##
## This is intentionally simple.  Jobs live under /var/tmp and disappear on
## reboot, which matches the demo appliance design.

import std/[algorithm, locks, options, tables, times]

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
    detailMessage: "",
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
  message: string,
  detailMessage = ""
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
      ## Keep the wait-page JSON small while a job is running.  Detailed
      ## timing output is only stored for completed/failed jobs.
      if status in {jsDone, jsFailed}:
        job.detailMessage = detailMessage
      else:
        job.detailMessage = ""
      job.updatedAtUnix = nowUnix()
      store.jobs[id] = job

proc setRunning*(store: JobStore, id: string, message = "running") =
  store.updateJob(id, jsRunning, 10, message)

proc setDone*(
  store: JobStore,
  id: string,
  message = "done",
  detailMessage = ""
) =
  store.updateJob(id, jsDone, 100, message, detailMessage)

proc setFailed*(store: JobStore, id: string, message: string) =
  store.updateJob(id, jsFailed, 100, message)

proc listJobs*(store: JobStore): seq[JobInfo] =
  withLock store.lock:
    for _, job in store.jobs:
      result.add(job)


proc pruneOldFinishedJobs*(
  store: JobStore;
  keep: int;
  protectedId = ""
): seq[JobInfo] =
  ## Remove old done/failed jobs from the in-memory index and return the removed
  ## entries so the caller can delete their filesystem directories.
  ##
  ## Queued/running jobs are never removed.  If many active jobs exist, the store
  ## can temporarily exceed `keep` until those jobs finish.
  ##
  ## `protectedId` is kept even when it is already done/failed.  This is useful
  ## immediately after a long-running job completes: the result page may be
  ## polling that exact job, so pruning it in the same worker turn makes the UI
  ## show "job not found" even though the output file was just produced.
  let keepCount = max(keep, 0)
  var candidates: seq[JobInfo]

  withLock store.lock:
    if store.jobs.len <= keepCount:
      return

    for _, job in store.jobs:
      if job.id == protectedId:
        continue
      if job.status in {jsDone, jsFailed}:
        candidates.add(job)

    if candidates.len == 0:
      return

    candidates.sort(proc(a, b: JobInfo): int =
      result = cmp(a.createdAtUnix, b.createdAtUnix)
      if result == 0:
        result = cmp(a.id, b.id)
    )

    var remaining = store.jobs.len
    for job in candidates:
      if remaining <= keepCount:
        break
      if job.id == protectedId:
        continue
      if job.id in store.jobs:
        store.jobs.del(job.id)
        result.add(job)
        dec remaining
