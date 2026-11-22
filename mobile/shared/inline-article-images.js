const prefix = '/leonbook-inline/';
const idPattern = '[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}';
const sourcePattern = new RegExp('^' + prefix + '(' + idPattern + ')$');
const attributePattern = new RegExp(' src="' + prefix + '(' + idPattern + ')"', 'g');

export const inlineArticlePath = id => prefix + id;
export const inlineArticleID = path => typeof path === 'string' ? sourcePattern.exec(path)?.[1] : undefined;

export function inlineArticleIDs(body) {
  return typeof body === 'string' ? new Set(Array.from(body.matchAll(attributePattern), match => match[1])) : new Set();
}

export function replaceInlineArticleImages(body, paths) {
  return body.replace(attributePattern, (attribute, id) => paths.has(id) ? ' src="' + paths.get(id) + '"' : attribute);
}
