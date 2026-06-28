const cameraGrid = document.getElementById('camera-grid');
const liveMessage = document.getElementById('live-message');
const refreshButton = document.getElementById('refresh-cameras');
const selectedBadge = document.getElementById('selected-camera-badge');
const selectedName = document.getElementById('selected-camera-name');
const selectedWebrtcLink = document.getElementById('selected-webrtc-link');
const aiWebrtcLink = document.getElementById('ai-webrtc-link');
const aiPipelineStatus = document.getElementById('ai-pipeline-status');
const aiPreviewBox = document.getElementById('ai-preview-box');
const sessionStartButton = document.getElementById('session-start');
const sessionStopButton = document.getElementById('session-stop');
const sessionInputRtsp = document.getElementById('session-input-rtsp');
const sessionOutputRtsp = document.getElementById('session-output-rtsp');
const sessionMessage = document.getElementById('session-message');
const liveDebugOverlayInput = document.getElementById('live-debug-overlay');
const liveOverlayPresetInput = document.getElementById('live-overlay-preset');
const liveSettingsSaveButton = document.getElementById('live-settings-save');
const liveSettingsStatus = document.getElementById('live-settings-status');
const liveSettingsEditState = document.getElementById('live-settings-edit-state');

const dialog = document.getElementById('camera-dialog');
const dialogTitle = document.getElementById('camera-dialog-title');
const cameraForm = document.getElementById('camera-form');
const cameraIdInput = document.getElementById('camera-id');
const cameraNameInput = document.getElementById('camera-name');
const cameraSourceInput = document.getElementById('camera-source');
const cameraTransportInput = document.getElementById('camera-transport');
const cameraDirectProxyInput = document.getElementById('camera-direct-proxy');
const cameraEnabledInput = document.getElementById('camera-enabled');
const cameraDeleteButton = document.getElementById('camera-delete');
const cameraCancelButton = document.getElementById('camera-cancel');
const cameraDialogCloseButton = document.getElementById('camera-dialog-close');

let slots = [];
let liveTarget = {
  selectedCameraId: '',
  aiMediamtxPath: 'cam-ai',
  aiWebrtcPath: '/cam-ai',
  pipelineStatus: 'not-started',
  running: false,
  message: 'no camera selected',
};
let liveSession = {
  status: 'stopped',
  running: false,
  selectedCameraId: '',
  selectedCameraName: '',
  inputMediamtxPath: '',
  inputRtspUrl: '',
  outputMediamtxPath: 'cam-ai',
  outputRtspUrl: 'rtsp://127.0.0.1:8554/cam-ai',
  aiWebrtcPath: '/cam-ai',
  message: 'live relay is stopped',
  startedAt: '',
  stoppedAt: '',
};
let liveSettings = {
  debugOverlay: true,
  overlayPreset: 'balanced',
  canEdit: true,
};
let liveSettingsDirty = false;
let liveSettingsSaving = false;

let previewReloadSerial = 0;
let previewResyncButton = null;

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

function withPreviewReloadToken(url, reason) {
  const next = new URL(url, location.href);
  previewReloadSerial += 1;
  next.searchParams.set('hailoPreviewReload', `${Date.now()}-${previewReloadSerial}`);
  if (reason) next.searchParams.set('hailoPreviewReason', reason);
  return next.toString();
}

function createWebrtcPreviewFrame(baseUrl, title, extraClass = '') {
  const frame = document.createElement('iframe');
  frame.className = extraClass ? `webrtc-preview-frame ${extraClass}` : 'webrtc-preview-frame';
  frame.src = baseUrl;
  frame.dataset.baseSrc = baseUrl;
  frame.title = title;
  frame.loading = 'lazy';
  frame.allow = 'autoplay; fullscreen; picture-in-picture';
  return frame;
}

