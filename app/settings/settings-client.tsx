"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import type { ArticleSummary } from "../article-types";
import {
  BlogRequestError,
  deleteArticle as removeArticle,
  getVersionedSiteSettings,
  listArticles,
  putSiteSettings,
} from "../../lib/blog-client";
import {
  DEFAULT_SITE_SETTINGS,
  applySiteTheme,
  normalizeSiteSettings,
  type HomeCopy,
  type HomeFallbackEntry,
  type HomeFrame,
  type HomeStyleSettings,
  type SiteLanguage,
  type SiteSettings,
} from "../site-settings";
import ThemePicker from "../theme-picker";

function TextSetting({ id, label, value, multiline = false, onChange }: { id: string; label: string; value: string; multiline?: boolean; onChange: (value: string) => void }) {
  return (
    <div className="setting-row">
      <label htmlFor={id}>{label}</label>
      {multiline ? <textarea id={id} rows={4} value={value} onChange={(event) => onChange(event.target.value)} /> : <input id={id} value={value} onChange={(event) => onChange(event.target.value)} />}
    </div>
  );
}

function ColorSetting({ id, label, value, onChange }: { id: string; label: string; value: string; onChange: (value: string) => void }) {
  return (
    <div className="setting-row color-setting-row">
      <label htmlFor={id}>{label}</label>
      <div className="color-setting-control"><input id={id} type="color" value={value} onChange={(event) => onChange(event.target.value)} /><code>{value}</code></div>
    </div>
  );
}

function ToggleSetting({ id, label, checked, onChange }: { id: string; label: string; checked: boolean; onChange: (checked: boolean) => void }) {
  return (
    <div className="setting-row setting-toggle-row">
      <label htmlFor={id}>{label}</label>
      <label className="setting-toggle" htmlFor={id}>
        <input id={id} type="checkbox" checked={checked} onChange={(event) => onChange(event.target.checked)} />
        <span aria-hidden="true" />
      </label>
    </div>
  );
}

const settingsCopy = {
  en: {
    eyebrow: "05 / Site settings",
    title: "Make the notebook yours.",
    intro: "Choose how the public journal looks, speaks, and presents your work.",
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
    articlesHint: "Manage drafts and published notes stored with this site.",
    noArticles: "No saved articles yet.",
    draft: "Draft",
    published: "Published",
    edit: "Edit",
    delete: "Delete",
    deleting: "Deleting…",
    deleteConfirm: "Delete this article and its media files? This cannot be undone.",
    articleLoadError: "Could not load saved articles.",
    data: "Durable site data",
    dataHint: "Site settings, articles, images, and videos stay in this Mac's local Notebook 36 folder.",
    reset: "Reset to defaults",
    saved: "Settings saved to the site",
    back: "Back to notebook",
  },
  zh: {
    eyebrow: "05 / 网站设置",
    title: "把这个日志变成你的空间。",
    intro: "调整公开日志的语言、气质和排版，让所有访客看到一致的站点。",
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
    articlesHint: "管理持久保存在站点中的草稿与已发布文章。",
    noArticles: "还没有保存的文章。",
    draft: "草稿",
    published: "已发布",
    edit: "编辑",
    delete: "删除",
    deleting: "删除中…",
    deleteConfirm: "确定删除这篇文章及其媒体文件吗？此操作无法撤销。",
    articleLoadError: "无法读取已保存的文章。",
    data: "持久站点数据",
    dataHint: "站点设置、文章、图片和视频只保存在这台 Mac 的 Notebook 36 本地目录中。",
    reset: "恢复默认设置",
    saved: "设置已保存到站点",
    back: "返回日志",
  },
} as const;

