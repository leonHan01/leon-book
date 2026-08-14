/** Cloudflare Worker entry point for the vinext-starter template. */
import { handleImageOptimization, DEFAULT_DEVICE_SIZES, DEFAULT_IMAGE_SIZES } from "vinext/server/image-optimization";
import handler from "vinext/server/app-router-entry";
import {
  createBlogApiHandler,
  servePublicUpload,
  type BlogApiEnvironment,
} from "../lib/server/blog-api";

interface Env extends BlogApiEnvironment {
  ASSETS: {
    fetch(request: Request): Promise<Response>;
  };
  IMAGES: {
    input(stream: ReadableStream): {
      transform(options: Record<string, unknown>): {
        output(options: { format: string; quality: number }): Promise<{ response(): Response }>;
      };
    };
  };
}

interface ExecutionContext {
  waitUntil(promise: Promise<unknown>): void;
  passThroughOnException(): void;
}

// Image security config. SVG sources with .svg extension auto-skip the
// optimization endpoint on the client side (served directly, no proxy).
// To route SVGs through the optimizer (with security headers), set
// dangerouslyAllowSVG: true in next.config.js and uncomment below:
// const imageConfig: ImageConfig = { dangerouslyAllowSVG: true };

function withSecurityHeaders(response: Response): Response {
  const secured = new Response(response.body, response);
  secured.headers.set("X-Content-Type-Options", "nosniff");
  secured.headers.set("Referrer-Policy", "strict-origin-when-cross-origin");
  secured.headers.set("Permissions-Policy", "camera=(), microphone=(), geolocation=()");
  return secured;
}

function isBlogApiPath(pathname: string): boolean {
  return (
    pathname === "/api/articles" ||
    pathname.startsWith("/api/articles/") ||
    pathname === "/api/activity" ||
    pathname === "/api/site-settings" ||
    pathname === "/api/media" ||
    pathname === "/api/imaging"
  );
}

const worker = {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    if (isBlogApiPath(url.pathname)) {
      try {
        const response = await createBlogApiHandler({ env })(request);
        return withSecurityHeaders(response);
      } catch (error) {
        console.error("[blog-api] Unhandled request error", error);
        return withSecurityHeaders(Response.json(
          { error: "Internal server error" },
          { status: 500, headers: { "Cache-Control": "no-store" } },
        ));
      }
    }

    if (
      url.pathname.startsWith("/uploads/") &&
      (request.method === "GET" || request.method === "HEAD")
    ) {
      return withSecurityHeaders(await servePublicUpload(request, env.UPLOADS));
    }

    if (url.pathname === "/_vinext/image") {
      const allowedWidths = [...DEFAULT_DEVICE_SIZES, ...DEFAULT_IMAGE_SIZES];
      const response = await handleImageOptimization(request, {
        fetchAsset: (path) => env.ASSETS.fetch(new Request(new URL(path, request.url))),
        transformImage: async (body, { width, format, quality }) => {
          const result = await env.IMAGES.input(body).transform(width > 0 ? { width } : {}).output({ format, quality });
          return result.response();
        },
      }, allowedWidths);
      return withSecurityHeaders(response);
    }

    return withSecurityHeaders(await handler.fetch(request, env, ctx));
  },
};

export default worker;
