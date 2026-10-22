import React from 'react';
import { createRoot } from 'react-dom/client';
import { Excalidraw, MainMenu, exportToBlob, serializeAsJSON } from '@excalidraw/excalidraw';
import '@excalidraw/excalidraw/index.css';

const send = payload => window.webkit?.messageHandlers?.whiteboard?.postMessage(payload);
const status = document.getElementById('status');
const saveButton = document.getElementById('save');
const cancelButton = document.getElementById('cancel');
let api, root, baseline, changed = false, saving = false;
const maximumSceneBytes = 16 * 1024 * 1024;
const serialize = (elements, appState, files) => serializeAsJSON(elements, appState, files, 'local');

function showError(message) {
  saving = false;
  saveButton.disabled = !api;
  cancelButton.disabled = false;
  status.textContent = message;
  status.style.color = '#c0392b';
}

class EditorBoundary extends React.Component {
  state = { error: null };
  static getDerivedStateFromError(error) { return { error }; }
  componentDidCatch(error) { showError('画板加载失败：' + error.message); }
  render() { return this.state.error ? <div id="message">画板未能加载，请关闭后重试。原画板数据没有改变。</div> : this.props.children; }
}

function load(raw) {
  const scene = raw ? JSON.parse(raw) : { elements: [], appState: { viewBackgroundColor: '#ffffff' }, files: {} };
  if (root) throw new Error('画板已经打开');
  root = createRoot(document.getElementById('app'));
  root.render(<EditorBoundary><Excalidraw
    initialData={{ ...scene, scrollToContent: true }}
    langCode="zh-CN"
    excalidrawAPI={value => { api = value; saveButton.disabled = false; status.textContent = '本地画板 · 保存后更新文章'; }}
    onChange={(elements, appState, files) => {
      // Scene versions are cheap to inspect. Serialize only when committing;
      // pointer motion and viewport changes do not ship the scene over the bridge.
      const signature = elements.map(element => `${element.id}:${element.version}:${element.isDeleted}`).join('|') + ':' + appState.viewBackgroundColor;
      if (baseline === undefined) baseline = signature;
      const next = signature !== baseline;
      if (next !== changed) { changed = next; send({ type: 'dirty', value: changed }); }
    }}
    validateEmbeddable={() => false}
    onLinkOpen={(_element, event) => event.preventDefault()}
    UIOptions={{ canvasActions: { loadScene: false, saveToActiveFile: false, saveAsImage: false, export: false } }}
  ><MainMenu><MainMenu.DefaultItems.ClearCanvas /><MainMenu.DefaultItems.ToggleTheme /><MainMenu.DefaultItems.ChangeCanvasBackground /></MainMenu></Excalidraw></EditorBoundary>);
}

function blobURL(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(new Error('无法读取画板预览'));
    reader.readAsDataURL(blob);
  });
}

async function snapshot() {
  if (!api) throw new Error('画板尚未加载');
  const elements = api.getSceneElements(), appState = api.getAppState(), files = api.getFiles();
  const scene = serialize(elements, appState, files);
  if (new Blob([scene]).size > maximumSceneBytes) throw new Error('画板超过 16 MB，请减少图片后保存。');
  await document.fonts.ready;
  let blob;
  if (elements.length) {
    blob = await exportToBlob({ elements, appState: { ...appState, exportWithDarkMode: false, exportBackground: true }, files, maxWidthOrHeight: 2048, mimeType: 'image/png' });
  } else {
    const canvas = document.createElement('canvas'); canvas.width = 800; canvas.height = 450;
    const context = canvas.getContext('2d'); context.fillStyle = appState.viewBackgroundColor || '#ffffff'; context.fillRect(0, 0, 800, 450);
    blob = await new Promise(resolve => canvas.toBlob(resolve, 'image/png'));
  }
  if (!blob) throw new Error('无法生成画板预览');
  return { scene, preview: await blobURL(blob) };
}

async function save() {
  if (saving || !api) return;
  saving = true; saveButton.disabled = cancelButton.disabled = true;
  status.style.color = ''; status.textContent = '正在保存画板…';
  try { send({ type: 'save', ...await snapshot() }); }
  catch (error) { showError(error.message); }
}

saveButton.addEventListener('click', save);
cancelButton.addEventListener('click', () => send({ type: 'cancel' }));
document.addEventListener('keydown', event => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 's') { event.preventDefault(); event.stopImmediatePropagation(); save(); }
}, true);
window.LeonWhiteboard = { load, showError, snapshot, getAPI: () => api };
send({ type: 'ready' });
