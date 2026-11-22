import { articleFolderPath } from './article-directories.js';
import { editableFields } from './editor.js';

const cachedBodies = new WeakMap();
const blockElements = 'article, section, div, p, br, h1, h2, h3, h4, h5, h6, blockquote, li, pre, td, th, figure, figcaption';

export function searchText(text) {
  return text.normalize('NFC').replace(/\s+/g, ' ').trim().toLocaleLowerCase();
}

function readableBody(article) {
  let body = cachedBodies.get(article);
  if (body) return body;
  const fields = editableFields('articles', article);
  let text = fields.body;
  if (fields.format === 'html') {
    // Template content stays inert, including any resource URLs in the article.
    const template = document.createElement('template');
    template.innerHTML = text;
    const fragment = template.content;
    fragment.querySelectorAll('head, script, style, template, noscript, iframe, object, svg, math, [hidden]')
      .forEach(node => node.remove());
    fragment.querySelectorAll(blockElements).forEach(node => { node.before(' '); node.after(' '); });
    fragment.querySelectorAll('img[alt]').forEach(node => node.replaceWith(` ${node.alt} `));
    text = fragment.textContent;
  }
  text = text.normalize('NFC').replace(/\s+/g, ' ').trim();
  body = { text, searchable: text.toLocaleLowerCase() };
  cachedBodies.set(article, body);
  return body;
}

export function searchArticles(articles, query, folder = '') {
  const results = new Map();
  for (const article of articles) {
    const path = articleFolderPath(article);
    if (folder && path !== folder && !path.startsWith(`${folder}/`)) continue;
    const metadata = [article.title, article.excerpt, path, ...(article.tags ?? [])];
    const { text, searchable } = readableBody(article);
    const match = searchable.indexOf(query);
    if (match === -1 && !metadata.some(value => value && searchText(value).includes(query))) continue;
    let snippet;
    if (match !== -1) {
      const start = Math.max(0, match - 24);
      const end = Math.min(text.length, match + Math.max(query.length, 20) + 24);
      snippet = `${start ? '…' : ''}${text.slice(start, end).trim()}${end < text.length ? '…' : ''}`;
    }
    results.set(article, snippet);
  }
  return results;
}
