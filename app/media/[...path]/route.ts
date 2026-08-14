import { proxyToLocalStorage } from "../../../lib/server/local-storage";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

type RouteContext = {
  params: Promise<{ path: string[] }>;
};

async function proxy(request: Request, context: RouteContext) {
  const { path } = await context.params;
  return proxyToLocalStorage(request, `/media/${path.map(encodeURIComponent).join("/")}`);
}

export const GET = proxy;
export const HEAD = proxy;
