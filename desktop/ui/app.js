"use strict";

const elements = {
  status: document.getElementById("receiver-status"),
  address: document.getElementById("server-address"),
  copyAddress: document.getElementById("copy-address"),
  code: document.getElementById("pairing-code"),
  toggleCode: document.getElementById("toggle-code"),
  copyCode: document.getElementById("copy-code"),
  pairingFeedback: document.getElementById("pairing-feedback"),
  openPairing: document.getElementById("open-pairing"),
  closePairing: document.getElementById("close-pairing"),
  pairingDialog: document.getElementById("pairing-dialog"),
  pairingAddress: document.getElementById("pairing-address"),
  pairingImage: document.getElementById("pairing-image"),
  pairingExpiry: document.getElementById("pairing-expiry"),
  pairingDevices: document.getElementById("dialog-devices"),
  qrFeedback: document.getElementById("qr-feedback"),
  refreshPairing: document.getElementById("refresh-pairing"),
  devicesCount: document.getElementById("devices-count"),
  devicesEmpty: document.getElementById("devices-empty"),
  deviceList: document.getElementById("device-list"),
  folder: document.getElementById("folder-path"),
  openFolder: document.getElementById("open-folder"),
  folderFeedback: document.getElementById("folder-feedback"),
  editFolder: document.getElementById("edit-folder"),
  folderDialog: document.getElementById("folder-dialog"),
  folderForm: document.getElementById("folder-form"),
  folderInput: document.getElementById("folder-input"),
  folderEditFeedback: document.getElementById("folder-edit-feedback"),
  pickFolder: document.getElementById("pick-folder"),
  cancelFolder: document.getElementById("cancel-folder"),
  saveFolder: document.getElementById("save-folder"),
  openFileShare: document.getElementById("open-file-share"),
  closeFileShare: document.getElementById("close-file-share"),
  fileShareDialog: document.getElementById("file-share-dialog"),
  fileShareForm: document.getElementById("file-share-form"),
  fileSharePath: document.getElementById("file-share-path"),
  fileShareAddress: document.getElementById("file-share-address"),
  pickFileShare: document.getElementById("pick-file-share"),
  generateFileShare: document.getElementById("generate-file-share"),
  fileShareFeedback: document.getElementById("file-share-feedback"),
  fileShareResult: document.getElementById("file-share-result"),
  fileShareImage: document.getElementById("file-share-image"),
  fileShareName: document.getElementById("file-share-name"),
  fileShareSize: document.getElementById("file-share-size"),
  fileShareExpiry: document.getElementById("file-share-expiry"),
  fileCount: document.getElementById("file-count"),
  empty: document.getElementById("empty-state"),
  emptyTitle: document.getElementById("empty-title"),
  emptyDescription: document.getElementById("empty-description"),
  files: document.getElementById("recent-files"),
  version: document.getElementById("version"),
};

const dateFormat = new Intl.DateTimeFormat("zh-CN", {
  year: "numeric",
  month: "short",
  day: "numeric",
  hour: "2-digit",
  minute: "2-digit",
  hour12: false,
});

const sizeFormat = new Intl.NumberFormat("zh-CN", { maximumFractionDigits: 1 });
let previousAddresses = "";
let previousDevices = "";
let previousFiles = "";
let statusLoaded = false;
let statusRequest;
let statusTimer;
let folderPath = "";
let folderOpening = false;
let folderEditorAction = "";
let folderPickerRequest;
let pairingRequest;
let pairingTimer;
let fileShareAvailable = false;
let fileShareRequest;
let fileShareTimer;
let fileShareCode;

function setStatus(label, state) {
  if (elements.status.textContent !== label) elements.status.textContent = label;
  elements.status.dataset.state = state;
}

function setFeedback(element, message, isError = false) {
  element.textContent = message;
  element.dataset.error = String(isError);
}

function updateFolder(folder) {
  folderPath = folder;
  const label = folder || "保存位置不可用";
  if (elements.folder.textContent !== label) elements.folder.textContent = label;
  elements.openFolder.disabled = !folderPath || folderOpening;
  elements.editFolder.disabled = !folderPath;
}

