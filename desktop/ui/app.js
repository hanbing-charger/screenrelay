"use strict";

const elements = {
  status: document.getElementById("receiver-status"),
  address: document.getElementById("server-address"),
  copyAddress: document.getElementById("copy-address"),
  code: document.getElementById("pairing-code"),
  toggleCode: document.getElementById("toggle-code"),
  copyCode: document.getElementById("copy-code"),
  pairingFeedback: document.getElementById("pairing-feedback"),
  folder: document.getElementById("folder-path"),
  openFolder: document.getElementById("open-folder"),
  folderFeedback: document.getElementById("folder-feedback"),
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
let previousFiles = "";
let statusLoaded = false;
let folderAvailable = false;
let folderOpening = false;

function setStatus(label, state) {
  if (elements.status.textContent !== label) elements.status.textContent = label;
  elements.status.dataset.state = state;
}

function setFeedback(element, message, isError = false) {
  element.textContent = message;
  element.dataset.error = String(isError);
}

function updateAddresses(addresses) {
  const snapshot = JSON.stringify(addresses);
  if (snapshot === previousAddresses) return;
  previousAddresses = snapshot;

  const selected = elements.address.value;
  const options = addresses.map((address) => new Option(address, address));
  if (options.length === 0) options.push(new Option("未发现局域网地址", ""));
  elements.address.replaceChildren(...options);
  if (addresses.includes(selected)) elements.address.value = selected;
  elements.address.disabled = addresses.length === 0;
  elements.copyAddress.disabled = addresses.length === 0;
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
  const files = Array.isArray(data.recent) ? data.recent.filter((file) => typeof file?.name === "string") : [];
  const token = typeof data.token === "string" ? data.token : "";
  const folder = typeof data.folder === "string" ? data.folder : "";

  if (!data.listening) setStatus("接收服务未启动", "unavailable");
  else if (addresses.length === 0) setStatus("等待局域网连接", "unavailable");
  else setStatus("接收服务运行中", "ready");
  updateAddresses(addresses);

  if (elements.code.value !== token) elements.code.value = token;
  elements.code.placeholder = "配对码不可用";
  elements.copyCode.disabled = !token;
  elements.toggleCode.disabled = !token;

  folderAvailable = Boolean(folder);
  const folderLabel = folder || "保存位置不可用";
  if (elements.folder.textContent !== folderLabel) elements.folder.textContent = folderLabel;
  elements.openFolder.disabled = !folderAvailable || folderOpening;
  updateFiles(files);

  const version = typeof data.version === "string" ? data.version : "";
  const versionLabel = version ? `版本 ${version}` : "";
  if (elements.version.textContent !== versionLabel) elements.version.textContent = versionLabel;
  elements.version.hidden = !version;
}

async function refreshStatus() {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 3000);
  try {
    const response = await fetch("/api/status", { cache: "no-store", signal: controller.signal });
    if (!response.ok) throw new Error("status");
    const data = await response.json();
    showStatus(data);
    statusLoaded = true;
  } catch {
    setStatus("无法连接接收端", "unavailable");
    if (!statusLoaded) {
      elements.address.replaceChildren(new Option("接收地址不可用", ""));
      elements.code.placeholder = "配对码不可用";
      elements.folder.textContent = "保存位置不可用";
      elements.emptyTitle.textContent = "暂时无法读取接收记录";
      elements.emptyDescription.textContent = "启动电脑接收端后会自动重连。";
    }
  } finally {
    clearTimeout(timeout);
    setTimeout(refreshStatus, 4000);
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

elements.address.addEventListener("change", () => setFeedback(elements.pairingFeedback, ""));
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
    elements.openFolder.disabled = !folderAvailable;
    elements.openFolder.removeAttribute("aria-busy");
  }
});

refreshStatus();
