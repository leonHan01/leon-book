import DOMPurify from 'dompurify';
import { inlineArticleID, inlineArticlePath } from '../shared/inline-article-images.js';

const opening = '<article data-leon-format="html-v1">';
const mediaElements = 'img, audio, video, source';
const safeStyles = ['color', 'background-color', 'font-weight', 'font-style', 'text-decoration', 'text-align', 'width', 'height'];
const toolbarActions = [
  ['正文', 'formatBlock', 'p'], ['标题', 'formatBlock', 'h2'], ['小标题', 'formatBlock', 'h3'],
  ['加粗', 'bold'], ['项目列表', 'insertUnorderedList'], ['编号列表', 'insertOrderedList'],
];

function documentFragment(fields) {
  if (fields.format !== 'html') {
    const fragment = document.createDocumentFragment();
    for (const line of fields.body.split(/\r?\n/)) {
      const paragraph = document.createElement('p');
      paragraph.append(line || document.createElement('br'));
      fragment.append(paragraph);
    }
    return fragment;
  }
  const fragment = DOMPurify.sanitize(fields.body, {
    RETURN_DOM_FRAGMENT: true, USE_PROFILES: { html: true },
    FORBID_TAGS: ['form', 'input', 'button', 'textarea', 'select', 'style', 'iframe', 'object', 'embed', 'picture'],
    FORBID_ATTR: ['srcset', 'poster', 'autoplay', 'contenteditable', 'tabindex', 'data-edit-source'],
  });
  for (const node of fragment.querySelectorAll('[style]')) {
    const styles = safeStyles.map(name => [name, node.style.getPropertyValue(name)]);
    node.removeAttribute('style');
    for (const [name, value] of styles) if (value) node.style.setProperty(name, value);
  }
  for (const media of fragment.querySelectorAll(mediaElements)) {
    const source = media.getAttribute('src');
    media.removeAttribute('src');
    if (source) media.dataset.editSource = source;
  }
  const wrapper = fragment.firstElementChild;
  if (wrapper?.matches('article[data-leon-format="html-v1"]') && fragment.childElementCount === 1) {
    wrapper.replaceWith(...wrapper.childNodes);
  }
  return fragment;
}

