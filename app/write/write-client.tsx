"use client";

import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { ArticleStatus, StoredArticle } from "../article-types";
import { ContentImage } from "../content-image";
import { renderMarkdown } from "../markdown-renderer";
import { BlogRequestError, getArticle, getSiteSettings, saveArticle, uploadMedia } from "../../lib/blog-client";
import {
  DEFAULT_SITE_SETTINGS,
  applySiteTheme,
  interfaceCopy,
  normalizeSiteSettings,
  readSiteThemePreference,
  type SiteSettings,
} from "../site-settings";

type DraftMedia = {
  id: string;
  kind: "image" | "video";
  name: string;
  previewUrl: string;
  url?: string;
  status: "uploading" | "uploaded" | "error";
  size: number;
};

type DraftBanner = {
  alt: string;
  id: string;
  name: string;
  previewUrl: string;
  size: number;
  status: "uploading" | "uploaded" | "error";
  url?: string;
};

type EditorBlock =
  | { id: string; type: "text"; value: string }
  | { id: string; type: "media"; media: DraftMedia };

type TextEditorBlock = Extract<EditorBlock, { type: "text" }>;
type MediaEditorBlock = Extract<EditorBlock, { type: "media" }>;

type SaveState = "idle" | "dirty" | "saving" | "saved" | "publishing" | "published" | "offline" | "conflict";
type EditorMode = "write" | "preview";

type RecoveryDraft = {
  articleStatus: ArticleStatus;
  banner: DraftBanner | null;
  baseUpdatedAt?: string;
  blocks: EditorBlock[];
  draftCategory: string;
  draftExcerpt: string;
  draftSlug: string;
  draftTags: string;
  draftTitle: string;
  requestedSlug: string | null;
  savedAt: number;
};

const RECOVERY_PREFIX = "notebook36-recovery-v1:";
const RECOVERY_MAX_AGE = 30 * 24 * 60 * 60 * 1000;

function recoveryKey(requestedSlug: string | null) {
  return `${RECOVERY_PREFIX}${encodeURIComponent(requestedSlug ?? "new")}`;
}

function readRecoveryDraft(requestedSlug: string | null): RecoveryDraft | null {
  try {
    const value = JSON.parse(localStorage.getItem(recoveryKey(requestedSlug)) ?? "null") as unknown;
    if (!value || typeof value !== "object") return null;
    const draft = value as Record<string, unknown>;
    if (draft.requestedSlug !== requestedSlug || typeof draft.savedAt !== "number" || Date.now() - draft.savedAt > RECOVERY_MAX_AGE) return null;

    const blocks = Array.isArray(draft.blocks) ? draft.blocks.flatMap((value): EditorBlock[] => {
      if (!value || typeof value !== "object") return [];
      const block = value as Record<string, unknown>;
      if (block.type === "text" && typeof block.id === "string" && typeof block.value === "string") {
        return [{ id: block.id, type: "text", value: block.value }];
      }
      if (block.type !== "media" || typeof block.id !== "string" || !block.media || typeof block.media !== "object") return [];
      const media = block.media as Record<string, unknown>;
      if (
        (media.kind !== "image" && media.kind !== "video") ||
        typeof media.id !== "string" ||
        typeof media.name !== "string" ||
        typeof media.size !== "number" ||
        typeof media.url !== "string"
      ) return [];
      return [{
        id: block.id,
        type: "media",
        media: {
          id: media.id,
          kind: media.kind,
          name: media.name,
          previewUrl: media.url,
          size: media.size,
          status: "uploaded",
          url: media.url,
        },
      }];
    }) : [];
    if (!blocks.length) blocks.push({ id: makeId("text"), type: "text", value: "" });

    const bannerValue = draft.banner;
    const banner = bannerValue && typeof bannerValue === "object" ? bannerValue as Record<string, unknown> : null;
    const restoredBanner: DraftBanner | null = banner &&
      typeof banner.alt === "string" &&
      typeof banner.id === "string" &&
      typeof banner.name === "string" &&
      typeof banner.size === "number" &&
      typeof banner.url === "string"
      ? {
          alt: banner.alt,
          id: banner.id,
          name: banner.name,
          previewUrl: banner.url,
          size: banner.size,
          status: "uploaded",
          url: banner.url,
        }
      : null;
    const stringField = (name: string, fallback = "") => typeof draft[name] === "string" ? draft[name] : fallback;
    return {
      articleStatus: draft.articleStatus === "published" ? "published" : "draft",
      banner: restoredBanner,
      ...(typeof draft.baseUpdatedAt === "string" ? { baseUpdatedAt: draft.baseUpdatedAt } : {}),
      blocks,
      draftCategory: stringField("draftCategory", "Notes"),
      draftExcerpt: stringField("draftExcerpt"),
      draftSlug: stringField("draftSlug", `draft-${Date.now()}`),
      draftTags: stringField("draftTags"),
      draftTitle: stringField("draftTitle"),
      requestedSlug,
      savedAt: draft.savedAt,
    };
  } catch {
    return null;
  }
}

function writeRecoveryDraft(draft: RecoveryDraft) {
  try {
    localStorage.setItem(recoveryKey(draft.requestedSlug), JSON.stringify(draft));
  } catch {
    // Recovery is best-effort; D1 remains the authoritative store.
  }
}

function clearRecoveryDraft(requestedSlug: string | null) {
  try {
    localStorage.removeItem(recoveryKey(requestedSlug));
  } catch {
    // Storage may be disabled by the browser.
  }
}

