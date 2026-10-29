// Adds copy buttons to code blocks. Exposed as naut.enhance(root) so the
// app can call it again after swapping the content of <main> without
// reloading the page (no flicker, scroll kept). Math and highlighting are
// done in libnaut; this is the only script on the page.
window.naut = {
  enhance(root = document) {
    for (const pre of root.querySelectorAll("pre")) {
      const button = document.createElement("button");
      button.className = "copy";
      button.ariaLabel = "Copy";
      button.innerHTML = naut.icons.copy;
      button.onclick = async () => {
        await navigator.clipboard.writeText(pre.querySelector("code").innerText);
        button.innerHTML = naut.icons.check;
        button.classList.add("done");
        setTimeout(() => {
          button.innerHTML = naut.icons.copy;
          button.classList.remove("done");
        }, 1200);
      };
      pre.append(button);
    }
  },

  icons: {
    copy: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><rect x="5.5" y="5.5" width="8" height="8" rx="2"/><path d="M10.5 3.5v-.5a1.5 1.5 0 0 0-1.5-1.5H4A1.5 1.5 0 0 0 2.5 3v5A1.5 1.5 0 0 0 4 9.5h.5"/></svg>',
    check: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M3 8.5l3 3 7-7"/></svg>',
  },
};

addEventListener("DOMContentLoaded", () => naut.enhance());
