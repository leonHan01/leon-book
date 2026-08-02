"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import type { StoredArticle } from "../article-types";
import {
  DEFAULT_SITE_SETTINGS,
  readSiteSettings,
  saveSiteSettings,
  type SiteLanguage,
  type SiteSettings,
  type SiteTheme,
} from "../site-settings";

const settingsCopy = {
  en: {
    eyebrow: "05 / Site settings",
    title: "Make the notebook yours.",
    intro: "Choose how the journal looks, speaks, and saves your work on this device.",
    appearance: "Appearance",
    appearanceHint: "Set the mood for your writing space.",
    language: "Interface language",
    languageHint: "This changes the navigation and editor controls.",
    languageEnglish: "English",
    languageChinese: "简体中文",
    theme: "Color theme",
    themePaper: "Paper · light",
    themeNight: "Night · dark",
    themeSystem: "System preference",
    writing: "Writing experience",
    writingHint: "Tune the editor to match your rhythm.",
    autoSave: "Auto-save timing",
    autoSaveHint: "How long to wait after your last change.",
    autoSaveFast: "After 1 second",
    autoSaveComfortable: "After 3 seconds",
    autoSaveSlow: "After 5 seconds",
    editorView: "Default editor view",
    editorWrite: "Write",
    editorPreview: "Preview",
    prompt: "Show writing prompt",
    promptHint: "Keep a small prompt beside the editor.",
    articles: "Article library",
    articlesHint: "Manage drafts and published notes in your work folder.",
    noArticles: "No saved articles yet.",
    draft: "Draft",
    published: "Published",
    delete: "Delete",
    deleting: "Deleting…",
    deleteConfirm: "Delete this article and its media files? This cannot be undone.",
    articleLoadError: "Could not load saved articles.",
    data: "Local preferences",
    dataHint: "These settings stay in your browser. Articles, images, and videos continue to save to your work folder.",
    reset: "Reset to defaults",
    saved: "Settings saved on this device",
    back: "Back to notebook",
  },
  zh: {
    eyebrow: "05 / 网站设置",
    title: "把这个日志变成你的空间。",
    intro: "调整界面的语言、气质和保存方式，让写作更符合你的节奏。",
    appearance: "外观",
    appearanceHint: "设置写作空间的整体氛围。",
    language: "界面语言",
    languageHint: "会改变导航和文章编辑器中的操作文案。",
    languageEnglish: "English",
    languageChinese: "简体中文",
    theme: "颜色主题",
    themePaper: "纸张 · 浅色",
    themeNight: "夜间 · 深色",
    themeSystem: "跟随系统",
    writing: "写作体验",
    writingHint: "让编辑器更贴合你的写作节奏。",
    autoSave: "自动保存时机",
    autoSaveHint: "最后一次修改后等待多久再保存。",
    autoSaveFast: "1 秒后保存",
    autoSaveComfortable: "3 秒后保存",
    autoSaveSlow: "5 秒后保存",
    editorView: "默认编辑视图",
    editorWrite: "编辑",
    editorPreview: "预览",
    prompt: "显示写作提示",
    promptHint: "在编辑器旁边保留一个小提示。",
    articles: "文章管理",
    articlesHint: "管理工作目录中的草稿和已发布文章。",
    noArticles: "还没有保存的文章。",
    draft: "草稿",
    published: "已发布",
    delete: "删除",
    deleting: "删除中…",
    deleteConfirm: "确定删除这篇文章及其媒体文件吗？此操作无法撤销。",
    articleLoadError: "无法读取已保存的文章。",
    data: "本地偏好",
    dataHint: "这些设置保存在当前浏览器中。文章、图片和视频仍会继续保存到你的工作目录。",
    reset: "恢复默认设置",
    saved: "设置已保存在此设备",
    back: "返回日志",
  },
} as const;

