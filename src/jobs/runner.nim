## Initial dummy runner.
##
## This is deliberately synchronous for the first step.  It lets us validate
## Mummy, nginx X-FILE, job paths and result pages before introducing the real
## threadtools/HAILO worker.

import std/[options, os]

import ./store

proc enqueueJob*(store: JobStore, jobId: string) =
  let maybeJob = store.getJob(jobId)
  if maybeJob.isNone:
    return

  let job = maybeJob.get
  store.setRunning(jobId, "dummy processing")
  sleep(250)

  try:
    if not fileExists(job.inputPath):
      raise newException(IOError, "input file is missing")

    copyFile(job.inputPath, job.outputPath)
    store.setDone(jobId, "dummy complete: copied input to output")
  except CatchableError as e:
    store.setFailed(jobId, e.msg)
