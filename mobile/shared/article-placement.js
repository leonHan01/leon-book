export const defaultArticleFolder = '未分类';
export const maximumArticleFolderDepth = 5;

export function validArticleDestination(path) {
  if (typeof path !== 'string' || path.trimStart() !== path || /[\\\u0000-\u001f\u007f]/.test(path)) return false;
  const parts = path.split('/');
  return parts.length <= maximumArticleFolderDepth && parts.every(part => part.trim() && !part.startsWith('.'));
}

export function articleSourcePath(folder, slug) {
  return `${folder}/${slug}.html`;
}
