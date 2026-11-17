function createArticleImages({ root, canEdit, isEmbeddedReader, frameTask }) {
  const images = new Map();
  let viewportTop = 0, viewportHeight = null, geometry = null;
  function resolvedSource(source, thumbnail = true) {
    if (/^(https?:|data:)/i.test(source)) return source;
    const url = /^leonmedia:/i.test(source) ? new URL(source)
      : new URL('leonmedia://asset?path=' + encodeURIComponent(source));
    if (thumbnail) url.searchParams.set('maxPixelSize', '2400');
    return url.href;
  }
  function stageHTML(html) {
    // A template is inert: strip sources before attaching the document so
    // offscreen originals cannot begin loading before viewport preparation.
    const template = document.createElement('template'); template.innerHTML = html;
    for (const image of template.content.querySelectorAll('img')) {
      const source = image.dataset.originalSrc || image.getAttribute('src');
      if (source) { image.dataset.originalSrc = source; image.removeAttribute('src'); }
    }
    return template.content;
  }
  function invalidate() { geometry = null; schedule(); }
  function prepare() {
    for (const [image, state] of images) if (!root.contains(image)) {
      image.removeEventListener('load', state.complete); image.removeEventListener('error', state.complete); images.delete(image);
    }
    for (const image of root.querySelectorAll('img')) {
      const source = image.dataset.originalSrc || image.getAttribute('src');
      if (!source) continue;
      if (images.get(image)?.source === source) {
        const state = images.get(image);
        if (canEdit() && !state.loaded) load(image, state);
        continue;
      }
      const previous = images.get(image);
      if (previous) { image.removeEventListener('load', previous.complete); image.removeEventListener('error', previous.complete); }
      image.dataset.originalSrc = source;
      const complete = () => { image.classList.remove('article-image-pending'); invalidate(); };
      const state = { source, loaded: false, complete };
      images.set(image, state);
      image.addEventListener('load', complete); image.addEventListener('error', complete);
      image.classList.add('article-image-pending');
      if (canEdit()) load(image, state);
      else image.removeAttribute('src');
    }
    invalidate();
  }
  function load(image, state) {
    state.loaded = true;
    image.src = resolvedSource(state.source);
  }
  function update() {
    if (canEdit()) return;
    if (!geometry) {
      geometry = [...images].filter(([image, state]) => !state.loaded && root.contains(image)).map(([image, state]) => {
        const rect = image.getBoundingClientRect(); return { image, state, top: rect.top + scrollY, bottom: rect.bottom + scrollY };
      }).sort((a, b) => a.top - b.top);
      let bottom = -Infinity;
      for (const item of geometry) { bottom = Math.max(bottom, item.bottom); item.prefixBottom = bottom; }
    }
    const top = isEmbeddedReader() ? viewportTop : scrollY;
    const height = isEmbeddedReader() ? (viewportHeight === null ? Math.min(innerHeight, 800) : viewportHeight) : innerHeight;
    if (height <= 0) return;
    const lower = top - 400, upper = top + height + 400;
    let low = 0, high = geometry.length;
    while (low < high) { const middle = (low + high) >>> 1; if (geometry[middle].prefixBottom < lower) low = middle + 1; else high = middle; }
    const visible = [];
    for (let index = low; index < geometry.length && geometry[index].top <= upper; index++) {
      const item = geometry[index];
      if (!item.state.loaded && item.bottom >= lower) visible.push(item);
    }
    // Keep all geometry reads above the writes that initiate image requests.
    for (const item of visible) load(item.image, item.state);
  }
  const schedule = frameTask(update);
  function reset() {
    schedule.cancel();
    for (const [image, state] of images) { image.removeEventListener('load', state.complete); image.removeEventListener('error', state.complete); }
    images.clear(); geometry = null; viewportTop = 0; viewportHeight = null;
  }
  return { stageHTML, prepare, invalidate, reset, schedule,
    setViewport(top, height) { viewportTop = Math.max(0, Number(top) || 0); viewportHeight = Math.max(0, Number(height) || 0); schedule(); }
  };
}
