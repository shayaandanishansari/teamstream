import { useState } from "react";

/* A poster frame with a graceful hole in it. video_editor's bits.js, ported.
 *
 * Its comment: "Posters are generated on demand and a file that will not decode
 * should cost one grey box, not the grid." That mattered there for the odd
 * unplayable clip. Here it fires constantly and by design — a zip, a .docx and
 * anything at all when ffmpeg is missing from the box all land in the fallback,
 * so the fallback is a first-class state rather than an error path.
 *
 * `loading="lazy"` is the whole laziness story: native, no IntersectionObserver,
 * and it means a folder of fifty only asks the server for what is on screen —
 * which matters because each miss costs a thumbnail generation.
 */
export function Shot({ src, fallback }: { src: string | null; fallback: string }) {
  const [failed, setFailed] = useState(false);

  if (src === null || failed) {
    return (
      <span className="shot shot-empty" aria-hidden="true">
        <span className="shot-ext">{fallback}</span>
      </span>
    );
  }

  return (
    <span className="shot">
      <img src={src} alt="" loading="lazy" decoding="async" onError={() => setFailed(true)} />
    </span>
  );
}
