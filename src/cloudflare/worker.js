// Serves published notes. Each note is one KV entry: key = slug, value =
// a complete HTML page rendered by libnote. Publishing writes the key,
// unpublishing deletes it, so this Worker never needs redeploying.
export default {
  async fetch(request, env) {
    const slug = decodeURIComponent(new URL(request.url).pathname.slice(1));
    const html = slug ? await env.NOTES.get(slug) : null;
    if (html === null) return new Response("Not found", { status: 404 });
    return new Response(html, {
      headers: { "content-type": "text/html; charset=utf-8" },
    });
  },
};
