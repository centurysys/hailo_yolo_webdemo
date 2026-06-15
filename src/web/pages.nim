## HTML/CSS rendering helpers.
##
## Pico CSS will be served by nginx later.  For standalone development, this
## module also serves a small built-in CSS file at /static/demo.css.

import std/[os, strformat, strutils]

import ../types

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

proc demoCss*(): string =
  """
:root { color-scheme: light dark; }
[hidden] { display: none !important; }
body { max-width: 960px; margin: 0 auto; padding: 2rem 1rem; font-family: system-ui, sans-serif; }
header { margin-bottom: 1.5rem; }
article { border: 1px solid #d0d7de; border-radius: 0.75rem; padding: 1rem; margin: 1rem 0; }
button, input, select { font: inherit; }
button { padding: 0.55rem 1rem; border-radius: 0.4rem; border: 1px solid #0969da; background: #0969da; color: white; cursor: pointer; }
button[disabled] { opacity: 0.55; cursor: wait; }
progress { width: 100%; height: 1rem; }
.result-media { max-width: 100%; border-radius: 0.5rem; border: 1px solid #d0d7de; }
.preview-card { margin-top: 1rem; }
.preview-card img { max-width: 100%; border-radius: 0.5rem; border: 1px solid #d0d7de; display: block; }
.muted { opacity: 0.72; }
.error { color: #cf222e; }
.summary-card { background: color-mix(in srgb, CanvasText 4%, Canvas); border: 1px solid #d0d7de; border-radius: 0.6rem; padding: 0.85rem; margin: 1rem 0; }
.summary-card p { margin: 0.25rem 0 0; }
.details-log { white-space: pre-wrap; overflow-wrap: anywhere; font-size: 0.85rem; line-height: 1.45; max-height: 18rem; overflow: auto; border: 1px solid #d0d7de; border-radius: 0.5rem; padding: 0.75rem; }
.result-actions { margin-top: 1rem; }
.media-grid { display: grid; grid-template-columns: 1fr; gap: 1rem; align-items: start; }
.media-card { border: 1px solid #d0d7de; border-radius: 0.65rem; padding: 0.85rem; background: color-mix(in srgb, CanvasText 3%, Canvas); }
.media-card h3 { margin-top: 0; }
.media-card p { margin: 0.35rem 0 0.75rem; }
.media-card .result-media { display: block; width: 100%; }
.row { display: flex; gap: 0.75rem; align-items: center; flex-wrap: wrap; }
.upload-form { display: grid; gap: 1.1rem; }
.file-row { display: grid; gap: 0.35rem; }
.options-panel { margin-top: 0.25rem; }
.options-panel h3 { margin: 0 0 0.8rem; }
.options-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0.9rem; align-items: start; }
.option-card { border: 1px solid color-mix(in srgb, CanvasText 18%, Canvas); border-radius: 0.65rem; padding: 0.85rem; background: color-mix(in srgb, CanvasText 3%, Canvas); }
.option-card label, .manual-extra label, .advanced-grid label { display: grid; gap: 0.35rem; margin: 0; }
.option-card select, .option-card input, .manual-extra input, .advanced-grid input { width: 100%; box-sizing: border-box; }
.option-title { font-weight: 700; margin-bottom: 0.45rem; }
.option-note { display: block; font-size: 0.88rem; line-height: 1.45; margin-top: 0.45rem; }
.manual-extra { margin-top: 0.75rem; padding-top: 0.75rem; border-top: 1px solid color-mix(in srgb, CanvasText 14%, Canvas); }
.advanced-options { margin-top: 0.9rem; border: 1px solid color-mix(in srgb, CanvasText 14%, Canvas); border-radius: 0.65rem; padding: 0.75rem 0.85rem; }
.advanced-options summary { cursor: pointer; font-weight: 700; }
.advanced-grid { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 0.75rem; margin-top: 0.75rem; }
.form-actions { display: flex; gap: 0.75rem; align-items: center; flex-wrap: wrap; margin-top: 0.1rem; }
#message { margin: 0; }
@media (max-width: 720px) {
  body { padding: 1rem 0.75rem; }
  .options-grid { grid-template-columns: 1fr; }
  .advanced-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}
@media (max-width: 480px) {
  .advanced-grid { grid-template-columns: 1fr; }
}
"""

proc renderLayout*(title, body: string): string =
  &"""<!doctype html>
<html lang="ja">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{title.htmlEscape}</title>
  <link rel="stylesheet" href="/static/pico.min.css">
  <link rel="stylesheet" href="/static/demo.css">
</head>
<body>
  <header>
    <h1>HAILO YOLO Web Demo</h1>
    <p class="muted">JPEG / MP4 をアップロードして、HAILO-8L 推論結果を確認するデモアプリです。</p>
  </header>
  <main>
    {body}
  </main>
</body>
</html>
"""