function setFolderEditorAction(action) {
  folderEditorAction = action;
  const busy = Boolean(action);
  elements.folderInput.readOnly = busy;
  elements.pickFolder.disabled = busy;
  elements.saveFolder.disabled = busy;
  elements.cancelFolder.disabled = action === "saving";
}

async function pickFolder() {
  if (folderEditorAction) return;
  const controller = new AbortController();
  folderPickerRequest = controller;
  setFolderEditorAction("picking");
  setFeedback(elements.folderEditFeedback, "正在等待系统选择文件夹…");
  let picked = false;
  try {
    const response = await fetch("/api/folder/pick", {
      method: "POST",
      headers: { "X-ScreenRelay": "1" },
      signal: controller.signal,
    });
    const data = response.status === 204 ? null : await response.json().catch(() => null);
    if (folderPickerRequest !== controller || !elements.folderDialog.open) return;
    if (response.status === 204) {
      setFeedback(elements.folderEditFeedback, "");
    } else if (response.ok && typeof data?.path === "string" && data.path) {
      elements.folderInput.value = data.path;
      setFeedback(elements.folderEditFeedback, "");
      picked = true;
    } else {
      setFeedback(elements.folderEditFeedback, data?.error || "无法打开文件夹选择器。可以手动输入路径。", true);
    }
  } catch {
    if (folderPickerRequest === controller && elements.folderDialog.open) {
      setFeedback(elements.folderEditFeedback, "无法打开文件夹选择器。可以手动输入路径。", true);
    }
  } finally {
    if (folderPickerRequest === controller && elements.folderDialog.open) {
      folderPickerRequest = undefined;
      setFolderEditorAction("");
      (picked ? elements.folderInput : elements.pickFolder).focus();
    }
  }
}

async function saveFolder(event) {
  event.preventDefault();
  if (folderEditorAction) return;
  const path = elements.folderInput.value;
  if (!path.trim()) {
    setFeedback(elements.folderEditFeedback, "请输入文件夹的绝对路径。", true);
    elements.folderInput.focus();
    return;
  }
  setFolderEditorAction("saving");
  setFeedback(elements.folderEditFeedback, "正在保存…");
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 12000);
  try {
    const response = await fetch("/api/folder", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-ScreenRelay": "1" },
      body: JSON.stringify({ path }),
      signal: controller.signal,
    });
    const data = await response.json().catch(() => null);
    if (!response.ok || typeof data?.folder !== "string" || !data.folder) {
      setFeedback(elements.folderEditFeedback, data?.error || "无法保存，请检查文件夹路径后重试。", true);
      return;
    }
    updateFolder(data.folder);
    elements.folderDialog.close();
    setFeedback(elements.folderFeedback, "保存位置已更新");
    refreshStatus();
  } catch {
    setFeedback(elements.folderEditFeedback, "保存请求未完成，请稍后重试。", true);
    refreshStatus();
  } finally {
    clearTimeout(timeout);
    setFolderEditorAction("");
    if (elements.folderDialog.open) elements.folderInput.focus();
  }
}

function updateAddresses(addresses) {
  const snapshot = JSON.stringify(addresses);
  if (snapshot === previousAddresses) return false;
  previousAddresses = snapshot;

  const selected = elements.address.value;
  for (const picker of [elements.address, elements.pairingAddress, elements.fileShareAddress]) {
    const preferred = picker === elements.fileShareAddress ? picker.value || selected : selected;
    const options = addresses.map((address) => new Option(address, address));
    if (options.length === 0) options.push(new Option("未发现局域网地址", ""));
    picker.replaceChildren(...options);
    if (addresses.includes(preferred)) picker.value = preferred;
    picker.disabled = addresses.length === 0;
  }
  elements.copyAddress.disabled = addresses.length === 0;
  return elements.address.value !== selected;
}

