export type SiteLanguage = "en" | "zh";
export type SiteTheme = "paper" | "night" | "sunset" | "forest" | "ocean" | "mono" | "sketch" | "eink" | "system";
export type DefaultEditorMode = "write" | "preview";

export const SITE_THEME_OPTIONS = [
  { value: "paper", label: { en: "Paper", zh: "纸张" }, description: { en: "Warm editorial", zh: "温暖编辑感" } },
  { value: "night", label: { en: "Night", zh: "夜间" }, description: { en: "Quiet and focused", zh: "安静专注" } },
  { value: "sunset", label: { en: "Sunset", zh: "日落" }, description: { en: "Soft and expressive", zh: "柔和表达" } },
  { value: "forest", label: { en: "Forest", zh: "森林" }, description: { en: "Grounded and calm", zh: "沉静自然" } },
  { value: "ocean", label: { en: "Ocean", zh: "海洋" }, description: { en: "Clear and airy", zh: "清澈通透" } },
  { value: "mono", label: { en: "Mono", zh: "黑白" }, description: { en: "Crisp and minimal", zh: "利落极简" } },
  { value: "sketch", label: { en: "Sketchbook", zh: "手绘" }, description: { en: "Loose and handmade", zh: "随性手作感" } },
  { value: "eink", label: { en: "E-ink", zh: "墨水屏" }, description: { en: "Calm paper display", zh: "克制纸屏感" } },
  { value: "system", label: { en: "System", zh: "跟随系统" }, description: { en: "Follow your device", zh: "跟随设备设置" } },
] as const;

export type HomeCopy = {
  brandMark: string;
  brandName: string;
  brandSubtitle: string;
  navJournal: string;
  navFrames: string;
  navAbout: string;
  navSettings: string;
  navWrite: string;
  searchLabel: string;
  searchPlaceholder: string;
  searchAria: string;
  clearSearchAria: string;
  issueLabel: string;
  heroTitleLead: string;
  heroTitleEmphasis: string;
  heroTitleTail: string;
  heroIntro: string;
  heroCta: string;
  heroStampNumber: string;
  heroStampLines: string;
  featuredKicker: string;
  featuredTitle: string;
  featuredNote: string;
  featuredImageLabel: string;
  featuredReadAria: string;
  recentKicker: string;
  recentTitle: string;
  recentFilterAria: string;
  recentReadMore: string;
  recentEmpty: string;
  framesKicker: string;
  framesTitle: string;
  framesNote: string;
  motionLabel: string;
  motionAria: string;
  motionCaption: string;
  aboutKicker: string;
  aboutTitleLead: string;
  aboutTitleEmphasis: string;
  aboutBio: string;
  aboutCta: string;
  contactEmail: string;
  footerCopyright: string;
  footerBackToTop: string;
  footerInstagram: string;
  footerEmail: string;
};

export type HomeFrame = {
  imageUrl: string;
  imageAlt: string;
  caption: string;
};

export type HomeMotion = {
  videoUrl: string;
  posterUrl: string;
};

export type HomeFallbackEntry = {
  category: string;
  date: string;
  readTime: string;
  title: string;
  excerpt: string;
  image: string;
  imageAlt: string;
  accent: string;
};

export type HomeStyleSettings = {
  palette: "theme" | "custom";
  accentColor: string;
  paperColor: string;
  paperDeepColor: string;
  inkColor: string;
  mutedColor: string;
  lineColor: string;
  contentWidth: 1000 | 1100 | 1240 | 1400;
  sidePadding: 32 | 40 | 48 | 64 | 80;
  headerHeight: 72 | 86 | 100;
  sectionSpacing: "compact" | "comfortable" | "airy";
  notesColumns: 2 | 3 | 4;
  heroLayout: "split" | "stacked";
  framesLayout: "collage" | "stacked";
  headingScale: "compact" | "standard" | "display";
  bodyScale: "compact" | "standard" | "large";
  cornerStyle: "square" | "soft";
  serifFont: "fraunces" | "georgia" | "system";
  showFeatured: boolean;
  showRecent: boolean;
  showFrames: boolean;
  showAbout: boolean;
  showFooter: boolean;
};

