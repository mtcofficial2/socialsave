(() => {
  "use strict";

  const SAMPLE_URL =
    "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4";
  const SAMPLE_THUMB = "./thumb-sample.jpg";
  const HISTORY_KEY = "socialsave.history";
  const SETTINGS_KEY = "socialsave.settings";
  const RING = 2 * Math.PI * 64;
  const API_BASE = window.location.hostname === "socialsave-api-p2tm.onrender.com"
    ? ""
    : "https://socialsave-api-p2tm.onrender.com";

  const PLATFORMS = [
    { id: "tiktok", name: "TikTok", color: "#000000" },
    { id: "instagram", name: "Instagram", color: "#E1306C" },
    { id: "facebook", name: "Facebook", color: "#1877F2" },
    { id: "x", name: "X", color: "#0F1419" },
    { id: "youtube", name: "YouTube", color: "#FF0000" },
    { id: "reddit", name: "Reddit", color: "#FF4500" },
    { id: "pinterest", name: "Pinterest", color: "#E60023" },
    { id: "direct", name: "Direct URL", color: "#0F766E" },
    { id: "web", name: "Other website", color: "#0F766E" },
  ];

  const HOSTS = {
    tiktok: ["tiktok.com", "vm.tiktok.com", "vt.tiktok.com"],
    instagram: ["instagram.com", "instagr.am"],
    facebook: ["facebook.com", "fb.com", "fb.watch"],
    x: ["twitter.com", "x.com"],
    youtube: ["youtube.com", "youtu.be", "youtube-nocookie.com"],
    reddit: ["reddit.com", "v.redd.it"],
    pinterest: ["pinterest.com", "pin.it"],
  };

  const VIDEO_EXT = ["mp4", "webm", "mov", "m4v", "mkv"];

  const QUALITIES = [
    { id: "best", label: "Best", height: 1080, bytes: 158_000_000 },
    { id: "1080p", label: "1080p", height: 1080, bytes: 142_000_000 },
    { id: "720p", label: "720p", height: 720, bytes: 82_000_000 },
    { id: "480p", label: "480p", height: 480, bytes: 45_000_000 },
    { id: "360p", label: "360p", height: 360, bytes: 22_000_000 },
  ];

  const DEFAULT_SETTINGS = {
    theme: "system",
    wifiOnly: true,
    autoStart: false,
    notifications: true,
    defaultQuality: "best",
  };

  const $ = (id) => document.getElementById(id);
  const qs = (sel, root = document) => root.querySelector(sel);
  const qsa = (sel, root = document) => [...root.querySelectorAll(sel)];

  const state = {
    screen: "home",
    tab: "home",
    stack: [],
    url: "",
    analyzing: false,
    preview: null,
    selectedQuality: "best",
    task: null,
    history: [],
    settings: { ...DEFAULT_SETTINGS },
    timer: null,
  };

  function load() {
    try {
      state.history = JSON.parse(localStorage.getItem(HISTORY_KEY) || "[]");
      if (!Array.isArray(state.history)) state.history = [];
    } catch {
      state.history = [];
    }
    try {
      state.settings = {
        ...DEFAULT_SETTINGS,
        ...JSON.parse(localStorage.getItem(SETTINGS_KEY) || "{}"),
      };
    } catch {
      state.settings = { ...DEFAULT_SETTINGS };
    }
  }

  function saveHistory() {
    localStorage.setItem(HISTORY_KEY, JSON.stringify(state.history.slice(0, 80)));
  }

  function saveSettings() {
    localStorage.setItem(SETTINGS_KEY, JSON.stringify(state.settings));
  }

  function escapeHtml(value) {
    return String(value ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function platformById(id) {
    return PLATFORMS.find((p) => p.id === id) || { id: "unknown", name: "Unknown", color: "#64748B" };
  }

  function hostOf(url) {
    try {
      return new URL(url).hostname.toLowerCase().replace(/^www\./, "");
    } catch {
      return "";
    }
  }

  function hostMatches(host, candidates) {
    return candidates.some((c) => host === c || host.endsWith(`.${c}`));
  }

  function detectPlatform(raw) {
    const host = hostOf(raw);
    if (!host) return "unknown";
    for (const [id, list] of Object.entries(HOSTS)) {
      if (hostMatches(host, list)) return id;
    }
    try {
      const parsed = new URL(raw);
      const path = parsed.pathname.toLowerCase();
      if (VIDEO_EXT.some((ext) => path.endsWith(`.${ext}`))) return "direct";
      if (parsed.protocol === "http:" || parsed.protocol === "https:") return "web";
    } catch {
      /* ignore */
    }
    return "unknown";
  }

  function looksRestricted(url) {
    const lower = url.toLowerCase();
    return (
      /\/stories\//.test(lower) ||
      /[?&]private=/.test(lower) ||
      /\b(private|members-only|login-wall|drm)\b/.test(lower) ||
      /instagram\.com\/(reel\/private|p\/private)/.test(lower)
    );
  }

  function isValidHttpUrl(value) {
    try {
      const u = new URL(value);
      return u.protocol === "http:" || u.protocol === "https:";
    } catch {
      return false;
    }
  }

  function formatBytes(n) {
    if (!n && n !== 0) return "—";
    const units = ["B", "KB", "MB", "GB"];
    let i = 0;
    let v = n;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i += 1;
    }
    return `${v >= 10 || i === 0 ? v.toFixed(0) : v.toFixed(1)} ${units[i]}`;
  }

  function formatDuration(seconds) {
    const s = Math.max(0, Math.round(seconds || 0));
    const m = Math.floor(s / 60);
    const r = s % 60;
    if (m >= 60) {
      const h = Math.floor(m / 60);
      return `${h}:${String(m % 60).padStart(2, "0")}:${String(r).padStart(2, "0")}`;
    }
    return `${m}:${String(r).padStart(2, "0")}`;
  }

  function formatSpeed(bps) {
    return `${formatBytes(bps)}/s`;
  }

  function relativeTime(ts) {
    const diff = Date.now() - ts;
    const min = Math.round(diff / 60000);
    if (min < 1) return "Just now";
    if (min < 60) return `${min}m ago`;
    const hr = Math.round(min / 60);
    if (hr < 24) return `${hr}h ago`;
    const d = Math.round(hr / 24);
    return `${d}d ago`;
  }

  function chipHtml(p, extra = "") {
    return `<span class="chip dot" data-platform="${p.id}" style="--dot:${p.color}" ${extra}>${escapeHtml(p.name)}</span>`;
  }

  function badgeHtml(kind, label) {
    return `<span class="badge ${kind}">${escapeHtml(label)}</span>`;
  }

  function toast(message) {
    const el = $("toast");
    el.textContent = message;
    el.classList.add("show");
    clearTimeout(toast._t);
    toast._t = setTimeout(() => el.classList.remove("show"), 2400);
  }

  function closeSheet() {
    $("sheet").classList.remove("show");
    $("sheet-body").innerHTML = "";
  }

  function openSheet(html) {
    $("sheet-body").innerHTML = `<div class="sheet-handle"></div>${html}`;
    $("sheet").classList.add("show");
  }

  function applyTheme() {
    const mode = state.settings.theme;
    const dark =
      mode === "dark" ||
      (mode === "system" && window.matchMedia("(prefers-color-scheme: dark)").matches);
    document.documentElement.setAttribute("data-theme", dark ? "dark" : "light");
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.content = dark ? "#0B1219" : "#0F766E";
    qsa("#theme-seg button").forEach((btn) => {
      btn.classList.toggle("active", btn.dataset.themeMode === mode);
    });
  }

  function setToggle(el, on) {
    el.classList.toggle("on", on);
    el.setAttribute("aria-pressed", on ? "true" : "false");
  }

  function showScreen(id, { push = true, tab = null } = {}) {
    if (push && state.screen !== id) state.stack.push(state.screen);
    state.screen = id;
    if (tab) state.tab = tab;
    qsa(".screen").forEach((s) => s.classList.toggle("active", s.id === `screen-${id}`));
    qsa(".nav button").forEach((b) => b.classList.toggle("active", b.dataset.nav === state.tab));
    if (id === "home") renderRecent();
    if (id === "downloads") renderDownloads();
    if (id === "settings") renderSettings();
    updateMini();
  }

  function goTab(tab) {
    state.stack = [];
    showScreen(tab, { push: false, tab });
  }

  function goBack() {
    const prev = state.stack.pop() || state.tab;
    showScreen(prev, { push: false });
  }

  function setUrl(value) {
    state.url = value.trim();
    $("url-input").value = value;
    $("url-clear").hidden = !state.url;
    $("home-error").innerHTML = "";
    const id = detectPlatform(state.url);
    const box = $("detected-platform");
    if (state.url && id !== "unknown") {
      box.className = "detected";
      box.innerHTML = chipHtml(platformById(id));
    } else {
      box.innerHTML = "";
    }
  }

  function mockAnalyze(url) {
    const platform = detectPlatform(url);
    const restricted = looksRestricted(url);
    const isSample = url.replace(/\/$/, "") === SAMPLE_URL;
    const titles = {
      tiktok: "Public Creative Commons clip",
      instagram: "Public sample reel",
      facebook: "Public video post",
      x: "Public video on X",
      youtube: "Big Buck Bunny",
      reddit: "Public video post",
      pinterest: "Public Pin video",
      direct: "Big Buck Bunny",
    };
    if (restricted) {
      titles.tiktok = "Private or login-walled TikTok";
      titles.instagram = "Private or login-walled Instagram";
      titles.facebook = "Private or login-walled Facebook";
      titles.x = "Private or login-walled post";
      titles.youtube = "Restricted YouTube video";
      titles.reddit = "Private Reddit video";
      titles.pinterest = "Private Pin";
    }
    const authors = {
      tiktok: "@blenderfoundation",
      instagram: "Blender Foundation",
      facebook: "Blender Foundation",
      x: "@Blender",
      youtube: "Blender Foundation",
      reddit: "r/publicdomain",
      pinterest: "Blender Foundation",
      direct: "Blender Foundation",
    };
    return {
      id: `media-${Date.now()}`,
      url,
      platform,
      title: isSample ? "Big Buck Bunny" : titles[platform] || "Public video",
      author: authors[platform] || "Public source",
      thumbnail: SAMPLE_THUMB,
      duration: 596,
      canDownload: !restricted,
      restrictedReason: restricted
        ? "This link looks private, login-walled, or DRM-protected. SocialSave only previews public, allowed media."
        : null,
      sourceFile: SAMPLE_URL,
      demo: platform !== "direct" && !isSample,
    };
  }

  function analyzeError(message) {
    $("home-error").innerHTML = `<div class="error-banner">${escapeHtml(message)}</div>`;
  }

  async function analyze() {
    if (state.analyzing) return;
    const url = state.url.trim();
    if (!url) {
      analyzeError("Paste a public video URL first.");
      return;
    }
    if (url.length > 2048) {
      analyzeError("That URL is too long.");
      return;
    }
    if (!isValidHttpUrl(url)) {
      analyzeError("That doesn’t look like a valid public link.");
      return;
    }
    const platform = detectPlatform(url);
    if (platform === "unknown") {
      analyzeError(
        "That doesn’t look like a public http or https link."
      );
      return;
    }

    state.analyzing = true;
    $("analyze-btn").disabled = true;
    $("paste-btn").disabled = true;
    $("analyze-label").textContent = "Analyzing…";
    $("analyze-btn").querySelector(".ms").hidden = true;
    if (!$("analyze-btn").querySelector(".spinner")) {
      $("analyze-btn").insertAdjacentHTML("afterbegin", '<span class="spinner"></span>');
    }
    $("detected-platform").innerHTML =
      chipHtml(platformById(platform)) + " " + badgeHtml("extract", "Extracting");

    let preview = null;
    let error = null;
    try {
      if (looksRestricted(url)) {
        preview = mockAnalyze(url);
      } else {
        preview = await apiAnalyze(url);
      }
    } catch (err) {
      if (url.replace(/\/$/, "") === SAMPLE_URL || detectPlatform(url) === "direct") {
        preview = mockAnalyze(url);
      } else {
        error = err.message || "Could not analyze that public link.";
      }
    }

    state.analyzing = false;
    $("analyze-btn").disabled = false;
    $("paste-btn").disabled = false;
    $("analyze-label").textContent = "Analyze";
    const spin = $("analyze-btn").querySelector(".spinner");
    if (spin) spin.remove();
    $("analyze-btn").querySelector(".ms").hidden = false;

    const box = $("detected-platform");
    if (state.url && platform !== "unknown") {
      box.className = "detected";
      box.innerHTML = chipHtml(platformById(platform));
    }

    if (error || !preview) {
      analyzeError(error || "Could not analyze that public link.");
      return;
    }

    state.preview = preview;
    state.selectedQuality = pickDefaultQuality(formatsFor(preview));
    renderPreview();
    if (preview.canDownload && state.settings.autoStart) {
      showScreen("preview", { tab: "home" });
      startDownload();
    } else {
      showScreen("preview", { tab: "home" });
    }
  }

  function apiErrorMessage(data, fallback) {
    return (
      data?.error?.message ||
      data?.detail?.error?.message ||
      (typeof data?.detail === "string" ? data.detail : null) ||
      fallback
    );
  }

  function mapFormats(list) {
    if (!Array.isArray(list) || !list.length) return QUALITIES;
    return list.map((item) => ({
      id: String(item.id),
      label: item.quality || item.id,
      bytes: item.filesize || 0,
      height: item.height || 0,
    }));
  }

  function formatsFor(media) {
    return media?.formats?.length ? media.formats : QUALITIES;
  }

  function qualityOf(id, media) {
    const list = formatsFor(media);
    return list.find((q) => q.id === id) || list[0] || QUALITIES[0];
  }

  function pickDefaultQuality(formats) {
    const wanted = (state.settings.defaultQuality || "best").toLowerCase();
    const exact = formats.find((q) => q.id.toLowerCase() === wanted || q.label.toLowerCase() === wanted);
    if (exact) return exact.id;
    if (wanted === "best") return formats[0].id;
    const height = parseInt(wanted, 10);
    if (height) {
      const match = formats.find((q) => q.height === height || String(q.label).includes(String(height)));
      if (match) return match.id;
    }
    return formats[0].id;
  }

  async function apiAnalyze(url) {
    const res = await fetch(`${API_BASE}/api/v1/analyze`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok || data.success === false) {
      throw new Error(apiErrorMessage(data, "Could not analyze that public link."));
    }
    const formats = mapFormats(data.formats);
    return {
      id: `media-${Date.now()}`,
      url: data.url || url,
      platform: data.platform || detectPlatform(url),
      title: data.title || "Public video",
      author: data.author || "",
      thumbnail: data.thumbnail || SAMPLE_THUMB,
      duration: data.duration || 0,
      canDownload: Boolean(data.can_download),
      restrictedReason: data.download_restricted_reason || null,
      formats,
      sourceFile: SAMPLE_URL,
      api: true,
      demo: false,
    };
  }

  function renderPreview() {
    const media = state.preview;
    if (!media) return;
    const p = platformById(media.platform);
    const q = qualityOf(state.selectedQuality, media);
    $("preview-thumb").src = media.thumbnail || SAMPLE_THUMB;
    $("preview-duration").textContent = media.duration ? formatDuration(media.duration) : "";
    const plat = $("preview-platform");
    plat.dataset.platform = p.id;
    plat.style.setProperty("--dot", p.color);
    plat.textContent = p.name;
    $("preview-badge").className = `badge ${media.canDownload ? "public" : "restricted"}`;
    $("preview-badge").textContent = media.canDownload ? "Public / CC" : "Restricted";
    $("preview-title").textContent = media.title;
    $("preview-author").textContent = media.author;
    $("preview-size").textContent = media.canDownload
      ? `Estimated size ${formatBytes(q.bytes)}`
      : "Download isn’t available for this source.";
    $("quality-block").hidden = !media.canDownload;
    $("quality-chips").innerHTML = formatsFor(media)
      .map(
        (item) =>
          `<button type="button" class="chip selectable${item.id === state.selectedQuality ? " selected" : ""}" data-quality="${item.id}">${escapeHtml(item.label)}</button>`
      )
      .join("");
    const restricted = $("preview-restricted");
    if (!media.canDownload) {
      restricted.innerHTML = `<div class="notice danger" style="margin-top:16px"><span class="ms">block</span><div><strong>Metadata only.</strong> ${escapeHtml(media.restrictedReason)}</div></div>`;
    } else if (media.demo) {
      restricted.innerHTML = `<div class="notice" style="margin-top:16px"><span class="ms">info</span><div>Demo mode saves a public Creative Commons MP4 so you can try the flow without scraping this platform.</div></div>`;
    } else {
      restricted.innerHTML = "";
    }
    $("download-btn").disabled = !media.canDownload;
  }

  function cellularBlocked() {
    if (!state.settings.wifiOnly) return false;
    const conn = navigator.connection || navigator.mozConnection || navigator.webkitConnection;
    if (!conn) return false;
    return conn.type === "cellular" || conn.saveData === true;
  }

  function startDownload(existing) {
    const media = existing?.media || state.preview;
    if (!media?.canDownload) return;
    if (cellularBlocked()) {
      toast("Wi-Fi only is on. Connect to Wi-Fi to download.");
      return;
    }
    const quality = qualityOf(existing?.quality || state.selectedQuality, media);
    const task = {
      id: existing?.id || `dl-${Date.now()}`,
      media,
      quality: quality.id,
      title: media.title,
      platform: media.platform,
      thumbnail: media.thumbnail,
      status: "running",
      progress: 0,
      received: 0,
      total: quality.bytes || 0,
      speed: 0,
      error: null,
      startedAt: Date.now(),
      sourceFile: media.sourceFile,
      api: Boolean(media.api),
    };
    state.task = task;
    renderActive();
    showScreen("active", { tab: state.tab === "downloads" ? "downloads" : "home" });
    if (task.api) startApiDownload(task);
    else tickDownload();
  }

  async function startApiDownload(task) {
    try {
      $("active-meta").textContent = "Preparing a public download…";
      const res = await fetch(`${API_BASE}/api/v1/download`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ url: task.media.url, format_id: task.quality }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok || data.success === false) {
        throw new Error(apiErrorMessage(data, "This source could not be saved."));
      }
      let downloadUrl = data.download_url;
      let fileName = data.file_name;
      if (data.state === "processing" && data.id) {
        downloadUrl = await pollJob(task, data.id);
        fileName = fileName || task.title;
      }
      if (!downloadUrl) throw new Error("No download link was issued for this public video.");
      if (data.filesize) task.total = data.filesize;
      await fetchToDevice(task, downloadUrl, fileName || filenameFor(task));
    } catch (err) {
      if (task.status === "cancelled") return;
      failDownload(err.message || "The download failed.");
    }
  }

  async function pollJob(task, jobId) {
    for (let i = 0; i < 90; i += 1) {
      if (!state.task || state.task.id !== task.id || task.status !== "running") {
        throw new Error("cancelled");
      }
      const res = await fetch(`${API_BASE}/api/v1/download/${jobId}`);
      const data = await res.json().catch(() => ({}));
      if (data.progress != null) {
        task.progress = Math.max(task.progress, Math.min(0.9, Number(data.progress) || 0));
        renderActiveProgress();
        updateMini();
      }
      if (data.state === "ready" && data.download_url) {
        if (data.filesize) task.total = data.filesize;
        return data.download_url;
      }
      if (data.state === "error" || data.error) {
        throw new Error(apiErrorMessage(data.error || data, "Preparing the file failed."));
      }
      $("active-meta").textContent = "Preparing the video on the server…";
      await new Promise((r) => setTimeout(r, 1200));
    }
    throw new Error("The server took too long to prepare this file.");
  }

  function fetchToDevice(task, url, filename) {
    return new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      state.xhr = xhr;
      xhr.open("GET", url);
      xhr.responseType = "blob";
      xhr.onprogress = (event) => {
        if (!state.task || state.task.id !== task.id) return;
        if (event.lengthComputable && event.total) {
          task.total = event.total;
          task.received = event.loaded;
          task.progress = event.loaded / event.total;
        } else if (event.loaded) {
          task.received = event.loaded;
          if (task.total) task.progress = Math.min(0.95, event.loaded / task.total);
        }
        const elapsed = Math.max(0.4, (Date.now() - task.startedAt) / 1000);
        task.speed = task.received / elapsed;
        renderActiveProgress();
        updateMini();
      };
      xhr.onload = () => {
        state.xhr = null;
        if (xhr.status >= 200 && xhr.status < 300) {
          const blob = xhr.response;
          if (blob && blob.size) task.total = blob.size;
          const objectUrl = URL.createObjectURL(blob);
          task.sourceFile = objectUrl;
          completeDownload(false);
          triggerBrowserDownload(objectUrl, filename);
          resolve();
        } else {
          reject(new Error("The file could not be saved to this device."));
        }
      };
      xhr.onerror = () => {
        state.xhr = null;
        reject(new Error("The download connection failed."));
      };
      xhr.onabort = () => {
        state.xhr = null;
        reject(new Error("cancelled"));
      };
      xhr.send();
    });
  }

  function tickDownload() {
    clearInterval(state.timer);
    const task = state.task;
    if (!task || task.status !== "running") return;
    const duration = 4200 + Math.random() * 1200;
    const start = Date.now();
    state.timer = setInterval(() => {
      if (!state.task || state.task.id !== task.id || state.task.status !== "running") {
        clearInterval(state.timer);
        return;
      }
      const t = Math.min(1, (Date.now() - start) / duration);
      const eased = 1 - Math.pow(1 - t, 1.35);
      task.progress = eased;
      task.received = Math.round(task.total * eased);
      const elapsed = Math.max(0.4, (Date.now() - task.startedAt) / 1000);
      task.speed = task.received / elapsed;
      renderActiveProgress();
      updateMini();
      if (t >= 1) {
        clearInterval(state.timer);
        completeDownload();
      }
    }, 80);
  }

  function completeDownload(triggerFile = true) {
    const task = state.task;
    if (!task) return;
    task.status = "completed";
    task.progress = 1;
    task.received = task.total;
    const record = {
      id: task.id,
      title: task.title,
      platform: task.platform,
      thumbnail: task.thumbnail,
      quality: task.quality,
      qualityLabel: qualityOf(task.quality, task.media).label,
      size: task.total,
      status: "completed",
      url: task.media.url,
      sourceFile: task.sourceFile,
      createdAt: Date.now(),
    };
    state.history = [record, ...state.history.filter((h) => h.id !== record.id)];
    saveHistory();
    if (triggerFile) triggerBrowserDownload(task.sourceFile, filenameFor(task));
    renderActive();
    renderDownloads();
    renderRecent();
    notify("Download complete", task.title);
    toast("Saved to this device");
    updateMini();
  }

  function failDownload(message) {
    const task = state.task;
    if (!task) return;
    clearInterval(state.timer);
    task.status = "failed";
    task.error = message;
    const record = {
      id: task.id,
      title: task.title,
      platform: task.platform,
      thumbnail: task.thumbnail,
      quality: task.quality,
      size: task.total,
      status: "failed",
      url: task.media.url,
      sourceFile: task.sourceFile,
      createdAt: Date.now(),
    };
    state.history = [record, ...state.history.filter((h) => h.id !== record.id)];
    saveHistory();
    renderActive();
    renderDownloads();
    notify("Download failed", message);
    updateMini();
  }

  function cancelDownload() {
    clearInterval(state.timer);
    if (state.xhr) {
      try {
        state.xhr.abort();
      } catch {
        /* ignore */
      }
      state.xhr = null;
    }
    if (state.task && state.task.status === "running") {
      state.task.status = "cancelled";
    }
    state.task = null;
    updateMini();
    goBack();
    toast("Download cancelled");
  }

  function retryDownload() {
    if (!state.task) return;
    startDownload({
      id: `dl-${Date.now()}`,
      media: state.task.media,
      quality: state.task.quality,
    });
  }

  function filenameFor(task) {
    const base = (task.title || "video")
      .replace(/[^\w\s-]+/g, "")
      .trim()
      .replace(/\s+/g, "_")
      .slice(0, 48) || "video";
    return `${base}_${task.quality}.mp4`;
  }

  function triggerBrowserDownload(url, filename) {
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    a.rel = "noopener";
    a.target = "_blank";
    document.body.appendChild(a);
    a.click();
    a.remove();
  }

  async function notify(title, body) {
    if (!state.settings.notifications || !("Notification" in window)) return;
    if (Notification.permission !== "granted") return;
    try {
      new Notification(title, { body, icon: "./icon-512.png" });
    } catch {
      /* ignore */
    }
  }

  function renderActive() {
    const task = state.task;
    if (!task) return;
    const p = platformById(task.platform);
    const labels = {
      running: "Downloading",
      completed: "Saved",
      failed: "Failed",
      cancelled: "Cancelled",
    };
    $("active-status").textContent = labels[task.status] || "Downloading";
    $("active-thumb").src = task.thumbnail;
    $("active-platform-wrap").innerHTML = chipHtml(p);
    $("active-title").textContent = task.title;
    renderActiveProgress();
    const actions = $("active-actions");
    if (task.status === "running") {
      actions.innerHTML = `<button class="btn btn-danger" id="cancel-dl" style="flex:1"><span class="ms">close</span> Cancel</button>`;
    } else if (task.status === "failed") {
      actions.innerHTML = `
        <button class="btn btn-outline" id="cancel-dl" style="flex:1">Close</button>
        <button class="btn btn-primary" id="retry-dl" style="flex:1"><span class="ms">refresh</span> Retry</button>`;
    } else if (task.status === "completed") {
      actions.innerHTML = `
        <button class="btn btn-outline" id="share-dl" style="flex:1"><span class="ms">ios_share</span> Share</button>
        <button class="btn btn-primary" id="open-dl" style="flex:1"><span class="ms">play_arrow</span> Open</button>`;
    } else {
      actions.innerHTML = `<button class="btn btn-outline" id="cancel-dl" style="flex:1">Close</button>`;
    }
  }

  function renderActiveProgress() {
    const task = state.task;
    if (!task) return;
    const pct = Math.round(task.progress * 100);
    $("active-pct").textContent = `${pct}%`;
    $("ring-fg").style.strokeDasharray = String(RING);
    $("ring-fg").style.strokeDashoffset = String(RING * (1 - task.progress));
    if (task.status === "failed") {
      $("active-meta").textContent = task.error || "The download failed.";
      return;
    }
    if (task.status === "completed") {
      $("active-meta").textContent = `${formatBytes(task.total)} · ${qualityOf(task.quality, task.media).label}`;
      return;
    }
    $("active-meta").textContent = `${formatSpeed(task.speed)} · ${formatBytes(task.received)} of ${formatBytes(task.total)}`;
  }

  function updateMini() {
    const mini = $("mini");
    const task = state.task;
    const show = task && task.status === "running" && state.screen !== "active";
    mini.classList.toggle("show", !!show);
    document.querySelector(".app-shell").classList.toggle("mini-on", !!show);
    if (show) {
      $("mini-title").textContent = task.title;
      $("mini-pct").textContent = `${Math.round(task.progress * 100)}%`;
      $("mini-bar").style.width = `${Math.round(task.progress * 100)}%`;
    }
  }

  function renderPlatformChips() {
    $("platform-chips").innerHTML = PLATFORMS.map((p) => chipHtml(p)).join("");
  }

  function renderRecent() {
    const box = $("recent-list");
    const items = state.history.filter((h) => h.status === "completed").slice(0, 6);
    if (!items.length) {
      box.innerHTML = `<p class="section-help" style="margin-top:4px">Nothing saved yet. Analyze a public link to start.</p>`;
      return;
    }
    box.innerHTML = `<div class="list">${items.map(listItemHtml).join("")}</div>`;
  }

  function statusLabel(record) {
    if (record.status === "completed") return `<span class="status-ok">Saved</span>`;
    if (record.status === "failed") return `<span class="status-fail">Failed</span>`;
    return `<span class="status-run">In progress</span>`;
  }

  function listItemHtml(record) {
    const p = platformById(record.platform);
    return `
      <article class="list-item" data-item="${escapeHtml(record.id)}">
        <img class="thumb" src="${escapeHtml(record.thumbnail)}" alt="" referrerpolicy="no-referrer" />
        <div class="meta">
          <h3>${escapeHtml(record.title)}</h3>
          <p>${chipHtml(p)}<span>${formatBytes(record.size)} · ${escapeHtml(record.qualityLabel || qualityOf(record.quality).label)} · ${statusLabel(record)}</span></p>
        </div>
        <button class="more" data-more="${escapeHtml(record.id)}" aria-label="Actions"><span class="ms">more_vert</span></button>
      </article>`;
  }

  function renderDownloads() {
    const body = $("downloads-body");
    const running = state.task && state.task.status === "running" ? [state.task] : [];
    if (!running.length && !state.history.length) {
      body.innerHTML = `
        <div class="empty">
          <span class="ms">download</span>
          <h2>No downloads yet</h2>
          <p>Analyze a public video URL to start your first save.</p>
        </div>`;
      return;
    }
    let html = "";
    if (running.length) {
      html += `<h2 class="section-label" style="margin-top:8px">In progress</h2><div class="list">`;
      html += running
        .map((task) => {
          const p = platformById(task.platform);
          const pct = Math.round(task.progress * 100);
          return `
            <button class="list-item" id="goto-active" type="button">
              <img class="thumb" src="${escapeHtml(task.thumbnail)}" alt="" referrerpolicy="no-referrer" />
              <div class="meta">
                <h3>${escapeHtml(task.title)}</h3>
                <p>${chipHtml(p)} ${pct}%</p>
                <div class="inline-bar"><span style="width:${pct}%"></span></div>
              </div>
              <span class="pct-sm">${pct}%</span>
            </button>`;
        })
        .join("");
      html += `</div>`;
    }
    if (state.history.length) {
      html += `<h2 class="section-label">History</h2><div class="list">${state.history.map(listItemHtml).join("")}</div>`;
    }
    body.innerHTML = html;
  }

  function renderSettings() {
    applyTheme();
    setToggle($("tog-wifi"), state.settings.wifiOnly);
    setToggle($("tog-auto"), state.settings.autoStart);
    setToggle($("tog-notify"), state.settings.notifications);
    $("q-label").textContent = (QUALITIES.find((q) => q.id === state.settings.defaultQuality) || QUALITIES[0]).label;
    $("loc-label").textContent = "This browser (Downloads folder)";
  }

  function itemById(id) {
    if (state.task && state.task.id === id) {
      return {
        id,
        title: state.task.title,
        platform: state.task.platform,
        thumbnail: state.task.thumbnail,
        quality: state.task.quality,
        size: state.task.total,
        status: state.task.status,
        url: state.task.media.url,
        sourceFile: state.task.sourceFile,
      };
    }
    return state.history.find((h) => h.id === id);
  }

  function openActions(id) {
    const item = itemById(id);
    if (!item) return;
    openSheet(`
      <h3>${escapeHtml(item.title)}</h3>
      <button class="full" data-act="open" data-id="${escapeHtml(id)}"><span class="ms">play_circle</span> Open</button>
      <button class="full" data-act="share" data-id="${escapeHtml(id)}"><span class="ms">ios_share</span> Share</button>
      <button class="full" data-act="again" data-id="${escapeHtml(id)}"><span class="ms">download</span> Download again</button>
      <button class="full danger" data-act="delete" data-id="${escapeHtml(id)}"><span class="ms">delete</span> Delete</button>
    `);
  }

  async function shareItem(item) {
    const data = { title: item.title, text: `${item.title} — public video`, url: item.url || item.sourceFile };
    try {
      if (navigator.share) {
        await navigator.share(data);
      } else if (navigator.clipboard) {
        await navigator.clipboard.writeText(data.url);
        toast("Link copied");
      }
    } catch {
      /* user cancelled */
    }
  }

  function deleteItem(id) {
    state.history = state.history.filter((h) => h.id !== id);
    saveHistory();
    renderDownloads();
    renderRecent();
    toast("Removed from history");
  }

  function downloadAgain(item) {
    const media = {
      id: item.id,
      url: item.url,
      platform: item.platform,
      title: item.title,
      author: "",
      thumbnail: item.thumbnail,
      duration: 596,
      canDownload: true,
      sourceFile: item.sourceFile || SAMPLE_URL,
      demo: false,
    };
    state.preview = media;
    state.selectedQuality = item.quality || state.settings.defaultQuality;
    startDownload({ media, quality: state.selectedQuality });
  }

  function pickQualitySetting() {
    openSheet(`
      <h3>Default quality</h3>
      ${QUALITIES.map(
        (q) =>
          `<button class="full${q.id === state.settings.defaultQuality ? " selected" : ""}" data-setq="${q.id}">${q.label}</button>`
      ).join("")}
    `);
  }

  function bind() {
    $("url-input").addEventListener("input", (e) => setUrl(e.target.value));
    $("url-input").addEventListener("keydown", (e) => {
      if (e.key === "Enter") analyze();
    });
    $("url-clear").addEventListener("click", () => setUrl(""));
    $("analyze-btn").addEventListener("click", analyze);
    $("sample-btn").addEventListener("click", () => {
      setUrl(SAMPLE_URL);
      analyze();
    });
    $("paste-btn").addEventListener("click", async () => {
      try {
        const text = await navigator.clipboard.readText();
        if (!text.trim()) {
          toast("Clipboard is empty");
          return;
        }
        setUrl(text.trim());
      } catch {
        toast("Allow clipboard access to paste");
        $("url-input").focus();
      }
    });

    $("quality-chips").addEventListener("click", (e) => {
      const btn = e.target.closest("[data-quality]");
      if (!btn) return;
      state.selectedQuality = btn.dataset.quality;
      renderPreview();
    });
    $("download-btn").addEventListener("click", () => startDownload());

    $("active-actions").addEventListener("click", (e) => {
      if (e.target.closest("#cancel-dl")) {
        if (state.task?.status === "running") cancelDownload();
        else {
          state.task = null;
          updateMini();
          goTab("downloads");
        }
      }
      if (e.target.closest("#retry-dl")) retryDownload();
      if (e.target.closest("#open-dl") && state.task) {
        triggerBrowserDownload(state.task.sourceFile, filenameFor(state.task));
      }
      if (e.target.closest("#share-dl") && state.task) {
        shareItem({ title: state.task.title, url: state.task.media.url, sourceFile: state.task.sourceFile });
      }
    });

    $("mini").addEventListener("click", () => {
      if (state.task) showScreen("active", { tab: state.tab });
    });

    $("downloads-body").addEventListener("click", (e) => {
      if (e.target.closest("#goto-active")) {
        showScreen("active", { tab: "downloads" });
        return;
      }
      const more = e.target.closest("[data-more]");
      if (more) {
        e.preventDefault();
        openActions(more.dataset.more);
        return;
      }
      const row = e.target.closest("[data-item]");
      if (row) openActions(row.dataset.item);
    });
    $("recent-list").addEventListener("click", (e) => {
      const more = e.target.closest("[data-more]");
      if (more) {
        openActions(more.dataset.more);
        return;
      }
      const row = e.target.closest("[data-item]");
      if (row) openActions(row.dataset.item);
    });

    $("clear-history").addEventListener("click", () => {
      if (!state.history.length) {
        toast("History is already empty");
        return;
      }
      openSheet(`
        <h3>Clear download history?</h3>
        <p class="help">This removes history from this browser. Files already saved stay in your Downloads folder.</p>
        <button class="full danger" data-act="clear"><span class="ms">delete_sweep</span> Clear history</button>
      `);
    });

    qsa("[data-nav]").forEach((btn) => btn.addEventListener("click", () => goTab(btn.dataset.nav)));
    qsa("[data-go]").forEach((btn) =>
      btn.addEventListener("click", () => {
        const target = btn.dataset.go;
        if (target === "settings") goTab("settings");
        else showScreen(target, { tab: "settings" });
      })
    );
    qsa("[data-back]").forEach((btn) => btn.addEventListener("click", goBack));

    qsa("#theme-seg button").forEach((btn) => {
      btn.addEventListener("click", () => {
        state.settings.theme = btn.dataset.themeMode;
        saveSettings();
        applyTheme();
      });
    });
    $("tog-wifi").addEventListener("click", () => {
      state.settings.wifiOnly = !state.settings.wifiOnly;
      saveSettings();
      renderSettings();
    });
    $("tog-auto").addEventListener("click", () => {
      state.settings.autoStart = !state.settings.autoStart;
      saveSettings();
      renderSettings();
    });
    $("tog-notify").addEventListener("click", async () => {
      const next = !state.settings.notifications;
      if (next && "Notification" in window && Notification.permission === "default") {
        try {
          await Notification.requestPermission();
        } catch {
          /* ignore */
        }
      }
      state.settings.notifications = next;
      saveSettings();
      renderSettings();
    });
    $("btn-location").addEventListener("click", () => {
      openSheet(`
        <h3>Download location</h3>
        <p class="help">Files are saved through this browser to your device Downloads folder. SocialSave does not write to a custom path on the web.</p>
        <button class="full selected"><span class="ms">folder</span> This browser (Downloads folder)</button>
      `);
    });
    $("btn-quality").addEventListener("click", pickQualitySetting);

    $("sheet").addEventListener("click", (e) => {
      if (e.target.id === "sheet") closeSheet();
      const setq = e.target.closest("[data-setq]");
      if (setq) {
        state.settings.defaultQuality = setq.dataset.setq;
        saveSettings();
        renderSettings();
        closeSheet();
        return;
      }
      const act = e.target.closest("[data-act]");
      if (!act) return;
      const id = act.dataset.id;
      const item = id ? itemById(id) : null;
      closeSheet();
      if (act.dataset.act === "clear") {
        state.history = [];
        saveHistory();
        renderDownloads();
        renderRecent();
        toast("History cleared");
      }
      if (!item) return;
      if (act.dataset.act === "open") triggerBrowserDownload(item.sourceFile || SAMPLE_URL, `${item.title}.mp4`);
      if (act.dataset.act === "share") shareItem(item);
      if (act.dataset.act === "again") downloadAgain(item);
      if (act.dataset.act === "delete") deleteItem(id);
    });

    window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
      if (state.settings.theme === "system") applyTheme();
    });
    window.addEventListener("offline", () => {
      if (state.task?.status === "running") failDownload("You’re offline. Retry when you’re back online.");
    });
  }

  load();
  bind();
  applyTheme();
  renderPlatformChips();
  renderRecent();
  renderSettings();
  showScreen("home", { push: false, tab: "home" });
})();