function reloadPreviewFrame(frame, reason) {
  if (!frame) return false;
  const baseSrc = frame.dataset.baseSrc || frame.src;
  if (!baseSrc) return false;
  frame.src = withPreviewReloadToken(baseSrc, reason);
  return true;
}

function cssEscapeIdentifier(value) {
  if (window.CSS && typeof window.CSS.escape === 'function') return window.CSS.escape(value);
  return String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}

function reloadSelectedRawPreview(reason) {
  const cameraId = selectedCameraId();
  if (!cameraId) return false;
  const card = cameraGrid.querySelector(`[data-camera-id="${cssEscapeIdentifier(cameraId)}"]`);
  if (!card) return false;
  return reloadPreviewFrame(card.querySelector('iframe.webrtc-preview-frame'), reason || 'selected-raw');
}

function reloadAiPreview(reason) {
  return reloadPreviewFrame(aiPreviewBox && aiPreviewBox.querySelector('iframe.webrtc-preview-frame'), reason || 'ai');
}

function resyncPreviewFrames(reason = 'manual') {
  const rawReloaded = reloadSelectedRawPreview(`${reason}-raw`);
  const aiReloaded = reloadAiPreview(`${reason}-ai`);
  return { rawReloaded, aiReloaded };
}

function schedulePreviewResync(reason, delayMs) {
  window.setTimeout(() => {
    const result = resyncPreviewFrames(reason);
    if (result.rawReloaded || result.aiReloaded) {
      console.debug('live preview resync', reason, result);
    }
  }, delayMs);
}

function webrtcUrl(slot) {
  return absoluteMediaUrl(8889, slot.webrtcPath || '/' + slot.mediamtxPath);
}

function hlsUrl(slot) {
  return absoluteMediaUrl(8888, slot.hlsPath || '/' + slot.mediamtxPath);
}

function normalizedInputMode(slot) {
  const mode = String(slot && slot.inputMode || '').trim().toLowerCase();
  return mode === 'direct' ? 'direct' : 'relay';
}

function inputModeLabel(slot) {
  return normalizedInputMode(slot) === 'direct' ? 'direct' : 'relay';
}

function aiWebrtcUrl() {
  return absoluteMediaUrl(8889, liveSession.aiWebrtcPath || liveTarget.aiWebrtcPath || '/cam-ai');
}

function defaultSlotName(slotId) {
  const n = String(slotId || '').replace('cam', '');
  return n ? `Camera ${n}` : 'Camera';
}

function selectedCameraId() {
  return liveTarget.selectedCameraId || '';
}

function findSlot(slotId) {
  return slots.find((slot) => slot.id === slotId) || null;
}

function hasSelectableTarget() {
  const slot = findSlot(selectedCameraId());
  return Boolean(slot && slot.enabled && slot.source);
}



function normalizeLiveOverlayPreset(value) {
  const normalized = String(value || '').trim().toLowerCase();
  if (normalized === 'light' || normalized === 'balanced' || normalized === 'rich' || normalized === 'boxes-only') {
    return normalized;
  }
  return 'balanced';
}

function liveSessionIsEditable() {
  const status = String(liveSession.status || liveTarget.pipelineStatus || 'stopped').toLowerCase();
  return !(liveSession.running || status === 'running' || status === 'starting' || status === 'stopping');
}

function currentLiveSettingsFormValue() {
  return {
    debugOverlay: Boolean(liveDebugOverlayInput && liveDebugOverlayInput.checked),
    overlayPreset: normalizeLiveOverlayPreset(liveOverlayPresetInput && liveOverlayPresetInput.value),
  };
}

function liveSettingsFormMatchesSaved() {
  if (!liveDebugOverlayInput) return true;
  const current = currentLiveSettingsFormValue();
  return Boolean(current.debugOverlay) === Boolean(liveSettings.debugOverlay)
    && normalizeLiveOverlayPreset(current.overlayPreset) === normalizeLiveOverlayPreset(liveSettings.overlayPreset);
}

