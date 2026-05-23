const widget = document.getElementById("widget");
const percentValue = document.getElementById("percentValue");
const resetTime = document.getElementById("resetTime");
const status = document.getElementById("status");
const hideButton = document.getElementById("hideButton");

let lastKnown = null;

hideButton.addEventListener("click", () => {
  window.quotaWidget.hide();
});

hideButton.addEventListener("dblclick", (event) => {
  event.stopPropagation();
});

widget.addEventListener("dblclick", () => {
  window.quotaWidget.refresh();
});

window.quotaWidget.onQuotaUpdate((payload) => {
  if (payload.ok) {
    lastKnown = payload;
    renderQuota(payload, false);
    return;
  }

  if (payload.lastKnown || lastKnown) {
    renderQuota(payload.lastKnown || lastKnown, true);
  } else {
    renderOffline(payload.error || "offline");
  }
});

function renderQuota(payload, offline) {
  const remaining = Number(payload.remainingPercent);
  const progress = Number.isFinite(remaining) ? Math.max(0, Math.min(100, remaining)) : 0;
  widget.style.setProperty("--progress", `${progress}%`);
  widget.style.setProperty("--glow", progress <= 20 ? "#ff5f87" : progress <= 50 ? "#ffd166" : "#63f5ff");
  widget.classList.toggle("offline", offline);
  percentValue.textContent = String(Math.round(progress));
  status.textContent = offline ? "offline" : "live";
  resetTime.textContent = payload.resetsAtText ? `reset ${payload.resetsAtText}` : "reset unknown";
}

function renderOffline(message) {
  widget.classList.add("offline");
  widget.style.setProperty("--progress", "0%");
  percentValue.textContent = "--";
  status.textContent = "offline";
  resetTime.textContent = message.slice(0, 28);
}
