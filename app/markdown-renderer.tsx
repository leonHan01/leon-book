import type { ReactNode } from "react";
import { ContentImage } from "./content-image";

const HEADING_TAGS = ["h1", "h2", "h3", "h4", "h5", "h6"] as const;

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
      nodes.push(source ? <ContentImage key={key} className="markdown-inline-image" src={source} alt={match[1]} /> : match[0]);
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

export function renderMarkdown(body: string, emptyMessage: string): ReactNode {
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
      const Heading = HEADING_TAGS[heading[1].length - 1] ?? "h6";
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