export default function SettingsPage() {
  const [settings, setSettings] = useState<SiteSettings>(DEFAULT_SITE_SETTINGS);
  const [articles, setArticles] = useState<StoredArticle[]>([]);
  const [articlesLoading, setArticlesLoading] = useState(true);
  const [articlesError, setArticlesError] = useState(false);
  const [deletingSlug, setDeletingSlug] = useState<string | null>(null);
  const language = settings.language;
  const copy = settingsCopy[language];

  useEffect(() => {
    // Local preferences are an external browser-side store; hydrate them after the first render.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setSettings(readSiteSettings());
  }, []);

  useEffect(() => {
    document.documentElement.dataset.theme = settings.theme;
  }, [settings.theme]);

  useEffect(() => {
    let active = true;
    fetch("http://localhost:8787/api/articles")
      .then((response) => response.ok ? response.json() as Promise<StoredArticle[]> : Promise.reject(new Error("load failed")))
      .then((savedArticles) => {
        if (!active) return;
        setArticles(Array.isArray(savedArticles) ? savedArticles : []);
        setArticlesLoading(false);
      })
      .catch(() => {
        if (!active) return;
        setArticlesError(true);
        setArticlesLoading(false);
      });
    return () => { active = false; };
  }, []);

  const updateSettings = (next: Partial<SiteSettings>) => {
    const updated = { ...settings, ...next };
    setSettings(updated);
    saveSiteSettings(updated);
  };

  const resetSettings = () => {
    setSettings(DEFAULT_SITE_SETTINGS);
    saveSiteSettings(DEFAULT_SITE_SETTINGS);
  };

  const deleteArticle = async (slug: string) => {
    if (!window.confirm(copy.deleteConfirm)) return;
    setDeletingSlug(slug);
    try {
      const response = await fetch(`http://localhost:8787/api/articles/${encodeURIComponent(slug)}`, { method: "DELETE" });
      if (!response.ok) throw new Error("delete failed");
      setArticles((current) => current.filter((article) => article.slug !== slug));
    } catch {
      setArticlesError(true);
    } finally {
      setDeletingSlug(null);
    }
  };

  return (
    <main className="settings-page">
      <header className="site-header settings-header">
        <Link className="brand" href="/" aria-label="Notebook 36 home">
          <span className="brand-mark">36</span>
          <span>
            <strong>Notebook</strong>
            <small>by Alex Rivera</small>
          </span>
        </Link>
        <Link className="settings-back" href="/">← {copy.back}</Link>
      </header>

      <section className="settings-wrap">
        <div className="settings-intro">
          <p className="eyebrow">{copy.eyebrow}</p>
          <h1>{copy.title}</h1>
          <p>{copy.intro}</p>
        </div>

        <div className="settings-layout">
          <div className="settings-form">
            <section className="settings-card">
              <div className="settings-card-heading">
                <div>
                  <p className="eyebrow">01</p>
                  <h2>{copy.appearance}</h2>
                </div>
                <p>{copy.appearanceHint}</p>
              </div>

              <div className="setting-row">
                <div><label htmlFor="settings-language">{copy.language}</label><p>{copy.languageHint}</p></div>
                <select id="settings-language" value={settings.language} onChange={(event) => updateSettings({ language: event.target.value as SiteLanguage })}>
                  <option value="en">{copy.languageEnglish}</option>
                  <option value="zh">{copy.languageChinese}</option>
                </select>
              </div>
              <div className="setting-row">
                <div><label htmlFor="settings-theme">{copy.theme}</label></div>
                <select id="settings-theme" value={settings.theme} onChange={(event) => updateSettings({ theme: event.target.value as SiteTheme })}>
                  <option value="paper">{copy.themePaper}</option>
                  <option value="night">{copy.themeNight}</option>
                  <option value="system">{copy.themeSystem}</option>
                </select>
              </div>
            </section>

            <section className="settings-card">
              <div className="settings-card-heading">
                <div>
                  <p className="eyebrow">02</p>
                  <h2>{copy.writing}</h2>
                </div>
                <p>{copy.writingHint}</p>
              </div>

              <div className="setting-row">
                <div><label htmlFor="settings-autosave">{copy.autoSave}</label><p>{copy.autoSaveHint}</p></div>
                <select id="settings-autosave" value={settings.autoSaveDelay} onChange={(event) => updateSettings({ autoSaveDelay: Number(event.target.value) as SiteSettings["autoSaveDelay"] })}>
                  <option value="900">{copy.autoSaveFast}</option>
                  <option value="3000">{copy.autoSaveComfortable}</option>
                  <option value="5000">{copy.autoSaveSlow}</option>
                </select>
              </div>
              <div className="setting-row">
                <div><label htmlFor="settings-editor-view">{copy.editorView}</label></div>
                <select id="settings-editor-view" value={settings.defaultEditorMode} onChange={(event) => updateSettings({ defaultEditorMode: event.target.value as SiteSettings["defaultEditorMode"] })}>
                  <option value="write">{copy.editorWrite}</option>
                  <option value="preview">{copy.editorPreview}</option>
                </select>
              </div>
              <div className="setting-row setting-toggle-row">
                <div><label htmlFor="settings-prompt">{copy.prompt}</label><p>{copy.promptHint}</p></div>
                <label className="setting-toggle" htmlFor="settings-prompt">
                  <input id="settings-prompt" type="checkbox" checked={settings.showWritingPrompt} onChange={(event) => updateSettings({ showWritingPrompt: event.target.checked })} />
                  <span aria-hidden="true" />
                </label>
              </div>
            </section>

            <section className="settings-card">
              <div className="settings-card-heading">
                <div>
                  <p className="eyebrow">03</p>
                  <h2>{copy.articles}</h2>
                </div>
                <p>{copy.articlesHint}</p>
              </div>

              {articlesLoading && <p className="article-library-state">Loading…</p>}
              {articlesError && <p className="article-library-state">{copy.articleLoadError}</p>}
              {!articlesLoading && !articlesError && !articles.length && <p className="article-library-state">{copy.noArticles}</p>}
              {!articlesLoading && !articlesError && articles.length > 0 && (
                <div className="article-library">
                  {articles.map((article) => {
                    const status = article.status === "published" ? copy.published : copy.draft;
                    return (
                      <div className="article-library-row" key={article.slug}>
                        <div>
                          <div className={`article-status ${article.status === "published" ? "is-published" : "is-draft"}`}>{status}</div>
                          <h3>{article.title}</h3>
                          <p>{new Date(article.updatedAt).toLocaleString(language === "zh" ? "zh-CN" : "en-US")}</p>
                        </div>
                        <button className="settings-delete" type="button" onClick={() => void deleteArticle(article.slug)} disabled={deletingSlug === article.slug}>
                          {deletingSlug === article.slug ? copy.deleting : copy.delete}
                        </button>
                      </div>
                    );
                  })}
                </div>
              )}
            </section>

            <div className="settings-actions">
              <button type="button" className="settings-reset" onClick={resetSettings}>{copy.reset}</button>
              <span className="settings-saved"><span />{copy.saved}</span>
            </div>
          </div>

          <aside className="settings-aside">
            <div className="settings-note">
              <span className="settings-note-mark">36</span>
              <p className="eyebrow">{copy.data}</p>
              <p>{copy.dataHint}</p>
              <code>notebook36-settings</code>
            </div>
          </aside>
        </div>
      </section>
    </main>
  );
}
