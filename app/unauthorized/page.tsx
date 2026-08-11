import Link from "next/link";

export default function UnauthorizedPage() {
  return (
    <main className="article-page">
      <div className="article-state">
        <p className="eyebrow">Notebook 36</p>
        <h1>没有管理权限</h1>
        <p>当前账号可以阅读公开文章，但不在这个站点的作者名单中。</p>
        <Link className="text-link" href="/">
          返回首页 <span aria-hidden="true">↗</span>
        </Link>
      </div>
    </main>
  );
}