export type HomeSettings = {
  copy: Record<SiteLanguage, HomeCopy>;
  fallbackEntries: HomeFallbackEntry[];
  frames: HomeFrame[];
  motion: HomeMotion;
  style: HomeStyleSettings;
};

export type SiteSettings = {
  language: SiteLanguage;
  theme: SiteTheme;
  autoSaveDelay: 900 | 3000 | 5000;
  defaultEditorMode: DefaultEditorMode;
  showWritingPrompt: boolean;
  home: HomeSettings;
};

export const SETTINGS_STORAGE_KEY = "notebook36-settings";

export function applySiteTheme(theme: SiteTheme) {
  if (typeof document === "undefined") return;
  const root = document.documentElement;
  root.classList.add("theme-transition");
  root.dataset.theme = theme;
  window.setTimeout(() => root.classList.remove("theme-transition"), 380);
}

const DEFAULT_HOME_COPY: Record<SiteLanguage, HomeCopy> = {
  en: {
    brandMark: "36",
    brandName: "Notebook",
    brandSubtitle: "by Alex Rivera",
    navJournal: "Journal",
    navFrames: "Frames",
    navAbout: "About",
    navSettings: "Settings",
    navWrite: "Write",
    searchLabel: "Search the notebook",
    searchPlaceholder: "Try “attention” or “frames”",
    searchAria: "Search entries",
    clearSearchAria: "Clear search",
    issueLabel: "Issue 07 · Spring / Summer 2025",
    heroTitleLead: "Notes on making,",
    heroTitleEmphasis: "noticing,",
    heroTitleTail: "and staying curious.",
    heroIntro: "A personal field guide to creative work, everyday rituals, and the images that stay with us.",
    heroCta: "Read the latest",
    heroStampNumber: "36",
    heroStampLines: "WRITING\nIMAGES\nMOTION",
    featuredKicker: "01 / Featured story",
    featuredTitle: "Start here",
    featuredNote: "A longer thought for a slower moment.",
    featuredImageLabel: "Field note 01",
    featuredReadAria: "Read featured story",
    recentKicker: "02 / The notebook",
    recentTitle: "Recent notes",
    recentFilterAria: "Filter entries",
    recentReadMore: "Keep reading",
    recentEmpty: "No notes found. Try another search.",
    framesKicker: "03 / Visual archive",
    framesTitle: "Frames",
    framesNote: "A moving and still collection of things worth remembering.",
    motionLabel: "Motion study / 01",
    motionAria: "A short motion study of a meadow",
    motionCaption: "Let the image breathe.",
    aboutKicker: "04 / About the author",
    aboutTitleLead: "Hi, I'm Alex.",
    aboutTitleEmphasis: "I make room for ideas.",
    aboutBio: "Writer, image-maker, and professional notice-taker. Notebook 36 is where I keep the threads: what I'm learning, what I'm looking at, and what I don't want to forget.",
    aboutCta: "Say hello",
    contactEmail: "hello@notebook36.com",
    footerCopyright: "© 2025 Alex Rivera",
    footerBackToTop: "Back to top ↑",
    footerInstagram: "Instagram",
    footerEmail: "Email",
  },
  zh: {
    brandMark: "36",
    brandName: "Notebook",
    brandSubtitle: "by Alex Rivera",
    navJournal: "日志",
    navFrames: "影像",
    navAbout: "关于",
    navSettings: "设置",
    navWrite: "写文章",
    searchLabel: "搜索日志",
    searchPlaceholder: "试试“专注”或“影像”",
    searchAria: "搜索文章",
    clearSearchAria: "清除搜索",
    issueLabel: "第 07 期 · 2025 春夏",
    heroTitleLead: "记录创作、",
    heroTitleEmphasis: "观察，",
    heroTitleTail: "以及保持好奇。",
    heroIntro: "一份关于创作、日常仪式，以及那些留在心里的画面的个人手册。",
    heroCta: "阅读最新文章",
    heroStampNumber: "36",
    heroStampLines: "文字\n影像\n动态",
    featuredKicker: "01 / 精选文章",
    featuredTitle: "从这里开始",
    featuredNote: "留给慢一点的时刻，一段更长的想法。",
    featuredImageLabel: "现场笔记 01",
    featuredReadAria: "阅读精选文章",
    recentKicker: "02 / 日志",
    recentTitle: "最近文章",
    recentFilterAria: "筛选文章",
    recentReadMore: "继续阅读",
    recentEmpty: "没有找到文章，换个关键词试试。",
    framesKicker: "03 / 视觉档案",
    framesTitle: "影像",
    framesNote: "记录那些值得记住的动态与静态片段。",
    motionLabel: "动态研究 / 01",
    motionAria: "一段草地的短片研究",
    motionCaption: "让画面自由呼吸。",
    aboutKicker: "04 / 关于作者",
    aboutTitleLead: "你好，我是 Alex。",
    aboutTitleEmphasis: "我为想法留出空间。",
    aboutBio: "作者、影像创作者，也是一名专业的细节记录者。Notebook 36 用来保存我正在学习的事、正在注视的东西，以及不想忘记的片段。",
    aboutCta: "来打个招呼",
    contactEmail: "hello@notebook36.com",
    footerCopyright: "© 2025 Alex Rivera",
    footerBackToTop: "回到顶部 ↑",
    footerInstagram: "Instagram",
    footerEmail: "邮件",
  },
};