function createDeviceRow(device) {
  const row = document.createElement("li");
  row.className = "device-row";
  const icon = document.createElement("span");
  icon.className = "device-icon";
  icon.setAttribute("aria-hidden", "true");
  const detail = document.createElement("div");
  const name = document.createElement("p");
  name.className = "device-name";
  name.dir = "auto";
  name.textContent = device.name || "未命名设备";
  detail.append(name);
  const date = new Date(device.pairedAt);
  if (device.pairedAt && Number.isFinite(date.getTime())) {
    const time = document.createElement("time");
    time.className = "device-time";
    time.dateTime = date.toISOString();
    time.textContent = dateFormat.format(date);
    detail.append(time);
  }
  row.append(icon, detail);
  return row;
}

function updateDevices(devices) {
  const snapshot = JSON.stringify(devices);
  if (snapshot === previousDevices) return;
  previousDevices = snapshot;

  elements.deviceList.replaceChildren(...devices.map(createDeviceRow));
  elements.deviceList.hidden = devices.length === 0;
  elements.devicesEmpty.hidden = devices.length !== 0;
  elements.devicesEmpty.textContent = "暂无扫码配对的设备";
  elements.devicesCount.hidden = false;
  elements.devicesCount.textContent = `${devices.length} 台`;
  const pairedCount = `已配对 ${devices.length} 台设备`;
  if (elements.pairingDevices.textContent !== pairedCount) elements.pairingDevices.textContent = pairedCount;
}

function clearPairingCode() {
  clearInterval(pairingTimer);
  elements.pairingImage.hidden = true;
  elements.pairingImage.removeAttribute("src");
  elements.pairingExpiry.hidden = true;
}

function remainingTime(expiry) {
  const seconds = Math.ceil((expiry - Date.now()) / 1000);
  if (seconds <= 0) return "";
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

function updatePairingCountdown(expiry) {
  const remaining = remainingTime(expiry);
  if (!remaining) {
    clearPairingCode();
    setFeedback(elements.qrFeedback, "二维码已过期，可以重新生成。", true);
    elements.refreshPairing.hidden = false;
    return;
  }
  elements.pairingExpiry.textContent = `剩余有效时间 ${remaining}`;
  elements.pairingExpiry.hidden = false;
}

async function requestPairingCode() {
  pairingRequest?.abort();
  clearPairingCode();
  elements.refreshPairing.hidden = true;
  const address = elements.pairingAddress.value;
  if (!address) {
    setFeedback(elements.qrFeedback, "没有可用的接收地址，请连接局域网。", true);
    return;
  }

  const controller = new AbortController();
  pairingRequest = controller;
  setFeedback(elements.qrFeedback, "正在生成二维码…");
  const timeout = setTimeout(() => controller.abort(), 6000);
  try {
    const response = await fetch("/api/pairing", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-ScreenRelay": "1" },
      body: JSON.stringify({ address }),
      signal: controller.signal,
    });
    if (!response.ok) throw new Error("pairing");
    const data = await response.json();
    if (pairingRequest !== controller || !elements.pairingDialog.open) return;

    const expiry = Date.parse(data.expiresAt);
    if (typeof data.image !== "string" || !data.image.startsWith("data:image/png;base64,") || !(expiry > Date.now())) {
      throw new Error("pairing response");
    }
    elements.pairingImage.src = data.image;
    elements.pairingImage.hidden = false;
    setFeedback(elements.qrFeedback, "");
    pairingTimer = setInterval(() => updatePairingCountdown(expiry), 1000);
    updatePairingCountdown(expiry);
  } catch {
    if (pairingRequest === controller && elements.pairingDialog.open) {
      setFeedback(elements.qrFeedback, "暂时无法生成二维码，请重试。", true);
      elements.refreshPairing.hidden = false;
    }
  } finally {
    clearTimeout(timeout);
    if (pairingRequest === controller) pairingRequest = undefined;
  }
}

