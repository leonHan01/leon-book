import UploadClient from "./upload-client";
import { requireBlogAuthor } from "../chatgpt-auth";

export const dynamic = "force-dynamic";

async function AuthorizedUpload() {
  await requireBlogAuthor("/upload");
  return <UploadClient />;
}

export default function UploadPage() {
  return <AuthorizedUpload />;
}