const DEFAULT_HOME_SETTINGS: HomeSettings = {
  copy: DEFAULT_HOME_COPY,
  fallbackEntries: [
    {
      category: "Stories",
      date: "May 28, 2025",
      readTime: "8 min read",
      title: "The quiet craft of paying attention",
      excerpt: "On walking slower, collecting small signals, and making room for the detail that changes everything.",
      image: "https://images.unsplash.com/photo-1499750310107-5fef28a66643?auto=format&fit=crop&w=1500&q=90",
      imageAlt: "Notebook, coffee, and a camera on a wooden table",
      accent: "coral",
    },
    {
      category: "Stories",
      date: "May 12, 2025",
      readTime: "5 min read",
      title: "A room can be a compass",
      excerpt: "The spaces we return to quietly teach us what we value.",
      image: "https://images.unsplash.com/photo-1494438639946-1ebd1d20bf85?auto=format&fit=crop&w=1100&q=85",
      imageAlt: "Sunlit desk in a calm interior",
      accent: "sage",
    },
    {
      category: "Notes",
      date: "April 30, 2025",
      readTime: "3 min read",
      title: "In praise of unfinished lists",
      excerpt: "A list is not a contract. Sometimes it is just a place to keep the door open.",
      image: "",
      imageAlt: "",
      accent: "lavender",
    },
    {
      category: "Frames",
      date: "April 18, 2025",
      readTime: "",
      title: "Light studies / 04",
      excerpt: "A visual notebook from three late afternoons in the city.",
      image: "https://images.unsplash.com/photo-1493246507139-91e8fad9978e?auto=format&fit=crop&w=1100&q=85",
      imageAlt: "Hazy mountains in soft evening light",
      accent: "ink",
    },
    {
      category: "Notes",
      date: "April 04, 2025",
      readTime: "4 min read",
      title: "What I keep beside the bed",
      excerpt: "Three books, one pencil, and a question I am still learning how to ask.",
      image: "",
      imageAlt: "",
      accent: "butter",
    },
  ],
  frames: [
    {
      imageUrl: "https://images.unsplash.com/photo-1500534623283-312aade485b7?auto=format&fit=crop&w=1400&q=90",
      imageAlt: "A quiet road through a green landscape",
      caption: "Somewhere between here and there",
    },
    {
      imageUrl: "https://images.unsplash.com/photo-1500530855697-b586d89ba3ee?auto=format&fit=crop&w=900&q=85",
      imageAlt: "Sunlight over a misty hillside",
      caption: "Morning light, remembered",
    },
    {
      imageUrl: "https://images.unsplash.com/photo-1518005020951-eccb494ad742?auto=format&fit=crop&w=900&q=85",
      imageAlt: "Abstract red architectural corner",
      caption: "Geometry of a pause",
    },
  ],
  motion: {
    videoUrl: "https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4",
    posterUrl: "https://images.unsplash.com/photo-1470770841072-f978cf4d019e?auto=format&fit=crop&w=1200&q=85",
  },
  style: {
    palette: "theme",
    accentColor: "#f2644b",
    paperColor: "#f3f0e9",
    paperDeepColor: "#e8e2d7",
    inkColor: "#1f201d",
    mutedColor: "#76746d",
    lineColor: "#d1ccc0",
    contentWidth: 1240,
    sidePadding: 48,
    headerHeight: 86,
    sectionSpacing: "comfortable",
    notesColumns: 3,
    heroLayout: "split",
    framesLayout: "collage",
    headingScale: "standard",
    bodyScale: "standard",
    cornerStyle: "square",
    serifFont: "fraunces",
    showFeatured: true,
    showRecent: true,
    showFrames: true,
    showAbout: true,
    showFooter: true,
  },
};