function getFileSize(bytes) {
  if (!Number.isFinite(bytes) || bytes < 0) return "";
  let amount = bytes;
  const units = ["B", "KB", "MB", "GB", "TB"];
  for (const unit of units) {
    if (amount < 1024 || unit === "TB") return `${sizeFormat.format(amount)} ${unit}`;
    amount /= 1024;
  }
}

function updateFileShareControls() {
  const busy = Boolean(fileShareRequest);
  elements.openFileShare.disabled = !fileShareAvailable;
  elements.fileSharePath.readOnly = busy;
  elements.fileShareAddress.disabled = busy || !fileShareAvailable;
  elements.pickFileShare.disabled = busy;
  elements.generateFileShare.disabled = busy || !fileShareAvailable;
}

function canRedisplayFileShare() {
  return fileShareCode && [...elements.fileShareAddress.options].some((option) => option.value === fileShareCode.address);
}

function renderFileShareCode() {
  const remaining = fileShareCode ? remainingTime(fileShareCode.expiry) : "";
  if (fileShareCode && !remaining) {
    clearInterval(fileShareTimer);
    fileShareCode = undefined;
    if (elements.fileShareDialog.open && !elements.fileShareResult.hidden) {
      setFeedback(elements.fileShareFeedback, "下载码已过期，可以重新生成。", true);
    }
  }
  const canRedisplay = canRedisplayFileShare();
  const buttonLabel = canRedisplay ? "查看下载码" : "创建下载码";
  if (elements.openFileShare.textContent !== buttonLabel) elements.openFileShare.textContent = buttonLabel;
  const visible = Boolean(canRedisplay && elements.fileShareDialog.open &&
    fileShareCode.path === elements.fileSharePath.value && fileShareCode.address === elements.fileShareAddress.value);
  elements.fileShareResult.hidden = !visible;
  const generateLabel = visible ? "重新生成" : "生成下载码";
  if (elements.generateFileShare.textContent !== generateLabel) elements.generateFileShare.textContent = generateLabel;
  if (!visible) {
    elements.fileShareImage.removeAttribute("src");
    return;
  }
  if (elements.fileShareImage.getAttribute("src") !== fileShareCode.image) {
    elements.fileShareImage.src = fileShareCode.image;
  }
  if (elements.fileShareName.textContent !== fileShareCode.name) {
    elements.fileShareName.textContent = fileShareCode.name;
  }
  const size = getFileSize(fileShareCode.size);
  if (elements.fileShareSize.textContent !== size) elements.fileShareSize.textContent = size;
  elements.fileShareExpiry.textContent = `剩余有效时间 ${remaining}`;
}

async function requestFileShare(url, payload) {
  if (fileShareRequest) return;
  const controller = new AbortController();
  fileShareRequest = controller;
  updateFileShareControls();
  const picking = !payload;
  const failure = picking ? "无法打开文件选择器。可以手动输入路径。" : "暂时无法生成下载码，请重试。";
  setFeedback(elements.fileShareFeedback, picking ? "正在等待系统选择文件…" : "正在生成下载码…");
  const headers = { "X-ScreenRelay": "1" };
  if (payload) headers["Content-Type"] = "application/json";
  const timeout = picking ? undefined : setTimeout(() => controller.abort(), 10000);
  let focus;
  try {
    const response = await fetch(url, {
      method: "POST",
      headers,
      body: payload ? JSON.stringify(payload) : undefined,
      signal: controller.signal,
    });
    const data = response.status === 204 ? null : await response.json().catch(() => null);
    if (fileShareRequest !== controller || !elements.fileShareDialog.open) return;
    setFeedback(elements.fileShareFeedback, "");
    if (picking && response.status === 204) return;
    if (!response.ok) {
      setFeedback(elements.fileShareFeedback, data?.error || failure, true);
      return;
    }
    if (picking) {
      if (typeof data?.path !== "string" || !data.path) throw new Error("selected file");
      elements.fileSharePath.value = data.path;
      renderFileShareCode();
      focus = elements.fileSharePath;
      return;
    }
    const expiry = Date.parse(data?.expiresAt);
    if (!(expiry > Date.now()) || typeof data?.image !== "string" || !data.image.startsWith("data:image/png;base64,") ||
        typeof data.name !== "string" || !Number.isFinite(data.size) || data.size < 0) throw new Error("file share response");
    if (payload.address !== elements.fileShareAddress.value) {
      setFeedback(elements.fileShareFeedback, "接收地址已变更，请重新生成下载码。", true);
      return;
    }
    fileShareCode = { ...payload, expiry, image: data.image, name: data.name, size: data.size };
    clearInterval(fileShareTimer);
    fileShareTimer = setInterval(renderFileShareCode, 1000);
    renderFileShareCode();
    focus = elements.fileShareName;
  } catch {
    if (fileShareRequest === controller && elements.fileShareDialog.open) setFeedback(elements.fileShareFeedback, failure, true);
  } finally {
    clearTimeout(timeout);
    if (fileShareRequest === controller && elements.fileShareDialog.open) {
      fileShareRequest = undefined;
      updateFileShareControls();
      (focus || (picking ? elements.pickFileShare : elements.generateFileShare)).focus();
    }
  }
}

