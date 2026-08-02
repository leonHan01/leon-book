export type SiteLanguage = "en" | "zh";
export type SiteTheme = "paper" | "night" | "system";
export type DefaultEditorMode = "write" | "preview";

export type SiteSettings = {
  language: SiteLanguage;
  theme: SiteTheme;
  autoSaveDelay: 900 | 3000 | 5000;
  defaultEditorMode: DefaultEditorMode;
  showWritingPrompt: boolean;
};

export const SETTINGS_STORAGE_KEY = "notebook36-settings";

export const DEFAULT_SITE_SETTINGS: SiteSettings = {
  language: "en",
  theme: "paper",
  autoSaveDelay: 900,
  defaultEditorMode: "write",
  showWritingPrompt: true,
};

export const interfaceCopy = {
  en: {
    nav: { journal: "Journal", frames: "Frames", about: "About", settings: "Settings", write: "Write" },
    search: "Search the notebook",
    searchPlaceholder: "Try “attention” or “frames”",
    editor: {
      newNote: "New field note",
      title: "Write something down.",
      lede: "A quiet space for the thought, image, or small detail you want to keep.",
      shortcut: "⌘ / Ctrl + S to save",
      saving: "Saving to your work folder…",
      publishing: "Publishing to your notebook…",
      saved: "Saved automatically",
      published: "Published to your notebook",
      offline: "Storage service unavailable — retry when it is running",
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
      write: "Write",
      preview: "Preview",
      markdown: "Markdown-friendly",
      noteLabel: "Your note",
      notePlaceholder: "Start with the detail you keep thinking about…",
      blankLine: "Use a blank line to separate ideas.",
      drop: "Drop images or videos at the cursor",
      browse: "or click to insert at the cursor · PNG, JPG, WebP, MP4, WebM",
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
      title: "写下此刻的想法。",
      lede: "一个安静的空间，记录你想留下的念头、画面和细节。",
      shortcut: "⌘ / Ctrl + S 保存",
      saving: "正在保存到工作目录…",
      publishing: "正在发布到日志…",
      saved: "已自动保存",
      published: "文章已发布",
      offline: "存储服务不可用——启动服务后重试",
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
      write: "编辑",
      preview: "预览",
      markdown: "支持 Markdown",
      noteLabel: "正文",
      notePlaceholder: "从那个一直在脑海里回响的细节开始……",
      blankLine: "用空行分隔不同想法。",
      drop: "将图片或视频插入光标位置",
      browse: "或点击插入到光标位置 · PNG、JPG、WebP、MP4、WebM",
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

export function readSiteSettings(): SiteSettings {
  if (typeof window === "undefined") return DEFAULT_SITE_SETTINGS;
  try {
    const parsed = JSON.parse(window.localStorage.getItem(SETTINGS_STORAGE_KEY) ?? "null") as Partial<SiteSettings> | null;
    return {
      ...DEFAULT_SITE_SETTINGS,
      ...parsed,
      autoSaveDelay: parsed?.autoSaveDelay === 3000 || parsed?.autoSaveDelay === 5000 ? parsed.autoSaveDelay : DEFAULT_SITE_SETTINGS.autoSaveDelay,
      defaultEditorMode: parsed?.defaultEditorMode === "preview" ? "preview" : DEFAULT_SITE_SETTINGS.defaultEditorMode,
      language: parsed?.language === "zh" ? "zh" : DEFAULT_SITE_SETTINGS.language,
      theme: parsed?.theme === "night" || parsed?.theme === "system" ? parsed.theme : DEFAULT_SITE_SETTINGS.theme,
      showWritingPrompt: parsed?.showWritingPrompt !== false,
    };
  } catch {
    return DEFAULT_SITE_SETTINGS;
  }
}

export function saveSiteSettings(settings: SiteSettings) {
  window.localStorage.setItem(SETTINGS_STORAGE_KEY, JSON.stringify(settings));
}