export const DEFAULT_SITE_SETTINGS: SiteSettings = {
  language: "en",
  theme: "paper",
  autoSaveDelay: 900,
  defaultEditorMode: "write",
  showWritingPrompt: true,
  home: DEFAULT_HOME_SETTINGS,
};

export const interfaceCopy = {
  en: {
    nav: { journal: "Journal", frames: "Frames", about: "About", settings: "Settings", write: "Write" },
    search: "Search the notebook",
    searchPlaceholder: "Try “attention” or “frames”",
    editor: {
      newNote: "New field note",
      editNote: "Edit field note",
      title: "Write something down.",
      editTitle: "Shape this note again.",
      lede: "A quiet space for the thought, image, or small detail you want to keep.",
      loading: "Loading article…",
      loadError: "Could not load this article. Return to settings and try again.",
      shortcut: "⌘ / Ctrl + S to save",
      saving: "Saving locally…",
      publishing: "Publishing to your notebook…",
      saved: "Saved automatically",
      published: "Published to your notebook",
      offline: "The site could not save — check your connection and retry",
      conflict: "This article changed elsewhere — refresh before saving again",
      leaveWithoutSaving: "This draft could not be saved. Leave anyway? A device-local recovery copy will be kept.",
      dirty: "Unsaved changes",
      ready: "Auto-save is ready",
      words: "words",
      read: "min read",
      attachment: "attachment",
      attachments: "attachments",
      titleLabel: "Title",
      titlePlaceholder: "Give this note a name",
      introLabel: "Short intro",
      introOptional: "(optional)",
      introPlaceholder: "One sentence to frame the idea",
      categoryLabel: "Category",
      categoryPlaceholder: "e.g. Stories",
      tagsLabel: "Tags",
      tagsOptional: "(comma separated)",
      tagsPlaceholder: "attention, craft, rituals",
      bannerLabel: "Article banner",
      bannerHint: "Shown on the homepage and at the top of the article.",
      bannerPasteHint: "Click this panel, then paste an image with ⌘/Ctrl + V.",
      bannerChoose: "Choose banner image",
      bannerReplace: "Replace image",
      bannerRemove: "Remove banner",
      bannerAltLabel: "Image description",
      bannerAltPlaceholder: "Describe the banner for readers using assistive technology",
      bannerUploading: "Uploading banner…",
      write: "Write",
      preview: "Preview",
      markdown: "Markdown-friendly",
      noteLabel: "Your note",
      notePlaceholder: "Start with the detail you keep thinking about…",
      blankLine: "Use a blank line to separate ideas.",
      drop: "Drop media or paste images at the cursor",
      browse: "Click to choose · paste with ⌘/Ctrl + V · PNG, JPG, WebP, MP4, WebM",
      addMedia: "Add media ↗",
      checklist: "Writing checklist",
      checklistTitle: "Add a clear title",
      checklistIdea: "Start with one idea",
      checklistMedia: "Add media if it helps",
      promptLabel: "A small prompt",
      prompt: "What detail would you still remember tomorrow?",
      promptHint: "Take your time · there is no publish pressure.",
      filesGoTo: "Files go to",
      save: "Save now",
      saveDraft: "Save draft",
      draftSaved: "Draft saved ✓",
      publish: "Publish article",
      savingButton: "Saving…",
      publishingButton: "Publishing…",
      savedButton: "Saved ✓",
      publishedButton: "Published ✓",
      close: "Close editor",
      previewLabel: "Preview · how your note will read",
      untitled: "Untitled note",
      emptyPreview: "Your finished note will appear here as you write.",
    },
  },
  zh: {
    nav: { journal: "日志", frames: "影像", about: "关于", settings: "设置", write: "写文章" },
    search: "搜索日志",
    searchPlaceholder: "试试“专注”或“影像”",
    editor: {
      newNote: "新文章",
      editNote: "编辑文章",
      title: "写下此刻的想法。",
      editTitle: "重新打磨这篇文章。",
      lede: "一个安静的空间，记录你想留下的念头、画面和细节。",
      loading: "正在加载文章…",
      loadError: "无法加载这篇文章，请返回设置页重试。",
      shortcut: "⌘ / Ctrl + S 保存",
      saving: "正在保存到本机…",
      publishing: "正在发布到日志…",
      saved: "已自动保存",
      published: "文章已发布",
      offline: "站点暂时无法保存——请检查网络后重试",
      conflict: "文章已在别处更新——请刷新页面后再保存",
      leaveWithoutSaving: "这份草稿暂时无法保存，仍要离开吗？本设备会保留一份恢复副本。",
      dirty: "有未保存的修改",
      ready: "自动保存已准备好",
      words: "字",
      read: "分钟阅读",
      attachment: "个附件",
      attachments: "个附件",
      titleLabel: "标题",
      titlePlaceholder: "给这篇文章起个名字",
      introLabel: "文章摘要",
      introOptional: "（可选）",
      introPlaceholder: "用一句话概括这篇文章",
      categoryLabel: "文章分类",
      categoryPlaceholder: "例如：随笔、旅行、读书",
      tagsLabel: "文章标签",
      tagsOptional: "（用逗号分隔）",
      tagsPlaceholder: "专注，创作，生活",
      bannerLabel: "文章 Banner",
      bannerHint: "将在首页和文章详情顶部展示。",
      bannerPasteHint: "点击此区域，然后按 ⌘/Ctrl + V 粘贴图片。",
      bannerChoose: "选择 Banner 图片",
      bannerReplace: "更换图片",
      bannerRemove: "移除 Banner",
      bannerAltLabel: "图片描述",
      bannerAltPlaceholder: "为使用辅助阅读工具的读者描述这张图片",
      bannerUploading: "Banner 上传中…",
      write: "编辑",
      preview: "预览",
      markdown: "支持 Markdown",
      noteLabel: "正文",
      notePlaceholder: "从那个一直在脑海里回响的细节开始……",
      blankLine: "用空行分隔不同想法。",
      drop: "拖入媒体，或在光标位置直接粘贴图片",
      browse: "点击选择 · 按 ⌘/Ctrl + V 粘贴 · PNG、JPG、WebP、MP4、WebM",
      addMedia: "添加媒体 ↗",
      checklist: "写作清单",
      checklistTitle: "补充一个清晰的标题",
      checklistIdea: "先写下一个想法",
      checklistMedia: "需要时添加媒体",
      promptLabel: "一个小提示",
      prompt: "明天醒来，你还会记得哪个细节？",
      promptHint: "慢慢写，不需要急着发布。",
      filesGoTo: "文件将保存到",
      save: "立即保存",
      saveDraft: "保存草稿",
      draftSaved: "草稿已保存 ✓",
      publish: "发布文章",
      savingButton: "保存中…",
      publishingButton: "发布中…",
      savedButton: "已保存 ✓",
      publishedButton: "已发布 ✓",
      close: "关闭编辑器",
      previewLabel: "预览 · 文章发布后的样子",
      untitled: "未命名文章",
      emptyPreview: "你写下的内容会显示在这里。",
    },
  },
} as const;

