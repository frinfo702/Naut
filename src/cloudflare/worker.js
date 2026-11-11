// Serves published notes. Each note is one KV entry: key = slug, value =
// a complete HTML page rendered by libnaut. Publishing writes the key,
// unpublishing deletes it, so this Worker never needs redeploying.
//
// Images pasted into notes live under "images/<hash>.<ext>". The name is
// the content's hash, so one never changes and can be cached for good.
const imageTypes = {
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
  heic: "image/heic",
  tiff: "image/tiff",
};

export default {
  async fetch(request, env) {
    let slug;
    try {
      slug = decodeURIComponent(new URL(request.url).pathname.slice(1));
    } catch {
      // Malformed escapes like "%E0%A4%A" can't name a note.
      slug = "";
    }
    if (slug.startsWith("images/")) {
      const type = imageTypes[slug.split(".").pop().toLowerCase()];
      const body = type ? await env.NOTES.get(slug, "arrayBuffer") : null;
      if (body === null) return new Response("Not found", { status: 404 });
      return new Response(body, {
        headers: {
          "content-type": type,
          "cache-control": "public, max-age=31536000, immutable",
        },
      });
    }
    const html = slug ? await env.NOTES.get(slug) : null;
    if (html === null) return new Response("Not found", { status: 404 });
    return new Response(html, {
      headers: { "content-type": "text/html; charset=utf-8" },
    });
  },
};
