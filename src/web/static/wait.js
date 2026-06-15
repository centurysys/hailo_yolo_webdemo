const waitPage = document.getElementById('wait-page');
const jobId = waitPage.dataset.jobId;
const previewCard = document.getElementById('preview-card');
const previewImage = document.getElementById('preview-image');
let previewLoaded = false;

function refreshPreview(job) {
  if (job.kind !== 'mp4') return;
  previewImage.onload = () => {
    previewLoaded = true;
    previewCard.hidden = false;
  };
  previewImage.onerror = () => {
    if (!previewLoaded) previewCard.hidden = true;
  };
  previewImage.src = '/preview/' + encodeURIComponent(jobId) + '?v=' + Date.now();
}

async function poll() {
  const res = await fetch('/api/jobs/' + encodeURIComponent(jobId));
  if (!res.ok) {
    document.getElementById('status').textContent = 'job not found';
    return;
  }
  const job = await res.json();
  document.getElementById('progress').value = job.progress;
  document.getElementById('status').textContent = job.status + ' - ' + job.message;
  if (job.status !== 'done' && job.status !== 'failed') {
    refreshPreview(job);
  }
  if (job.status === 'done' || job.status === 'failed') {
    location.href = '/result/' + encodeURIComponent(jobId);
    return;
  }
  setTimeout(poll, 250);
}

poll();
