(() => {
  'use strict';
  let language = 'zh-Hans', strings = {};
  const bindings = new Set(), bound = new WeakMap();
  function text(key, ...values) {
    const format = strings[key] ?? key;
    let index = 0;
    return values.length ? format.replace(/%%|%(?:(\d+)\$)?(?:@|lld|ld|d)/g, (token, position) => {
      if (token === '%%') return '%';
      return String(values[position ? Number(position) - 1 : index++] ?? '');
    }) : format;
  }
  function bind(node, attribute, source) {
    if (!/[\u3400-\u9fff]/u.test(source)) return;
    let attributes = bound.get(node);
    if (!attributes) { attributes = new Set(); bound.set(node, attributes); }
    if (attributes.has(attribute)) return;
    attributes.add(attribute);
    const binding = { node, attribute, source };
    bindings.add(binding);
    update(binding);
  }
  function update(binding) {
    const { node, attribute, source } = binding;
    const current = attribute ? node.getAttribute(attribute) : node.nodeValue;
    if (binding.last !== undefined && current !== binding.last) {
      bindings.delete(binding);
      bound.get(node)?.delete(attribute);
      return;
    }
    binding.last = attribute ? text(source) : source.replace(source.trim(), text(source.trim()));
    if (attribute) node.setAttribute(attribute, binding.last);
    else node.nodeValue = binding.last;
  }
  // Bind only application chrome at creation time, before loading user content.
  // Never observe arbitrary DOM mutations or translate document/card text.
  function bindChrome(root) {
    if (!root) return;
    for (const binding of bindings) if (!binding.node.isConnected) bindings.delete(binding);
    applyDocumentLanguage();
    const visit = node => {
      if (node.nodeType === 3) { bind(node, '', node.nodeValue); return; }
      if (node.nodeType !== 1 && node.nodeType !== 9) return;
      if (node.matches?.('script,style,textarea,[data-user-content]')) return;
      for (const attribute of ['title', 'aria-label', 'placeholder', 'alt']) {
        if (node.hasAttribute?.(attribute)) bind(node, attribute, node.getAttribute(attribute));
      }
      for (const child of node.childNodes) visit(child);
    };
    visit(root);
  }
  function applyDocumentLanguage() {
    if (!document.documentElement) return;
    document.documentElement.lang = language;
    document.documentElement.style.setProperty('--editor-placeholder', JSON.stringify(text('开始写作，或输入 / 插入内容')));
    document.documentElement.style.setProperty('--image-caption-placeholder', JSON.stringify(text('添加图片说明')));
  }
  function setLanguage(payload) {
    language = payload.language;
    strings = payload.strings || {};
    applyDocumentLanguage();
    for (const binding of bindings) {
      if (binding.node.isConnected) update(binding);
      else bindings.delete(binding);
    }
    window.dispatchEvent(new CustomEvent('leonlanguagechange', { detail: { language } }));
  }
  window.LeonL10n = { text, bindChrome, setLanguage, get language() { return language; } };
})();