function partialObject<T extends object>(value: unknown): Partial<T> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return {};
  return value as Partial<T>;
}

function isSiteTheme(value: unknown): value is SiteTheme {
  return SITE_THEME_OPTIONS.some((option) => option.value === value);
}

export function normalizeSiteSettings(value: unknown): SiteSettings {
  const parsed = partialObject<SiteSettings>(value);
  const storedHome = partialObject<HomeSettings>(parsed.home);
  const storedCopy = partialObject<Record<SiteLanguage, Partial<HomeCopy>>>(storedHome.copy);
  const storedFallbackEntries = Array.isArray(storedHome.fallbackEntries)
    ? storedHome.fallbackEntries.map((entry) => partialObject<HomeFallbackEntry>(entry))
    : [];
  const storedFrames = Array.isArray(storedHome.frames)
    ? storedHome.frames.map((frame) => partialObject<HomeFrame>(frame))
    : [];

  return {
    ...DEFAULT_SITE_SETTINGS,
    ...parsed,
    autoSaveDelay: parsed.autoSaveDelay === 3000 || parsed.autoSaveDelay === 5000
      ? parsed.autoSaveDelay
      : DEFAULT_SITE_SETTINGS.autoSaveDelay,
    defaultEditorMode: parsed.defaultEditorMode === "preview"
      ? "preview"
      : DEFAULT_SITE_SETTINGS.defaultEditorMode,
    language: parsed.language === "zh" ? "zh" : DEFAULT_SITE_SETTINGS.language,
    theme: isSiteTheme(parsed.theme) ? parsed.theme : DEFAULT_SITE_SETTINGS.theme,
    showWritingPrompt: parsed.showWritingPrompt !== false,
    home: {
      ...DEFAULT_HOME_SETTINGS,
      ...storedHome,
      copy: {
        en: { ...DEFAULT_HOME_COPY.en, ...(storedCopy.en ?? {}) },
        zh: { ...DEFAULT_HOME_COPY.zh, ...(storedCopy.zh ?? {}) },
      },
      fallbackEntries: DEFAULT_HOME_SETTINGS.fallbackEntries.map((entry, index) => ({
        ...entry,
        ...(storedFallbackEntries[index] ?? {}),
      })),
      frames: DEFAULT_HOME_SETTINGS.frames.map((frame, index) => ({
        ...frame,
        ...(storedFrames[index] ?? {}),
      })),
      motion: {
        ...DEFAULT_HOME_SETTINGS.motion,
        ...partialObject<HomeMotion>(storedHome.motion),
      },
      style: {
        ...DEFAULT_HOME_SETTINGS.style,
        ...partialObject<HomeStyleSettings>(storedHome.style),
      },
    },
  };
}

