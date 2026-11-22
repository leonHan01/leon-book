import { defaultArticleFolder, maximumArticleFolderDepth } from '../shared/article-placement.js';

const folderNames = new Intl.Collator(undefined, { sensitivity: 'accent' });

function pathParts(path) {
  return typeof path === 'string' ? path.replaceAll('\\', '/').normalize('NFC').split('/').filter(Boolean) : [];
}

export function articleFolderPath(article) {
  return pathParts(article.sourceRelativePath).slice(0, -1).slice(0, maximumArticleFolderDepth).join('/') || defaultArticleFolder;
}

export function parentFolderPath(path) {
  return path.slice(0, Math.max(0, path.lastIndexOf('/')));
}

export function buildArticleDirectory(articles, paths = []) {
  const root = { name: '', path: '', folders: [], articles: [] };
  const directories = new Map([['', root]]);

  function addFolder(parts) {
    let folder = root;
    for (const name of parts) {
      const path = folder.path ? `${folder.path}/${name}` : name;
      let child = directories.get(path);
      if (!child) {
        child = { name, path, folders: [], articles: [] };
        directories.set(path, child);
        folder.folders.push(child);
      }
      folder = child;
    }
    return folder;
  }

  for (const path of paths) addFolder(pathParts(path).slice(0, maximumArticleFolderDepth));
  for (const article of articles) addFolder(articleFolderPath(article).split('/')).articles.push(article);
  for (const folder of directories.values()) {
    folder.folders.sort((a, b) => folderNames.compare(a.name, b.name) || a.path.localeCompare(b.path));
  }
  return directories;
}
