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

function detectUploadKind(filename) {
  const name = String(filename || '').toLowerCase();
  if (name.endsWith('.mp4') || name.endsWith('.m4v')) return 'mp4';
  return 'jpeg';
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
    const kind = job.kind || detectUploadKind(file.name);
    if (kind === 'mp4') {
      message.textContent = 'opening live interactive viewer...';
      location.href = '/result/' + encodeURIComponent(job.id);
    } else {
      message.textContent = 'processing...';
      location.href = '/wait/' + encodeURIComponent(job.id);
    }
  } catch (err) {
    message.textContent = 'error: ' + err.message;
    button.disabled = false;
  }
});
