// libnaut C API.
//
// Strings returned by this library are owned by the caller and must be
// released with naut_string_free. Input strings are borrowed for the
// duration of the call. Every function is safe to call from any thread.

#ifndef NAUT_H
#define NAUT_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// A UTF-8 byte string, not NUL-terminated. ptr may be NULL when len is 0.
typedef struct {
  char *ptr;
  size_t len;
} naut_string_s;

typedef struct {
  const char *title;
  size_t title_len;
  // Include the outline sidebar. Published pages want it; the app draws
  // its own.
  bool toc;
} naut_page_options_s;

typedef struct {
  const char *account_id;  // NUL-terminated, 32 hex characters
  const char *api_token;   // NUL-terminated
} naut_cloudflare_s;

void naut_string_free(naut_string_s);

// Markdown to an HTML fragment (the contents of <main>) and its headings
// as JSON: [{"level":1,"text":"...","id":"..."}, ...]. Both outputs are
// always set and must be freed.
void naut_render(const char *src, size_t len, naut_string_s *html,
                 naut_string_s *outline_json);

// Markdown to a complete HTML page with styles and scripts.
naut_string_s naut_render_page(const char *src, size_t len,
                                 const naut_page_options_s *opts);

// Publishing. Each returns true on success. On success *out holds the
// result (JSON, or empty); on failure *out holds a message for the user.
// Either way *out must be freed. These block on the network and, for
// provision, on Terraform: never call them on the main thread.

// Create or update the KV namespace and Worker with Terraform. workdir is
// an absolute directory that keeps Terraform state between runs.
// Result: {"namespace_id":"...","url":"https://..."}
bool naut_cloudflare_provision(const naut_cloudflare_s *cf,
                                const char *workdir, naut_string_s *out);

bool naut_cloudflare_put(const naut_cloudflare_s *cf,
                          const char *namespace_id, const char *key,
                          const char *value, size_t value_len,
                          naut_string_s *out);

bool naut_cloudflare_delete(const naut_cloudflare_s *cf,
                             const char *namespace_id, const char *key,
                             naut_string_s *out);

#ifdef __cplusplus
}
#endif

#endif
