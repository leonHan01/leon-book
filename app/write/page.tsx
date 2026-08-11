import WriteClient from "./write-client";
import { requireBlogAuthor } from "../chatgpt-auth";

export const dynamic = "force-dynamic";

type WritePageProps = {
  searchParams?: Promise<Record<string, string | string[] | undefined>>;
};

async function AuthorizedWriter({ searchParams }: WritePageProps) {
  const query = await searchParams;
  const rawSlug = query?.slug;
  const slug = Array.isArray(rawSlug) ? rawSlug[0] : rawSlug;
  const returnTo = slug ? `/write?slug=${encodeURIComponent(slug)}` : "/write";
  await requireBlogAuthor(returnTo);
  return <WriteClient />;
}

export default function WritePage(props: WritePageProps) {
  return <AuthorizedWriter {...props} />;
}
