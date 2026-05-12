import Foundation

enum ImageCandidateScriptBuilder {
    static func makeScript() -> String {
        #"""
        (() => {
          function textOf(el) {
            return (el && el.innerText) ? el.innerText.trim() : "";
          }

          function attr(el, name) {
            const value = el.getAttribute(name);
            return value == null ? "" : String(value);
          }

          function classListString(el) {
            if (!el || !el.classList) { return ""; }
            return Array.from(el.classList).join(" ");
          }

          function collectAncestors(el, maxDepth = 6) {
            const out = [];
            let current = el.parentElement;
            let depth = 0;

            while (current && depth < maxDepth) {
              out.push({
                tag: (current.tagName || "").toLowerCase(),
                id: current.id || "",
                className: classListString(current),
                role: attr(current, "role")
              });
              current = current.parentElement;
              depth += 1;
            }

            return out;
          }

          function nearestTextBlockLength(el) {
            const block = el.closest("figure, article, section, main, div, p, li");
            if (!block) { return 0; }
            return textOf(block).length;
          }

          function filenameFromUrl(url) {
            try {
              const parsed = new URL(url, document.baseURI);
              const path = parsed.pathname || "";
              const segment = path.split("/").filter(Boolean).pop() || "";
              return segment.toLowerCase();
            } catch {
              return "";
            }
          }

          const images = Array.from(document.images);

          return JSON.stringify(images.map((img, index) => {
            const rect = img.getBoundingClientRect();
            const figure = img.closest("figure");
            const link = img.closest("a");
            const currentSrc = img.currentSrc || img.src || attr(img, "src");
            const computedStyle = window.getComputedStyle(img);
            const isVisible =
              rect.width > 0 &&
              rect.height > 0 &&
              computedStyle.visibility !== "hidden" &&
              computedStyle.display !== "none" &&
              computedStyle.opacity !== "0";

            return {
              index,
              src: attr(img, "src"),
              currentSrc,
              alt: img.alt || "",
              title: img.title || "",
              id: img.id || "",
              className: classListString(img),
              naturalWidth: Number(img.naturalWidth || 0),
              naturalHeight: Number(img.naturalHeight || 0),
              renderedWidth: Number(rect.width || 0),
              renderedHeight: Number(rect.height || 0),
              top: Number(rect.top + window.scrollY || 0),
              left: Number(rect.left + window.scrollX || 0),
              loading: attr(img, "loading"),
              decoding: attr(img, "decoding"),
              role: attr(img, "role"),
              ariaHidden: attr(img, "aria-hidden"),
              isVisible,
              inArticle: !!img.closest("article, main, [role='main'], .content, .post, .entry, .article, .markdown-body"),
              inHeader: !!img.closest("header, [role='banner'], .header, .site-header"),
              inNav: !!img.closest("nav, .nav, .navbar, .menu"),
              inFooter: !!img.closest("footer, .footer, .site-footer"),
              inAside: !!img.closest("aside, .sidebar"),
              inFigure: !!figure,
              figcaption: figure ? textOf(figure.querySelector("figcaption")) : "",
              linkedHref: link ? (link.href || "") : "",
              linkedToRoot: link ? (() => {
                try {
                  const parsed = new URL(link.href, document.baseURI);
                  return parsed.pathname === "/" || parsed.pathname === "";
                } catch {
                  return false;
                }
              })() : false,
              filename: filenameFromUrl(currentSrc),
              isDataUri: currentSrc.startsWith("data:"),
              isSvg: currentSrc.toLowerCase().includes(".svg") || currentSrc.startsWith("data:image/svg"),
              nearestTextBlockLength: nearestTextBlockLength(img),
              ancestors: collectAncestors(img, 6)
            };
          }));
        })()
        """#
    }
}
