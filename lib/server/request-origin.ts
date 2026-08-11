const LOCAL_HOSTNAMES = new Set(["localhost", "127.0.0.1", "[::1]"]);

function requestHost(requestHeaders: Pick<Headers, "get">): string {
  const rawHost = requestHeaders.get("x-forwarded-host") ?? requestHeaders.get("host") ?? "";
  return rawHost.split(",", 1)[0].trim();
}

export function isLocalRequestHeaders(requestHeaders: Pick<Headers, "get">): boolean {
  try {
    return LOCAL_HOSTNAMES.has(new URL(`http://${requestHost(requestHeaders)}`).hostname);
  } catch {
    return false;
  }
}

export function requestOrigin(requestHeaders: Pick<Headers, "get">): URL {
  const host = requestHost(requestHeaders);
  const rawProtocol = requestHeaders.get("x-forwarded-proto")?.split(",", 1)[0].trim();

  try {
    const parsedHost = new URL(`http://${host}`);
    const protocol = rawProtocol ?? (LOCAL_HOSTNAMES.has(parsedHost.hostname) ? "http" : "https");
    if (protocol !== "http" && protocol !== "https") throw new Error("Unsupported protocol");

    const origin = new URL(`${protocol}://${host}`);
    if (
      !origin.hostname ||
      origin.username ||
      origin.password ||
      origin.pathname !== "/" ||
      origin.search ||
      origin.hash
    ) {
      throw new Error("Invalid host");
    }
    return origin;
  } catch {
    return new URL("http://localhost:3000");
  }
}