function updateLiveSettingsDirtyFromForm() {
  liveSettingsDirty = !liveSettingsFormMatchesSaved();
}

function updateLiveSettingsPanel(options = {}) {
  if (!liveDebugOverlayInput || !liveSettingsSaveButton) return;
  const canEdit = Boolean(liveSettings.canEdit && liveSessionIsEditable());
  const preserveForm = Boolean(options.preserveForm || liveSettingsDirty || liveSettingsSaving);

  if (!preserveForm) {
    liveDebugOverlayInput.checked = Boolean(liveSettings.debugOverlay);
    if (liveOverlayPresetInput) liveOverlayPresetInput.value = normalizeLiveOverlayPreset(liveSettings.overlayPreset);
    liveSettingsDirty = false;
  }

  liveDebugOverlayInput.disabled = !canEdit || liveSettingsSaving;
  if (liveOverlayPresetInput) liveOverlayPresetInput.disabled = !canEdit || liveSettingsSaving;

  if (!canEdit) {
    liveSettingsSaveButton.disabled = true;
    liveSettingsSaveButton.textContent = 'Stop to edit';
    liveSettingsSaveButton.classList.add('secondary');
    liveSettingsSaveButton.classList.remove('settings-save-dirty');
    if (liveSettingsStatus) liveSettingsStatus.textContent = 'running - setting is locked';
  } else if (liveSettingsSaving) {
    liveSettingsSaveButton.disabled = true;
    liveSettingsSaveButton.textContent = 'Saving...';
    liveSettingsSaveButton.classList.add('secondary');
    liveSettingsSaveButton.classList.remove('settings-save-dirty');
    if (liveSettingsStatus) liveSettingsStatus.textContent = 'saving...';
  } else if (liveSettingsDirty) {
    liveSettingsSaveButton.disabled = false;
    liveSettingsSaveButton.textContent = 'Save changes';
    liveSettingsSaveButton.classList.remove('secondary');
    liveSettingsSaveButton.classList.add('settings-save-dirty');
    if (liveSettingsStatus) liveSettingsStatus.textContent = 'changed - applies on next Start';
  } else {
    liveSettingsSaveButton.disabled = true;
    liveSettingsSaveButton.textContent = 'Saved';
    liveSettingsSaveButton.classList.add('secondary');
    liveSettingsSaveButton.classList.remove('settings-save-dirty');
    if (liveSettingsStatus) liveSettingsStatus.textContent = 'current';
  }

  if (liveSettingsEditState) {
    liveSettingsEditState.textContent = canEdit ? 'editable while stopped' : 'stop AI preview to edit';
  }
}

async function loadLiveSettings() {
  const res = await fetch('/api/live/settings', { cache: 'no-store' });
  if (!res.ok) throw new Error(await res.text());
  liveSettings = await res.json();
  liveSettings.overlayPreset = normalizeLiveOverlayPreset(liveSettings.overlayPreset);
  liveSettingsDirty = false;
}

async function saveLiveSettings(options = {}) {
  if (!liveDebugOverlayInput) return liveSettings;
  const quiet = Boolean(options.quiet);

  updateLiveSettingsDirtyFromForm();
  if (!liveSettingsDirty) {
    updateLiveSettingsPanel();
    return liveSettings;
  }

  try {
    liveSettingsSaving = true;
    updateLiveSettingsPanel({ preserveForm: true });
    const res = await fetch('/api/live/settings', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(currentLiveSettingsFormValue()),
    });
    if (!res.ok) throw new Error(await res.text());
    liveSettings = await res.json();
    liveSettings.overlayPreset = normalizeLiveOverlayPreset(liveSettings.overlayPreset);
    liveSettingsDirty = false;
    if (!quiet) setMessage('live AI settings saved');
    return liveSettings;
  } catch (err) {
    if (!quiet) setMessage('error: ' + err.message, true);
    throw err;
  } finally {
    liveSettingsSaving = false;
    updateLiveSettingsPanel();
  }
}