proc renderIndexPage*(): string =
  let body = """
<article>
  <h2>Upload</h2>
  <p class="muted">JPEGはHAILO-8L上のYOLOv11sで検出し、bbox/label付きJPEGを生成します。MP4は各フレームにYOLO検出結果をoverlayし、bbox/label付きH.264/MP4を生成します。</p>
  <form id="upload-form" class="upload-form">
    <label class="file-row">
      <span>Input file</span>
      <input id="file" type="file" accept=".jpg,.jpeg,.mp4,.m4v" required>
    </label>

    <section class="options-panel" aria-labelledby="processing-options-title">
      <h3 id="processing-options-title">Processing options</h3>

      <div class="options-grid">
        <div class="option-card">
          <div class="option-title">MP4 quality</div>
          <label>
            <span class="muted">出力MP4の画質</span>
            <select id="mp4-quality">
              <option value="auto" selected>Auto</option>
              <option value="small">Small file</option>
              <option value="balanced">Balanced</option>
              <option value="high">High quality</option>
              <option value="manual">Manual</option>
            </select>
          </label>
          <span class="muted option-note">ブロックノイズが気になる場合は High quality を選びます。</span>

          <div id="manual-bitrate-row" class="manual-extra" hidden>
            <label>
              Manual bitrate (Mbps)
              <input id="manual-bitrate" type="number" min="0.25" max="20" step="0.25" value="4">
            </label>
          </div>
        </div>

        <div class="option-card">
          <div class="option-title">Overlay amount</div>
          <label>
            <span class="muted">bbox / label の表示量</span>
            <select id="overlay-preset">
              <option value="light">Light</option>
              <option value="balanced" selected>Balanced</option>
              <option value="rich">Rich</option>
              <option value="boxes-only">Boxes only</option>
              <option value="manual">Manual</option>
            </select>
          </label>
          <span class="muted option-note">多すぎる場合は Light または Boxes only が見やすいです。</span>
        </div>
      </div>

      <details id="advanced-options" class="advanced-options">
        <summary>Advanced overlay thresholds</summary>
        <div class="advanced-grid">
          <label>
            Max boxes
            <input id="max-boxes" type="number" min="0" max="200" step="1" value="12">
          </label>
          <label>
            Max labels
            <input id="max-labels" type="number" min="0" max="200" step="1" value="6">
          </label>
          <label>
            Box score threshold
            <input id="min-box-score" type="number" min="0" max="1" step="0.05" value="0.25">
          </label>
          <label>
            Label score threshold
            <input id="min-label-score" type="number" min="0" max="1" step="0.05" value="0.50">
          </label>
        </div>
      </details>
    </section>

    <div class="form-actions">
      <button id="run" type="submit">Upload and Run</button>
      <p id="message" class="muted"></p>
    </div>
  </form>
</article>
<script>
const form = document.getElementById('upload-form');
const fileInput = document.getElementById('file');
const button = document.getElementById('run');
const message = document.getElementById('message');
const mp4Quality = document.getElementById('mp4-quality');
const manualBitrateRow = document.getElementById('manual-bitrate-row');
const manualBitrate = document.getElementById('manual-bitrate');
const overlayPreset = document.getElementById('overlay-preset');
const advancedOptions = document.getElementById('advanced-options');

function refreshOptionVisibility() {
  manualBitrateRow.hidden = mp4Quality.value !== 'manual';
  if (overlayPreset.value === 'manual') {
    advancedOptions.open = true;
  }
}

mp4Quality.addEventListener('change', refreshOptionVisibility);
overlayPreset.addEventListener('change', refreshOptionVisibility);
refreshOptionVisibility();

function appendOptions(url) {
  url.searchParams.set('mp4Quality', mp4Quality.value);
  url.searchParams.set('manualBitrateMbps', manualBitrate.value);
  url.searchParams.set('overlayPreset', overlayPreset.value);
  url.searchParams.set('maxBoxes', document.getElementById('max-boxes').value);
  url.searchParams.set('maxLabels', document.getElementById('max-labels').value);
  url.searchParams.set('minBoxScore', document.getElementById('min-box-score').value);
  url.searchParams.set('minLabelScore', document.getElementById('min-label-score').value);
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const file = fileInput.files[0];
  if (!file) return;

  button.disabled = true;
  message.textContent = 'uploading...';

  try {
    const url = new URL('/upload', location.origin);
    url.searchParams.set('filename', file.name);
    appendOptions(url);
    const res = await fetch(url.pathname + url.search, { method: 'PUT', body: file });
    if (!res.ok) {
      throw new Error(await res.text());
    }
    const job = await res.json();
    location.href = '/wait/' + encodeURIComponent(job.id);
  } catch (err) {
    message.textContent = 'error: ' + err.message;
    button.disabled = false;
  }
});
</script>
"""
  renderLayout("HAILO YOLO Web Demo", body)

