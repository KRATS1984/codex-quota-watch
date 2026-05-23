import { contextBridge, ipcRenderer } from "electron";

contextBridge.exposeInMainWorld("quotaWidget", {
  hide: () => ipcRenderer.send("widget:hide"),
  refresh: () => ipcRenderer.invoke("quota:refresh"),
  onQuotaUpdate: (callback) => {
    const listener = (_event, payload) => callback(payload);
    ipcRenderer.on("quota:update", listener);
    return () => ipcRenderer.removeListener("quota:update", listener);
  },
});