function createFileRow(file) {
  const row = document.createElement("li");
  row.className = "file-row";

  const kind = file.kind === "screen-recording" ? "screen-recording" : "screenshot";
  const icon = document.createElement("span");
  icon.className = "file-type-icon";
  icon.dataset.kind = kind;
  icon.setAttribute("aria-hidden", "true");
  icon.append(document.createElement("span"));

  const info = document.createElement("div");
  info.className = "file-info";
  const name = document.createElement("p");
  name.className = "file-name";
  name.dir = "auto";
  name.textContent = file.name;
  name.title = file.name;
  const details = document.createElement("div");
  details.className = "file-details";
  const type = document.createElement("span");
  type.textContent = kind === "screen-recording" ? "录屏" : "截图";
  details.append(type);
  const size = getFileSize(file.size);
  if (size) {
    const sizeLabel = document.createElement("span");
    sizeLabel.textContent = size;
    details.append(sizeLabel);
  }
  const date = new Date(file.receivedAt);
  if (file.receivedAt && Number.isFinite(date.getTime())) {
    const time = document.createElement("time");
    time.dateTime = date.toISOString();
    time.textContent = dateFormat.format(date);
    details.append(time);
  }
  info.append(name, details);
  row.append(icon, info);

  if (typeof file.url === "string" && /^\/files\/[a-zA-Z0-9._-]+$/.test(file.url)) {
    const actions = document.createElement("div");
    actions.className = "file-actions";
    const view = document.createElement("a");
    view.href = file.url;
    view.target = "_blank";
    view.rel = "noopener";
    view.textContent = "查看";
    view.setAttribute("aria-label", `查看 ${file.name}`);
    const download = document.createElement("a");
    download.href = `${file.url}?download=1`;
    download.download = file.name;
    download.textContent = "下载";
    download.setAttribute("aria-label", `下载 ${file.name}`);
    actions.append(view, download);
    row.append(actions);
  }
  return row;
}

function updateFiles(files) {
  elements.emptyTitle.textContent = "暂无接收记录";
  elements.emptyDescription.textContent = "手机上传的截图和录屏会显示在这里。";
  const snapshot = JSON.stringify(files);
  if (snapshot === previousFiles) return;
  previousFiles = snapshot;

  elements.files.replaceChildren(...files.map(createFileRow));
  elements.files.hidden = files.length === 0;
  elements.empty.hidden = files.length > 0;
  elements.fileCount.hidden = files.length === 0;
  elements.fileCount.textContent = `${files.length} 个文件`;
}

