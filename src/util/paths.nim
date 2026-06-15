## Filesystem helpers for /var/tmp/hailo-demo.

import std/[os, strutils]

import ../types

proc ensureWorkDirs*(workRoot, uploadDir, jobsDir: string) =
  createDir(workRoot)
  createDir(uploadDir)
  createDir(jobsDir)

proc sanitizeFilename*(name: string): string =
  ## Keep this intentionally conservative.  The original name is only used for
  ## display and extension detection; stored paths are generated from job ids.
  result = ""
  for ch in name.extractFilename:
    if ch.isAlphaNumeric or ch in {'_', '-', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "upload"

proc detectJobKind*(filename: string): JobKind =
  let ext = filename.splitFile.ext.toLowerAscii()
  case ext
  of ".jpg", ".jpeg": jkJpeg
  of ".mp4", ".m4v": jkMp4
  else:
    raise newException(ValueError, "unsupported file type: " & filename)

proc jobDir*(jobsDir, jobId: string): string =
  jobsDir / jobId

proc inputPath*(jobsDir, jobId: string, kind: JobKind): string =
  jobsDir.jobDir(jobId) / ("input" & kind.extension)

proc outputPath*(jobsDir, jobId: string, kind: JobKind): string =
  ## JPEG jobs produce output.jpg.
  ##
  ## The first MP4 step produces a JPEG preview frame with HAILO overlay instead
  ## of a processed MP4.  Keeping this as the job output path allows the same
  ## /files/<id> route to serve the preview image.
  case kind
  of jkJpeg:
    jobsDir.jobDir(jobId) / "output.jpg"
  of jkMp4:
    jobsDir.jobDir(jobId) / "preview.jpg"

proc extractedFramePath*(jobsDir, jobId: string): string =
  jobsDir.jobDir(jobId) / "frame.jpg"

proc ensureJobDir*(jobsDir, jobId: string) =
  createDir(jobsDir.jobDir(jobId))

proc moveOrCopyFile*(src, dst: string) =
  ## nginx upload temp and job dir should both be under /var/tmp, so rename is
  ## the fast path.  Copy fallback keeps local testing flexible.
  try:
    moveFile(src, dst)
  except OSError:
    copyFile(src, dst)
    removeFile(src)


proc cleanupJobDirs*(jobsDir: string): int =
  ## Remove leftover job directories from a previous process lifetime.
  ##
  ## Job metadata is in-memory only, so after a restart these directories are no
  ## longer reachable from the web UI.  Cleaning them at startup prevents tmpfs
  ## usage from growing while iterating on the demo.
  if not dirExists(jobsDir):
    return 0

  for kind, path in walkDir(jobsDir):
    case kind
    of pcDir:
      try:
        removeDir(path)
        inc result
      except OSError as e:
        echo "warning: failed to remove old job dir ", path, ": ", e.msg
    else:
      try:
        removeFile(path)
      except OSError as e:
        echo "warning: failed to remove old job file ", path, ": ", e.msg
