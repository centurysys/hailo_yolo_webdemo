## HTML/CSS/JS rendering helpers.
##
## Keep HTML/CSS/JavaScript in real files so editors can provide proper syntax
## highlighting.  staticRead() embeds those files into the Nim binary at compile
## time, so the appliance still does not need to deploy template/static files.

import std/[os, strformat, strutils]

import ../types

const moduleDir = currentSourcePath().splitFile.dir
const layoutTemplate = staticRead(moduleDir / "templates" / "layout.html")
const indexTemplate = staticRead(moduleDir / "templates" / "index.html")
const waitTemplate = staticRead(moduleDir / "templates" / "wait.html")
const resultTemplate = staticRead(moduleDir / "templates" / "result.html")
const errorTemplate = staticRead(moduleDir / "templates" / "error.html")
const demoCssContent = staticRead(moduleDir / "static" / "demo.css")
const indexJsContent = staticRead(moduleDir / "static" / "index.js")
const waitJsContent = staticRead(moduleDir / "static" / "wait.js")
const resultViewerJsContent = staticRead(moduleDir / "static" / "result-viewer.js")

proc htmlEscape*(s: string): string =
  result = ""
  for ch in s:
    case ch
    of '&': result.add("&amp;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    of '"': result.add("&quot;")
    of '\'': result.add("&#39;")
    else: result.add(ch)

proc replaceToken(content, token, value: string): string =
  content.replace("{{" & token & "}}", value)

proc scriptTag(path: string): string =
  if path.len == 0:
    return ""
  &"  <script src=\"{path.htmlEscape}\" defer></script>"

proc demoCss*(): string = demoCssContent
proc indexJs*(): string = indexJsContent
proc waitJs*(): string = waitJsContent
proc resultViewerJs*(): string = resultViewerJsContent

proc renderLayout*(title, body: string; scriptPath = ""): string =
  result = layoutTemplate
    .replaceToken("TITLE", title.htmlEscape)
    .replaceToken("BODY", body)
    .replaceToken("SCRIPT_TAG", scriptPath.scriptTag)

proc renderIndexPage*(): string =
  renderLayout("HAILO YOLO Web Demo", indexTemplate, "/static/index.js")

proc renderWaitPage*(jobId: string): string =
  let safeJobId = jobId.htmlEscape
  let body = waitTemplate.replaceToken("JOB_ID", safeJobId)
  renderLayout("Processing", body, "/static/wait.js")

proc isImageOutput(job: JobInfo): bool =
  let ext = job.outputPath.splitFile.ext.toLowerAscii()
  ext in [".jpg", ".jpeg"]

proc renderResultPage*(job: JobInfo): string =
  let safeJobId = job.id.htmlEscape

  let previewBlock =
    if job.status == jsDone and not job.isImageOutput:
      &"<details><summary>Preview frame</summary><img class=\"result-media\" src=\"/preview/{safeJobId}?v={job.updatedAtUnix}\" alt=\"preview frame\"></details>"
    else:
      ""

  let mediaBlock =
    if job.status == jsDone:
      if job.isImageOutput:
        &"<img class=\"result-media\" src=\"/files/{safeJobId}\" alt=\"result\">"
      else:
        &"""
  {previewBlock}
  <section class="media-grid" aria-label="MP4 result viewers">
    <div class="media-card">
      <h3>Original video</h3>
      <p class="muted">アップロードされた元動画です。次のステップでここに検出結果を重ねます。</p>
      <video class="result-media" controls preload="metadata" src="/job-media/{safeJobId}/input.mp4"></video>
    </div>
    <div class="media-card">
      <h3>Generated overlay MP4</h3>
      <p class="muted">bbox / label を焼き込んだ生成済みMP4です。ダウンロードにも使えます。</p>
      <video class="result-media" controls preload="metadata" src="/job-media/{safeJobId}/output.mp4"></video>
    </div>
  </section>"""
    else:
      &"<p class=\"error\">{job.message.htmlEscape}</p>"

  let detailBlock =
    if job.status == jsDone and job.detailMessage.len > 0:
      &"""
  <details>
    <summary>Technical timing details</summary>
    <pre class="details-log">{job.detailMessage.htmlEscape}</pre>
  </details>"""
    else:
      ""

  let downloadLink =
    if job.status == jsDone:
      &"<a href=\"/files/{safeJobId}\">Download</a>"
    else:
      ""

  let detectionsLink =
    if job.status == jsDone and job.kind == jkMp4:
      &"<a href=\"/job-media/{safeJobId}/detections.json\">Detection JSON</a>"
    else:
      ""

  let body = resultTemplate
    .replaceToken("JOB_ID", safeJobId)
    .replaceToken("KIND", job.kind.toWire.htmlEscape)
    .replaceToken("STATUS", job.status.toWire.htmlEscape)
    .replaceToken("SUMMARY", job.message.htmlEscape)
    .replaceToken("MEDIA_BLOCK", mediaBlock)
    .replaceToken("DETAIL_BLOCK", detailBlock)
    .replaceToken("DOWNLOAD_LINK", downloadLink)
    .replaceToken("DETECTIONS_LINK", detectionsLink)

  renderLayout("Result", body)

proc renderErrorPage*(message: string): string =
  let body = errorTemplate.replaceToken("MESSAGE", message.htmlEscape)
  renderLayout("Error", body)