function showStatus(data) {
  const addresses = Array.isArray(data.addresses) ? data.addresses.filter((address) => typeof address === "string" && address) : [];
  const devices = Array.isArray(data.devices) ? data.devices.filter((device) => typeof device?.id === "string") : [];
  const files = Array.isArray(data.recent) ? data.recent.filter((file) => typeof file?.name === "string") : [];
  const token = typeof data.token === "string" ? data.token : "";
  const folder = typeof data.folder === "string" ? data.folder : "";

  if (!data.listening) setStatus("接收服务未启动", "unavailable");
  else if (addresses.length === 0) setStatus("等待局域网连接", "unavailable");
  else setStatus("接收服务运行中", "ready");
  const addressChanged = updateAddresses(addresses);
  elements.openPairing.disabled = !data.listening || addresses.length === 0;
  if (addressChanged && elements.pairingDialog.open) requestPairingCode();
  fileShareAvailable = Boolean(data.listening && addresses.length);
  updateFileShareControls();
  renderFileShareCode();
  updateDevices(devices);

  if (elements.code.value !== token) elements.code.value = token;
  elements.code.placeholder = "配对码不可用";
  elements.copyCode.disabled = !token;
  elements.toggleCode.disabled = !token;

  updateFolder(folder);
  updateFiles(files);

  const version = typeof data.version === "string" ? data.version : "";
  const versionLabel = version ? `版本 ${version}` : "";
  if (elements.version.textContent !== versionLabel) elements.version.textContent = versionLabel;
  elements.version.hidden = !version;
}

async function refreshStatus() {
  clearTimeout(statusTimer);
  statusRequest?.abort();
  const controller = new AbortController();
  statusRequest = controller;
  const timeout = setTimeout(() => controller.abort(), 3000);
  try {
    const response = await fetch("/api/status", { cache: "no-store", signal: controller.signal });
    if (!response.ok) throw new Error("status");
    const data = await response.json();
    if (statusRequest !== controller) return;
    showStatus(data);
    statusLoaded = true;
  } catch {
    if (statusRequest !== controller) return;
    setStatus("无法连接接收端", "unavailable");
    elements.openPairing.disabled = true;
    fileShareAvailable = false;
    updateFileShareControls();
    if (!statusLoaded) {
      elements.address.replaceChildren(new Option("接收地址不可用", ""));
      elements.code.placeholder = "配对码不可用";
      updateFolder("");
      elements.emptyTitle.textContent = "暂时无法读取接收记录";
      elements.emptyDescription.textContent = "启动电脑接收端后会自动重连。";
      elements.devicesEmpty.textContent = "暂时无法读取已配对设备";
    }
  } finally {
    clearTimeout(timeout);
    if (statusRequest === controller) {
      statusRequest = undefined;
      statusTimer = setTimeout(refreshStatus, 4000);
    }
  }
}

async function copyToClipboard(value) {
  if (navigator.clipboard) {
    try {
      await navigator.clipboard.writeText(value);
      return true;
    } catch {
      // Fall back to selecting a temporary field when browser permissions block the API.
    }
  }
  const focus = document.activeElement;
  const field = document.createElement("textarea");
  field.className = "clipboard-field";
  field.setAttribute("readonly", "");
  field.value = value;
  document.body.append(field);
  field.select();
  try {
    return document.execCommand("copy");
  } catch {
    return false;
  } finally {
    field.remove();
    focus?.focus({ preventScroll: true });
  }
}

function setCodeVisibility(visible) {
  elements.code.type = visible ? "text" : "password";
  elements.toggleCode.textContent = visible ? "隐藏" : "显示";
  elements.toggleCode.setAttribute("aria-label", visible ? "隐藏配对码" : "显示配对码");
}

