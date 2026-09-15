const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('api', {
  storeGet: () => ipcRenderer.invoke('store:get'),
  storeSet: (data) => ipcRenderer.invoke('store:set', data),
  getJson: (url) => ipcRenderer.invoke('net:getJson', url),
  getText: (url) => ipcRenderer.invoke('net:getText', url),
  getProxyBase: () => ipcRenderer.invoke('proxy:getBase'),
  getThumbBase: () => ipcRenderer.invoke('proxy:getThumbBase'),
  getThumbBases: () => ipcRenderer.invoke('proxy:getThumbBases'),
  getCatalog: () => ipcRenderer.invoke('catalog:get'),
  setCatalog: (data) => ipcRenderer.invoke('catalog:set', data),
  getCacheInfo: () => ipcRenderer.invoke('cache:info'),
  clearVideoCache: () => ipcRenderer.invoke('cache:clear'),
  getAppVersion: () => ipcRenderer.invoke('app:getVersion'),
  focusWindow: () => ipcRenderer.invoke('window:focus'),
  downloadsList: () => ipcRenderer.invoke('downloads:list'),
  downloadsAdd: (meta) => ipcRenderer.invoke('downloads:add', meta),
  downloadsPause: (id) => ipcRenderer.invoke('downloads:pause', id),
  downloadsResume: (id) => ipcRenderer.invoke('downloads:resume', id),
  downloadsRemove: (id, deleteFile) => ipcRenderer.invoke('downloads:remove', id, deleteFile),
  downloadsGetDir: () => ipcRenderer.invoke('downloads:getDir'),
  downloadsSetConcurrent: (on) => ipcRenderer.invoke('downloads:setConcurrent', on),
  downloadsChooseDir: () => ipcRenderer.invoke('downloads:chooseDir'),
  downloadsOpenFolder: (id) => ipcRenderer.invoke('downloads:openFolder', id),
  downloadsFileUrl: (id) => ipcRenderer.invoke('downloads:fileUrl', id),
  onDownloadsUpdate: (cb) => {
    const handler = (_e, list) => cb(list);
    ipcRenderer.on('downloads:update', handler);
    return () => ipcRenderer.removeListener('downloads:update', handler);
  },
  licenseGetStatus: () => ipcRenderer.invoke('license:getStatus'),
  licenseRecheckNow: () => ipcRenderer.invoke('license:recheckNow'),
  licenseVerify: (key) => ipcRenderer.invoke('license:verify', key),
  licenseGetPlans: () => ipcRenderer.invoke('license:getPlans'),
  licenseGetSettings: () => ipcRenderer.invoke('license:getSettings'),
  openExternal: (url) => ipcRenderer.invoke('shell:openExternal', url),
  openDownloadUrl: (url) => ipcRenderer.invoke('shell:openDownloadUrl', url),
  checkTrialAvailability: () => ipcRenderer.invoke('trial:checkAvailability'),
  claimTrial: () => ipcRenderer.invoke('trial:claim'),
  getAnnouncement: () => ipcRenderer.invoke('announcement:get'),
  checkForUpdate: () => ipcRenderer.invoke('update:check'),
  onLicenseInvalidated: (cb) => {
    const handler = () => cb();
    ipcRenderer.on('license:invalidated', handler);
    return () => ipcRenderer.removeListener('license:invalidated', handler);
  },
  onIptvCacheUpdated: (cb) => {
    const handler = () => cb();
    ipcRenderer.on('iptv:cacheUpdated', handler);
    return () => ipcRenderer.removeListener('iptv:cacheUpdated', handler);
  }
});