proc renderWaitPage*(jobId: string): string =
  let safeJobId = jobId.htmlEscape
  let body = &"""
<article>
  <h2>Status</h2>
  <p>job: <code>{safeJobId}</code></p>
  <progress id="progress" value="0" max="100"></progress>
  <p id="status" class="muted">queued</p>

  <section id="preview-card" class="preview-card" hidden>
    <h3>Preview frame</h3>
    <p class="muted">A single annotated preview frame appears here once it becomes available.</p>
    <img id="preview-image" alt="processing preview">
  </section>
</article>
<script>
const jobId = '{safeJobId}';
const previewCard = document.getElementById('preview-card');
const previewImage = document.getElementById('preview-image');
let previewLoaded = false;

function refreshPreview(job) {{
  if (job.kind !== 'mp4') return;
  previewImage.onload = () => {{
    previewLoaded = true;
    previewCard.hidden = false;
  }};
  previewImage.onerror = () => {{
    if (!previewLoaded) previewCard.hidden = true;
  }};
  previewImage.src = '/preview/' + encodeURIComponent(jobId) + '?v=' + Date.now();
}}

async function poll() {{
  const res = await fetch('/api/jobs/' + encodeURIComponent(jobId));
  if (!res.ok) {{
    document.getElementById('status').textContent = 'job not found';
    return;
  }}
  const job = await res.json();
  document.getElementById('progress').value = job.progress;
  document.getElementById('status').textContent = job.status + ' - ' + job.message;
  if (job.status !== 'done' && job.status !== 'failed') {{
    refreshPreview(job);
  }}
  if (job.status === 'done' || job.status === 'failed') {{
    location.href = '/result/' + encodeURIComponent(jobId);
    return;
  }}
  setTimeout(poll, 250);
}}
poll();
</script>
"""
  renderLayout("Processing", body)

proc isImageOutput(job: JobInfo): bool =
  let ext = job.outputPath.splitFile.ext.toLowerAscii()
  ext in [".jpg", ".jpeg"]

proc renderResultPage*(job: JobInfo): string =
  let previewBlock =
    if job.status == jsDone and not job.isImageOutput:
      &"<details><summary>Preview frame</summary><img class=\"result-media\" src=\"/preview/{job.id.htmlEscape}?v={job.updatedAtUnix}\" alt=\"preview frame\"></details>"
    else:
      ""

  let media =
    if job.status == jsDone:
      if job.isImageOutput:
        &"<img class=\"result-media\" src=\"/files/{job.id.htmlEscape}\" alt=\"result\">"
      else:
        &"""
  {previewBlock}
  <section class="media-grid" aria-label="MP4 result viewers">
    <div class="media-card">
      <h3>Original video</h3>
      <p class="muted">アップロードされた元動画です。次のステップでここに検出結果を重ねます。</p>
      <video class="result-media" controls preload="metadata" src="/job-media/{job.id.htmlEscape}/input.mp4"></video>
    </div>
    <div class="media-card">
      <h3>Generated overlay MP4</h3>
      <p class="muted">bbox / label を焼き込んだ生成済みMP4です。ダウンロードにも使えます。</p>
      <video class="result-media" controls preload="metadata" src="/job-media/{job.id.htmlEscape}/output.mp4"></video>
    </div>
  </section>
"""
    else:
      &"<p class=\"error\">{job.message.htmlEscape}</p>"

  let detailBlock =
    if job.status == jsDone and job.detailMessage.len > 0:
      &"""
  <details>
    <summary>Technical timing details</summary>
    <pre class="details-log">{job.detailMessage.htmlEscape}</pre>
  </details>
"""
    else:
      ""

  let downloadLink =
    if job.status == jsDone:
      &"<a href=\"/files/{job.id.htmlEscape}\">Download</a>"
    else:
      ""

  let body = &"""
<article>
  <h2>Result</h2>
  <p>job: <code>{job.id.htmlEscape}</code></p>
  <p>kind: <code>{job.kind.toWire}</code>, status: <code>{job.status.toWire}</code></p>

  <section class="summary-card">
    <strong>Summary</strong>
    <p>{job.message.htmlEscape}</p>
  </section>

  {media}
  {detailBlock}

  <p class="row result-actions"><a href="/">Back</a>{downloadLink}</p>
</article>
"""
  renderLayout("Result", body)

proc renderErrorPage*(message: string): string =
  renderLayout("Error", &"""
<article>
  <h2>Error</h2>
  <p class="error">{message.htmlEscape}</p>
  <p><a href="/">Back</a></p>
</article>
""")
