const cameraGrid = document.getElementById('camera-grid');
const liveMessage = document.getElementById('live-message');
const refreshButton = document.getElementById('refresh-cameras');
const selectedBadge = document.getElementById('selected-camera-badge');
const selectedName = document.getElementById('selected-camera-name');
const selectedWebrtcLink = document.getElementById('selected-webrtc-link');
const aiWebrtcLink = document.getElementById('ai-webrtc-link');

const dialog = document.getElementById('camera-dialog');
const dialogTitle = document.getElementById('camera-dialog-title');
const cameraForm = document.getElementById('camera-form');
const cameraIdInput = document.getElementById('camera-id');
const cameraNameInput = document.getElementById('camera-name');
const cameraSourceInput = document.getElementById('camera-source');
const cameraTransportInput = document.getElementById('camera-transport');
const cameraEnabledInput = document.getElementById('camera-enabled');
const cameraDeleteButton = document.getElementById('camera-delete');
const cameraCancelButton = document.getElementById('camera-cancel');
const cameraDialogCloseButton = document.getElementById('camera-dialog-close');

let slots = [];
let selectedCameraId = localStorage.getItem('hailo-live-selected-camera') || '';

function setMessage(text, isError = false) {
  liveMessage.textContent = text || '';
  liveMessage.classList.toggle('error', Boolean(isError));
  liveMessage.classList.toggle('muted', !isError);
}

function absoluteMediaUrl(port, path) {
  const scheme = location.protocol === 'https:' ? 'https:' : 'http:';
  const cleanPath = String(path || '').startsWith('/') ? path : '/' + String(path || '');
  return `${scheme}//${location.hostname}:${port}${cleanPath}`;
}

function webrtcUrl(slot) {
  return absoluteMediaUrl(8889, slot.webrtcPath || '/' + slot.mediamtxPath);
}

function hlsUrl(slot) {
  return absoluteMediaUrl(8888, slot.hlsPath || '/' + slot.mediamtxPath);
}

function aiWebrtcUrl() {
  return absoluteMediaUrl(8889, '/cam-ai');
}

function defaultSlotName(slotId) {
  const n = String(slotId || '').replace('cam', '');
  return n ? `Camera ${n}` : 'Camera';
}

function findSlot(slotId) {
  return slots.find((slot) => slot.id === slotId) || null;
}

function updateSelectedPanel() {
  const slot = findSlot(selectedCameraId);
  aiWebrtcLink.href = aiWebrtcUrl();
  aiWebrtcLink.textContent = aiWebrtcUrl();

  if (!slot || !slot.enabled || !slot.source) {
    selectedBadge.textContent = 'not selected';
    selectedBadge.classList.remove('active');
    selectedName.textContent = 'None';
    selectedWebrtcLink.removeAttribute('href');
    selectedWebrtcLink.textContent = 'not available';
    return;
  }

  selectedBadge.textContent = slot.id;
  selectedBadge.classList.add('active');
  selectedName.textContent = slot.name || slot.id;
  selectedWebrtcLink.href = webrtcUrl(slot);
  selectedWebrtcLink.textContent = webrtcUrl(slot);
}

function renderCameraCard(slot) {
  const configured = Boolean(slot.enabled && slot.source);
  const selected = slot.id === selectedCameraId;
  const card = document.createElement('article');
  card.className = 'camera-card';
  card.classList.toggle('configured', configured);
  card.classList.toggle('selected', selected);
  card.dataset.cameraId = slot.id;

  const title = document.createElement('div');
  title.className = 'camera-card-title';

  const titleText = document.createElement('strong');
  titleText.textContent = slot.name || defaultSlotName(slot.id);
  title.appendChild(titleText);

  const badge = document.createElement('span');
  badge.className = 'status-pill';
  badge.classList.toggle('active', configured);
  badge.textContent = configured ? (selected ? 'AI target' : 'enabled') : 'not set';
  title.appendChild(badge);
  card.appendChild(title);

  const preview = document.createElement('div');
  preview.className = 'camera-preview-box';

  if (!configured) {
    const addButton = document.createElement('button');
    addButton.type = 'button';
    addButton.className = 'add-camera-button';
    addButton.textContent = '+';
    addButton.title = `Configure ${slot.id}`;
    addButton.addEventListener('click', () => openCameraDialog(slot));
    preview.appendChild(addButton);
  } else {
    const frame = document.createElement('iframe');
    frame.className = 'webrtc-preview-frame';
    frame.src = webrtcUrl(slot);
    frame.title = `${slot.name || slot.id} WebRTC preview`;
    frame.loading = 'lazy';
    frame.allow = 'autoplay; fullscreen; picture-in-picture';
    preview.appendChild(frame);
  }

  card.appendChild(preview);

  if (configured) {
    const meta = document.createElement('div');
    meta.className = 'camera-preview-meta';

    const pathLabel = document.createElement('strong');
    pathLabel.textContent = '/' + slot.mediamtxPath;
    meta.appendChild(pathLabel);

    const source = document.createElement('span');
    source.className = 'muted one-line';
    source.textContent = slot.source;
    meta.appendChild(source);

    const links = document.createElement('div');
    links.className = 'preview-links';

    const webrtc = document.createElement('a');
    webrtc.href = webrtcUrl(slot);
    webrtc.target = '_blank';
    webrtc.rel = 'noreferrer';
    webrtc.textContent = 'Open WebRTC';
    links.appendChild(webrtc);

    const hls = document.createElement('a');
    hls.href = hlsUrl(slot);
    hls.target = '_blank';
    hls.rel = 'noreferrer';
    hls.textContent = 'HLS';
    links.appendChild(hls);

    meta.appendChild(links);
    card.appendChild(meta);
  }

  const actions = document.createElement('div');
  actions.className = 'camera-actions';

  const edit = document.createElement('button');
  edit.type = 'button';
  edit.className = configured ? 'secondary' : '';
  edit.textContent = configured ? 'Edit' : 'Configure';
  edit.addEventListener('click', () => openCameraDialog(slot));
  actions.appendChild(edit);

  const select = document.createElement('button');
  select.type = 'button';
  select.className = selected ? '' : 'secondary';
  select.disabled = !configured;
  select.textContent = selected ? 'Selected' : 'AI target';
  select.addEventListener('click', () => selectCamera(slot.id));
  actions.appendChild(select);

  card.appendChild(actions);
  return card;
}

