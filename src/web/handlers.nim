## HTTP handlers for Mummy.

import mummy
import std/[options, os, strformat, strutils, uri]

import ../config
import ../jobs/[runner, store]
import ../types
import ../util/[ids, paths]
import ./pages
import ./api

var gStorePtr: pointer

proc setJobStore*(store: JobStore) =
  ## Keep only an untraced pointer in global state so Mummy handler procs stay
  ## GC-safe.  The real JobStore ref is owned by main for the lifetime of
  ## server.serve(), and JobStore methods protect their Table with a Lock.
  gStorePtr = cast[pointer](store)

proc currentStore(): JobStore {.gcsafe.} =
  ## Mummy invokes handlers from worker threads and therefore requires
  ## GC-safe handlers.  Do not store a GC-managed JobStore ref directly in a
  ## global; keep a raw pointer and cast it back only at this boundary.
  {.cast(gcsafe).}:
    result = cast[JobStore](gStorePtr)

proc respondText(request: Request, status: int, text: string) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  request.respond(status, headers, text)

proc respondHtml(request: Request, status: int, html: string) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html; charset=utf-8"
  request.respond(status, headers, html)

proc respondJson(request: Request, status: int, json: string) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json; charset=utf-8"
  request.respond(status, headers, json)

proc getHeader(request: Request, name: string): string {.gcsafe.} =
  result = request.headers[name]
  if result.len == 0:
    result = request.headers[name.toLowerAscii]

proc queryValue(uri, key: string): string =
  let qMark = uri.find('?')
  if qMark < 0:
    return ""
  for part in uri[qMark + 1 .. ^1].split('&'):
    let eq = part.find('=')
    if eq < 0:
      if decodeUrl(part) == key:
        return ""
    else:
      let k = decodeUrl(part[0 ..< eq])
      if k == key:
        return decodeUrl(part[eq + 1 .. ^1])

proc trailingPathSegment(path, prefix: string): string =
  if path.startsWith(prefix):
    result = path[prefix.len .. ^1]
  else:
    result = ""
  result = result.strip(chars = {'/'})

proc outputContentType(job: JobInfo): string =
  let ext = job.outputPath.splitFile.ext.toLowerAscii()
  case ext
  of ".jpg", ".jpeg": "image/jpeg"
  of ".mp4", ".m4v": "video/mp4"
  else: job.kind.contentType

proc outputFilename(job: JobInfo): string =
  let ext = job.outputPath.splitFile.ext.toLowerAscii()
  if job.kind == jkMp4 and ext in [".jpg", ".jpeg"]:
    "preview.jpg"
  else:
    "output" & job.kind.extension

proc handleIndex*(request: Request) {.gcsafe.} =
  request.respondHtml(200, renderIndexPage())

proc handleDemoCss*(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/css; charset=utf-8"
  request.respond(200, headers, demoCss())

proc handleMissingPico*(request: Request) {.gcsafe.} =
  ## Keep standalone development harmless when Pico CSS has not been installed
  ## under nginx yet.  The app-specific fallback CSS still makes the page usable.
  var headers: HttpHeaders
  headers["Content-Type"] = "text/css; charset=utf-8"
  request.respond(200, headers, "/* pico.min.css is expected to be served by nginx in the final package. */\n")

proc handleUpload*(request: Request) {.gcsafe.} =
  let store = currentStore()
  if store == nil:
    request.respondText(500, "job store is not initialized")
    return

  try:
    let qFilename = queryValue(request.uri, "filename")
    let rawOriginalName =
      if qFilename.len > 0: qFilename
      else: getHeader(request, "X-Upload-Filename")
    let originalName = sanitizeFilename(rawOriginalName)
    let kind = detectJobKind(originalName)
    let jobId = newJobId()

    ensureJobDir(jobsDir, jobId)
    let input = inputPath(jobsDir, jobId, kind)
    let output = outputPath(jobsDir, jobId, kind)

    let nginxFile = getHeader(request, "X-FILE")
    if nginxFile.len > 0:
      if not fileExists(nginxFile):
        raise newException(IOError, &"X-FILE path does not exist: {nginxFile}")
      moveOrCopyFile(nginxFile, input)
    else:
      ## Development path when directly PUT-ing to Mummy without nginx.
      if request.body.len == 0:
        raise newException(ValueError, "missing X-FILE header and empty request body")
      writeFile(input, request.body)

    let job = store.createJob(jobId, kind, input, output, originalName)
    store.enqueueJob(job.id)

    request.respondJson(200, uploadJson(job))
  except CatchableError as e:
    request.respondHtml(400, renderErrorPage(e.msg))

proc handleWait*(request: Request) {.gcsafe.} =
  let jobId = trailingPathSegment(request.path, "/wait/")
  if jobId.len == 0:
    request.respondHtml(404, renderErrorPage("missing job id"))
    return
  request.respondHtml(200, renderWaitPage(jobId))

proc handleApiJob*(request: Request) {.gcsafe.} =
  let store = currentStore()
  if store == nil:
    request.respondText(500, "job store is not initialized")
    return

  let jobId = trailingPathSegment(request.path, "/api/jobs/")
  let maybeJob = store.getJob(jobId)
  if maybeJob.isNone:
    request.respondText(404, "job not found")
    return

  request.respondJson(200, jobJson(maybeJob.get))


proc handlePreview*(request: Request) {.gcsafe.} =
  let store = currentStore()
  if store == nil:
    request.respondText(500, "job store is not initialized")
    return

  let jobId = trailingPathSegment(request.path, "/preview/")
  let maybeJob = store.getJob(jobId)
  if maybeJob.isNone:
    request.respondText(404, "job not found")
    return

  let path = previewPath(jobsDir, jobId)
  if not fileExists(path):
    request.respondText(404, "preview not available")
    return

  var headers: HttpHeaders
  headers["Content-Type"] = "image/jpeg"
  headers["Cache-Control"] = "no-store, no-cache, must-revalidate"
  headers["Pragma"] = "no-cache"
  request.respond(200, headers, readFile(path))

proc handleResult*(request: Request) {.gcsafe.} =
  let store = currentStore()
  if store == nil:
    request.respondHtml(500, renderErrorPage("job store is not initialized"))
    return

  let jobId = trailingPathSegment(request.path, "/result/")
  let maybeJob = store.getJob(jobId)
  if maybeJob.isNone:
    request.respondHtml(404, renderErrorPage("job not found"))
    return

  request.respondHtml(200, renderResultPage(maybeJob.get))

proc handleFile*(request: Request) {.gcsafe.} =
  let store = currentStore()
  if store == nil:
    request.respondText(500, "job store is not initialized")
    return

  let jobId = trailingPathSegment(request.path, "/files/")
  let maybeJob = store.getJob(jobId)
  if maybeJob.isNone:
    request.respondText(404, "job not found")
    return

  let job = maybeJob.get
  if job.status != jsDone:
    request.respondText(409, "job is not done")
    return
  if not fileExists(job.outputPath):
    request.respondText(404, "output file not found")
    return

  var headers: HttpHeaders
  headers["Content-Type"] = job.outputContentType
  headers["Content-Disposition"] = &"inline; filename=\"{job.outputFilename}\""
  request.respond(200, headers, readFile(job.outputPath))

proc handleNotFound*(request: Request) {.gcsafe.} =
  request.respondHtml(404, renderErrorPage("not found"))
