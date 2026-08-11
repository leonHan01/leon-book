import SettingsClient from "./settings-client";
import { requireBlogAuthor } from "../chatgpt-auth";

export const dynamic = "force-dynamic";

async function AuthorizedSettings() {
  await requireBlogAuthor("/settings");
  return <SettingsClient />;
}

export default function SettingsPage() {
  return <AuthorizedSettings />;
}
