import { previewImageBlob } from './attachments.js';

const clamp = (value, min, max) => Math.min(Math.max(value, min), max);
const distance = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);
const midpoint = (a, b) => ({ x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 });
const isDownward = (dx, dy) => dy > 1.25 * Math.abs(dx);
const tapSlop = 12;
const doubleTapDelay = 320;

function control(text, label, className, click) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = className;
  button.textContent = text;
  button.setAttribute('aria-label', label);
  button.addEventListener('click', click);
  return button;
}

export function showPhotoGallery(photos, startIndex, loadPhoto, onClose) {
  const dialog = document.createElement('dialog');
  dialog.className = 'photo-gallery';
  dialog.setAttribute('aria-label', '微博图片');
  const stage = document.createElement('div');
  stage.className = 'photo-gallery-stage';
  const image = document.createElement('img');
  image.draggable = false;
  const message = document.createElement('div');
  message.className = 'photo-gallery-message';
  const status = document.createElement('span');
  status.setAttribute('role', 'status');
  const retry = control('重试', '重新加载图片', 'photo-gallery-control', () => select(index));
  message.append(status, retry);
  stage.append(image, message);

  const toolbar = document.createElement('header');
  toolbar.className = 'photo-gallery-toolbar';
  const counter = document.createElement('span');
  counter.setAttribute('aria-live', 'polite');
  const close = control('关闭', '关闭图片查看器', 'photo-gallery-control photo-gallery-close', () => dialog.close());
  close.autofocus = true;
  toolbar.append(counter, close);
  const previous = control('‹', '上一张', 'photo-gallery-control photo-gallery-previous', () => step(-1));
  const next = control('›', '下一张', 'photo-gallery-control photo-gallery-next', () => step(1));
  previous.hidden = next.hidden = photos.length < 2;
  dialog.append(stage, toolbar, previous, next);

  let index = startIndex;
  let request;
  let url;
  let view = { scale: 1, x: 0, y: 0 };
  let swipeOffset = 0;
  let dismissOffset = 0;
  const pointers = new Map();
  let gesture;
  let usedPinch = false;
  let lastTap;

  function setView(scale, x, y) {
    const width = stage.clientWidth;
    const height = stage.clientHeight;
    const fit = image.naturalWidth && image.naturalHeight
      ? Math.min(width / image.naturalWidth, height / image.naturalHeight) : 0;
    const limitX = Math.max(0, (image.naturalWidth * fit * scale - width) / 2);
    const limitY = Math.max(0, (image.naturalHeight * fit * scale - height) / 2);
    view = { scale, x: clamp(x, -limitX, limitX), y: clamp(y, -limitY, limitY) };
    paint();
  }

  function paint() {
    const opacity = dismissOffset ? clamp(1 - dismissOffset / Math.max(1, stage.clientHeight * .6), .2, 1) : 1;
    image.style.transform = `translate3d(${view.x + swipeOffset}px, ${view.y + dismissOffset}px, 0) scale(${view.scale})`;
    dialog.style.setProperty('--photo-gallery-opacity', opacity);
  }

  function releaseImage() {
    request?.abort();
    image.onload = image.onerror = null;
    image.removeAttribute('src');
    image.hidden = true;
    if (url) URL.revokeObjectURL(url);
    url = undefined;
  }

  async function select(selected) {
    index = selected;
    releaseImage();
    const controller = new AbortController();
    request = controller;
    pointers.clear();
    gesture = undefined;
    usedPinch = false;
    lastTap = undefined;
    swipeOffset = 0;
    dismissOffset = 0;
    setView(1, 0, 0);
    counter.textContent = `${index + 1} / ${photos.length}`;
    counter.setAttribute('aria-label', `第 ${index + 1} 张，共 ${photos.length} 张`);
    previous.disabled = index === 0;
    next.disabled = index === photos.length - 1;
    status.textContent = '正在加载图片…';
    message.hidden = false;
    retry.hidden = true;
    const photo = photos[index];
    const name = photo.ref.name;
    image.alt = name;
    try {
      const blob = await loadPhoto(photo, controller.signal);
      if (controller.signal.aborted) return;
      const normalized = blob && previewImageBlob(blob, name);
      if (!normalized) throw new Error('这张图片暂无法预览。');
      url = URL.createObjectURL(normalized);
      image.onload = () => {
        message.hidden = true;
        image.hidden = false;
        setView(1, 0, 0);
      };
      image.onerror = () => {
        releaseImage();
        status.textContent = '手机暂无法预览这张图片。';
      };
      image.src = url;
    } catch (error) {
      if (controller.signal.aborted) return;
      status.textContent = error?.message || '图片加载失败。';
      retry.hidden = false;
    }
  }

  function step(offset) {
    const selected = index + offset;
    if (selected >= 0 && selected < photos.length) void select(selected);
  }

  function point(event) {
    const rect = stage.getBoundingClientRect();
    return { x: event.clientX - rect.left - rect.width / 2, y: event.clientY - rect.top - rect.height / 2 };
  }

  function rebaseGesture(time) {
    const [a, b] = pointers.values();
    if (b) {
      usedPinch = true;
      lastTap = undefined;
      swipeOffset = 0;
      dismissOffset = 0;
      gesture = { center: midpoint(a, b), distance: Math.max(1, distance(a, b)), view };
      paint();
    } else {
      gesture = a ? { start: a, view, time, moved: false } : undefined;
    }
  }

  stage.addEventListener('pointerdown', event => {
    if (event.button !== 0 || pointers.size >= 2 || event.target.closest('button')) return;
    stage.setPointerCapture(event.pointerId);
    pointers.set(event.pointerId, point(event));
    rebaseGesture(event.timeStamp);
  });
  stage.addEventListener('pointermove', event => {
    if (!pointers.has(event.pointerId) || !gesture) return;
    const position = point(event);
    pointers.set(event.pointerId, position);
    const [a, b] = pointers.values();
    if (b && !image.hidden) {
      const center = midpoint(a, b);
      const scale = clamp(gesture.view.scale * distance(a, b) / gesture.distance, 1, 4);
      const ratio = scale / gesture.view.scale;
      setView(scale, center.x - (gesture.center.x - gesture.view.x) * ratio,
        center.y - (gesture.center.y - gesture.view.y) * ratio);
    } else if (gesture.start) {
      const dx = position.x - gesture.start.x;
      const dy = position.y - gesture.start.y;
      if (Math.hypot(dx, dy) > tapSlop) gesture.moved = true;
      if (gesture.view.scale > 1) {
        setView(view.scale, gesture.view.x + dx, gesture.view.y + dy);
      } else if (!usedPinch) {
        const atEdge = dx < 0 ? index === photos.length - 1 : index === 0;
        swipeOffset = photos.length > 1 && Math.abs(dx) > Math.abs(dy) ? dx * (atEdge ? .16 : .5) : 0;
        dismissOffset = isDownward(dx, dy) ? dy * .8 : 0;
        paint();
      }
    }
  });

  function tap(event, position) {
    const time = event.timeStamp;
    if (lastTap?.type === event.pointerType && time - lastTap.time <= doubleTapDelay &&
        distance(position, lastTap.position) <= 28) {
      lastTap = undefined;
      swipeOffset = 0;
      dismissOffset = 0;
      if (view.scale > 1) setView(1, 0, 0);
      else setView(2, -position.x, -position.y);
    } else {
      lastTap = { position, time, type: event.pointerType };
    }
  }

  function finishGesture(event) {
    if (!pointers.delete(event.pointerId)) return;
    const singleRelease = event.type === 'pointerup' && !pointers.size && !usedPinch && gesture?.start;
    if (event.type !== 'pointerup' && pointers.size) usedPinch = true;
    if (singleRelease) {
      const position = point(event);
      const dx = position.x - gesture.start.x;
      const dy = position.y - gesture.start.y;
      if (!image.hidden && !gesture.moved && Math.hypot(dx, dy) <= tapSlop &&
          event.timeStamp - gesture.time <= 250) tap(event, position);
      else {
        lastTap = undefined;
        if (view.scale === 1) {
          const closeDistance = clamp(stage.clientHeight * .12, 72, 120);
          if (dy >= closeDistance && isDownward(dx, dy)) {
            dialog.close();
            return;
          }
          if (Math.abs(dx) >= 48 && Math.abs(dx) > 1.25 * Math.abs(dy)) step(dx < 0 ? 1 : -1);
        }
      }
    } else lastTap = undefined;
    if (!pointers.size) usedPinch = false;
    swipeOffset = 0;
    dismissOffset = 0;
    rebaseGesture(event.timeStamp);
    paint();
  }

  stage.addEventListener('pointerup', finishGesture);
  stage.addEventListener('pointercancel', finishGesture);
  stage.addEventListener('lostpointercapture', finishGesture);
  dialog.addEventListener('keydown', event => {
    if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
    event.preventDefault();
    step(event.key === 'ArrowRight' ? 1 : -1);
  });
  const resize = new ResizeObserver(() => setView(view.scale, view.x, view.y));
  dialog.addEventListener('close', () => {
    releaseImage();
    resize.disconnect();
    dialog.remove();
    onClose();
  }, { once: true });

  document.body.append(dialog);
  dialog.showModal();
  resize.observe(stage);
  void select(startIndex);
  return dialog;
}