function makeId(prefix: string) {
  return `${prefix}-${Date.now()}-${Math.random()}`;
}

function countWords(value: string) {
  return value.trim() ? value.trim().split(/\s+/).length : 0;
}

function isTextEditorBlock(block: EditorBlock): block is TextEditorBlock {
  return block.type === "text";
}

function isMediaEditorBlock(block: EditorBlock): block is MediaEditorBlock {
  return block.type === "media";
}

function getClipboardImages(clipboardData: DataTransfer) {
  const itemImages = Array.from(clipboardData.items)
    .filter((item) => item.kind === "file" && item.type.startsWith("image/"))
    .map((item) => item.getAsFile())
    .filter((file): file is File => file !== null);

  if (itemImages.length) return itemImages;
  return Array.from(clipboardData.files).filter((file) => file.type.startsWith("image/"));
}

function serializeBlocks(blocks: EditorBlock[]) {
  return blocks.map((block) => {
    if (block.type === "text") return block.value.trim();
    if (!block.media.url) return "";
    return block.media.kind === "image"
      ? `![${block.media.name}](${block.media.url})`
      : `<video controls src="${block.media.url}"></video>`;
  }).filter(Boolean).join("\n\n");
}

function deserializeArticle(article: StoredArticle): EditorBlock[] {
  const body = article.body ?? "";
  const mediaPattern = /!\[([^\]]*)\]\(([^)\s]+)\)|<video\s+controls\s+src="([^"]+)"\s*><\/video>/g;
  const blocks: EditorBlock[] = [];
  const storedMedia = article.media ?? [];
  let cursor = 0;
  let match: RegExpExecArray | null;

  while ((match = mediaPattern.exec(body))) {
    const textBefore = body.slice(cursor, match.index).replace(/^\n+|\n+$/g, "");
    if (textBefore.trim()) blocks.push({ id: makeId("text"), type: "text", value: textBefore });

    const kind = match[1] !== undefined ? "image" : "video";
    const url = match[2] ?? match[3];
    const media = storedMedia.find((item) => item.url === url);
    const draftMedia: DraftMedia = {
      id: makeId("media"),
      kind,
      name: media?.name ?? match[1] ?? `${kind}-media`,
      previewUrl: url,
      size: media?.size ?? 0,
      status: "uploaded",
      url,
    };
    blocks.push({ id: makeId("media-block"), type: "media", media: draftMedia });
    cursor = match.index + match[0].length;
  }

  const textAfter = body.slice(cursor).replace(/^\n+|\n+$/g, "");
  if (textAfter.trim()) blocks.push({ id: makeId("text"), type: "text", value: textAfter });
  if (!blocks.length || blocks[blocks.length - 1].type === "media") blocks.push({ id: makeId("text"), type: "text", value: "" });
  if (blocks[0].type === "media") blocks.unshift({ id: makeId("text"), type: "text", value: "" });
  return blocks;
}

function renderPreviewBlocks(blocks: EditorBlock[], emptyMessage: string) {
  const visibleBlocks = blocks.filter((block) => block.type === "media" || block.value.trim());
  if (!visibleBlocks.length) return <p className="preview-placeholder">{emptyMessage}</p>;
  return visibleBlocks.map((block) => {
    if (block.type === "text") return <div className="preview-block" key={block.id}>{renderMarkdown(block.value, "")}</div>;
    const source = block.media.url ?? block.media.previewUrl;
    return block.media.kind === "video"
      ? <figure className="preview-inline-media" key={block.id}><video src={source} controls playsInline /><figcaption>{block.media.name}</figcaption></figure>
      : <figure className="preview-inline-media" key={block.id}><ContentImage src={source} alt={block.media.name} priority /><figcaption>{block.media.name}</figcaption></figure>;
  });
}

export default function WriteClient() {
  return (
    <main className="write-page">
      <header className="site-header write-page-header">
        <Link className="brand" href="/" aria-label="Notebook 36 home">
          <span className="brand-mark">36</span>
          <span><strong>Notebook</strong><small>by Alex Rivera</small></span>
        </Link>
        <div className="write-page-actions">
          <Link href="/settings">Settings</Link>
          <Link className="back-to-notebook" href="/">← Back to notebook</Link>
        </div>
      </header>
      <WriteEditor />
    </main>
  );
}

