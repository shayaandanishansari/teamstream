import { describe, expect, it } from "vitest";
import { fingerprint, uploadFile } from "./filesApi";
import { pb } from "./pb";

/* The REAL client upload loop, against the REAL services.
 *
 * files/tests/verify_service.py drives the server with its own hand-written
 * chunk loop, which proves the server and proves nothing about the client. This
 * imports `uploadFile` itself — the same function the drive page calls — so
 * what is exercised is the chunking, the 409 re-slice and the progress
 * reporting that actually ship.
 *
 * SKIPPED unless the services are up, so `npm test` stays offline-safe. Bring
 * them up with run.bat, or:
 *   backend> pocketbase.exe serve --dir=...\pb_data_dev --hooksDir=...\pb_hooks
 *   files>   uvicorn app.main:app --port 8091
 *   web>     npm run dev
 *
 * Two shims, neither of which changes the code under test: relative URLs
 * (the client is deliberately origin-relative and Node has no origin) and
 * localStorage (the PocketBase SDK's auth store writes to it).
 */

/* Vitest exposes the environment on import.meta.env; `process` is not in this
 * project's type lib, because everything else here is browser code. */
const env = import.meta.env as Record<string, string | undefined>;
const ORIGIN = env.TS_ORIGIN ?? "http://localhost:5173";
const PW = env.TS_DEV_PASSWORD ?? "teamstream-dev-local";

/* Set at MODULE level, not in beforeAll.
 *
 * `it.runIf(live)` is evaluated when the test is DEFINED, not when it runs, so
 * a flag set in beforeAll is still false at collection time and every case
 * skips silently — which is exactly what the first version of this file did,
 * reporting "3 skipped" against services that were up. Top-level await runs
 * before the describe bodies, so the flag is true by the time it is read.
 */
const ORIGIN_FETCH = globalThis.fetch;
globalThis.fetch = ((input: RequestInfo | URL, init?: RequestInit) =>
  ORIGIN_FETCH(
    typeof input === "string" && input.startsWith("/") ? ORIGIN + input : input,
    init,
  )) as typeof fetch;

const mem = new Map<string, string>();
(globalThis as { localStorage?: unknown }).localStorage = {
  getItem: (k: string) => mem.get(k) ?? null,
  setItem: (k: string, v: string) => void mem.set(k, String(v)),
  removeItem: (k: string) => void mem.delete(k),
  clear: () => mem.clear(),
  key: () => null,
  length: 0,
};

let live = false;
try {
  const health = await fetch("/files/health");
  if (health.ok) {
    await pb.collection("members").authWithPassword("shayaan@teamstream.local", PW);
    live = true;
  }
} catch {
  live = false;
}
/** getRandomValues refuses more than 65,536 bytes per call.
 *
 *  Typed over ArrayBuffer explicitly: `Uint8Array` is generic over
 *  ArrayBufferLike in the current lib, and a SharedArrayBuffer-backed view is
 *  not a valid BlobPart. Pinning it here keeps every call site clean. */
function randomBytes(n: number): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(new ArrayBuffer(n));
  for (let i = 0; i < n; i += 65536) {
    crypto.getRandomValues(out.subarray(i, Math.min(i + 65536, n)));
  }
  return out;
}

const sha256 = async (bytes: Uint8Array<ArrayBuffer>): Promise<string> =>
  [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

describe("the client upload loop", () => {
  it.runIf(live)("sends a multi-chunk file and reports progress", async () => {
    // Larger than one 8MB chunk, so the loop genuinely loops.
    const bytes = randomBytes(20 * 1024 * 1024);
    const expected = await sha256(bytes);

    const file = new File([bytes], "big clip.bin", { type: "application/octet-stream" });
    const seen: Array<{ sent: number; chunk: number; chunks: number }> = [];
    const done = await uploadFile(file, {
      folder: "Verification",
      onProgress: (p) => seen.push(p),
    });

    expect(done.sha256).toBe(expected);
    expect(done.size).toBe(bytes.length);
    expect(done.folder).toBe("Verification");
    expect(seen.length).toBeGreaterThan(2);
    expect(seen.at(-1)!.sent).toBe(bytes.length);
    expect(seen.at(-1)!.chunk).toBe(seen.at(-1)!.chunks);
  }, 120_000);

  it.runIf(live)("uploading the same name twice makes a NEW record", async () => {
    // The deletion policy's other half: nothing is ever overwritten, so the
    // store carries a version history for free.
    const bytes = randomBytes(1024);
    const mk = () => new File([bytes], "twice.bin", { type: "application/octet-stream" });

    const first = await uploadFile(mk());
    const second = await uploadFile(mk());

    expect(second.file_id).not.toBe(first.file_id);
    expect(second.sha256).toBe(first.sha256);
  }, 60_000);

  it.runIf(live)("refuses to be confused about the offset", async () => {
    // The server answers a wrong offset with 409 + the true `received`, and
    // uploadFile's only correct response is to re-slice. Provoke it by
    // creating an upload, sending a chunk behind the client's back, and then
    // letting the loop discover it is out of step.
    const bytes = randomBytes(300_000);
    const file = new File([bytes], "raced.bin", { type: "application/octet-stream" });
    const fp = await fingerprint(file, "");

    const created = await fetch("/files/uploads", {
      method: "POST",
      headers: {
        Authorization: pb.authStore.token,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        name: file.name,
        size: file.size,
        mime: file.type,
        folder: "",
        fingerprint: fp,
      }),
    }).then((r) => r.json());

    // Someone else's chunk lands first.
    await fetch(`/files/uploads/${created.upload_id}?offset=0`, {
      method: "PUT",
      headers: {
        Authorization: pb.authStore.token,
        "Content-Type": "application/octet-stream",
      },
      body: bytes.slice(0, 50_000),
    });

    // uploadFile now resumes the SAME upload (same fingerprint) and must pick
    // up at 50000 rather than starting again.
    const done = await uploadFile(file, {});
    expect(done.sha256).toBe(await sha256(bytes));
  }, 60_000);
});

/* The mode goes in the test NAME, not a console.log.
 *
 * A file whose every case is `runIf` reports "skipped" with no explanation, and
 * anything logged at module scope is swallowed — that code runs during
 * collection, before the reporter attaches. The name is the one channel that
 * always reaches the person reading the output. */
it(
  live
    ? `integration cases ran against ${ORIGIN}`
    : `integration cases SKIPPED - ${ORIGIN} is not answering (start the services to run them)`,
  () => {
    expect(typeof live).toBe("boolean");
  },
);
