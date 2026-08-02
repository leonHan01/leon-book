"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { ReactNode } from "react";
import type { ArticleStatus } from "../article-types";
import {
  DEFAULT_SITE_SETTINGS,
  interfaceCopy,
  readSiteSettings,
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

type EditorBlock =
  | { id: string; type: "text"; value: string }
  | { id: string; type: "media"; media: DraftMedia };

type SaveState = "idle" | "dirty" | "saving" | "saved" | "publishing" | "published" | "offline";
type EditorMode = "write" | "preview";

const STORAGE_URL = "http://localhost:8787";

function makeId(prefix: string) {
  return `${prefix}-${Date.now()}-${Math.random()}`;
}

function countWords(value: string) {
  return value.trim() ? value.trim().split(/\s+/).length : 0;
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

function safeMarkdownUrl(value: string, kind: "image" | "link") {
  const url = value.trim();
  if (/^(https?:\/\/|\/|#|mailto:)/i.test(url)) return url;
  if (kind === "image" && /^(blob:|data:image\/)/i.test(url)) return url;
  return null;
}

function renderInlineMarkdown(value: string, keyPrefix: string): ReactNode[] {
  const nodes: ReactNode[] = [];
  const pattern = /!\[([^\]]*)\]\(([^)\s]+)\)|\[([^\]]+)\]\(([^)\s]+)\)|(`+)([\s\S]*?)\5|\*\*([\s\S]+?)\*\*|__([\s\S]+?)__|~~([\s\S]+?)~~|\*([^*\n]+)\*|_([^_\n]+)_/g;
  let cursor = 0;
  let tokenIndex = 0;
  let match: RegExpExecArray | null;

  while ((match = pattern.exec(value))) {
    if (match.index > cursor) nodes.push(value.slice(cursor, match.index));
    const key = `${keyPrefix}-${tokenIndex++}`;

    if (match[1] !== undefined) {
      const source = safeMarkdownUrl(match[2], "image");
      nodes.push(source ? <img key={key} className="markdown-inline-image" src={source} alt={match[1]} /> : match[0]);
    } else if (match[3] !== undefined) {
      const href = safeMarkdownUrl(match[4], "link");
      nodes.push(href ? <a key={key} href={href} target="_blank" rel="noreferrer">{renderInlineMarkdown(match[3], key)}</a> : match[3]);
    } else if (match[5] !== undefined) {
      nodes.push(<code key={key}>{match[6]}</code>);
    } else if (match[7] !== undefined || match[8] !== undefined) {
      nodes.push(<strong key={key}>{renderInlineMarkdown(match[7] ?? match[8] ?? "", key)}</strong>);
    } else if (match[9] !== undefined) {
      nodes.push(<del key={key}>{renderInlineMarkdown(match[9], key)}</del>);
    } else {
      nodes.push(<em key={key}>{renderInlineMarkdown(match[10] ?? match[11] ?? "", key)}</em>);
    }
    cursor = match.index + match[0].length;
  }

  if (cursor < value.length) nodes.push(value.slice(cursor));
  return nodes;
}

function renderMarkdown(body: string, emptyMessage: string): ReactNode {
  const lines = body.replace(/\r\n?/g, "\n").split("\n");
  if (!body.trim()) return <p className="preview-placeholder">{emptyMessage}</p>;

  const nodes: ReactNode[] = [];
  const isBlockStart = (line: string) => /^( {0,3}(#{1,6})\s+| {0,3}```| {0,3}[-*+]\s+| {0,3}\d+\.\s+| {0,3}>\s?| {0,3}(---+|\*\*\*+|___+)\s*$)/.test(line);
  let lineIndex = 0;
  let nodeIndex = 0;

  while (lineIndex < lines.length) {
    const line = lines[lineIndex];
    if (!line.trim()) {
      lineIndex += 1;
      continue;
    }

    const fence = line.match(/^ {0,3}```\s*([\w-]+)?\s*$/);
    if (fence) {
      const codeLines: string[] = [];
      lineIndex += 1;
      while (lineIndex < lines.length && !/^ {0,3}```\s*$/.test(lines[lineIndex])) {
        codeLines.push(lines[lineIndex]);
        lineIndex += 1;
      }
      if (lineIndex < lines.length) lineIndex += 1;
      const language = fence[1] ? `language-${fence[1]}` : undefined;
      nodes.push(<pre key={`markdown-code-${nodeIndex++}`}><code className={language}>{codeLines.join("\n")}</code></pre>);
      continue;
    }

    const heading = line.match(/^ {0,3}(#{1,6})\s+(.+?)\s*#*\s*$/);
    if (heading) {
      const Heading = `h${heading[1].length}` as keyof JSX.IntrinsicElements;
      nodes.push(<Heading key={`markdown-heading-${nodeIndex++}`}>{renderInlineMarkdown(heading[2], `heading-${nodeIndex}`)}</Heading>);
      lineIndex += 1;
      continue;
    }

    if (lineIndex + 1 < lines.length && line.trim() && /^ {0,3}(=+|-+)\s*$/.test(lines[lineIndex + 1])) {
      const Heading = /^\s*=/.test(lines[lineIndex + 1]) ? "h1" : "h2";
      nodes.push(<Heading key={`markdown-setext-${nodeIndex++}`}>{renderInlineMarkdown(line.trim(), `setext-${nodeIndex}`)}</Heading>);
      lineIndex += 2;
      continue;
    }

    if (/^ {0,3}([-*_])(?:\s*\1){2,}\s*$/.test(line)) {
      nodes.push(<hr key={`markdown-rule-${nodeIndex++}`} />);
      lineIndex += 1;
      continue;
    }

    const unordered = /^ {0,3}[-*+]\s+(.+)$/.exec(line);
    if (unordered) {
      const items: string[] = [];
      while (lineIndex < lines.length) {
        const item = /^ {0,3}[-*+]\s+(.+)$/.exec(lines[lineIndex]);
        if (!item) break;
        items.push(item[1]);
        lineIndex += 1;
      }
      nodes.push(<ul key={`markdown-list-${nodeIndex++}`}>{items.map((item, itemIndex) => {
        const task = /^\[([ xX])\]\s+(.+)$/.exec(item);
        return <li key={`item-${itemIndex}`}>{task ? <><input type="checkbox" checked={task[1].toLowerCase() === "x"} readOnly /> {renderInlineMarkdown(task[2], `task-${itemIndex}`)}</> : renderInlineMarkdown(item, `list-${itemIndex}`)}</li>;
      })}</ul>);
      continue;
    }

    const ordered = /^ {0,3}\d+\.\s+(.+)$/.exec(line);
    if (ordered) {
      const items: string[] = [];
      while (lineIndex < lines.length) {
        const item = /^ {0,3}\d+\.\s+(.+)$/.exec(lines[lineIndex]);
        if (!item) break;
        items.push(item[1]);
        lineIndex += 1;
      }
      nodes.push(<ol key={`markdown-ordered-list-${nodeIndex++}`}>{items.map((item, itemIndex) => <li key={`item-${itemIndex}`}>{renderInlineMarkdown(item, `ordered-${itemIndex}`)}</li>)}</ol>);
      continue;
    }

    if (/^ {0,3}>\s?/.test(line)) {
      const quoteLines: string[] = [];
      while (lineIndex < lines.length) {
        const quote = /^ {0,3}>\s?(.*)$/.exec(lines[lineIndex]);
        if (!quote) break;
        quoteLines.push(quote[1]);
        lineIndex += 1;
      }
      nodes.push(<blockquote key={`markdown-quote-${nodeIndex++}`}>{renderMarkdown(quoteLines.join("\n"), "")}</blockquote>);
      continue;
    }

    const paragraphLines = [line];
    lineIndex += 1;
    while (lineIndex < lines.length && lines[lineIndex].trim() && !isBlockStart(lines[lineIndex])) {
      paragraphLines.push(lines[lineIndex]);
      lineIndex += 1;
    }
    nodes.push(<p key={`markdown-paragraph-${nodeIndex++}`}>{paragraphLines.map((paragraphLine, paragraphLineIndex) => <span key={`line-${paragraphLineIndex}`}>{renderInlineMarkdown(paragraphLine, `paragraph-${nodeIndex}-${paragraphLineIndex}`)}{paragraphLineIndex < paragraphLines.length - 1 && <br />}</span>)}</p>);
  }

  return nodes;
}

function renderPreviewBlocks(blocks: EditorBlock[], emptyMessage: string) {
  const visibleBlocks = blocks.filter((block) => block.type === "media" || block.value.trim());
  if (!visibleBlocks.length) return <p className="preview-placeholder">{emptyMessage}</p>;
  return visibleBlocks.map((block) => {
    if (block.type === "text") return <div className="preview-block" key={block.id}>{renderMarkdown(block.value, "")}</div>;
    const source = block.media.url ?? block.media.previewUrl;
    return block.media.kind === "video"
      ? <figure className="preview-inline-media" key={block.id}><video src={source} controls playsInline /><figcaption>{block.media.name}</figcaption></figure>
      : <figure className="preview-inline-media" key={block.id}><img src={source} alt={block.media.name} /><figcaption>{block.media.name}</figcaption></figure>;
  });
}

export default function WritePage() {
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
  const [draftSlug] = useState(() => `draft-${Date.now()}`);
  const [draftTitle, setDraftTitle] = useState("");
  const [draftExcerpt, setDraftExcerpt] = useState("");
  const [draftCategory, setDraftCategory] = useState("Notes");
  const [draftTags, setDraftTags] = useState("");
  const [blocks, setBlocks] = useState<EditorBlock[]>(() => [{ id: `text-${Date.now()}`, type: "text", value: "" }]);
  const [dragActive, setDragActive] = useState(false);
  const [saveState, setSaveState] = useState<SaveState>("idle");
  const [articleStatus, setArticleStatus] = useState<ArticleStatus>("draft");
  const [editorMode, setEditorMode] = useState<EditorMode>("write");
  const [siteSettings, setSiteSettings] = useState<SiteSettings>(DEFAULT_SITE_SETTINGS);
  const textAreaRefs = useRef<Record<string, HTMLTextAreaElement | null>>({});
  const selectionByBlock = useRef<Record<string, { start: number; end: number }>>({});
  const blocksRef = useRef(blocks);
  const activeTextBlockId = useRef(blocks[0].id);
  const text = interfaceCopy[siteSettings.language];

  useEffect(() => {
    blocksRef.current = blocks;
  }, [blocks]);

  useEffect(() => {
    const preferences = readSiteSettings();
    // Local preferences are an external browser-side store; hydrate them after the first render.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setSiteSettings(preferences);
    setEditorMode(preferences.defaultEditorMode);
  }, []);

  useEffect(() => {
    document.documentElement.dataset.theme = siteSettings.theme;
  }, [siteSettings.theme]);

  const mediaBlocks = useMemo(() => blocks.filter((block): block is Extract<EditorBlock, { type: "media" }> => block.type === "media"), [blocks]);
  const bodyText = useMemo(() => blocks.filter((block): block is Extract<EditorBlock, { type: "text" }> => block.type === "text").map((block) => block.value).join(" "), [blocks]);
  const articleTags = useMemo(() => [...new Set(draftTags.split(/[\n,，]+/).map((tag) => tag.trim().replace(/^#/, "")).filter(Boolean))], [draftTags]);
  const hasDraftContent = Boolean(draftTitle.trim() || bodyText.trim() || mediaBlocks.length);
  const canPublish = Boolean(draftTitle.trim() && bodyText.trim()) && !mediaBlocks.some((block) => block.media.status === "uploading");
  const wordCount = useMemo(() => countWords(`${draftTitle} ${bodyText}`), [bodyText, draftTitle]);
  const readingTime = Math.max(1, Math.ceil(wordCount / 200));

  const insertMarkdown = (prefix: string, suffix = "", placeholder = "text") => {
    const targetId = activeTextBlockId.current || blocksRef.current.find((block) => block.type === "text")?.id;
    const target = blocksRef.current.find((block) => block.id === targetId && block.type === "text");
    const textarea = targetId ? textAreaRefs.current[targetId] : null;
    if (!target || !textarea) return;
    const selection = selectionByBlock.current[target.id] ?? { start: target.value.length, end: target.value.length };
    const start = selection.start;
    const end = selection.end;
    const selected = target.value.slice(start, end);
    const inserted = selected ? `${prefix}${selected}${suffix}` : `${prefix}${placeholder}${suffix}`;
    const nextValue = `${target.value.slice(0, start)}${inserted}${target.value.slice(end)}`;
    setBlocks((current) => current.map((block) => block.id === target.id && block.type === "text" ? { ...block, value: nextValue } : block));
    setSaveState("dirty");
    window.requestAnimationFrame(() => {
      textarea.focus();
      const cursor = selected ? start + inserted.length : start + prefix.length;
      textarea.setSelectionRange(cursor, selected ? cursor : cursor + placeholder.length);
      selectionByBlock.current[target.id] = { start: cursor, end: selected ? cursor : cursor + placeholder.length };
    });
  };

  const persistArticle = useCallback(async (status: ArticleStatus) => {
    if (!hasDraftContent || mediaBlocks.some((block) => block.media.status === "uploading")) return false;
    setSaveState(status === "published" ? "publishing" : "saving");
    try {
      const response = await fetch(`${STORAGE_URL}/api/articles`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          body: serializeBlocks(blocks),
          excerpt: draftExcerpt,
          category: draftCategory.trim() || "Uncategorized",
          tags: articleTags,
          media: mediaBlocks.filter((block) => block.media.status === "uploaded").map((block) => ({ kind: block.media.kind, name: block.media.name, size: block.media.size, url: block.media.url })),
          slug: draftSlug,
          status,
          title: draftTitle,
        }),
      });
      if (!response.ok) throw new Error("save failed");
      setArticleStatus(status);
      setSaveState(status === "published" ? "published" : "saved");
      return true;
    } catch {
      setSaveState("offline");
      return false;
    }
  }, [articleTags, blocks, draftCategory, draftExcerpt, draftSlug, draftTitle, hasDraftContent, mediaBlocks]);

  const saveDraftNow = useCallback(() => persistArticle("draft"), [persistArticle]);
  const publishArticle = useCallback(() => persistArticle("published"), [persistArticle]);

  useEffect(() => {
    if (!hasDraftContent || mediaBlocks.some((block) => block.media.status === "uploading")) return;
    const timer = window.setTimeout(() => void persistArticle(articleStatus), siteSettings.autoSaveDelay);
    return () => window.clearTimeout(timer);
  }, [articleStatus, blocks, draftExcerpt, draftTitle, hasDraftContent, mediaBlocks, persistArticle, siteSettings.autoSaveDelay]);

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
    setSaveState("dirty");
    for (const file of supportedFiles) {
      const kind = file.type.startsWith("video/") ? "video" : "image";
      const id = makeId(`${file.name}-${file.lastModified}`);
      const item: DraftMedia = { id, kind, name: file.name, previewUrl: URL.createObjectURL(file), size: file.size, status: "uploading" };
      insertMediaBlock(item);
      try {
        const response = await fetch(`${STORAGE_URL}/api/media?slug=${encodeURIComponent(draftSlug)}&kind=${kind}`, {
          method: "POST",
          body: file,
          headers: { "Content-Type": file.type || "application/octet-stream", "X-File-Name": encodeURIComponent(file.name) },
        });
        if (!response.ok) throw new Error("upload failed");
        const result = await response.json();
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

  const removeMedia = (id: string) => {
    const item = mediaBlocks.find((block) => block.media.id === id)?.media;
    if (item?.previewUrl.startsWith("blob:")) URL.revokeObjectURL(item.previewUrl);
    setBlocks((current) => current.filter((block) => block.type !== "media" || block.media.id !== id));
    setSaveState("dirty");
  };

  return (
    <section className="composer write-editor" aria-labelledby="composer-title">
      <div className="composer-header">
        <div>
          <div className="composer-kicker"><p className="eyebrow">{text.editor.newNote}</p><span className="editor-shortcut">{text.editor.shortcut}</span></div>
          <h1 id="composer-title">{text.editor.title}</h1>
          <p className="composer-lede">{text.editor.lede}</p>
        </div>
        <Link className="close-button" href="/" aria-label="Back to notebook">×</Link>
      </div>

      <div className="editor-status-row">
        <div className="editor-path" aria-live="polite">
          <span className={`save-dot ${saveState}`} aria-hidden="true" />
          <span>{saveState === "saving" && text.editor.saving}{saveState === "publishing" && text.editor.publishing}{saveState === "saved" && text.editor.saved}{saveState === "published" && text.editor.published}{saveState === "offline" && text.editor.offline}{saveState === "dirty" && text.editor.dirty}{saveState === "idle" && text.editor.ready}</span>
          <code>/Volumes/T7Shield/myblog</code>
        </div>
        <div className="editor-stats" aria-label="Draft statistics">
          <span>{wordCount} {text.editor.words}</span><span>·</span><span>{readingTime} {text.editor.read}</span><span>·</span><span>{mediaBlocks.length} {mediaBlocks.length === 1 ? text.editor.attachment : text.editor.attachments}</span>
        </div>
      </div>

      <div className="editor-layout">
        <div className="composer-main">
          <div className="composer-fields">
            <div className="title-field"><label htmlFor="draft-title">{text.editor.titleLabel}</label><input id="draft-title" value={draftTitle} onChange={(event) => { setDraftTitle(event.target.value); setSaveState("dirty"); }} placeholder={text.editor.titlePlaceholder} /></div>
            <div className="excerpt-field"><label htmlFor="draft-excerpt">{text.editor.introLabel} <span>{text.editor.introOptional}</span></label><input id="draft-excerpt" value={draftExcerpt} onChange={(event) => { setDraftExcerpt(event.target.value); setSaveState("dirty"); }} placeholder={text.editor.introPlaceholder} /></div>
          </div>
          <div className="composer-fields article-metadata-fields">
            <div className="category-field"><label htmlFor="draft-category">{text.editor.categoryLabel}</label><input id="draft-category" value={draftCategory} onChange={(event) => { setDraftCategory(event.target.value); setSaveState("dirty"); }} placeholder={text.editor.categoryPlaceholder} /></div>
            <div className="tags-field"><label htmlFor="draft-tags">{text.editor.tagsLabel} <span>{text.editor.tagsOptional}</span></label><input id="draft-tags" value={draftTags} onChange={(event) => { setDraftTags(event.target.value); setSaveState("dirty"); }} placeholder={text.editor.tagsPlaceholder} /></div>
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
                    className={`block-textarea ${index === 0 ? "primary" : ""}`}
                    id={index === 0 ? "draft-body" : undefined}
                    value={block.value}
                    rows={Math.max(10, Math.min(24, block.value.split("\n").length + 5))}
                    onFocus={(event) => rememberSelection(block.id, event.currentTarget)}
                    onClick={(event) => rememberSelection(block.id, event.currentTarget)}
                    onSelect={(event) => rememberSelection(block.id, event.currentTarget)}
                    onChange={(event) => {
                      rememberSelection(block.id, event.currentTarget);
                      setBlocks((current) => current.map((item) => item.id === block.id && item.type === "text" ? { ...item, value: event.target.value } : item));
                      setSaveState("dirty");
                    }}
                    onKeyDown={(event) => { if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") { event.preventDefault(); void saveDraftNow(); } }}
                    placeholder={index === 0 ? text.editor.notePlaceholder : text.editor.notePlaceholder}
                  />
                ) : (
                  <div className={`inline-media-block ${block.media.status}`} key={block.id}>
                    {block.media.kind === "video" ? <video src={block.media.previewUrl} muted controls playsInline preload="metadata" /> : <img src={block.media.previewUrl} alt={block.media.name} />}
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
              <div className="preview-copy">{renderPreviewBlocks(blocks, text.editor.emptyPreview)}</div>
            </article>
          )}

          <div className={`editor-dropzone ${dragActive ? "is-dragging" : ""}`} onDragEnter={(event) => { event.preventDefault(); setDragActive(true); }} onDragOver={(event) => { event.preventDefault(); setDragActive(true); }} onDragLeave={(event) => { event.preventDefault(); setDragActive(false); }} onDrop={(event) => { event.preventDefault(); setDragActive(false); void uploadFiles(event.dataTransfer.files); }}>
            <input id="media-picker" className="visually-hidden" type="file" accept="image/*,video/*" multiple onChange={(event) => { if (event.target.files) void uploadFiles(event.target.files); event.currentTarget.value = ""; }} />
            <label htmlFor="media-picker" className="dropzone-label"><span className="dropzone-icon" aria-hidden="true">＋</span><span><strong>{text.editor.drop}</strong><small>{text.editor.browse}</small></span><span className="dropzone-action">{text.editor.addMedia}</span></label>
          </div>

        </div>

        <aside className="editor-aside">
          <div className="aside-card"><p className="aside-label">{text.editor.checklist}</p><ul className="editor-checklist"><li className={draftTitle.trim() ? "complete" : ""}><span>✓</span> {text.editor.checklistTitle}</li><li className={bodyText.trim() ? "complete" : ""}><span>✓</span> {text.editor.checklistIdea}</li><li className={mediaBlocks.length ? "complete" : ""}><span>✓</span> {text.editor.checklistMedia}</li></ul></div>
          {siteSettings.showWritingPrompt && <div className="aside-card aside-tip"><p className="aside-label">{text.editor.promptLabel}</p><p>{text.editor.prompt}</p><span>{text.editor.promptHint}</span></div>}
        </aside>
      </div>

      <div className="composer-footer">
        <span>{text.editor.filesGoTo} <strong>articles/</strong> {text.editor.filesGoTo === "Files go to" ? "and" : "和"} <strong>media/</strong></span>
        <div className="composer-footer-actions">
          <button className="save-draft-button" type="button" onClick={() => void saveDraftNow()} disabled={!hasDraftContent || saveState === "saving" || saveState === "publishing" || mediaBlocks.some((block) => block.media.status === "uploading")}>
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