function WriteEditor() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const requestedSlug = searchParams.get("slug");
  const [draftSlug, setDraftSlug] = useState(() => `draft-${Date.now()}`);
  const [draftTitle, setDraftTitle] = useState("");
  const [draftExcerpt, setDraftExcerpt] = useState("");
  const [draftCategory, setDraftCategory] = useState("Notes");
  const [draftTags, setDraftTags] = useState("");
  const [banner, setBanner] = useState<DraftBanner | null>(null);
  const [blocks, setBlocks] = useState<EditorBlock[]>(() => [{ id: `text-${Date.now()}`, type: "text", value: "" }]);
  const [dragActive, setDragActive] = useState(false);
  const [saveState, setSaveState] = useState<SaveState>("idle");
  const [articleStatus, setArticleStatus] = useState<ArticleStatus>("draft");
  const [loadedArticleSlug, setLoadedArticleSlug] = useState<string | null>(null);
  const [articleErrorSlug, setArticleErrorSlug] = useState<string | null>(null);
  const [editorMode, setEditorMode] = useState<EditorMode>("write");
  const [siteSettings, setSiteSettings] = useState<SiteSettings>(DEFAULT_SITE_SETTINGS);
  const textAreaRefs = useRef<Record<string, HTMLTextAreaElement | null>>({});
  const selectionByBlock = useRef<Record<string, { start: number; end: number }>>({});
  const blocksRef = useRef(blocks);
  const saveQueue = useRef<Promise<boolean>>(Promise.resolve(true));
  const persistedArticle = useRef<{ slug: string; updatedAt: string } | null>(null);
  const desiredArticleStatus = useRef<ArticleStatus>("draft");
  const editVersion = useRef(0);
  const recoverySnapshot = useRef<RecoveryDraft | null>(null);
  const recoveryWriteTimer = useRef<number | null>(null);
  const activeTextBlockId = useRef(blocks[0].id);
  const text = interfaceCopy[siteSettings.language];
  const isEditing = Boolean(requestedSlug);
  const articleLoading = Boolean(requestedSlug && loadedArticleSlug !== requestedSlug);
  const articleLoadError = Boolean(requestedSlug && articleErrorSlug === requestedSlug);
  const markDirty = useCallback(() => {
    editVersion.current += 1;
    setSaveState("dirty");
  }, []);

  useEffect(() => {
    blocksRef.current = blocks;
  }, [blocks]);

  useEffect(() => {
    if (requestedSlug) return;
    let active = true;
    window.queueMicrotask(() => {
      const recovery = readRecoveryDraft(null);
      if (!active || !recovery) return;
      setDraftSlug(recovery.draftSlug);
      setDraftTitle(recovery.draftTitle);
      setDraftExcerpt(recovery.draftExcerpt);
      setDraftCategory(recovery.draftCategory);
      setDraftTags(recovery.draftTags);
      setBanner(recovery.banner);
      blocksRef.current = recovery.blocks;
      setBlocks(recovery.blocks);
      activeTextBlockId.current = recovery.blocks.find(isTextEditorBlock)?.id ?? recovery.blocks[0].id;
      desiredArticleStatus.current = recovery.articleStatus;
      setArticleStatus(recovery.articleStatus);
      persistedArticle.current = recovery.baseUpdatedAt
        ? { slug: recovery.draftSlug, updatedAt: recovery.baseUpdatedAt }
        : null;
      recoverySnapshot.current = recovery;
      editVersion.current += 1;
      setSaveState("dirty");
    });
    return () => { active = false; };
  }, [requestedSlug]);

  useEffect(() => {
    let active = true;
    getSiteSettings()
      .then((value) => normalizeSiteSettings(value))
      .catch(() => DEFAULT_SITE_SETTINGS)
      .then((settings) => {
        if (!active) return;
        const preferredTheme = readSiteThemePreference();
        const hydrated = preferredTheme ? { ...settings, theme: preferredTheme } : settings;
        setSiteSettings(hydrated);
        setEditorMode(hydrated.defaultEditorMode);
      });
    return () => { active = false; };
  }, []);

  useEffect(() => {
    const slug = requestedSlug;
    if (!slug) return;
    let active = true;
    getArticle(slug, { includeDraft: true })
      .then((article) => {
        if (!active) return;
        const savedRecovery = readRecoveryDraft(slug);
        const recovery = savedRecovery?.baseUpdatedAt === article.updatedAt && savedRecovery.draftSlug === article.slug
          ? savedRecovery
          : null;
        const nextBlocks = recovery?.blocks ?? deserializeArticle(article);
        setDraftSlug(recovery?.draftSlug ?? article.slug);
        setDraftTitle(recovery?.draftTitle ?? article.title);
        setDraftExcerpt(recovery?.draftExcerpt ?? article.excerpt);
        setDraftCategory(recovery?.draftCategory ?? (article.category || "Notes"));
        setDraftTags(recovery?.draftTags ?? (article.tags ?? []).join(", "));
        setBanner(recovery?.banner ?? (article.banner ? {
          ...article.banner,
          id: makeId("banner"),
          previewUrl: article.banner.url,
          status: "uploaded",
        } : null));
        blocksRef.current = nextBlocks;
        activeTextBlockId.current = nextBlocks.find((block) => block.type === "text")?.id ?? nextBlocks[0].id;
        setBlocks(nextBlocks);
        const loadedStatus = recovery?.articleStatus ?? (article.status === "published" ? "published" : "draft");
        desiredArticleStatus.current = loadedStatus;
        persistedArticle.current = { slug: article.slug, updatedAt: article.updatedAt };
        recoverySnapshot.current = recovery;
        setArticleStatus(loadedStatus);
        if (recovery) {
          editVersion.current += 1;
          setSaveState("dirty");
        }
        setLoadedArticleSlug(article.slug);
        setArticleErrorSlug(null);
      })
      .catch(() => {
        if (!active) return;
        setLoadedArticleSlug(slug);
        setArticleErrorSlug(slug);
      });
    return () => { active = false; };
  }, [requestedSlug]);

  useEffect(() => {
    applySiteTheme(siteSettings.theme);
  }, [siteSettings.theme]);

  const mediaBlocks = useMemo(() => blocks.filter(isMediaEditorBlock), [blocks]);
  const bodyText = useMemo(() => blocks.filter(isTextEditorBlock).map((block) => block.value).join(" "), [blocks]);
  const articleTags = useMemo(() => [...new Set(draftTags.split(/[\n,，]+/).map((tag) => tag.trim().replace(/^#/, "")).filter(Boolean))], [draftTags]);
  const bannerUploading = banner?.status === "uploading";
  const hasDraftContent = Boolean(draftTitle.trim() || bodyText.trim() || mediaBlocks.length || banner);
  const canPublish = Boolean(draftTitle.trim() && bodyText.trim()) && !bannerUploading && !mediaBlocks.some((block) => block.media.status === "uploading");
  const wordCount = useMemo(() => countWords(`${draftTitle} ${bodyText}`), [bodyText, draftTitle]);
  const readingTime = Math.max(1, Math.ceil(wordCount / 200));

  const insertMarkdown = (prefix: string, suffix = "", placeholder = "text") => {
    const targetId = activeTextBlockId.current || blocksRef.current.find((block) => block.type === "text")?.id;
    const target = blocksRef.current.find((block): block is TextEditorBlock => block.id === targetId && block.type === "text");
    const textarea = targetId ? textAreaRefs.current[targetId] : null;
    if (!target || !textarea) return;
    const selection = selectionByBlock.current[target.id] ?? { start: target.value.length, end: target.value.length };
    const start = selection.start;
    const end = selection.end;
    const selected = target.value.slice(start, end);
    const inserted = selected ? `${prefix}${selected}${suffix}` : `${prefix}${placeholder}${suffix}`;
    const nextValue = `${target.value.slice(0, start)}${inserted}${target.value.slice(end)}`;
    setBlocks((current) => current.map((block) => block.id === target.id && block.type === "text" ? { ...block, value: nextValue } : block));
    markDirty();
    window.requestAnimationFrame(() => {
      textarea.focus();
      const cursor = selected ? start + inserted.length : start + prefix.length;
      textarea.setSelectionRange(cursor, selected ? cursor : cursor + placeholder.length);
      selectionByBlock.current[target.id] = { start: cursor, end: selected ? cursor : cursor + placeholder.length };
    });
  };

  const persistArticle = useCallback((status: ArticleStatus) => {
    if (!hasDraftContent || bannerUploading || mediaBlocks.some((block) => block.media.status === "uploading")) {
      return Promise.resolve(false);
    }

    const article = {
      banner: banner?.status === "uploaded" && banner.url ? { alt: banner.alt.trim() || banner.name, name: banner.name, size: banner.size, url: banner.url } : undefined,
      body: serializeBlocks(blocks),
      excerpt: draftExcerpt,
      category: draftCategory.trim() || "Uncategorized",
      tags: articleTags,
      media: mediaBlocks.flatMap((block) => block.media.status === "uploaded" && block.media.url
        ? [{ kind: block.media.kind, name: block.media.name, size: block.media.size, url: block.media.url }]
        : []),
      slug: draftSlug,
      status,
      title: draftTitle,
    };

    desiredArticleStatus.current = status;
    const savedVersion = editVersion.current;
    setSaveState(status === "published" ? "publishing" : "saving");

    const executeSave = async () => {
      try {
        const currentVersion = persistedArticle.current?.slug === article.slug
          ? persistedArticle.current.updatedAt
          : undefined;
        const saved = await saveArticle({ ...article, expectedUpdatedAt: currentVersion });
        persistedArticle.current = { slug: saved.slug, updatedAt: saved.updatedAt };
        if (editVersion.current !== savedVersion && recoverySnapshot.current) {
          const updatedRecovery = {
            ...recoverySnapshot.current,
            baseUpdatedAt: saved.updatedAt,
            draftSlug: saved.slug,
            savedAt: Date.now(),
          };
          recoverySnapshot.current = updatedRecovery;
          writeRecoveryDraft(updatedRecovery);
        } else {
          recoverySnapshot.current = null;
          clearRecoveryDraft(requestedSlug);
        }
        setDraftSlug(saved.slug);
        setArticleStatus(saved.status);
        setSaveState(editVersion.current === savedVersion
          ? status === "published" ? "published" : "saved"
          : "dirty");
        return true;
      } catch (error) {
        setSaveState(error instanceof BlogRequestError && error.status === 409 ? "conflict" : "offline");
        return false;
      }
    };

    const pending = saveQueue.current.catch(() => false).then(executeSave);
    saveQueue.current = pending;
    return pending;
  }, [articleTags, banner, bannerUploading, blocks, draftCategory, draftExcerpt, draftSlug, draftTitle, hasDraftContent, mediaBlocks, requestedSlug]);

  const saveDraftNow = useCallback(() => persistArticle("draft"), [persistArticle]);
  const publishArticle = useCallback(() => persistArticle("published"), [persistArticle]);

  useEffect(() => {
    if (!hasDraftContent || bannerUploading || mediaBlocks.some((block) => block.media.status === "uploading")) return;
    if (saveState !== "dirty") return;
    const timer = window.setTimeout(() => void persistArticle(desiredArticleStatus.current), siteSettings.autoSaveDelay);
    return () => window.clearTimeout(timer);
  }, [articleStatus, banner, bannerUploading, blocks, draftExcerpt, draftTitle, hasDraftContent, mediaBlocks, persistArticle, saveState, siteSettings.autoSaveDelay]);

  useEffect(() => {
    const shouldRecover = saveState === "dirty" || saveState === "offline" || saveState === "conflict" || saveState === "saving" || saveState === "publishing";
    if (!shouldRecover) {
      if (saveState === "saved" || saveState === "published") {
        recoverySnapshot.current = null;
        clearRecoveryDraft(requestedSlug);
      }
      return;
    }

    const recoverableBlocks = blocks.flatMap((block): EditorBlock[] => {
      if (block.type === "text") return [block];
      if (block.media.status !== "uploaded" || !block.media.url) return [];
      return [{
        ...block,
        media: {
          ...block.media,
          previewUrl: block.media.url,
          status: "uploaded",
          url: block.media.url,
        },
      }];
    });
    if (!recoverableBlocks.length) recoverableBlocks.push({ id: makeId("text"), type: "text", value: "" });
    const recoverableBanner = banner?.status === "uploaded" && banner.url
      ? { ...banner, previewUrl: banner.url, status: "uploaded" as const, url: banner.url }
      : null;
    const snapshot: RecoveryDraft = {
      articleStatus: desiredArticleStatus.current,
      banner: recoverableBanner,
      ...(persistedArticle.current?.updatedAt ? { baseUpdatedAt: persistedArticle.current.updatedAt } : {}),
      blocks: recoverableBlocks,
      draftCategory,
      draftExcerpt,
      draftSlug,
      draftTags,
      draftTitle,
      requestedSlug,
      savedAt: Date.now(),
    };
    recoverySnapshot.current = snapshot;
    if (recoveryWriteTimer.current !== null) window.clearTimeout(recoveryWriteTimer.current);
    recoveryWriteTimer.current = window.setTimeout(() => {
      if (recoverySnapshot.current) writeRecoveryDraft(recoverySnapshot.current);
      recoveryWriteTimer.current = null;
    }, 200);
    return () => {
      if (recoveryWriteTimer.current !== null) window.clearTimeout(recoveryWriteTimer.current);
    };
  }, [banner, blocks, draftCategory, draftExcerpt, draftSlug, draftTags, draftTitle, requestedSlug, saveState]);

  useEffect(() => () => {
    if (recoveryWriteTimer.current !== null) window.clearTimeout(recoveryWriteTimer.current);
    if (recoverySnapshot.current) writeRecoveryDraft(recoverySnapshot.current);
  }, []);

  useEffect(() => {
    const hasUnsavedChanges = saveState === "dirty" || saveState === "offline" || saveState === "conflict" || saveState === "saving" || saveState === "publishing";
    if (!hasUnsavedChanges) return;

    const warnBeforeUnload = (event: BeforeUnloadEvent) => {
      if (recoverySnapshot.current) writeRecoveryDraft(recoverySnapshot.current);
      event.preventDefault();
      event.returnValue = "";
    };
    const preserveRecoveryOnHistoryChange = () => {
      if (recoverySnapshot.current) writeRecoveryDraft(recoverySnapshot.current);
    };
    const saveBeforeNavigation = (event: MouseEvent) => {
      if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      if (!(event.target instanceof Element)) return;
      const anchor = event.target.closest<HTMLAnchorElement>("a[href]");
      if (!anchor || anchor.target || anchor.hasAttribute("download")) return;

      const destination = new URL(anchor.href, window.location.href);
      if (destination.href === window.location.href) return;
      event.preventDefault();
      const pending = saveState === "saving" || saveState === "publishing"
        ? saveQueue.current
        : persistArticle(desiredArticleStatus.current);
      void pending.then((saved) => {
        if (!saved && !window.confirm(text.editor.leaveWithoutSaving)) return;
        if (recoverySnapshot.current) writeRecoveryDraft(recoverySnapshot.current);
        if (destination.origin === window.location.origin) {
          router.push(`${destination.pathname}${destination.search}${destination.hash}`);
        } else {
          window.location.assign(destination.href);
        }
      });
    };

    window.addEventListener("beforeunload", warnBeforeUnload);
    window.addEventListener("popstate", preserveRecoveryOnHistoryChange);
    document.addEventListener("click", saveBeforeNavigation, true);
    return () => {
      window.removeEventListener("beforeunload", warnBeforeUnload);
      window.removeEventListener("popstate", preserveRecoveryOnHistoryChange);
      document.removeEventListener("click", saveBeforeNavigation, true);
    };
  }, [persistArticle, router, saveState, text.editor.leaveWithoutSaving]);

  const rememberSelection = (id: string, textarea: HTMLTextAreaElement) => {
    activeTextBlockId.current = id;
    selectionByBlock.current[id] = { start: textarea.selectionStart, end: textarea.selectionEnd };
  };

  const insertMediaBlock = (media: DraftMedia) => {
    const currentBlocks = blocksRef.current;
    const targetId = activeTextBlockId.current || currentBlocks.find((block) => block.type === "text")?.id;
    const targetIndex = currentBlocks.findIndex((block) => block.id === targetId && block.type === "text");
    const target = targetIndex >= 0 ? currentBlocks[targetIndex] : null;
    const mediaBlock: EditorBlock = { id: `media-${media.id}`, type: "media", media };

    if (!target || target.type !== "text") {
      const trailingId = makeId("text");
      const nextBlocks: EditorBlock[] = [...currentBlocks, mediaBlock, { id: trailingId, type: "text", value: "" }];
      blocksRef.current = nextBlocks;
      setBlocks(nextBlocks);
      activeTextBlockId.current = trailingId;
      selectionByBlock.current[trailingId] = { start: 0, end: 0 };
      return;
    }

    const selection = selectionByBlock.current[target.id] ?? { start: target.value.length, end: target.value.length };
    const beforeId = target.id;
    const afterId = makeId("text");
    const before: EditorBlock = { id: beforeId, type: "text", value: target.value.slice(0, selection.start) };
    const after: EditorBlock = { id: afterId, type: "text", value: target.value.slice(selection.end) };
    const nextBlocks = [...currentBlocks.slice(0, targetIndex), before, mediaBlock, after, ...currentBlocks.slice(targetIndex + 1)];
    blocksRef.current = nextBlocks;
    setBlocks(nextBlocks);
    activeTextBlockId.current = afterId;
    selectionByBlock.current[afterId] = { start: 0, end: 0 };
    window.requestAnimationFrame(() => textAreaRefs.current[afterId]?.focus());
  };

  const uploadFiles = async (files: FileList | File[]) => {
    const supportedFiles = Array.from(files).filter((file) => file.type.startsWith("image/") || file.type.startsWith("video/"));
    if (!supportedFiles.length) return;
    markDirty();
    for (const file of supportedFiles) {
      const kind = file.type.startsWith("video/") ? "video" : "image";
      const id = makeId(`${file.name}-${file.lastModified}`);
      const item: DraftMedia = { id, kind, name: file.name, previewUrl: URL.createObjectURL(file), size: file.size, status: "uploading" };
      insertMediaBlock(item);
      try {
        const result = await uploadMedia(file, { kind, slug: draftSlug });
        setBlocks((current) => current.map((block) => {
          if (block.type !== "media" || block.media.id !== id) return block;
          if (block.media.previewUrl.startsWith("blob:")) URL.revokeObjectURL(block.media.previewUrl);
          return { ...block, media: { ...block.media, status: "uploaded", url: result.url, previewUrl: result.url } };
        }));
      } catch {
        setBlocks((current) => current.map((block) => block.type === "media" && block.media.id === id ? { ...block, media: { ...block.media, status: "error" } } : block));
        setSaveState("offline");
      }
    }
  };

  const uploadBanner = async (file: File) => {
    if (!file.type.startsWith("image/")) return;
    const previousBanner = banner;
    const id = makeId(`banner-${file.name}-${file.lastModified}`);
    const previewUrl = URL.createObjectURL(file);
    const nextBanner: DraftBanner = {
      alt: file.name,
      id,
      name: file.name,
      previewUrl,
      size: file.size,
      status: "uploading",
    };
    setBanner(nextBanner);
    markDirty();

    try {
      const result = await uploadMedia(file, { kind: "image", slug: draftSlug });
      setBanner((current) => {
        if (current?.id !== id) return current;
        URL.revokeObjectURL(previewUrl);
        return { ...current, previewUrl: result.url, status: "uploaded", url: result.url };
      });
    } catch {
      setBanner((current) => current?.id === id ? previousBanner : current);
      URL.revokeObjectURL(previewUrl);
      setSaveState("offline");
    }
  };

  const removeBanner = () => {
    if (banner?.previewUrl.startsWith("blob:")) URL.revokeObjectURL(banner.previewUrl);
    setBanner(null);
    markDirty();
  };

  const removeMedia = (id: string) => {
    const item = mediaBlocks.find((block) => block.media.id === id)?.media;
    if (item?.previewUrl.startsWith("blob:")) URL.revokeObjectURL(item.previewUrl);
    setBlocks((current) => current.filter((block) => block.type !== "media" || block.media.id !== id));
    markDirty();
  };

  return (
    <section className="composer write-editor" aria-labelledby="composer-title">
      <div className="composer-header">
        <div>
          <div className="composer-kicker"><p className="eyebrow">{isEditing ? text.editor.editNote : text.editor.newNote}</p><span className="editor-shortcut">{text.editor.shortcut}</span></div>
          <h1 id="composer-title">{isEditing ? text.editor.editTitle : text.editor.title}</h1>
          <p className="composer-lede">{articleLoading ? text.editor.loading : articleLoadError ? text.editor.loadError : text.editor.lede}</p>
        </div>
        <Link className="close-button" href="/" aria-label="Back to notebook">×</Link>
      </div>

      <div className="editor-status-row">
        <div className="editor-path" aria-live="polite">
          <span className={`save-dot ${saveState}`} aria-hidden="true" />
          <span>{saveState === "saving" && text.editor.saving}{saveState === "publishing" && text.editor.publishing}{saveState === "saved" && text.editor.saved}{saveState === "published" && text.editor.published}{saveState === "offline" && text.editor.offline}{saveState === "conflict" && text.editor.conflict}{saveState === "dirty" && text.editor.dirty}{saveState === "idle" && text.editor.ready}</span>
          <code>D1 · R2</code>
        </div>
        <div className="editor-stats" aria-label="Draft statistics">
          <span>{wordCount} {text.editor.words}</span><span>·</span><span>{readingTime} {text.editor.read}</span><span>·</span><span>{mediaBlocks.length} {mediaBlocks.length === 1 ? text.editor.attachment : text.editor.attachments}</span>
        </div>
      </div>

      <div className="editor-layout">
        <div className="composer-main">
          <div className="composer-fields">
            <div className="title-field"><label htmlFor="draft-title">{text.editor.titleLabel}</label><input id="draft-title" disabled={articleLoading || articleLoadError} value={draftTitle} onChange={(event) => { setDraftTitle(event.target.value); markDirty(); }} placeholder={text.editor.titlePlaceholder} /></div>
            <div className="excerpt-field"><label htmlFor="draft-excerpt">{text.editor.introLabel} <span>{text.editor.introOptional}</span></label><input id="draft-excerpt" disabled={articleLoading || articleLoadError} value={draftExcerpt} onChange={(event) => { setDraftExcerpt(event.target.value); markDirty(); }} placeholder={text.editor.introPlaceholder} /></div>
          </div>
          <div className="composer-fields article-metadata-fields">
            <div className="category-field"><label htmlFor="draft-category">{text.editor.categoryLabel}</label><input id="draft-category" disabled={articleLoading || articleLoadError} value={draftCategory} onChange={(event) => { setDraftCategory(event.target.value); markDirty(); }} placeholder={text.editor.categoryPlaceholder} /></div>
            <div className="tags-field"><label htmlFor="draft-tags">{text.editor.tagsLabel} <span>{text.editor.tagsOptional}</span></label><input id="draft-tags" disabled={articleLoading || articleLoadError} value={draftTags} onChange={(event) => { setDraftTags(event.target.value); markDirty(); }} placeholder={text.editor.tagsPlaceholder} /></div>
          </div>

          <div
            className={`article-banner-editor ${banner ? "has-banner" : ""}`}
            role="group"
            aria-label={text.editor.bannerLabel}
            aria-disabled={articleLoading || articleLoadError || bannerUploading}
            tabIndex={0}
            onMouseDown={(event) => {
              if (!(event.target as HTMLElement).closest("input, button, label")) event.currentTarget.focus();
            }}
            onPaste={(event) => {
              if (event.target instanceof HTMLInputElement || articleLoading || articleLoadError || bannerUploading) return;
              const image = getClipboardImages(event.clipboardData)[0];
              if (!image) return;
              event.preventDefault();
              void uploadBanner(image);
            }}
          >
            <input
              id="article-banner-picker"
              className="visually-hidden"
              type="file"
              accept="image/*"
              disabled={articleLoading || articleLoadError || bannerUploading}
              onChange={(event) => {
                const file = event.target.files?.[0];
                if (file) void uploadBanner(file);
                event.currentTarget.value = "";
              }}
            />
            <div className="article-banner-heading">
              <div><p>{text.editor.bannerLabel}</p><span>{text.editor.bannerHint} {text.editor.bannerPasteHint}</span></div>
              {banner && <div className="article-banner-actions">
                <label className={bannerUploading ? "disabled" : ""} htmlFor="article-banner-picker">{text.editor.bannerReplace}</label>
                <button type="button" disabled={bannerUploading} onClick={removeBanner}>{text.editor.bannerRemove}</button>
              </div>}
            </div>
            {banner ? <>
              <div className={`article-banner-preview ${banner.status}`} aria-live="polite">
                <ContentImage src={banner.previewUrl} alt={banner.alt} priority />
                <span>{bannerUploading ? text.editor.bannerUploading : banner.name}</span>
              </div>
              <div className="article-banner-alt">
                <label htmlFor="article-banner-alt">{text.editor.bannerAltLabel}</label>
                <input id="article-banner-alt" value={banner.alt} onChange={(event) => { setBanner((current) => current ? { ...current, alt: event.target.value } : current); markDirty(); }} placeholder={text.editor.bannerAltPlaceholder} />
              </div>
            </> : <label className="article-banner-picker" htmlFor="article-banner-picker"><span aria-hidden="true">＋</span><strong>{text.editor.bannerChoose}</strong><small>{text.editor.bannerPasteHint}</small></label>}
          </div>

          <div className="editor-tabs" role="tablist" aria-label="Editor view">
            <button type="button" role="tab" aria-selected={editorMode === "write"} className={editorMode === "write" ? "active" : ""} onClick={() => setEditorMode("write")}>{text.editor.write}</button>
            <button type="button" role="tab" aria-selected={editorMode === "preview"} className={editorMode === "preview" ? "active" : ""} onClick={() => setEditorMode("preview")}>{text.editor.preview}</button>
            <span className="editor-tabs-hint">{text.editor.markdown}</span>
          </div>

          {editorMode === "write" ? (
            <div className="editor-surface">
              <div className="editor-toolbar" aria-label="Formatting toolbar">
                <button type="button" onMouseDown={(event) => { event.preventDefault(); insertMarkdown("## ", "", "Section heading"); }} aria-label="Insert heading">H2</button>
                <button type="button" onMouseDown={(event) => { event.preventDefault(); insertMarkdown("**", "**", "bold text"); }} aria-label="Bold">B</button>
                <button type="button" onMouseDown={(event) => { event.preventDefault(); insertMarkdown("_", "_", "italic text"); }} aria-label="Italic"><em>I</em></button>
                <button type="button" onMouseDown={(event) => { event.preventDefault(); insertMarkdown("> ", "", "A thought worth keeping"); }} aria-label="Insert quote">“</button>
                <button type="button" onMouseDown={(event) => { event.preventDefault(); insertMarkdown("- ", "", "List item"); }} aria-label="Insert list">☷</button>
                <button type="button" onMouseDown={(event) => { event.preventDefault(); insertMarkdown("[", "](https://)", "link text"); }} aria-label="Insert link">↗</button>
                <button type="button" onMouseDown={(event) => { event.preventDefault(); insertMarkdown("`", "`", "inline code"); }} aria-label="Insert inline code">`</button>
                <button type="button" onMouseDown={(event) => { event.preventDefault(); insertMarkdown("```\n", "\n```", "code"); }} aria-label="Insert code block">&lt;/&gt;</button>
              </div>
              <div className="editor-canvas-body">
                {blocks.map((block, index) => block.type === "text" ? (
                  <textarea
                    key={block.id}
                    ref={(node) => { textAreaRefs.current[block.id] = node; }}
                    className={`block-textarea ${mediaBlocks.length === 0 && index === 0 ? "primary" : ""}`}
                    id={index === 0 ? "draft-body" : undefined}
                    value={block.value}
                    rows={mediaBlocks.length === 0 && index === 0
                      ? Math.max(10, Math.min(24, block.value.split("\n").length + 5))
                      : Math.max(1, Math.min(24, block.value.split("\n").length))}
                    onFocus={(event) => rememberSelection(block.id, event.currentTarget)}
                    onClick={(event) => rememberSelection(block.id, event.currentTarget)}
                    onSelect={(event) => rememberSelection(block.id, event.currentTarget)}
                    onPaste={(event) => {
                      rememberSelection(block.id, event.currentTarget);
                      const images = getClipboardImages(event.clipboardData);
                      if (!images.length) return;
                      event.preventDefault();
                      void uploadFiles(images);
                    }}
                    onChange={(event) => {
                      rememberSelection(block.id, event.currentTarget);
                      setBlocks((current) => current.map((item) => item.id === block.id && item.type === "text" ? { ...item, value: event.target.value } : item));
                      markDirty();
                    }}
                    onKeyDown={(event) => { if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") { event.preventDefault(); void saveDraftNow(); } }}
                    placeholder={index === 0 ? text.editor.notePlaceholder : text.editor.notePlaceholder}
                  />
                ) : (
                  <div className={`inline-media-block ${block.media.status}`} key={block.id}>
                    {block.media.kind === "video" ? <video src={block.media.previewUrl} muted controls playsInline preload="metadata" /> : <ContentImage src={block.media.previewUrl} alt={block.media.name} priority />}
                    <div className="inline-media-toolbar"><span>{block.media.status === "uploading" ? "Uploading…" : block.media.status === "error" ? "Upload failed" : block.media.name}</span><button type="button" onClick={() => removeMedia(block.media.id)} aria-label={`Remove ${block.media.name}`}>Remove ×</button></div>
                  </div>
                ))}
              </div>
              <div className="editor-surface-footer"><span>{text.editor.blankLine}</span><span>{bodyText.length} characters · {mediaBlocks.length} inline media</span></div>
            </div>
          ) : (
            <article className="editor-preview" aria-label="Article preview">
              <p className="preview-label">{text.editor.previewLabel}</p>
              <h1>{draftTitle.trim() || text.editor.untitled}</h1>
              <div className="preview-meta"><span>{draftCategory.trim() || "Uncategorized"}</span>{articleTags.map((tag) => <span key={tag}>#{tag}</span>)}</div>
              {draftExcerpt.trim() && <p className="preview-excerpt">{draftExcerpt}</p>}
              {banner && <figure className="editor-preview-banner"><ContentImage src={banner.previewUrl} alt={banner.alt.trim() || banner.name} priority /></figure>}
              <div className="preview-copy">{renderPreviewBlocks(blocks, text.editor.emptyPreview)}</div>
            </article>
          )}

          <div className={`editor-dropzone ${dragActive ? "is-dragging" : ""}`} onDragEnter={(event) => { event.preventDefault(); setDragActive(true); }} onDragOver={(event) => { event.preventDefault(); setDragActive(true); }} onDragLeave={(event) => { event.preventDefault(); setDragActive(false); }} onDrop={(event) => { event.preventDefault(); setDragActive(false); void uploadFiles(event.dataTransfer.files); }}>
            <input id="media-picker" className="visually-hidden" type="file" accept="image/*,video/*" multiple onChange={(event) => { if (event.target.files) void uploadFiles(event.target.files); event.currentTarget.value = ""; }} />
            <label htmlFor="media-picker" className="dropzone-label"><span className="dropzone-icon" aria-hidden="true">＋</span><span><strong>{text.editor.drop}</strong><small>{text.editor.browse}</small></span><span className="dropzone-action">{text.editor.addMedia}</span></label>
          </div>

        </div>

        <aside className="editor-aside">
          <div className="aside-card"><p className="aside-label">{text.editor.checklist}</p><ul className="editor-checklist"><li className={draftTitle.trim() ? "complete" : ""}><span>✓</span> {text.editor.checklistTitle}</li><li className={bodyText.trim() ? "complete" : ""}><span>✓</span> {text.editor.checklistIdea}</li><li className={banner || mediaBlocks.length ? "complete" : ""}><span>✓</span> {text.editor.checklistMedia}</li></ul></div>
          {siteSettings.showWritingPrompt && <div className="aside-card aside-tip"><p className="aside-label">{text.editor.promptLabel}</p><p>{text.editor.prompt}</p><span>{text.editor.promptHint}</span></div>}
        </aside>
      </div>

      <div className="composer-footer">
        <span>{text.editor.filesGoTo} <strong>articles/</strong> {text.editor.filesGoTo === "Files go to" ? "and" : "和"} <strong>media/</strong></span>
        <div className="composer-footer-actions">
          <button className="save-draft-button" type="button" onClick={() => void saveDraftNow()} disabled={!hasDraftContent || bannerUploading || saveState === "saving" || saveState === "publishing" || mediaBlocks.some((block) => block.media.status === "uploading")}>
            {saveState === "saved" && articleStatus === "draft" ? text.editor.draftSaved : text.editor.saveDraft}
          </button>
          <button className="write-button" type="button" onClick={() => void publishArticle()} disabled={!canPublish || saveState === "saving" || saveState === "publishing"}>
            {saveState === "published" ? text.editor.publishedButton : saveState === "publishing" ? text.editor.publishingButton : text.editor.publish}
          </button>
        </div>
      </div>
    </section>
  );
}