async function saveLiveSettingsBeforeStart() {
  updateLiveSettingsDirtyFromForm();
  if (liveSettingsDirty) {
    setMessage('saving live AI settings before start...');
    await saveLiveSettings({ quiet: true });
  }
}

function renderAiPreviewBox() {
  if (!aiPreviewBox) return;
  const status = liveSession.status || liveTarget.pipelineStatus || 'stopped';
  const shouldEmbed = status === 'running' || liveSession.running;

  aiPreviewBox.replaceChildren();
  if (shouldEmbed) {
    const frame = createWebrtcPreviewFrame(
      aiWebrtcUrl(),
      'AI preview WebRTC stream',
      'ai-preview-frame'
    );
    frame.dataset.previewRole = 'ai';
    aiPreviewBox.appendChild(frame);
    return;
  }

  const placeholder = document.createElement('div');
  placeholder.className = 'ai-preview-placeholder';

  const label = document.createElement('strong');
  label.textContent = '/cam-ai';
  placeholder.appendChild(label);

  const text = document.createElement('span');
  text.className = 'muted';
  if (status === 'error') {
    text.textContent = 'ライブリレーが停止しました。状態を確認して再度 Start AI relay を実行してください。';
  } else {
    text.textContent = 'Start AI relay 後に、選択中カメラの /cam-ai stream を表示します。';
  }
  placeholder.appendChild(text);

  aiPreviewBox.appendChild(placeholder);
}

function updateSessionPanel() {
  const status = liveSession.status || liveTarget.pipelineStatus || 'stopped';
  aiPipelineStatus.textContent = status;
  sessionInputRtsp.textContent = liveSession.inputRtspUrl || 'not prepared';
  sessionOutputRtsp.textContent = liveSession.outputRtspUrl || 'not prepared';
  sessionMessage.textContent = liveSession.message || liveTarget.message || '';
  renderAiPreviewBox();

  const canPrepare = hasSelectableTarget() && status !== 'running' && status !== 'starting';
  sessionStartButton.disabled = !canPrepare;
  sessionStopButton.disabled = !(liveSession.running || status === 'running' || status === 'starting');
  updateLiveSettingsPanel();
}

function updateSelectedPanel() {
  const slot = findSlot(selectedCameraId());
  const aiUrl = aiWebrtcUrl();
  aiWebrtcLink.href = aiUrl;
  aiWebrtcLink.textContent = aiUrl;

  if (!slot || !slot.enabled || !slot.source) {
    selectedBadge.textContent = 'not selected';
    selectedBadge.classList.remove('active');
    selectedName.textContent = 'None';
    selectedWebrtcLink.removeAttribute('href');
    selectedWebrtcLink.textContent = 'not available';
    updateSessionPanel();
    return;
  }

  selectedBadge.textContent = slot.id;
  selectedBadge.classList.add('active');
  selectedName.textContent = slot.name || slot.id;
  selectedWebrtcLink.href = webrtcUrl(slot);
  selectedWebrtcLink.textContent = webrtcUrl(slot);
  updateSessionPanel();
}

function renderCameraCard(slot) {
  const configured = Boolean(slot.enabled && slot.source);
  const selected = slot.id === selectedCameraId();
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
  badge.classList.toggle('active', configured || selected);
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
    const frame = createWebrtcPreviewFrame(
      webrtcUrl(slot),
      `${slot.name || slot.id} WebRTC preview`
    );
    frame.dataset.previewRole = 'raw';
    frame.dataset.cameraId = slot.id;
    preview.appendChild(frame);
  }

  card.appendChild(preview);

  if (configured) {
    const meta = document.createElement('div');
    meta.className = 'camera-preview-meta';

    const pathLabel = document.createElement('strong');
    pathLabel.textContent = '/' + slot.mediamtxPath;
    meta.appendChild(pathLabel);

    const mode = document.createElement('span');
    mode.className = 'muted';
    mode.textContent = `input: ${inputModeLabel(slot)}`;
    meta.appendChild(mode);

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
  select.textContent = selected ? 'Clear target' : 'AI target';
  select.title = selected ? 'Clear the selected AI target' : `Use ${slot.id} as the AI target`;
  select.addEventListener('click', () => {
    if (selected) {
      clearAiTarget();
    } else {
      selectCamera(slot.id);
    }
  });
  actions.appendChild(select);

  card.appendChild(actions);
  return card;
}