export function createArticleRichEditor(initial, { chooseImages, onChange, resolveImage }) {
  const wrapper = document.createElement('section');
  wrapper.className = 'article-rich-editor';
  const heading = document.createElement('p');
  heading.className = 'article-rich-label';
  heading.textContent = '正文';
  const bar = document.createElement('div');
  bar.className = 'article-rich-toolbar';
  bar.setAttribute('role', 'group');
  bar.setAttribute('aria-label', '正文格式');
  const surface = document.createElement('div');
  surface.className = 'article-rich-input';
  surface.contentEditable = 'true';
  surface.setAttribute('role', 'textbox');
  surface.setAttribute('aria-label', '文章正文');
  surface.setAttribute('aria-multiline', 'true');
  surface.append(documentFragment(initial));
  wrapper.append(heading, bar, surface);

  const abort = new AbortController();
  const previews = new Map();
  const tried = new WeakSet();
  let selection, previewQueue = Promise.resolve();

  function rememberSelection() {
    const current = document.getSelection();
    if (!current?.rangeCount) return false;
    const range = current.getRangeAt(0);
    if (!surface.contains(range.commonAncestorContainer)) return false;
    selection = range.cloneRange();
    return true;
  }

  function focusSelection() {
    surface.focus({ preventScroll: true });
    const current = document.getSelection();
    if (!selection || !surface.contains(selection.commonAncestorContainer)) {
      selection = document.createRange();
      selection.selectNodeContents(surface);
      selection.collapse(false);
    }
    current.removeAllRanges();
    current.addRange(selection);
  }

  function tool(label, run) {
    const control = document.createElement('button');
    control.type = 'button';
    control.textContent = label;
    control.addEventListener('pointerdown', rememberSelection);
    control.addEventListener('mousedown', event => event.preventDefault());
    control.addEventListener('click', run);
    bar.append(control);
    return control;
  }

  function command(action, value) {
    focusSelection();
    document.execCommand('defaultParagraphSeparator', false, 'p');
    document.execCommand(action, false, value);
    changed();
    rememberSelection();
  }

  const controls = toolbarActions.map(([label, commandName, value]) =>
    [tool(label, () => command(commandName, value)), commandName, value]);
  for (const [control] of controls) control.setAttribute('aria-pressed', 'false');
  tool('插图', () => { rememberSelection(); chooseImages(); });
  document.addEventListener('selectionchange', () => {
    if (!rememberSelection()) return;
    for (const [control, name, value] of controls) {
      const current = value
        ? String(document.queryCommandValue(name)).toLowerCase() === value
        : document.queryCommandState(name);
      control.setAttribute('aria-pressed', String(current));
    }
  }, { signal: abort.signal });

  function showPreviews() {
    for (const image of surface.querySelectorAll('img[data-edit-source]')) {
      const path = image.dataset.editSource;
      if (tried.has(image)) continue;
      tried.add(image);
      if (!previews.has(path)) {
        const next = previewQueue.then(async () => {
          if (abort.signal.aborted) return null;
          if (/^data:image\/(png|jpeg|gif|webp);base64,/i.test(path)) return { url: path, object: false };
          const blob = await resolveImage(path, abort.signal);
          return blob && !abort.signal.aborted ? { url: URL.createObjectURL(blob), object: true } : null;
        }).catch(() => null);
        previews.set(path, next);
        previewQueue = next;
      }
      previews.get(path).then(preview => {
        if (preview && !abort.signal.aborted) image.src = preview.url;
      });
    }
  }

  function serialize() {
    const copy = surface.cloneNode(true);
    for (const node of copy.querySelectorAll(mediaElements)) {
      const source = node.dataset.editSource;
      delete node.dataset.editSource;
      node.removeAttribute('src');
      if (source) node.setAttribute('src', source);
    }
    return opening + copy.innerHTML + '</article>';
  }

  const baseline = serialize();
  function changed() {
    showPreviews();
    onChange();
  }
  surface.addEventListener('input', changed);
  surface.addEventListener('click', event => { if (event.target.closest('a')) event.preventDefault(); });
  surface.addEventListener('paste', event => {
    event.preventDefault();
    if (event.clipboardData) command('insertText', event.clipboardData.getData('text/plain'));
  });
  surface.addEventListener('drop', event => event.preventDefault());
  showPreviews();

  return {
    element: wrapper,
    body() {
      const html = serialize();
      return html === baseline ? { body: initial.body, format: initial.format } : { body: html, format: 'html' };
    },
    hasContent() {
      return Boolean(surface.textContent.trim() || surface.querySelector('img[data-edit-source], audio[data-edit-source], video[data-edit-source], pre, aside, table, hr'));
    },
    inlineIDs() {
      return new Set(Array.from(surface.querySelectorAll('img[data-edit-source]'), image => inlineArticleID(image.dataset.editSource)).filter(Boolean));
    },
    insertImages(files) {
      const fragment = document.createElement('div');
      for (const file of files) {
        const paragraph = document.createElement('p');
        const image = document.createElement('img');
        image.dataset.editSource = inlineArticlePath(file.id);
        image.alt = file.name;
        paragraph.append(image);
        fragment.append(paragraph);
      }
      command('insertHTML', fragment.innerHTML + '<p><br></p>');
    },
    removeImage(id) {
      for (const image of surface.querySelectorAll('img[data-edit-source]')) {
        if (image.dataset.editSource === inlineArticlePath(id)) image.remove();
      }
    },
    dispose() {
      abort.abort();
      for (const result of previews.values()) result.then(preview => { if (preview?.object) URL.revokeObjectURL(preview.url); });
    },
  };
}
