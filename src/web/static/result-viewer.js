(() => {
  const root = document.getElementById('interactive-viewer');
  if (!root) return;

  const video = document.getElementById('iv-video');
  const canvas = document.getElementById('iv-canvas');
  const toggleButton = document.getElementById('iv-overlay-toggle');
  const presetSelect = document.getElementById('iv-overlay-preset');
  const labelsCheckbox = document.getElementById('iv-show-labels');
  const statusText = document.getElementById('iv-status');
  const playButton = document.getElementById('iv-play');
  const seekControl = document.getElementById('iv-seek');
  const timeReadout = document.getElementById('iv-time');
  const muteButton = document.getElementById('iv-mute');
  const fullscreenButton = document.getElementById('iv-fullscreen');
  const videoWrap = root.querySelector('.video-overlay-wrap');

  if (!video || !canvas) return;

  const ctx = canvas.getContext('2d');
  const detectionsUrl = root.dataset.detectionsUrl;
  const presets = {
    light: { maxBoxes: 8, maxLabels: 3, minBoxScore: 0.35, minLabelScore: 0.60 },
    balanced: { maxBoxes: 12, maxLabels: 6, minBoxScore: 0.25, minLabelScore: 0.50 },
    rich: { maxBoxes: 24, maxLabels: 12, minBoxScore: 0.20, minLabelScore: 0.40 },
    'boxes-only': { maxBoxes: 16, maxLabels: 0, minBoxScore: 0.25, minLabelScore: 1.00 }
  };

  let detections = null;
  let frames = [];
  let overlayEnabled = true;
  let lastDrawnFrame = -1;
  let lastCanvasWidth = 0;
  let lastCanvasHeight = 0;
  let rafId = 0;
  let rvfcActive = false;
  let userSeeking = false;

  function setStatus(text) {
    if (statusText) statusText.textContent = text;
  }

  function currentPreset() {
    return presets[presetSelect?.value || 'balanced'] || presets.balanced;
  }

  function clearOverlay() {
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    lastDrawnFrame = -1;
  }

  function finiteDuration() {
    return Number.isFinite(video.duration) && video.duration > 0;
  }

  function formatTime(seconds) {
    if (!Number.isFinite(seconds) || seconds < 0) return '0:00';
    const total = Math.floor(seconds + 0.5);
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    if (h > 0) return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
    return `${m}:${String(s).padStart(2, '0')}`;
  }

  function updatePlaybackUi() {
    if (playButton) playButton.textContent = video.paused ? 'Play' : 'Pause';
    if (muteButton) muteButton.textContent = video.muted ? 'Unmute' : 'Mute';

    const durationKnown = finiteDuration();
    if (seekControl) {
      seekControl.disabled = !durationKnown;
      if (durationKnown && !userSeeking) {
        const pos = Math.max(0, Math.min(1000, Math.round((video.currentTime / video.duration) * 1000)));
        seekControl.value = String(pos);
      }
    }

    if (timeReadout) {
      const cur = formatTime(video.currentTime || 0);
      const dur = durationKnown ? formatTime(video.duration) : '0:00';
      timeReadout.textContent = `${cur} / ${dur}`;
    }
  }

  function resizeCanvas() {
    const rect = video.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return false;

    const dpr = window.devicePixelRatio || 1;
    const cssWidth = Math.round(rect.width);
    const cssHeight = Math.round(rect.height);
    const pixelWidth = Math.max(1, Math.round(cssWidth * dpr));
    const pixelHeight = Math.max(1, Math.round(cssHeight * dpr));

    canvas.style.width = cssWidth + 'px';
    canvas.style.height = cssHeight + 'px';

    if (canvas.width !== pixelWidth || canvas.height !== pixelHeight) {
      canvas.width = pixelWidth;
      canvas.height = pixelHeight;
      lastCanvasWidth = cssWidth;
      lastCanvasHeight = cssHeight;
      lastDrawnFrame = -1;
    }

    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    return true;
  }

  function frameForTime(time) {
    if (!frames.length) return null;

    let lo = 0;
    let hi = frames.length - 1;
    while (lo < hi) {
      const mid = Math.floor((lo + hi) / 2);
      if (frames[mid].time < time) lo = mid + 1;
      else hi = mid;
    }

    if (lo > 0) {
      const prev = frames[lo - 1];
      const cur = frames[lo];
      if (Math.abs(prev.time - time) <= Math.abs(cur.time - time)) return prev;
    }
    return frames[lo];
  }

  function detectionBox(det, width, height) {
    const normalized = Math.abs(det.x) <= 1.5 && Math.abs(det.y) <= 1.5 &&
      Math.abs(det.w) <= 1.5 && Math.abs(det.h) <= 1.5;

    if (normalized) {
      return {
        x: det.x * width,
        y: det.y * height,
        w: det.w * width,
        h: det.h * height
      };
    }

    const sourceWidth = detections?.video?.width || video.videoWidth || width;
    const sourceHeight = detections?.video?.height || video.videoHeight || height;
    return {
      x: det.x * width / sourceWidth,
      y: det.y * height / sourceHeight,
      w: det.w * width / sourceWidth,
      h: det.h * height / sourceHeight
    };
  }

  function classColor(det, alpha = 0.92) {
    const palette = [
      [31, 136, 61],
      [9, 105, 218],
      [191, 135, 0],
      [130, 80, 223]
    ];
    const rawId = Number(det?.classId);
    const idx = Number.isFinite(rawId) ? ((Math.trunc(rawId) % palette.length) + palette.length) % palette.length : 0;
    const [r, g, b] = palette[idx];
    return `rgba(${r}, ${g}, ${b}, ${alpha})`;
  }

  function drawLabel(text, x, y, bgColor, viewportWidth, viewportHeight) {
    const safeText = String(text || '').slice(0, 64);
    if (!safeText) return;

    ctx.font = '14px system-ui, sans-serif';
    ctx.textBaseline = 'top';

    const padX = 5;
    const padY = 3;
    const labelHeight = 20;
    const textWidth = Math.ceil(ctx.measureText(safeText).width);
    const labelWidth = Math.max(32, textWidth + padX * 2);

    let labelX = x;
    if (Number.isFinite(viewportWidth) && viewportWidth > 0) {
      labelX = Math.max(0, Math.min(labelX, viewportWidth - labelWidth));
    }

    let labelY = y >= labelHeight + 2 ? y - labelHeight - 2 : y + 2;
    if (Number.isFinite(viewportHeight) && viewportHeight > 0) {
      labelY = Math.max(0, Math.min(labelY, viewportHeight - labelHeight));
    }

    ctx.fillStyle = bgColor || 'rgba(0, 0, 0, 0.72)';
    ctx.fillRect(labelX, labelY, labelWidth, labelHeight);
    ctx.fillStyle = 'rgba(255, 255, 255, 0.95)';
    ctx.fillText(safeText, labelX + padX, labelY + padY);
  }

  function drawForTime(time) {
    updatePlaybackUi();

    if (!overlayEnabled || !detections || !resizeCanvas()) {
      if (!overlayEnabled) clearOverlay();
      return;
    }

    const frame = frameForTime(time);
    if (!frame) {
      clearOverlay();
      return;
    }

    const width = lastCanvasWidth || video.clientWidth;
    const height = lastCanvasHeight || video.clientHeight;
    if (frame.frame === lastDrawnFrame && width > 0 && height > 0) return;

    ctx.clearRect(0, 0, width, height);
    lastDrawnFrame = frame.frame;

    const preset = currentPreset();
    const showLabels = labelsCheckbox ? labelsCheckbox.checked : true;
    const items = (frame.detections || [])
      .filter((det) => Number(det.score) >= preset.minBoxScore)
      .sort((a, b) => Number(b.score) - Number(a.score))
      .slice(0, preset.maxBoxes);

    ctx.lineWidth = 3;

    let labelsDrawn = 0;
    for (const det of items) {
      const box = detectionBox(det, width, height);
      const x = Math.max(0, Math.min(width, box.x));
      const y = Math.max(0, Math.min(height, box.y));
      const w = Math.max(0, Math.min(width - x, box.w));
      const h = Math.max(0, Math.min(height - y, box.h));
      if (w <= 1 || h <= 1) continue;

      const color = classColor(det);
      ctx.strokeStyle = color;
      ctx.strokeRect(x, y, w, h);

      if (showLabels && labelsDrawn < preset.maxLabels && Number(det.score) >= preset.minLabelScore) {
        const score = Number(det.score);
        const label = `${det.label || det.classId} ${(score * 100).toFixed(0)}%`;
        drawLabel(label, x, y, color, width, height);
        labelsDrawn += 1;
      }
    }

    setStatus(`frame ${frame.frame}, ${items.length} boxes`);
  }

  function redraw() {
    lastDrawnFrame = -1;
    drawForTime(video.currentTime || 0);
  }

  function scheduleVideoFrameCallback() {
    if (typeof video.requestVideoFrameCallback !== 'function') return false;
    if (rvfcActive) return true;

    rvfcActive = true;
    const onFrame = (_now, metadata) => {
      const mediaTime = typeof metadata?.mediaTime === 'number' ? metadata.mediaTime : video.currentTime;
      drawForTime(mediaTime);
      if (!video.paused && !video.ended) {
        video.requestVideoFrameCallback(onFrame);
      } else {
        rvfcActive = false;
      }
    };
    video.requestVideoFrameCallback(onFrame);
    return true;
  }

  function scheduleAnimationFrameLoop() {
    if (rafId) return;
    const tick = () => {
      drawForTime(video.currentTime || 0);
      if (!video.paused && !video.ended) {
        rafId = requestAnimationFrame(tick);
      } else {
        rafId = 0;
      }
    };
    rafId = requestAnimationFrame(tick);
  }

  function startDrawLoop() {
    if (!scheduleVideoFrameCallback()) scheduleAnimationFrameLoop();
  }

  function togglePlayback() {
    if (video.paused || video.ended) {
      const promise = video.play();
      if (promise && typeof promise.catch === 'function') {
        promise.catch((err) => setStatus(`play failed: ${err.message}`));
      }
    } else {
      video.pause();
    }
    updatePlaybackUi();
  }

  function seekFromControl() {
    if (!seekControl || !finiteDuration()) return;
    const ratio = Math.max(0, Math.min(1, Number(seekControl.value) / 1000));
    video.currentTime = ratio * video.duration;
    redraw();
    updatePlaybackUi();
  }

  function toggleFullscreen() {
    const target = root;
    if (document.fullscreenElement) {
      document.exitFullscreen?.();
      return;
    }
    if (target.requestFullscreen) {
      target.requestFullscreen().catch((err) => setStatus(`fullscreen failed: ${err.message}`));
    } else if (videoWrap?.webkitRequestFullscreen) {
      videoWrap.webkitRequestFullscreen();
    }
  }

  toggleButton?.addEventListener('click', () => {
    overlayEnabled = !overlayEnabled;
    toggleButton.textContent = overlayEnabled ? 'Overlay: ON' : 'Overlay: OFF';
    toggleButton.setAttribute('aria-pressed', overlayEnabled ? 'true' : 'false');
    redraw();
  });

  presetSelect?.addEventListener('change', redraw);
  labelsCheckbox?.addEventListener('change', redraw);
  playButton?.addEventListener('click', togglePlayback);
  video.addEventListener('click', togglePlayback);
  muteButton?.addEventListener('click', () => {
    video.muted = !video.muted;
    updatePlaybackUi();
  });
  fullscreenButton?.addEventListener('click', toggleFullscreen);
  seekControl?.addEventListener('input', () => {
    userSeeking = true;
    seekFromControl();
  });
  seekControl?.addEventListener('change', () => {
    seekFromControl();
    userSeeking = false;
  });
  seekControl?.addEventListener('pointerup', () => {
    userSeeking = false;
    updatePlaybackUi();
  });
  seekControl?.addEventListener('keyup', () => {
    userSeeking = false;
    updatePlaybackUi();
  });

  video.addEventListener('loadedmetadata', redraw);
  video.addEventListener('durationchange', updatePlaybackUi);
  video.addEventListener('play', () => {
    updatePlaybackUi();
    startDrawLoop();
  });
  video.addEventListener('pause', () => {
    updatePlaybackUi();
    redraw();
  });
  video.addEventListener('ended', updatePlaybackUi);
  video.addEventListener('seeked', redraw);
  video.addEventListener('timeupdate', () => {
    updatePlaybackUi();
    if (video.paused) redraw();
  });
  window.addEventListener('resize', redraw);
  document.addEventListener('fullscreenchange', redraw);

  updatePlaybackUi();

  fetch(detectionsUrl, { cache: 'no-store' })
    .then((res) => {
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return res.json();
    })
    .then((json) => {
      detections = json;
      frames = Array.isArray(json.frames) ? json.frames.slice().sort((a, b) => a.time - b.time) : [];
      setStatus(`loaded ${frames.length} frames`);
      redraw();
    })
    .catch((err) => {
      setStatus(`failed to load detections: ${err.message}`);
      clearOverlay();
    });
})();
