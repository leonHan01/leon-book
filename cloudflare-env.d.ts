/**
 * Project-scoped Cloudflare runtime declarations.
 *
 * These interfaces intentionally cover the bindings and runtime APIs used by
 * this application. Keep them in sync with the Worker compatibility date when
 * adding new Cloudflare APIs.
 */

interface Fetcher {
  fetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response>;
}

interface D1Meta {
  duration: number;
  size_after: number;
  rows_read: number;
  rows_written: number;
  last_row_id: number;
  changed_db: boolean;
  changes: number;
  served_by_region?: string;
  served_by_colo?: string;
  served_by_primary?: boolean;
  total_attempts?: number;
}

interface D1Response {
  success: true;
  meta: D1Meta & Record<string, unknown>;
  error?: never;
}

type D1Result<T = unknown> = D1Response & {
  results: T[];
};

interface D1ExecResult {
  count: number;
  duration: number;
}

type D1SessionConstraint = "first-primary" | "first-unconstrained";
type D1SessionBookmark = string;

declare abstract class D1Database {
  prepare(query: string): D1PreparedStatement;
  batch<T = unknown>(statements: D1PreparedStatement[]): Promise<D1Result<T>[]>;
  exec(query: string): Promise<D1ExecResult>;
  withSession(constraintOrBookmark?: D1SessionBookmark | D1SessionConstraint): D1DatabaseSession;
  dump(): Promise<ArrayBuffer>;
}

declare abstract class D1DatabaseSession {
  prepare(query: string): D1PreparedStatement;
  batch<T = unknown>(statements: D1PreparedStatement[]): Promise<D1Result<T>[]>;
  getBookmark(): D1SessionBookmark | null;
}

declare abstract class D1PreparedStatement {
  bind(...values: unknown[]): D1PreparedStatement;
  first<T = unknown>(columnName: string): Promise<T | null>;
  first<T = Record<string, unknown>>(): Promise<T | null>;
  run<T = Record<string, unknown>>(): Promise<D1Result<T>>;
  all<T = Record<string, unknown>>(): Promise<D1Result<T>>;
  raw<T = unknown[]>(options: { columnNames: true }): Promise<[string[], ...T[]]>;
  raw<T = unknown[]>(options?: { columnNames?: false }): Promise<T[]>;
}

interface R2HTTPMetadata {
  contentType?: string;
  contentLanguage?: string;
  contentDisposition?: string;
  contentEncoding?: string;
  cacheControl?: string;
  cacheExpiry?: Date;
}

interface R2Conditional {
  etagMatches?: string;
  etagDoesNotMatch?: string;
  uploadedBefore?: Date;
  uploadedAfter?: Date;
  secondsGranularity?: boolean;
}

type R2Range =
  | { offset: number; length?: number }
  | { offset?: number; length: number }
  | { suffix: number };

interface R2GetOptions {
  onlyIf?: R2Conditional | Headers;
  range?: R2Range | Headers;
  ssecKey?: ArrayBuffer | string;
}

interface R2PutOptions {
  onlyIf?: R2Conditional | Headers;
  httpMetadata?: R2HTTPMetadata | Headers;
  customMetadata?: Record<string, string>;
  md5?: ArrayBuffer | ArrayBufferView | string;
  sha1?: ArrayBuffer | ArrayBufferView | string;
  sha256?: ArrayBuffer | ArrayBufferView | string;
  sha384?: ArrayBuffer | ArrayBufferView | string;
  sha512?: ArrayBuffer | ArrayBufferView | string;
  storageClass?: string;
  ssecKey?: ArrayBuffer | string;
}

interface R2ListOptions {
  limit?: number;
  prefix?: string;
  cursor?: string;
  delimiter?: string;
  startAfter?: string;
  include?: Array<"httpMetadata" | "customMetadata">;
}

declare abstract class R2Object {
  readonly key: string;
  readonly version: string;
  readonly size: number;
  readonly etag: string;
  readonly httpEtag: string;
  readonly uploaded: Date;
  readonly httpMetadata?: R2HTTPMetadata;
  readonly customMetadata?: Record<string, string>;
  readonly range?: R2Range;
  readonly storageClass: string;
  writeHttpMetadata(headers: Headers): void;
}

interface R2ObjectBody extends R2Object {
  readonly body: ReadableStream;
  readonly bodyUsed: boolean;
  arrayBuffer(): Promise<ArrayBuffer>;
  bytes(): Promise<Uint8Array>;
  text(): Promise<string>;
  json<T>(): Promise<T>;
  blob(): Promise<Blob>;
}

interface R2Objects {
  objects: R2Object[];
  truncated: boolean;
  cursor?: string;
  delimitedPrefixes: string[];
}

interface R2Bucket {
  head(key: string): Promise<R2Object | null>;
  get(key: string, options?: R2GetOptions): Promise<R2ObjectBody | null>;
  put(
    key: string,
    value: ReadableStream | ArrayBuffer | ArrayBufferView | string | null | Blob,
    options?: R2PutOptions,
  ): Promise<R2Object>;
  delete(keys: string | string[]): Promise<void>;
  list(options?: R2ListOptions): Promise<R2Objects>;
}

declare namespace Cloudflare {
  interface Env {
    ASSETS: Fetcher;
    DB: D1Database;
    UPLOADS: R2Bucket;
    BLOG_ALLOW_LOCAL_WRITES?: string;
    BLOG_AUTHOR_EMAILS?: string;
    BLOG_AUTHOR_USER_IDS?: string;
  }
}

declare module "cloudflare:workers" {
  export const env: Cloudflare.Env;
}
