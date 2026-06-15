## Initial runner.
##
## JPEG jobs now run the HAILO YOLOv11s path.  MP4 still uses copy-through
## behavior until the libav pipeline is introduced.

import std/[options, os]

import ../config
import ../draw/overlay
import ../types
import ./store

proc enqueueJob*(store: JobStore, jobId: string) {.gcsafe.} =
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
      {.cast(gcsafe).}:
        drawHailoOverlay(job.inputPath, job.outputPath, fontPath)
      store.setDone(jobId, "complete: ran HAILO YOLOv11s inference and drew overlay")

    of jkMp4:
      store.updateJob(jobId, jsRunning, 35, "dummy copy-through for MP4")
      copyFile(job.inputPath, job.outputPath)
      store.setDone(jobId, "dummy complete: copied input to output")

  except CatchableError as e:
    store.setFailed(jobId, e.msg)