function renderCameraGrid() {
  cameraGrid.replaceChildren(...slots.map(renderCameraCard));
  updateSelectedPanel();
}

async function loadLiveTarget() {
  const res = await fetch('/api/live/target', { cache: 'no-store' });
  if (!res.ok) throw new Error(await res.text());
  liveTarget = await res.json();
}

async function loadLiveSession() {
  const res = await fetch('/api/live/session', { cache: 'no-store' });
  if (!res.ok) throw new Error(await res.text());
  liveSession = await res.json();
}

async function loadCameras() {
  setMessage('loading cameras...');
  try {
    const res = await fetch('/api/live/cameras', { cache: 'no-store' });
    if (!res.ok) throw new Error(await res.text());
    const data = await res.json();
    slots = Array.isArray(data.slots) ? data.slots : [];
    await loadLiveTarget();
    await loadLiveSession();
    await loadLiveSettings();
    renderCameraGrid();
    setMessage('');
  } catch (err) {
    setMessage('error: ' + err.message, true);
  }
}

function openCameraDialog(slot) {
  const hasSavedSource = Boolean(String(slot.source || '').trim());
  const hasSavedState = Boolean(slot.enabled || hasSavedSource);

  cameraIdInput.value = slot.id;
  cameraNameInput.value = slot.name || defaultSlotName(slot.id);
  cameraSourceInput.value = slot.source || '';
  cameraTransportInput.value = slot.rtspTransport || 'udp';
  cameraDirectProxyInput.checked = normalizedInputMode(slot) === 'direct';

  // New camera slots should become usable with a single Save after the user
  // enters an RTSP URL. Existing disabled slots keep their saved state unless
  // the user explicitly changes the checkbox.
  cameraEnabledInput.checked = hasSavedState ? Boolean(slot.enabled || hasSavedSource) : true;
  cameraEnabledInput.dataset.userChanged = '0';
  cameraDeleteButton.hidden = !hasSavedState;
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
  const source = cameraSourceInput.value.trim();
  const body = {
    name: cameraNameInput.value.trim() || defaultSlotName(cameraId),
    source,
    rtspTransport: cameraTransportInput.value,
    inputMode: cameraDirectProxyInput.checked ? 'direct' : 'relay',
    enabled: Boolean(source) && cameraEnabledInput.checked,
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
    closeCameraDialog();
    await loadCameras();
    setMessage(`${cameraId} deleted`);
  } catch (err) {
    setMessage('error: ' + err.message, true);
  }
}

async function selectCamera(cameraId) {
  const slot = findSlot(cameraId);
  if (!slot || !slot.enabled || !slot.source) return;

  try {
    setMessage(`selecting ${cameraId} as AI target...`);
    const res = await fetch('/api/live/target/' + encodeURIComponent(cameraId), { method: 'PUT' });
    if (!res.ok) throw new Error(await res.text());
    liveTarget = await res.json();
    await loadLiveSession();
    renderCameraGrid();
    setMessage(`${cameraId} selected as AI target`);
  } catch (err) {
    setMessage('error: ' + err.message, true);
  }
}