function renderCameraGrid() {
  cameraGrid.replaceChildren(...slots.map(renderCameraCard));
  updateSelectedPanel();
}

async function loadCameras() {
  setMessage('loading cameras...');
  try {
    const res = await fetch('/api/live/cameras', { cache: 'no-store' });
    if (!res.ok) throw new Error(await res.text());
    const data = await res.json();
    slots = Array.isArray(data.slots) ? data.slots : [];
    if (selectedCameraId && !findSlot(selectedCameraId)) {
      selectedCameraId = '';
      localStorage.removeItem('hailo-live-selected-camera');
    }
    renderCameraGrid();
    setMessage('');
  } catch (err) {
    setMessage('error: ' + err.message, true);
  }
}

function openCameraDialog(slot) {
  cameraIdInput.value = slot.id;
  cameraNameInput.value = slot.name || defaultSlotName(slot.id);
  cameraSourceInput.value = slot.source || '';
  cameraTransportInput.value = slot.rtspTransport || 'tcp';
  cameraEnabledInput.checked = Boolean(slot.enabled || slot.source);
  cameraDeleteButton.hidden = !(slot.enabled || slot.source);
  dialogTitle.textContent = `${slot.id} settings`;

  if (typeof dialog.showModal === 'function') {
    dialog.showModal();
  } else {
    dialog.setAttribute('open', '');
  }
}

function closeCameraDialog() {
  if (typeof dialog.close === 'function') {
    dialog.close();
  } else {
    dialog.removeAttribute('open');
  }
}

async function saveCamera(event) {
  event.preventDefault();
  const cameraId = cameraIdInput.value;
  const body = {
    name: cameraNameInput.value.trim() || defaultSlotName(cameraId),
    source: cameraSourceInput.value.trim(),
    rtspTransport: cameraTransportInput.value,
    enabled: cameraEnabledInput.checked,
  };

  try {
    setMessage(`saving ${cameraId}...`);
    const res = await fetch('/api/live/cameras/' + encodeURIComponent(cameraId), {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error(await res.text());
    closeCameraDialog();
    await loadCameras();
    setMessage(`${cameraId} saved`);
  } catch (err) {
    setMessage('error: ' + err.message, true);
  }
}

async function deleteCamera() {
  const cameraId = cameraIdInput.value;
  if (!cameraId) return;
  try {
    setMessage(`deleting ${cameraId}...`);
    const res = await fetch('/api/live/cameras/' + encodeURIComponent(cameraId), { method: 'DELETE' });
    if (!res.ok) throw new Error(await res.text());
    if (selectedCameraId === cameraId) {
      selectedCameraId = '';
      localStorage.removeItem('hailo-live-selected-camera');
    }
    closeCameraDialog();
    await loadCameras();
    setMessage(`${cameraId} deleted`);
  } catch (err) {
    setMessage('error: ' + err.message, true);
  }
}

function selectCamera(cameraId) {
  const slot = findSlot(cameraId);
  if (!slot || !slot.enabled || !slot.source) return;
  selectedCameraId = cameraId;
  localStorage.setItem('hailo-live-selected-camera', cameraId);
  renderCameraGrid();
  setMessage(`${cameraId} selected as AI target`);
}

refreshButton.addEventListener('click', loadCameras);
cameraForm.addEventListener('submit', saveCamera);
cameraDeleteButton.addEventListener('click', deleteCamera);
cameraCancelButton.addEventListener('click', closeCameraDialog);
cameraDialogCloseButton.addEventListener('click', closeCameraDialog);

dialog.addEventListener('click', (event) => {
  if (event.target === dialog) closeCameraDialog();
});

loadCameras();
