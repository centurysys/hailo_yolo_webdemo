## HTML/CSS rendering helpers.
##
## Pico CSS will be served by nginx later.  For standalone development, this
## module also serves a small built-in CSS file at /static/demo.css.

import std/strformat

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
body { max-width: 960px; margin: 0 auto; padding: 2rem 1rem; font-family: system-ui, sans-serif; }
header { margin-bottom: 1.5rem; }
article { border: 1px solid #d0d7de; border-radius: 0.75rem; padding: 1rem; margin: 1rem 0; }
button, input[type=file] { font: inherit; }
button { padding: 0.55rem 1rem; border-radius: 0.4rem; border: 1px solid #0969da; background: #0969da; color: white; cursor: pointer; }
button[disabled] { opacity: 0.55; cursor: wait; }
progress { width: 100%; height: 1rem; }
.result-media { max-width: 100%; border-radius: 0.5rem; border: 1px solid #d0d7de; }
.muted { opacity: 0.72; }
.error { color: #cf222e; }
.row { display: flex; gap: 0.75rem; align-items: center; flex-wrap: wrap; }
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
  <p class="muted">現在のステップでは、libyuv_nimで640x640 YOLO入力bufferを作り、固定bboxを元画像座標へ戻して描画します。HAILO推論は次の段階で接続します。</p>
  <form id="upload-form">
    <input id="file" type="file" accept=".jpg,.jpeg,.mp4" required>
    <button id="run" type="submit">Upload and Run</button>
  </form>
  <p id="message" class="muted"></p>
</article>
<script>
const form = document.getElementById('upload-form');
const fileInput = document.getElementById('file');
const button = document.getElementById('run');
const message = document.getElementById('message');

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const file = fileInput.files[0];
  if (!file) return;

  button.disabled = true;
  message.textContent = 'uploading...';

  try {
    const url = '/upload?filename=' + encodeURIComponent(file.name);
    const res = await fetch(url, { method: 'PUT', body: file });
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
</article>
<script>
const jobId = '{safeJobId}';
async function poll() {{
  const res = await fetch('/api/jobs/' + encodeURIComponent(jobId));
  if (!res.ok) {{
    document.getElementById('status').textContent = 'job not found';
    return;
  }}
  const job = await res.json();
  document.getElementById('progress').value = job.progress;
  document.getElementById('status').textContent = job.status + ' - ' + job.message;
  if (job.status === 'done' || job.status === 'failed') {{
    location.href = '/result/' + encodeURIComponent(jobId);
    return;
  }}
  setTimeout(poll, 700);
}}
poll();
</script>
"""
  renderLayout("Processing", body)

proc renderResultPage*(job: JobInfo): string =
  let media =
    if job.status == jsDone:
      case job.kind
      of jkJpeg:
        &"<img class=\"result-media\" src=\"/files/{job.id.htmlEscape}\" alt=\"result\">"
      of jkMp4:
        &"<video class=\"result-media\" controls src=\"/files/{job.id.htmlEscape}\"></video>"
    else:
      &"<p class=\"error\">{job.message.htmlEscape}</p>"

  let body = &"""
<article>
  <h2>Result</h2>
  <p>job: <code>{job.id.htmlEscape}</code></p>
  <p>kind: <code>{job.kind.toWire}</code>, status: <code>{job.status.toWire}</code></p>
  <p class="muted">{job.message.htmlEscape}</p>
  {media}
  <p class="row"><a href="/">Back</a><a href="/files/{job.id.htmlEscape}">Download</a></p>
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