const homeEditorCopy = {
  en: {
    title: "Homepage editor",
    hint: "Edit the homepage copy, media, colors, sections, and layout. Changes save automatically.",
    identity: "Brand and navigation",
    identityHint: "Shape the first impression and the main links.",
    brandMark: "Brand mark",
    brandName: "Brand name",
    brandSubtitle: "Brand subtitle",
    navJournal: "Journal link",
    navFrames: "Frames link",
    navAbout: "About link",
    navSettings: "Settings link",
    navWrite: "Write button",
    search: "Search",
    searchLabel: "Search label",
    searchPlaceholder: "Search placeholder",
    searchAria: "Search accessibility label",
    clearSearchAria: "Clear-search accessibility label",
    hero: "Hero section",
    heroHint: "The opening message visitors see first.",
    issueLabel: "Issue label",
    heroTitleLead: "Headline first line",
    heroTitleEmphasis: "Headline emphasis",
    heroTitleTail: "Headline final line",
    heroIntro: "Introduction",
    heroCta: "Hero link",
    heroStampNumber: "Stamp number",
    heroStampLines: "Stamp lines (one per line)",
    featured: "Featured section",
    featuredHint: "Labels around the leading article.",
    featuredKicker: "Section kicker",
    featuredTitle: "Section title",
    featuredNote: "Section note",
    featuredImageLabel: "Image label",
    featuredReadAria: "Featured-link accessibility label",
    recent: "Recent notes section",
    recentHint: "The article grid and its filters.",
    recentKicker: "Section kicker",
    recentTitle: "Section title",
    recentFilterAria: "Filter accessibility label",
    recentReadMore: "Read-more link",
    recentEmpty: "Empty search message",
    fallback: "Default note cards",
    fallbackHint: "These appear only when no published articles are available.",
    category: "Category",
    date: "Date",
    readTime: "Read time",
    titleField: "Title",
    excerpt: "Excerpt",
    frames: "Visual archive",
    framesHint: "Edit the three still images and their captions.",
    frameImage: "Image URL",
    frameAlt: "Image description",
    frameCaption: "Caption",
    motion: "Motion card",
    motionHint: "Replace the video and poster used in the archive.",
    motionLabel: "Motion label",
    motionAria: "Video accessibility label",
    motionCaption: "Motion caption",
    videoUrl: "Video URL",
    posterUrl: "Poster image URL",
    about: "About section",
    aboutHint: "Introduce the person behind the notebook.",
    aboutKicker: "Section kicker",
    aboutTitleLead: "Heading first line",
    aboutTitleEmphasis: "Heading emphasis",
    aboutBio: "Biography",
    aboutCta: "Contact link",
    contactEmail: "Contact email",
    footer: "Footer",
    footerHint: "The final line of the homepage.",
    footerCopyright: "Copyright line",
    footerBackToTop: "Back-to-top link",
    footerInstagram: "Instagram link",
    footerEmail: "Email link",
    style: "Homepage style and layout",
    styleHint: "Control the visual system without editing CSS.",
    palette: "Color palette",
    paletteTheme: "Use selected theme",
    paletteCustom: "Use custom colors",
    accentColor: "Accent color",
    paperColor: "Paper color",
    paperDeepColor: "Deep paper color",
    inkColor: "Ink color",
    mutedColor: "Muted text color",
    lineColor: "Border color",
    contentWidth: "Content width",
    sidePadding: "Side padding",
    headerHeight: "Header height",
    sectionSpacing: "Section spacing",
    spacingCompact: "Compact",
    spacingComfortable: "Comfortable",
    spacingAiry: "Airy",
    notesColumns: "Note columns",
    heroLayout: "Hero layout",
    heroSplit: "Split with stamp",
    heroStacked: "Stacked",
    framesLayout: "Frames layout",
    framesCollage: "Collage",
    framesStacked: "Stacked grid",
    headingScale: "Heading scale",
    bodyScale: "Body scale",
    compact: "Compact",
    standard: "Standard",
    display: "Display",
    large: "Large",
    cornerStyle: "Card corners",
    square: "Square",
    soft: "Soft",
    serifFont: "Display font",
    fraunces: "Fraunces",
    georgia: "Georgia",
    system: "System serif",
    visibleSections: "Visible sections",
    showFeatured: "Show featured section",
    showRecent: "Show recent notes",
    showFrames: "Show visual archive",
    showAbout: "Show about section",
    showFooter: "Show footer",
  },
  zh: {
    title: "首页编辑器",
    hint: "编辑首页文案、媒体、颜色、区块和排版，修改会自动保存。",
    identity: "品牌与导航",
    identityHint: "调整访客看到的第一印象和主要链接。",
    brandMark: "品牌标记",
    brandName: "品牌名称",
    brandSubtitle: "品牌副标题",
    navJournal: "日志链接",
    navFrames: "影像链接",
    navAbout: "关于链接",
    navSettings: "设置链接",
    navWrite: "写文章按钮",
    search: "搜索",
    searchLabel: "搜索标签",
    searchPlaceholder: "搜索占位提示",
    searchAria: "搜索辅助标签",
    clearSearchAria: "清除搜索辅助标签",
    hero: "首屏区域",
    heroHint: "访客进入首页最先看到的信息。",
    issueLabel: "期号标签",
    heroTitleLead: "标题第一行",
    heroTitleEmphasis: "标题强调文字",
    heroTitleTail: "标题最后一行",
    heroIntro: "首屏介绍",
    heroCta: "首屏链接",
    heroStampNumber: "印章数字",
    heroStampLines: "印章文字（每行一项）",
    featured: "精选文章区",
    featuredHint: "精选文章周围的提示文案。",
    featuredKicker: "区块眉题",
    featuredTitle: "区块标题",
    featuredNote: "区块说明",
    featuredImageLabel: "图片标签",
    featuredReadAria: "精选文章链接辅助标签",
    recent: "最近文章区",
    recentHint: "文章网格和筛选器文案。",
    recentKicker: "区块眉题",
    recentTitle: "区块标题",
    recentFilterAria: "筛选器辅助标签",
    recentReadMore: "继续阅读链接",
    recentEmpty: "无搜索结果提示",
    fallback: "默认文章卡片",
    fallbackHint: "没有已发布文章时才会显示这些卡片。",
    category: "分类",
    date: "日期",
    readTime: "阅读时长",
    titleField: "标题",
    excerpt: "摘要",
    frames: "视觉档案",
    framesHint: "编辑三张图片和对应说明。",
    frameImage: "图片地址",
    frameAlt: "图片描述",
    frameCaption: "图片说明",
    motion: "动态卡片",
    motionHint: "替换视觉档案中的视频和封面图。",
    motionLabel: "动态标签",
    motionAria: "视频辅助描述",
    motionCaption: "动态说明",
    videoUrl: "视频地址",
    posterUrl: "封面图地址",
    about: "关于区域",
    aboutHint: "介绍日志背后的人。",
    aboutKicker: "区块眉题",
    aboutTitleLead: "标题第一行",
    aboutTitleEmphasis: "标题强调文字",
    aboutBio: "个人介绍",
    aboutCta: "联系链接",
    contactEmail: "联系邮箱",
    footer: "页脚",
    footerHint: "首页最后一行信息。",
    footerCopyright: "版权信息",
    footerBackToTop: "返回顶部链接",
    footerInstagram: "Instagram 链接",
    footerEmail: "邮件链接",
    style: "首页样式与排版",
    styleHint: "无需修改 CSS，即可控制视觉系统。",
    palette: "颜色方案",
    paletteTheme: "使用当前主题",
    paletteCustom: "使用自定义颜色",
    accentColor: "强调色",
    paperColor: "纸张颜色",
    paperDeepColor: "深层纸张颜色",
    inkColor: "墨色",
    mutedColor: "次要文字颜色",
    lineColor: "边框颜色",
    contentWidth: "内容宽度",
    sidePadding: "左右留白",
    headerHeight: "顶部高度",
    sectionSpacing: "区块间距",
    spacingCompact: "紧凑",
    spacingComfortable: "舒适",
    spacingAiry: "宽松",
    notesColumns: "文章列数",
    heroLayout: "首屏排版",
    heroSplit: "左右分栏",
    heroStacked: "上下堆叠",
    framesLayout: "影像排版",
    framesCollage: "拼贴",
    framesStacked: "堆叠网格",
    headingScale: "标题大小",
    bodyScale: "正文大小",
    compact: "紧凑",
    standard: "标准",
    display: "展示",
    large: "大",
    cornerStyle: "卡片圆角",
    square: "直角",
    soft: "柔和圆角",
    serifFont: "展示字体",
    fraunces: "Fraunces",
    georgia: "Georgia",
    system: "系统衬线",
    visibleSections: "显示区块",
    showFeatured: "显示精选文章区",
    showRecent: "显示最近文章",
    showFrames: "显示视觉档案",
    showAbout: "显示关于区域",
    showFooter: "显示页脚",
  },
} as const;

