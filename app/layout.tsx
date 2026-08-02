import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  metadataBase: new URL("http://localhost:3000"),
  title: "Notebook 36 — Alex Rivera",
  description:
    "A personal field guide to creative work, everyday rituals, and the images that stay with us.",
  openGraph: {
    title: "Notebook 36 — Alex Rivera",
    description: "Writing, images, and motion by Alex Rivera.",
    type: "website",
    images: [{ url: "/og.png", width: 1734, height: 907, alt: "Notebook 36 social preview" }],
  },
  twitter: {
    card: "summary_large_image",
    title: "Notebook 36 — Alex Rivera",
    description: "Writing, images, and motion by Alex Rivera.",
    images: ["/og.png"],
  },
  icons: { icon: "/favicon.svg", shortcut: "/favicon.svg" },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
