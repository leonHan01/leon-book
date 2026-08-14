"use client";

import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import { uploadMedia } from "../../lib/blog-client";

type UploadStatus = "ready" | "uploading" | "uploaded" | "error";

type ImagingFile = {
  error?: string;
  file: File;
  id: string;
  key?: string;
  previewUrl: string;
  remoteUrl?: string;
  status: UploadStatus;
};

type UploadResponse = {
  error?: string;
  key?: string;
  url?: string;
};

const MAX_FILES = 12;
const MAX_FILE_BYTES = 25 * 1024 * 1024;
const ACCEPTED_TYPES = new Set([
  "image/avif",
  "image/gif",
  "image/jpeg",
  "image/png",
  "image/webp",
]);

function makeId() {
  return `image-${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

function formatBytes(bytes: number) {
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

const statusCopy: Record<UploadStatus, string> = {
  error: "上传失败",
  ready: "等待上传",
  uploaded: "已保存",
  uploading: "上传中",
};

export default function UploadClient() {
  const [images, setImages] = useState<ImagingFile[]>([]);
  const [dragging, setDragging] = useState(false);
  const [notice, setNotice] = useState("");
  const [uploading, setUploading] = useState(false);
  const activeUrls = useRef(new Set<string>());

  useEffect(() => {
    const urls = activeUrls.current;
    return () => urls.forEach((url) => URL.revokeObjectURL(url));
  }, []);

  const addFiles = (incoming: File[]) => {
    if (!incoming.length) return;

    const existing = new Set(images.map(({ file }) => `${file.name}:${file.size}:${file.lastModified}`));
    const available = Math.max(0, MAX_FILES - images.length);
    const accepted: File[] = [];
    let rejectedType = 0;
    let rejectedSize = 0;
    let duplicate = 0;

    for (const file of incoming) {
      const signature = `${file.name}:${file.size}:${file.lastModified}`;
      if (!ACCEPTED_TYPES.has(file.type)) {
        rejectedType += 1;
      } else if (file.size > MAX_FILE_BYTES) {
        rejectedSize += 1;
      } else if (existing.has(signature)) {
        duplicate += 1;
      } else if (accepted.length < available) {
        existing.add(signature);
        accepted.push(file);
      }
    }

    const additions = accepted.map((file): ImagingFile => {
      const previewUrl = URL.createObjectURL(file);
      activeUrls.current.add(previewUrl);
      return { file, id: makeId(), previewUrl, status: "ready" };
    });
    setImages((current) => [...current, ...additions]);

    const messages = [
      rejectedType ? `${rejectedType} 张格式不支持` : "",
      rejectedSize ? `${rejectedSize} 张超过 25 MB` : "",
      duplicate ? `${duplicate} 张已在列表中` : "",
      incoming.length - accepted.length - rejectedType - rejectedSize - duplicate > 0
        ? `每批最多 ${MAX_FILES} 张`
        : "",
    ].filter(Boolean);
    setNotice(messages.length ? messages.join("；") : `已加入 ${accepted.length} 张影像。`);
  };

  const removeImage = (id: string) => {
    setImages((current) => {
      const target = current.find((image) => image.id === id);
      if (target) {
        URL.revokeObjectURL(target.previewUrl);
        activeUrls.current.delete(target.previewUrl);
      }
      return current.filter((image) => image.id !== id);
    });
  };

  const uploadImage = async (image: ImagingFile) => {
    setImages((current) => current.map((item) => (
      item.id === image.id ? { ...item, error: undefined, status: "uploading" } : item
    )));

    try {
      const result = await uploadMedia(image.file, { kind: "image" }) as UploadResponse;
      if (!result.url || !result.key) throw new Error("服务器暂时无法保存这张影像。");

      setImages((current) => current.map((item) => (
        item.id === image.id
          ? { ...item, key: result.key, remoteUrl: result.url, status: "uploaded" }
          : item
      )));
      return true;
    } catch (error) {
      const message = error instanceof Error ? error.message : "上传失败，请稍后重试。";
      setImages((current) => current.map((item) => (
        item.id === image.id ? { ...item, error: message, status: "error" } : item
      )));
      return false;
    }
  };

  const uploadAll = async () => {
    const pending = images.filter((image) => image.status === "ready" || image.status === "error");
    if (!pending.length || uploading) return;

    setUploading(true);
    setNotice(`正在保存 ${pending.length} 张影像…`);
    let uploadedCount = 0;
    for (const image of pending) {
      if (await uploadImage(image)) uploadedCount += 1;
    }
    setUploading(false);
    setNotice(
      uploadedCount === pending.length
        ? `${uploadedCount} 张影像已安全写入媒体库。`
        : `${uploadedCount} 张已保存，${pending.length - uploadedCount} 张需要重试。`,
    );
  };

  const pendingCount = images.filter((image) => image.status === "ready" || image.status === "error").length;
  const uploadedCount = images.filter((image) => image.status === "uploaded").length;

  return (
    <main className="imaging-page">
      <header className="imaging-header">
        <Link className="imaging-brand" href="/" aria-label="返回 Notebook 36 首页">
          <span className="imaging-brand-mark">N°</span>
          <span>
            <strong>Notebook 36</strong>
            <small>Image intake</small>
          </span>
        </Link>
        <Link className="imaging-back" href="/">
          <span aria-hidden="true">←</span> 返回首页
        </Link>
      </header>

      <div className="imaging-layout">
        <section className="imaging-intro" aria-labelledby="imaging-title">
          <p className="imaging-kicker"><span /> 影像入库 · 01</p>
          <h1 id="imaging-title">上传影像，<br /><em>保留每一处细节。</em></h1>
          <p className="imaging-lede">
            将需要整理的影像集中上传到媒体库。选择完成后可先检查预览，再一次提交整批图片。
          </p>

          <dl className="imaging-facts">
            <div><dt>格式</dt><dd>JPG · PNG · WEBP · GIF · AVIF</dd></div>
            <div><dt>容量</dt><dd>单张不超过 25 MB</dd></div>
            <div><dt>数量</dt><dd>每批最多 12 张</dd></div>
          </dl>

          <aside className="imaging-privacy">
            <span className="imaging-privacy-icon" aria-hidden="true">!</span>
            <div>
              <strong>上传前请检查隐私信息</strong>
              <p>请移除姓名、证件号、联系方式等可识别个人身份的内容。</p>
            </div>
          </aside>
        </section>

        <section className="imaging-workspace" aria-labelledby="batch-title">
          <div className="imaging-workspace-heading">
            <div>
              <p className="imaging-kicker">New batch</p>
              <h2 id="batch-title">新建影像批次</h2>
            </div>
            <p><span className="imaging-live-dot" /> 本机媒体目录已连接</p>
          </div>

          <div
            className={`imaging-dropzone ${dragging ? "is-dragging" : ""}`}
            onDragEnter={(event) => { event.preventDefault(); setDragging(true); }}
            onDragLeave={(event) => { event.preventDefault(); setDragging(false); }}
            onDragOver={(event) => event.preventDefault()}
            onDrop={(event) => {
              event.preventDefault();
              setDragging(false);
              addFiles(Array.from(event.dataTransfer.files));
            }}
          >
            <input
              id="imaging-file-input"
              className="visually-hidden"
              type="file"
              accept="image/jpeg,image/png,image/webp,image/gif,image/avif"
              multiple
              onChange={(event) => {
                addFiles(Array.from(event.target.files ?? []));
                event.target.value = "";
              }}
            />
            <label htmlFor="imaging-file-input">
              <span className="imaging-add-icon" aria-hidden="true">+</span>
              <span>
                <strong>拖入影像，或点击选择</strong>
                <small>可以一次选择多张图片</small>
              </span>
              <span className="imaging-select-action">选择图片 <i aria-hidden="true">↗</i></span>
            </label>
          </div>

          <div className="imaging-list-heading" aria-live="polite">
            <div>
              <strong>{images.length ? `已选择 ${images.length} 张` : "等待选择影像"}</strong>
              <span>{notice || "图片会先在浏览器中预览，确认后再上传。"}</span>
            </div>
            {images.length > 0 && <span className="imaging-counter">{uploadedCount}/{images.length} 已保存</span>}
          </div>

          {images.length > 0 ? (
            <ul className="imaging-grid" aria-label="待上传影像">
              {images.map((image, index) => (
                <li className={`imaging-card is-${image.status}`} key={image.id}>
                  <div className="imaging-preview">
                    {/* Blob previews are local, short-lived URLs and cannot use Next Image optimization. */}
                    {/* eslint-disable-next-line @next/next/no-img-element */}
                    <img src={image.previewUrl} alt={`影像预览 ${index + 1}：${image.file.name}`} />
                    <span className="imaging-index">{String(index + 1).padStart(2, "0")}</span>
                    {image.status === "uploading" && <span className="imaging-progress" />}
                  </div>
                  <div className="imaging-card-copy">
                    <strong title={image.file.name}>{image.file.name}</strong>
                    <span>{formatBytes(image.file.size)}</span>
                    {image.error && <small title={image.error}>{image.error}</small>}
                  </div>
                  <span className={`imaging-status is-${image.status}`}>{statusCopy[image.status]}</span>
                  {image.remoteUrl ? (
                    <a className="imaging-view" href={image.remoteUrl} target="_blank" rel="noreferrer">查看</a>
                  ) : (
                    <button
                      className="imaging-remove"
                      type="button"
                      aria-label={`移除 ${image.file.name}`}
                      disabled={image.status === "uploading"}
                      onClick={() => removeImage(image.id)}
                    >×</button>
                  )}
                </li>
              ))}
            </ul>
          ) : (
            <div className="imaging-empty" aria-hidden="true">
              <span>01</span><span>02</span><span>03</span>
            </div>
          )}

          <footer className="imaging-actions">
            <p><span aria-hidden="true">⌁</span> 上传期间请保持页面开启</p>
            <button
              className="imaging-upload-button"
              type="button"
              disabled={!pendingCount || uploading}
              onClick={uploadAll}
            >
              {uploading ? "正在上传…" : pendingCount ? `上传 ${pendingCount} 张影像` : images.length ? "本批次已完成" : "上传影像"}
              <span aria-hidden="true">→</span>
            </button>
          </footer>
        </section>
      </div>
    </main>
  );
}
