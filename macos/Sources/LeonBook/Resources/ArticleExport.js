// Parse into an inert template: article scripts and remote resources never run.
const template = document.createElement('template');
template.innerHTML = body;
const root = template.content;
root.querySelectorAll('script,style,link,meta,base,object,embed,form,input,button,textarea,select,template').forEach(node => node.remove());
root.querySelectorAll('iframe').forEach(node => {
    const link = document.createElement('a');
    link.href = node.getAttribute('src') || '';
    link.textContent = node.getAttribute('title') || link.href;
    node.replaceWith(link);
});
if (pdf) root.querySelectorAll('audio,video').forEach(node => {
    const label = document.createElement('p');
    label.textContent = node.getAttribute('aria-label') || node.getAttribute('title') || node.getAttribute('src')?.split('/').pop() || node.tagName;
    node.replaceWith(label);
});
const references = [], tokens = new Map();
const safeStyles = new Set(['color','background-color','font-weight','font-style','text-decoration','text-align','width','height','max-width','font-size','line-height','border-color']);
const allowedTags = new Set('article header section footer main p div span h1 h2 h3 h4 h5 h6 pre code aside blockquote ul ol li hr br table thead tbody tfoot tr th td colgroup col img figure figcaption a strong b em i u s del mark sub sup audio video source details summary'.split(' '));
const allowedAttributes = new Set('href src poster alt title class width height colspan rowspan span start controls type id data-type data-checked data-number data-depth data-language'.split(' '));
function asset(value) {
    if (!tokens.has(value)) {
        const token = `leon-export-asset:${references.length}`;
        tokens.set(value, token); references.push({ value, token });
    }
    return tokens.get(value);
}
for (const node of [...root.querySelectorAll('*')]) {
    if (!allowedTags.has(node.localName)) { node.replaceWith(...node.childNodes); continue; }
    for (const attribute of [...node.attributes]) {
        const name = attribute.name, value = attribute.value.trim();
        if (name === 'style') {
            for (const property of [...node.style]) {
                if (!safeStyles.has(property) || /url\s*\(|expression\s*\(|@import/i.test(node.style.getPropertyValue(property))) node.style.removeProperty(property);
            }
            continue;
        }
        if (!allowedAttributes.has(name)) { node.removeAttribute(name); continue; }
        if (!['src','href','poster'].includes(name)) continue;
        if (!value) { node.removeAttribute(name); continue; }
        const scheme = value.match(/^([a-z][a-z\d+.-]*):/i)?.[1]?.toLowerCase();
        if (name === 'href' && (scheme === 'leonbook')) {
            try {
                const url = new URL(value), slug = url.searchParams.get('slug');
                if (Object.prototype.hasOwnProperty.call(links, slug)) node.setAttribute(name, links[slug] + url.hash);
            } catch { node.removeAttribute(name); }
            continue;
        }
        if (name === 'href' && (/^(https?:|mailto:|tel:)/i.test(value) || value.startsWith('#'))) continue;
        if (scheme === 'data' && name !== 'href' && /^data:(image|audio|video)\//i.test(value)) continue;
        if (scheme && !['http','https'].includes(scheme)) { node.removeAttribute(name); continue; }
        if (pdf && name === 'href') { node.removeAttribute(name); continue; }
        node.setAttribute(name, asset(value.startsWith('//') ? 'https:' + value : value));
        if (name === 'href') node.setAttribute('download', value.split('/').pop() || 'attachment');
    }
    if (node.localName === 'img') { node.loading = 'eager'; node.removeAttribute('height'); }
    if (['audio','video'].includes(node.localName)) { node.controls = true; node.preload = 'none'; }
    if (node.dataset.depth) node.style.marginLeft = `${Math.min(8, Math.max(0, Number(node.dataset.depth) || 0)) * 20}px`;
}
return { html: template.innerHTML, references };
