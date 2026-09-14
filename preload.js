const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('api', {
  storeGet: () => ipcRenderer.invoke('store:get'),
  storeSet: (data) => ipcRenderer.invoke('store:set', data),
  getJson: (url) => ipcRenderer.invoke('net:getJson', url),
  getText: (url) => ipcRenderer.invoke('net:getText', url),
  getProxyBase: () => ipcRenderer.invoke('proxy:getBase'),
  getAppVersion: () => ipcRenderer.invoke('app:getVersion')
});