export function readSiteSettings(): SiteSettings {
  if (typeof window === "undefined") return DEFAULT_SITE_SETTINGS;
  try {
    const parsed: unknown = JSON.parse(window.localStorage.getItem(SETTINGS_STORAGE_KEY) ?? "null");
    return normalizeSiteSettings(parsed);
  } catch {
    return DEFAULT_SITE_SETTINGS;
  }
}

export function readSiteThemePreference(): SiteTheme | null {
  if (typeof window === "undefined") return null;
  try {
    const parsed = partialObject<SiteSettings>(
      JSON.parse(window.localStorage.getItem(SETTINGS_STORAGE_KEY) ?? "null"),
    );
    return isSiteTheme(parsed.theme) ? parsed.theme : null;
  } catch {
    return null;
  }
}

export function saveSiteThemePreference(theme: SiteTheme) {
  if (typeof window === "undefined") return;
  let current: Record<string, unknown> = {};
  try {
    current = partialObject<Record<string, unknown>>(
      JSON.parse(window.localStorage.getItem(SETTINGS_STORAGE_KEY) ?? "null"),
    );
  } catch {
    current = {};
  }
  window.localStorage.setItem(SETTINGS_STORAGE_KEY, JSON.stringify({ ...current, theme }));
}

export function saveSiteSettings(settings: SiteSettings) {
  window.localStorage.setItem(SETTINGS_STORAGE_KEY, JSON.stringify(settings));
}
