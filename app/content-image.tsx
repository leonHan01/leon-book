import type { ImgHTMLAttributes } from "react";

type ContentImageProps = Omit<ImgHTMLAttributes<HTMLImageElement>, "alt" | "decoding" | "loading"> & {
  alt: string;
  priority?: boolean;
};

/**
 * Blog images may be author-configured remote URLs or local blob previews, so
 * they cannot safely be sent through a permissive server-side image proxy.
 */
export function ContentImage({ alt, priority = false, ...props }: ContentImageProps) {
  /* eslint-disable-next-line @next/next/no-img-element -- See component contract above. */
  return <img {...props} alt={alt} decoding="async" fetchPriority={priority ? "high" : props.fetchPriority} loading={priority ? "eager" : "lazy"} />;
}