elements.address.addEventListener("change", () => {
  elements.pairingAddress.value = elements.address.value;
  setFeedback(elements.pairingFeedback, "");
});
elements.openPairing.addEventListener("click", () => {
  elements.pairingDialog.showModal();
  requestPairingCode();
});
elements.closePairing.addEventListener("click", () => elements.pairingDialog.close());
elements.pairingDialog.addEventListener("close", () => {
  if (elements.pairingDialog.open) return;
  pairingRequest?.abort();
  pairingRequest = undefined;
  clearPairingCode();
});
elements.pairingAddress.addEventListener("change", () => {
  elements.address.value = elements.pairingAddress.value;
  setFeedback(elements.pairingFeedback, "");
  requestPairingCode();
});
elements.refreshPairing.addEventListener("click", requestPairingCode);
elements.copyAddress.addEventListener("click", async () => {
  const address = elements.address.value;
  if (await copyToClipboard(address)) setFeedback(elements.pairingFeedback, "接收地址已复制");
  else setFeedback(elements.pairingFeedback, `请在手机上手动输入接收地址 ${address}`, true);
});
elements.copyCode.addEventListener("click", async () => {
  if (await copyToClipboard(elements.code.value)) {
    setFeedback(elements.pairingFeedback, "配对码已复制");
  } else {
    setCodeVisibility(true);
    elements.code.select();
    setFeedback(elements.pairingFeedback, "配对码已选中，可手动复制。", true);
  }
});
elements.toggleCode.addEventListener("click", () => setCodeVisibility(elements.code.type === "password"));

elements.openFileShare.addEventListener("click", () => {
  if (canRedisplayFileShare() && remainingTime(fileShareCode.expiry)) {
    elements.fileSharePath.value = fileShareCode.path;
    elements.fileShareAddress.value = fileShareCode.address;
  } else {
    elements.fileShareAddress.value = elements.address.value;
  }
  setFeedback(elements.fileShareFeedback, "");
  elements.fileShareDialog.showModal();
  renderFileShareCode();
});
elements.closeFileShare.addEventListener("click", () => elements.fileShareDialog.close());
elements.fileShareDialog.addEventListener("close", () => {
  if (elements.fileShareDialog.open) return;
  fileShareRequest?.abort();
  fileShareRequest = undefined;
  updateFileShareControls();
  renderFileShareCode();
});
elements.fileSharePath.addEventListener("input", renderFileShareCode);
elements.fileShareAddress.addEventListener("change", renderFileShareCode);
elements.pickFileShare.addEventListener("click", () => requestFileShare("/api/file-share/pick"));
elements.fileShareForm.addEventListener("submit", (event) => {
  event.preventDefault();
  const path = elements.fileSharePath.value;
  const address = elements.fileShareAddress.value;
  if (!path.trim()) {
    setFeedback(elements.fileShareFeedback, "请输入文件的绝对路径。", true);
    elements.fileSharePath.focus();
    return;
  }
  if (fileShareAvailable && address) requestFileShare("/api/file-share", { address, path });
});

elements.editFolder.addEventListener("click", () => {
  elements.folderInput.value = folderPath;
  setFeedback(elements.folderEditFeedback, "");
  elements.folderDialog.showModal();
});
elements.folderForm.addEventListener("submit", saveFolder);
elements.pickFolder.addEventListener("click", pickFolder);
elements.cancelFolder.addEventListener("click", () => elements.folderDialog.close());
elements.folderDialog.addEventListener("cancel", (event) => {
  if (folderEditorAction === "saving") event.preventDefault();
});
elements.folderDialog.addEventListener("close", () => {
  if (elements.folderDialog.open) return;
  folderPickerRequest?.abort();
  folderPickerRequest = undefined;
  setFolderEditorAction("");
});

elements.openFolder.addEventListener("click", async () => {
  folderOpening = true;
  elements.openFolder.disabled = true;
  elements.openFolder.setAttribute("aria-busy", "true");
  setFeedback(elements.folderFeedback, "");
  try {
    const response = await fetch("/api/open-folder", {
      method: "POST",
      headers: { "X-ScreenRelay": "1" },
    });
    if (!response.ok) throw new Error("folder");
    setFeedback(elements.folderFeedback, "已请求系统打开文件夹");
  } catch {
    setFeedback(elements.folderFeedback, "无法打开文件夹，请在文件管理器中输入上方路径。", true);
  } finally {
    folderOpening = false;
    elements.openFolder.disabled = !folderPath;
    elements.openFolder.removeAttribute("aria-busy");
  }
});

refreshStatus();