export default function SettingsClient() {
  const [settings, setSettings] = useState<SiteSettings>(DEFAULT_SITE_SETTINGS);
  const [settingsReady, setSettingsReady] = useState(false);
  const [settingsSaveState, setSettingsSaveState] = useState<"idle" | "saving" | "saved" | "error" | "conflict">("idle");
  const [articles, setArticles] = useState<ArticleSummary[]>([]);
  const [articlesLoading, setArticlesLoading] = useState(true);
  const [articlesError, setArticlesError] = useState(false);
  const [deletingSlug, setDeletingSlug] = useState<string | null>(null);
  const latestSave = useRef(0);
  const settingsSaveQueue = useRef<Promise<void>>(Promise.resolve());
  const pendingSettingsSave = useRef<SiteSettings | null>(null);
  const settingsUpdatedAt = useRef<string | null>(null);
  const settingsConflict = useRef(false);
  const skipInitialSettingsSave = useRef(true);
  const language = settings.language;
  const copy = settingsCopy[language];
  const homeCopy = settings.home.copy[language];
  const homeLabels = homeEditorCopy[language];

  useEffect(() => {
    let active = true;
    getVersionedSiteSettings()
      .then(({ settings: payload, updatedAt }) => {
        if (!active) return;
        settingsUpdatedAt.current = updatedAt;
        setSettings(normalizeSiteSettings(payload));
        setSettingsReady(true);
      })
      .catch(() => {
        if (!active) return;
        setSettings(DEFAULT_SITE_SETTINGS);
        setSettingsSaveState("error");
      });
    return () => { active = false; };
  }, []);

  useEffect(() => {
    applySiteTheme(settings.theme);
  }, [settings.theme]);

  useEffect(() => {
    let active = true;
    listArticles({ includeDrafts: true })
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

  useEffect(() => {
    if (!settingsReady) return;
    if (settingsConflict.current) {
      setSettingsSaveState("conflict");
      return;
    }
    if (skipInitialSettingsSave.current) {
      skipInitialSettingsSave.current = false;
      return;
    }
    const saveId = ++latestSave.current;
    pendingSettingsSave.current = settings;
    setSettingsSaveState("saving");
    const timer = window.setTimeout(() => {
      const pending = settingsSaveQueue.current
        .catch(() => undefined)
        .then(async () => {
          if (settingsConflict.current) return;
          const saved = await putSiteSettings(settings, {
            expectedUpdatedAt: settingsUpdatedAt.current,
          });
          settingsUpdatedAt.current = saved.updatedAt;
          if (pendingSettingsSave.current === settings) pendingSettingsSave.current = null;
          if (latestSave.current === saveId) setSettingsSaveState("saved");
        })
        .catch((error: unknown) => {
          if (error instanceof BlogRequestError && error.status === 409) {
            settingsConflict.current = true;
            pendingSettingsSave.current = null;
            setSettingsSaveState("conflict");
            return;
          }
          if (latestSave.current === saveId) setSettingsSaveState("error");
        });
      settingsSaveQueue.current = pending;
    }, 500);
    return () => window.clearTimeout(timer);
  }, [settings, settingsReady]);

  useEffect(() => {
    const flushPendingSettings = () => {
      const pending = pendingSettingsSave.current;
      if (!pending || settingsConflict.current) return;
      pendingSettingsSave.current = null;
      const flushed = settingsSaveQueue.current
        .catch(() => undefined)
        .then(async () => {
          if (settingsConflict.current) return;
          const saved = await putSiteSettings(pending, {
            expectedUpdatedAt: settingsUpdatedAt.current,
            keepalive: true,
          });
          settingsUpdatedAt.current = saved.updatedAt;
        })
        .then(() => undefined)
        .catch((error: unknown) => {
          if (error instanceof BlogRequestError && error.status === 409) {
            settingsConflict.current = true;
            setSettingsSaveState("conflict");
          }
        });
      settingsSaveQueue.current = flushed;
    };
    window.addEventListener("pagehide", flushPendingSettings);
    return () => {
      window.removeEventListener("pagehide", flushPendingSettings);
      flushPendingSettings();
    };
  }, []);

  useEffect(() => {
    if (settingsSaveState !== "saving" && settingsSaveState !== "error" && settingsSaveState !== "conflict") return;
    const warnBeforeUnload = (event: BeforeUnloadEvent) => {
      event.preventDefault();
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", warnBeforeUnload);
    return () => window.removeEventListener("beforeunload", warnBeforeUnload);
  }, [settingsSaveState]);

  const updateSettings = (next: Partial<SiteSettings>) => {
    const updated = { ...settings, ...next };
    setSettings(updated);
  };

  const updateHomeCopy = (next: Partial<HomeCopy>) => {
    updateSettings({ home: { ...settings.home, copy: { ...settings.home.copy, [language]: { ...homeCopy, ...next } } } });
  };

  const updateHomeStyle = (next: Partial<HomeStyleSettings>) => {
    updateSettings({ home: { ...settings.home, style: { ...settings.home.style, ...next } } });
  };

  const updateFrame = (index: number, next: Partial<HomeFrame>) => {
    updateSettings({ home: { ...settings.home, frames: settings.home.frames.map((frame, frameIndex) => frameIndex === index ? { ...frame, ...next } : frame) } });
  };

  const updateFallbackEntry = (index: number, next: Partial<HomeFallbackEntry>) => {
    updateSettings({ home: { ...settings.home, fallbackEntries: settings.home.fallbackEntries.map((entry, entryIndex) => entryIndex === index ? { ...entry, ...next } : entry) } });
  };

  const updateHomeMotion = (next: Partial<SiteSettings["home"]["motion"]>) => {
    updateSettings({ home: { ...settings.home, motion: { ...settings.home.motion, ...next } } });
  };

  const resetSettings = () => {
    setSettings(DEFAULT_SITE_SETTINGS);
  };

  const deleteArticle = async (article: ArticleSummary) => {
    if (!window.confirm(copy.deleteConfirm)) return;
    setDeletingSlug(article.slug);
    try {
      await removeArticle(article.slug, article.updatedAt);
      setArticles((current) => current.filter((savedArticle) => savedArticle.slug !== article.slug));
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

              <div className="settings-field-grid">
                <div className="setting-row">
                  <div><label htmlFor="settings-language">{copy.language}</label><p>{copy.languageHint}</p></div>
                  <select id="settings-language" value={settings.language} onChange={(event) => updateSettings({ language: event.target.value as SiteLanguage })}>
                    <option value="en">{copy.languageEnglish}</option>
                    <option value="zh">{copy.languageChinese}</option>
                  </select>
                </div>
                <div className="setting-row theme-setting-row">
                  <div><label>{copy.theme}</label><p>{language === "zh" ? "点击色卡即可即时切换，当前选择会同步到整个写作空间。" : "Choose a swatch to change the entire writing space instantly."}</p></div>
                  <ThemePicker language={language} value={settings.theme} onChange={(theme) => updateSettings({ theme })} />
                </div>
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

              <div className="settings-field-grid">
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
              </div>
              <div className="setting-row setting-toggle-row">
                <div><label htmlFor="settings-prompt">{copy.prompt}</label><p>{copy.promptHint}</p></div>
                <label className="setting-toggle" htmlFor="settings-prompt">
                  <input id="settings-prompt" type="checkbox" checked={settings.showWritingPrompt} onChange={(event) => updateSettings({ showWritingPrompt: event.target.checked })} />
                  <span aria-hidden="true" />
                </label>
              </div>
            </section>

            <section className="settings-card homepage-editor-card">
              <div className="settings-card-heading">
                <div>
                  <p className="eyebrow">03</p>
                  <h2>{homeLabels.title}</h2>
                </div>
                <p>{homeLabels.hint}</p>
              </div>

              <div className="settings-subheading"><h3>{homeLabels.identity}</h3><p>{homeLabels.identityHint}</p></div>
              <div className="settings-field-grid">
                <TextSetting id="home-brand-mark" label={homeLabels.brandMark} value={homeCopy.brandMark} onChange={(value) => updateHomeCopy({ brandMark: value })} />
                <TextSetting id="home-brand-name" label={homeLabels.brandName} value={homeCopy.brandName} onChange={(value) => updateHomeCopy({ brandName: value })} />
                <TextSetting id="home-brand-subtitle" label={homeLabels.brandSubtitle} value={homeCopy.brandSubtitle} onChange={(value) => updateHomeCopy({ brandSubtitle: value })} />
              </div>
              <div className="settings-subheading"><h3>{homeLabels.search}</h3></div>
              <div className="settings-field-grid">
                <TextSetting id="home-search-label" label={homeLabels.searchLabel} value={homeCopy.searchLabel} onChange={(value) => updateHomeCopy({ searchLabel: value })} />
                <TextSetting id="home-search-placeholder" label={homeLabels.searchPlaceholder} value={homeCopy.searchPlaceholder} onChange={(value) => updateHomeCopy({ searchPlaceholder: value })} />
                <TextSetting id="home-search-aria" label={homeLabels.searchAria} value={homeCopy.searchAria} onChange={(value) => updateHomeCopy({ searchAria: value })} />
                <TextSetting id="home-clear-search-aria" label={homeLabels.clearSearchAria} value={homeCopy.clearSearchAria} onChange={(value) => updateHomeCopy({ clearSearchAria: value })} />
              </div>
              <div className="settings-field-grid">
                <TextSetting id="home-nav-journal" label={homeLabels.navJournal} value={homeCopy.navJournal} onChange={(value) => updateHomeCopy({ navJournal: value })} />
                <TextSetting id="home-nav-frames" label={homeLabels.navFrames} value={homeCopy.navFrames} onChange={(value) => updateHomeCopy({ navFrames: value })} />
                <TextSetting id="home-nav-about" label={homeLabels.navAbout} value={homeCopy.navAbout} onChange={(value) => updateHomeCopy({ navAbout: value })} />
                <TextSetting id="home-nav-settings" label={homeLabels.navSettings} value={homeCopy.navSettings} onChange={(value) => updateHomeCopy({ navSettings: value })} />
                <TextSetting id="home-nav-write" label={homeLabels.navWrite} value={homeCopy.navWrite} onChange={(value) => updateHomeCopy({ navWrite: value })} />
              </div>

              <div className="settings-subheading"><h3>{homeLabels.hero}</h3><p>{homeLabels.heroHint}</p></div>
              <div className="settings-field-grid">
                <TextSetting id="home-issue-label" label={homeLabels.issueLabel} value={homeCopy.issueLabel} onChange={(value) => updateHomeCopy({ issueLabel: value })} />
                <TextSetting id="home-hero-title-lead" label={homeLabels.heroTitleLead} value={homeCopy.heroTitleLead} onChange={(value) => updateHomeCopy({ heroTitleLead: value })} />
                <TextSetting id="home-hero-title-emphasis" label={homeLabels.heroTitleEmphasis} value={homeCopy.heroTitleEmphasis} onChange={(value) => updateHomeCopy({ heroTitleEmphasis: value })} />
                <TextSetting id="home-hero-title-tail" label={homeLabels.heroTitleTail} value={homeCopy.heroTitleTail} onChange={(value) => updateHomeCopy({ heroTitleTail: value })} />
                <TextSetting id="home-hero-cta" label={homeLabels.heroCta} value={homeCopy.heroCta} onChange={(value) => updateHomeCopy({ heroCta: value })} />
                <TextSetting id="home-hero-stamp-number" label={homeLabels.heroStampNumber} value={homeCopy.heroStampNumber} onChange={(value) => updateHomeCopy({ heroStampNumber: value })} />
              </div>
              <TextSetting id="home-hero-intro" label={homeLabels.heroIntro} value={homeCopy.heroIntro} multiline onChange={(value) => updateHomeCopy({ heroIntro: value })} />
              <TextSetting id="home-hero-stamp-lines" label={homeLabels.heroStampLines} value={homeCopy.heroStampLines} multiline onChange={(value) => updateHomeCopy({ heroStampLines: value })} />

              <div className="settings-subheading"><h3>{homeLabels.featured}</h3><p>{homeLabels.featuredHint}</p></div>
              <div className="settings-field-grid">
                <TextSetting id="home-featured-kicker" label={homeLabels.featuredKicker} value={homeCopy.featuredKicker} onChange={(value) => updateHomeCopy({ featuredKicker: value })} />
                <TextSetting id="home-featured-title" label={homeLabels.featuredTitle} value={homeCopy.featuredTitle} onChange={(value) => updateHomeCopy({ featuredTitle: value })} />
                <TextSetting id="home-featured-image-label" label={homeLabels.featuredImageLabel} value={homeCopy.featuredImageLabel} onChange={(value) => updateHomeCopy({ featuredImageLabel: value })} />
                <TextSetting id="home-featured-read-aria" label={homeLabels.featuredReadAria} value={homeCopy.featuredReadAria} onChange={(value) => updateHomeCopy({ featuredReadAria: value })} />
              </div>
              <TextSetting id="home-featured-note" label={homeLabels.featuredNote} value={homeCopy.featuredNote} multiline onChange={(value) => updateHomeCopy({ featuredNote: value })} />

              <div className="settings-subheading"><h3>{homeLabels.recent}</h3><p>{homeLabels.recentHint}</p></div>
              <div className="settings-field-grid">
                <TextSetting id="home-recent-kicker" label={homeLabels.recentKicker} value={homeCopy.recentKicker} onChange={(value) => updateHomeCopy({ recentKicker: value })} />
                <TextSetting id="home-recent-title" label={homeLabels.recentTitle} value={homeCopy.recentTitle} onChange={(value) => updateHomeCopy({ recentTitle: value })} />
                <TextSetting id="home-recent-filter-aria" label={homeLabels.recentFilterAria} value={homeCopy.recentFilterAria} onChange={(value) => updateHomeCopy({ recentFilterAria: value })} />
                <TextSetting id="home-recent-read-more" label={homeLabels.recentReadMore} value={homeCopy.recentReadMore} onChange={(value) => updateHomeCopy({ recentReadMore: value })} />
                <TextSetting id="home-recent-empty" label={homeLabels.recentEmpty} value={homeCopy.recentEmpty} onChange={(value) => updateHomeCopy({ recentEmpty: value })} />
              </div>

              <div className="settings-subheading"><h3>{homeLabels.about}</h3><p>{homeLabels.aboutHint}</p></div>
              <div className="settings-field-grid">
                <TextSetting id="home-about-kicker" label={homeLabels.aboutKicker} value={homeCopy.aboutKicker} onChange={(value) => updateHomeCopy({ aboutKicker: value })} />
                <TextSetting id="home-about-title-lead" label={homeLabels.aboutTitleLead} value={homeCopy.aboutTitleLead} onChange={(value) => updateHomeCopy({ aboutTitleLead: value })} />
                <TextSetting id="home-about-title-emphasis" label={homeLabels.aboutTitleEmphasis} value={homeCopy.aboutTitleEmphasis} onChange={(value) => updateHomeCopy({ aboutTitleEmphasis: value })} />
                <TextSetting id="home-about-cta" label={homeLabels.aboutCta} value={homeCopy.aboutCta} onChange={(value) => updateHomeCopy({ aboutCta: value })} />
                <TextSetting id="home-contact-email" label={homeLabels.contactEmail} value={homeCopy.contactEmail} onChange={(value) => updateHomeCopy({ contactEmail: value })} />
              </div>
              <TextSetting id="home-about-bio" label={homeLabels.aboutBio} value={homeCopy.aboutBio} multiline onChange={(value) => updateHomeCopy({ aboutBio: value })} />

              <div className="settings-subheading"><h3>{homeLabels.footer}</h3><p>{homeLabels.footerHint}</p></div>
              <div className="settings-field-grid">
                <TextSetting id="home-footer-copyright" label={homeLabels.footerCopyright} value={homeCopy.footerCopyright} onChange={(value) => updateHomeCopy({ footerCopyright: value })} />
                <TextSetting id="home-footer-top" label={homeLabels.footerBackToTop} value={homeCopy.footerBackToTop} onChange={(value) => updateHomeCopy({ footerBackToTop: value })} />
                <TextSetting id="home-footer-instagram" label={homeLabels.footerInstagram} value={homeCopy.footerInstagram} onChange={(value) => updateHomeCopy({ footerInstagram: value })} />
                <TextSetting id="home-footer-email" label={homeLabels.footerEmail} value={homeCopy.footerEmail} onChange={(value) => updateHomeCopy({ footerEmail: value })} />
              </div>
            </section>

            <section className="settings-card homepage-editor-card">
              <div className="settings-card-heading">
                <div><p className="eyebrow">04</p><h2>{homeLabels.frames}</h2></div>
                <p>{homeLabels.framesHint}</p>
              </div>
              {settings.home.frames.map((frame, index) => (
                <div className="settings-media-editor" key={`frame-${index}`}>
                  <div className="settings-subheading"><h3>0{index + 1}</h3></div>
                  <div className="settings-field-grid">
                    <TextSetting id={`home-frame-${index}-url`} label={homeLabels.frameImage} value={frame.imageUrl} onChange={(value) => updateFrame(index, { imageUrl: value })} />
                    <TextSetting id={`home-frame-${index}-alt`} label={homeLabels.frameAlt} value={frame.imageAlt} onChange={(value) => updateFrame(index, { imageAlt: value })} />
                    <TextSetting id={`home-frame-${index}-caption`} label={homeLabels.frameCaption} value={frame.caption} onChange={(value) => updateFrame(index, { caption: value })} />
                  </div>
                </div>
              ))}
              <div className="settings-subheading"><h3>{homeLabels.motion}</h3><p>{homeLabels.motionHint}</p></div>
              <div className="settings-field-grid">
                <TextSetting id="home-motion-label" label={homeLabels.motionLabel} value={homeCopy.motionLabel} onChange={(value) => updateHomeCopy({ motionLabel: value })} />
                <TextSetting id="home-motion-aria" label={homeLabels.motionAria} value={homeCopy.motionAria} onChange={(value) => updateHomeCopy({ motionAria: value })} />
                <TextSetting id="home-motion-caption" label={homeLabels.motionCaption} value={homeCopy.motionCaption} onChange={(value) => updateHomeCopy({ motionCaption: value })} />
                <TextSetting id="home-motion-video" label={homeLabels.videoUrl} value={settings.home.motion.videoUrl} onChange={(value) => updateHomeMotion({ videoUrl: value })} />
                <TextSetting id="home-motion-poster" label={homeLabels.posterUrl} value={settings.home.motion.posterUrl} onChange={(value) => updateHomeMotion({ posterUrl: value })} />
              </div>
            </section>

            <section className="settings-card homepage-editor-card">
              <div className="settings-card-heading">
                <div><p className="eyebrow">05</p><h2>{homeLabels.fallback}</h2></div>
                <p>{homeLabels.fallbackHint}</p>
              </div>
              {settings.home.fallbackEntries.map((entry, index) => (
                <div className="settings-media-editor" key={`fallback-${index}`}>
                  <div className="settings-subheading"><h3>0{index + 1}</h3></div>
                  <div className="settings-field-grid">
                    <TextSetting id={`home-fallback-${index}-category`} label={homeLabels.category} value={entry.category} onChange={(value) => updateFallbackEntry(index, { category: value })} />
                    <TextSetting id={`home-fallback-${index}-date`} label={homeLabels.date} value={entry.date} onChange={(value) => updateFallbackEntry(index, { date: value })} />
                    <TextSetting id={`home-fallback-${index}-read-time`} label={homeLabels.readTime} value={entry.readTime} onChange={(value) => updateFallbackEntry(index, { readTime: value })} />
                    <TextSetting id={`home-fallback-${index}-title`} label={homeLabels.titleField} value={entry.title} onChange={(value) => updateFallbackEntry(index, { title: value })} />
                    <TextSetting id={`home-fallback-${index}-image`} label={homeLabels.frameImage} value={entry.image} onChange={(value) => updateFallbackEntry(index, { image: value })} />
                    <TextSetting id={`home-fallback-${index}-alt`} label={homeLabels.frameAlt} value={entry.imageAlt} onChange={(value) => updateFallbackEntry(index, { imageAlt: value })} />
                  </div>
                  <TextSetting id={`home-fallback-${index}-excerpt`} label={homeLabels.excerpt} value={entry.excerpt} multiline onChange={(value) => updateFallbackEntry(index, { excerpt: value })} />
                </div>
              ))}
            </section>

            <section className="settings-card homepage-editor-card">
              <div className="settings-card-heading">
                <div><p className="eyebrow">06</p><h2>{homeLabels.style}</h2></div>
                <p>{homeLabels.styleHint}</p>
              </div>
              <div className="setting-row">
                <label htmlFor="home-palette">{homeLabels.palette}</label>
                <select id="home-palette" value={settings.home.style.palette} onChange={(event) => updateHomeStyle({ palette: event.target.value as HomeStyleSettings["palette"] })}>
                  <option value="theme">{homeLabels.paletteTheme}</option>
                  <option value="custom">{homeLabels.paletteCustom}</option>
                </select>
              </div>
              {settings.home.style.palette === "custom" && <div className="settings-color-grid">
                <ColorSetting id="home-accent" label={homeLabels.accentColor} value={settings.home.style.accentColor} onChange={(value) => updateHomeStyle({ accentColor: value })} />
                <ColorSetting id="home-paper" label={homeLabels.paperColor} value={settings.home.style.paperColor} onChange={(value) => updateHomeStyle({ paperColor: value })} />
                <ColorSetting id="home-paper-deep" label={homeLabels.paperDeepColor} value={settings.home.style.paperDeepColor} onChange={(value) => updateHomeStyle({ paperDeepColor: value })} />
                <ColorSetting id="home-ink" label={homeLabels.inkColor} value={settings.home.style.inkColor} onChange={(value) => updateHomeStyle({ inkColor: value })} />
                <ColorSetting id="home-muted" label={homeLabels.mutedColor} value={settings.home.style.mutedColor} onChange={(value) => updateHomeStyle({ mutedColor: value })} />
                <ColorSetting id="home-line" label={homeLabels.lineColor} value={settings.home.style.lineColor} onChange={(value) => updateHomeStyle({ lineColor: value })} />
              </div>}
              <div className="settings-field-grid">
                <div className="setting-row"><label htmlFor="home-content-width">{homeLabels.contentWidth}</label><select id="home-content-width" value={settings.home.style.contentWidth} onChange={(event) => updateHomeStyle({ contentWidth: Number(event.target.value) as HomeStyleSettings["contentWidth"] })}><option value="1000">1000px</option><option value="1100">1100px</option><option value="1240">1240px</option><option value="1400">1400px</option></select></div>
                <div className="setting-row"><label htmlFor="home-side-padding">{homeLabels.sidePadding}</label><select id="home-side-padding" value={settings.home.style.sidePadding} onChange={(event) => updateHomeStyle({ sidePadding: Number(event.target.value) as HomeStyleSettings["sidePadding"] })}><option value="32">32px</option><option value="40">40px</option><option value="48">48px</option><option value="64">64px</option><option value="80">80px</option></select></div>
                <div className="setting-row"><label htmlFor="home-header-height">{homeLabels.headerHeight}</label><select id="home-header-height" value={settings.home.style.headerHeight} onChange={(event) => updateHomeStyle({ headerHeight: Number(event.target.value) as HomeStyleSettings["headerHeight"] })}><option value="72">72px</option><option value="86">86px</option><option value="100">100px</option></select></div>
                <div className="setting-row"><label htmlFor="home-spacing">{homeLabels.sectionSpacing}</label><select id="home-spacing" value={settings.home.style.sectionSpacing} onChange={(event) => updateHomeStyle({ sectionSpacing: event.target.value as HomeStyleSettings["sectionSpacing"] })}><option value="compact">{homeLabels.spacingCompact}</option><option value="comfortable">{homeLabels.spacingComfortable}</option><option value="airy">{homeLabels.spacingAiry}</option></select></div>
                <div className="setting-row"><label htmlFor="home-columns">{homeLabels.notesColumns}</label><select id="home-columns" value={settings.home.style.notesColumns} onChange={(event) => updateHomeStyle({ notesColumns: Number(event.target.value) as HomeStyleSettings["notesColumns"] })}><option value="2">2</option><option value="3">3</option><option value="4">4</option></select></div>
                <div className="setting-row"><label htmlFor="home-hero-layout">{homeLabels.heroLayout}</label><select id="home-hero-layout" value={settings.home.style.heroLayout} onChange={(event) => updateHomeStyle({ heroLayout: event.target.value as HomeStyleSettings["heroLayout"] })}><option value="split">{homeLabels.heroSplit}</option><option value="stacked">{homeLabels.heroStacked}</option></select></div>
                <div className="setting-row"><label htmlFor="home-frames-layout">{homeLabels.framesLayout}</label><select id="home-frames-layout" value={settings.home.style.framesLayout} onChange={(event) => updateHomeStyle({ framesLayout: event.target.value as HomeStyleSettings["framesLayout"] })}><option value="collage">{homeLabels.framesCollage}</option><option value="stacked">{homeLabels.framesStacked}</option></select></div>
                <div className="setting-row"><label htmlFor="home-heading-scale">{homeLabels.headingScale}</label><select id="home-heading-scale" value={settings.home.style.headingScale} onChange={(event) => updateHomeStyle({ headingScale: event.target.value as HomeStyleSettings["headingScale"] })}><option value="compact">{homeLabels.compact}</option><option value="standard">{homeLabels.standard}</option><option value="display">{homeLabels.display}</option></select></div>
                <div className="setting-row"><label htmlFor="home-body-scale">{homeLabels.bodyScale}</label><select id="home-body-scale" value={settings.home.style.bodyScale} onChange={(event) => updateHomeStyle({ bodyScale: event.target.value as HomeStyleSettings["bodyScale"] })}><option value="compact">{homeLabels.compact}</option><option value="standard">{homeLabels.standard}</option><option value="large">{homeLabels.large}</option></select></div>
                <div className="setting-row"><label htmlFor="home-corners">{homeLabels.cornerStyle}</label><select id="home-corners" value={settings.home.style.cornerStyle} onChange={(event) => updateHomeStyle({ cornerStyle: event.target.value as HomeStyleSettings["cornerStyle"] })}><option value="square">{homeLabels.square}</option><option value="soft">{homeLabels.soft}</option></select></div>
                <div className="setting-row"><label htmlFor="home-serif">{homeLabels.serifFont}</label><select id="home-serif" value={settings.home.style.serifFont} onChange={(event) => updateHomeStyle({ serifFont: event.target.value as HomeStyleSettings["serifFont"] })}><option value="fraunces">{homeLabels.fraunces}</option><option value="georgia">{homeLabels.georgia}</option><option value="system">{homeLabels.system}</option></select></div>
              </div>
              <div className="settings-subheading"><h3>{homeLabels.visibleSections}</h3></div>
              <div className="settings-toggle-grid">
                <ToggleSetting id="home-show-featured" label={homeLabels.showFeatured} checked={settings.home.style.showFeatured} onChange={(checked) => updateHomeStyle({ showFeatured: checked })} />
                <ToggleSetting id="home-show-recent" label={homeLabels.showRecent} checked={settings.home.style.showRecent} onChange={(checked) => updateHomeStyle({ showRecent: checked })} />
                <ToggleSetting id="home-show-frames" label={homeLabels.showFrames} checked={settings.home.style.showFrames} onChange={(checked) => updateHomeStyle({ showFrames: checked })} />
                <ToggleSetting id="home-show-about" label={homeLabels.showAbout} checked={settings.home.style.showAbout} onChange={(checked) => updateHomeStyle({ showAbout: checked })} />
                <ToggleSetting id="home-show-footer" label={homeLabels.showFooter} checked={settings.home.style.showFooter} onChange={(checked) => updateHomeStyle({ showFooter: checked })} />
              </div>
            </section>

            <section className="settings-card">
              <div className="settings-card-heading">
                <div>
                  <p className="eyebrow">07</p>
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
                        <div className="article-library-actions">
                          <Link className="settings-edit" href={`/write?slug=${encodeURIComponent(article.slug)}`}>{copy.edit}</Link>
                          <button className="settings-delete" type="button" onClick={() => void deleteArticle(article)} disabled={deletingSlug === article.slug}>
                            {deletingSlug === article.slug ? copy.deleting : copy.delete}
                          </button>
                        </div>
                      </div>
                    );
                  })}
                </div>
              )}
            </section>

            <div className="settings-actions">
              <button type="button" className="settings-reset" onClick={resetSettings}>{copy.reset}</button>
              <span className={`settings-saved ${settingsSaveState === "conflict" ? "error" : settingsSaveState}`}><span />{settingsSaveState === "conflict" ? (language === "zh" ? "其他标签页已修改设置，请刷新后重试" : "Settings changed in another tab; reload before retrying") : settingsSaveState === "error" ? (language === "zh" ? "保存失败" : "Save failed") : settingsSaveState === "saving" ? (language === "zh" ? "正在保存…" : "Saving…") : (language === "zh" ? "已保存到站点" : "Saved to site")}</span>
            </div>
          </div>

          <aside className="settings-aside">
            <div className="settings-note">
              <span className="settings-note-mark">36</span>
              <p className="eyebrow">{copy.data}</p>
              <p>{copy.dataHint}</p>
              <code>LOCAL · site-settings.json</code>
            </div>
          </aside>
        </div>
      </section>
    </main>
  );
}