async function clearAiTarget() {
  const status = liveSession.status || liveTarget.pipelineStatus || 'stopped';
  if (liveSession.running || status === 'running' || status === 'starting') {
    setMessage('stop live AI relay before clearing the AI target', true);
    return;
  }

  try {
    setMessage('clearing AI target...');
    const res = await fetch('/api/live/target', { method: 'DELETE' });
    const text = await res.text();
    if (!res.ok) throw new Error(text || res.statusText);

    if (text.trim()) {
      liveTarget = JSON.parse(text);
    } else {
      await loadLiveTarget();
    }
    await loadLiveSession();
    renderCameraGrid();
    setMessage('AI target cleared');
  } catch (err) {
    setMessage('error: ' + err.message, true);
  }
}

async function prepareSession() {
  try {
    await saveLiveSettingsBeforeStart();
    setMessage('starting live AI relay...');
    const res = await fetch('/api/live/session/start', { method: 'POST' });
    if (!res.ok) throw new Error(await res.text());
    liveSession = await res.json();
    await loadLiveTarget();
    await loadLiveSettings();
    updateSelectedPanel();
    schedulePreviewResync('session-start', 1200);
    setMessage(liveSession.message || 'live AI relay started');
  } catch (err) {
    setMessage('error: ' + err.message, true);
  }
}

async function stopSession() {
  try {
    setMessage('stopping live AI relay...');
    const res = await fetch('/api/live/session/stop', { method: 'POST' });
    if (!res.ok) throw new Error(await res.text());
    liveSession = await res.json();
    await loadLiveTarget();
    await loadLiveSettings();
    updateSelectedPanel();
    setMessage('live AI relay stopped');
  } catch (err) {
    setMessage('error: ' + err.message, true);
  }
}


function initPreviewResyncButton() {
  if (!sessionStartButton || !sessionStopButton || previewResyncButton) return;
  previewResyncButton = document.createElement('button');
  previewResyncButton.id = 'preview-resync';
  previewResyncButton.type = 'button';
  previewResyncButton.className = 'secondary';
  previewResyncButton.textContent = 'Resync previews';
  previewResyncButton.title = 'Reload the selected raw WebRTC preview and the AI WebRTC preview at nearly the same time.';
  previewResyncButton.addEventListener('click', () => {
    const result = resyncPreviewFrames('manual');
    if (result.rawReloaded || result.aiReloaded) {
      setMessage('raw / AI preview players reloaded');
    } else {
      setMessage('no active preview player to reload', true);
    }
  });
  sessionStopButton.insertAdjacentElement('afterend', previewResyncButton);
}

initPreviewResyncButton();

refreshButton.addEventListener('click', loadCameras);
sessionStartButton.addEventListener('click', prepareSession);
sessionStopButton.addEventListener('click', stopSession);
if (liveSettingsSaveButton) liveSettingsSaveButton.addEventListener('click', () => {
  saveLiveSettings().catch(() => {});
});
if (liveDebugOverlayInput) {
  liveDebugOverlayInput.addEventListener('change', () => {
    updateLiveSettingsDirtyFromForm();
    updateLiveSettingsPanel({ preserveForm: true });
  });
}
if (liveOverlayPresetInput) {
  liveOverlayPresetInput.addEventListener('change', () => {
    updateLiveSettingsDirtyFromForm();
    updateLiveSettingsPanel({ preserveForm: true });
  });
}
cameraForm.addEventListener('submit', saveCamera);
cameraSourceInput.addEventListener('input', () => {
  if (cameraSourceInput.value.trim() && cameraEnabledInput.dataset.userChanged !== '1') {
    cameraEnabledInput.checked = true;
  }
});
cameraEnabledInput.addEventListener('change', () => {
  cameraEnabledInput.dataset.userChanged = '1';
});
cameraDeleteButton.addEventListener('click', deleteCamera);
cameraCancelButton.addEventListener('click', closeCameraDialog);
cameraDialogCloseButton.addEventListener('click', closeCameraDialog);

dialog.addEventListener('click', (event) => {
  if (event.target === dialog) closeCameraDialog();
});

loadCameras();
