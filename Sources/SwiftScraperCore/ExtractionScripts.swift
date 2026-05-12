import Foundation

enum ExtractionScriptBuilder {
    static func makeScript(for extraction: ExtractionMode) -> String {
        switch extraction {
        case .outerHTML:
            return """
            (() => {
              if (!document.documentElement) { return ''; }
              const clone = document.documentElement.cloneNode(true);
              sanitizeClone(document.documentElement, clone);
              return clone.outerHTML;

              function sanitizeClone(originalRoot, clonedRoot) {
                clonedRoot.querySelectorAll('script, noscript').forEach(node => node.remove());

                const originalIframes = Array.from(originalRoot.querySelectorAll('iframe'));
                const clonedIframes = Array.from(clonedRoot.querySelectorAll('iframe'));

                originalIframes.forEach((iframe, index) => {
                  if (shouldRemoveIframe(iframe)) {
                    clonedIframes[index]?.remove();
                  }
                });
              }

              function shouldRemoveIframe(iframe) {
                if (iframe.hidden) { return true; }

                const style = window.getComputedStyle ? window.getComputedStyle(iframe) : null;
                if (style && (style.display === 'none' || style.visibility === 'hidden')) {
                  return true;
                }

                const rect = iframe.getBoundingClientRect ? iframe.getBoundingClientRect() : null;
                if (rect && (rect.width === 0 || rect.height === 0)) {
                  return true;
                }

                const width = Number.parseFloat(iframe.getAttribute('width') || '');
                const height = Number.parseFloat(iframe.getAttribute('height') || '');
                return (Number.isFinite(width) && width === 0) || (Number.isFinite(height) && height === 0);
              }
            })()
            """
        case .bodyText:
            return "document.body ? document.body.innerText : ''"
        case .selectorInnerHTML(let selector):
            return """
            (() => {
              const element = document.querySelector(\(javascriptStringLiteral(selector)));
              if (!element) { return null; }
              if (element.tagName && ['script', 'noscript'].includes(element.tagName.toLowerCase())) { return ''; }
              if (element.tagName && element.tagName.toLowerCase() === 'iframe' && shouldRemoveIframe(element)) { return ''; }
              const clone = element.cloneNode(true);
              sanitizeClone(element, clone);
              return clone.innerHTML;

              function sanitizeClone(originalRoot, clonedRoot) {
                clonedRoot.querySelectorAll('script, noscript').forEach(node => node.remove());

                const originalIframes = Array.from(originalRoot.querySelectorAll('iframe'));
                const clonedIframes = Array.from(clonedRoot.querySelectorAll('iframe'));

                originalIframes.forEach((iframe, index) => {
                  if (shouldRemoveIframe(iframe)) {
                    clonedIframes[index]?.remove();
                  }
                });
              }

              function shouldRemoveIframe(iframe) {
                if (iframe.hidden) { return true; }

                const style = window.getComputedStyle ? window.getComputedStyle(iframe) : null;
                if (style && (style.display === 'none' || style.visibility === 'hidden')) {
                  return true;
                }

                const rect = iframe.getBoundingClientRect ? iframe.getBoundingClientRect() : null;
                if (rect && (rect.width === 0 || rect.height === 0)) {
                  return true;
                }

                const width = Number.parseFloat(iframe.getAttribute('width') || '');
                const height = Number.parseFloat(iframe.getAttribute('height') || '');
                return (Number.isFinite(width) && width === 0) || (Number.isFinite(height) && height === 0);
              }
            })()
            """
        case .contentOnly:
            return #"""
            (() => {
              \#(pageAnalysisHelpers)
              const analysis = analyzeDocument();
              return analysis.clone ? analysis.clone.outerHTML : '';
            })()
            """#
        case .structureInspection:
            return #"""
            (() => {
              \#(pageAnalysisHelpers)
              const analysis = analyzeDocument();
              const landmarks = {
                header: document.querySelectorAll('header, [role="banner"]').length,
                footer: document.querySelectorAll('footer, [role="contentinfo"]').length,
                nav: document.querySelectorAll('nav, [role="navigation"]').length,
                aside: document.querySelectorAll('aside, [role="complementary"]').length,
                main: document.querySelectorAll('main, [role="main"]').length,
                article: document.querySelectorAll('article').length
              };

              return JSON.stringify({
                title: document.title || '',
                url: window.location ? window.location.href : '',
                landmarks,
                candidate: describeNode(analysis.node),
                candidateTextLength: analysis.textLength,
                testedCandidates: analysis.testedCandidates,
                fallbackToBody: analysis.fallbackToBody,
                contentOnlyRemoval: analysis.removedCounts
              });
            })()
            """#
        }
    }

    private static func javascriptStringLiteral(_ value: String) -> String {
        JavaScriptLiteral.string(value)
    }

    private static var pageAnalysisHelpers: String {
        #"""
        function analyzeDocument() {
          const candidates = collectCandidates();
          const body = document.body || null;
          if (body && !candidates.includes(body)) {
            candidates.push(body);
          }

          let best = null;

          candidates.forEach(node => {
            const clone = node.cloneNode(true);
            const removedCounts = sanitizeClone(clone);
            const textLength = normalizeWhitespace(clone.innerText || clone.textContent || '').length;
            const score = textLength + semanticWeight(node) - Math.floor(linkDensity(node) * 500);

            if (!best || score > best.score) {
              best = {
                node,
                clone,
                removedCounts,
                textLength,
                score,
                fallbackToBody: body !== null && node === body
              };
            }
          });

          if (!best) {
            return {
              node: null,
              clone: null,
              removedCounts: emptyRemovalCounts(),
              textLength: 0,
              testedCandidates: 0,
              fallbackToBody: body !== null
            };
          }

          return {
            node: best.node,
            clone: best.clone,
            removedCounts: best.removedCounts,
            textLength: best.textLength,
            testedCandidates: candidates.length,
            fallbackToBody: best.fallbackToBody
          };
        }

        function collectCandidates() {
          const selectors = [
            'main',
            '[role="main"]',
            'article',
            '#content',
            '#main',
            '.content',
            '.main',
            '.article',
            '.article-body',
            '.article-content',
            '.post-content',
            '.entry-content',
            '.content-body',
            '.page-content',
            '.story-body'
          ];
          const seen = new Set();
          const candidates = [];

          selectors.forEach(selector => {
            document.querySelectorAll(selector).forEach(node => {
              if (!seen.has(node)) {
                seen.add(node);
                candidates.push(node);
              }
            });
          });

          return candidates;
        }

        function sanitizeClone(root) {
          const counts = emptyRemovalCounts();
          walk(root);
          return counts;

          function walk(node) {
            Array.from(node.children).forEach(child => {
              if (isScriptLike(child)) {
                counts.scriptLike += 1;
                child.remove();
                return;
              }

              if (shouldRemoveNode(child)) {
                incrementRemovalCount(child, counts);
                child.remove();
                return;
              }

              walk(child);
            });
          }
        }

        function emptyRemovalCounts() {
          return {
            header: 0,
            footer: 0,
            nav: 0,
            aside: 0,
            sidebarLike: 0,
            hidden: 0,
            scriptLike: 0
          };
        }

        function shouldRemoveNode(node) {
          return isLandmarkChrome(node) || isSidebarLike(node) || isHidden(node);
        }

        function isScriptLike(node) {
          const tag = node.tagName ? node.tagName.toLowerCase() : '';
          return tag === 'script' || tag === 'noscript' || tag === 'template';
        }

        function isLandmarkChrome(node) {
          const tag = node.tagName ? node.tagName.toLowerCase() : '';
          if (tag === 'header' || tag === 'footer' || tag === 'nav' || tag === 'aside') {
            return true;
          }

          const role = (node.getAttribute('role') || '').toLowerCase();
          return role === 'banner' || role === 'contentinfo' || role === 'navigation' || role === 'complementary';
        }

        function isSidebarLike(node) {
          const tokens = nodeTokenSource(node);
          return /(^|\b)(sidebar|side-bar|sidenav|side-nav|rail|right-rail|left-rail|breadcrumbs?|share|social|related|promo|advert|ads)(\b|$)/.test(tokens);
        }

        function isHidden(node) {
          if (node.hidden) {
            return true;
          }

          const ariaHidden = (node.getAttribute('aria-hidden') || '').toLowerCase();
          if (ariaHidden === 'true') {
            return true;
          }

          const style = (node.getAttribute('style') || '').toLowerCase();
          if (style.includes('display:none') || style.includes('display: none') || style.includes('visibility:hidden') || style.includes('visibility: hidden')) {
            return true;
          }

          return /(^|\b)(hidden|sr-only|visually-hidden)(\b|$)/.test(nodeTokenSource(node));
        }

        function incrementRemovalCount(node, counts) {
          if (isLandmarkChrome(node)) {
            const tag = node.tagName ? node.tagName.toLowerCase() : '';
            const role = (node.getAttribute('role') || '').toLowerCase();

            if (tag === 'header' || role === 'banner') {
              counts.header += 1;
              return;
            }

            if (tag === 'footer' || role === 'contentinfo') {
              counts.footer += 1;
              return;
            }

            if (tag === 'nav' || role === 'navigation') {
              counts.nav += 1;
              return;
            }

            if (tag === 'aside' || role === 'complementary') {
              counts.aside += 1;
              return;
            }
          }

          if (isSidebarLike(node)) {
            counts.sidebarLike += 1;
            return;
          }

          if (isHidden(node)) {
            counts.hidden += 1;
          }
        }

        function semanticWeight(node) {
          let weight = 0;
          const tag = node.tagName ? node.tagName.toLowerCase() : '';
          const role = (node.getAttribute('role') || '').toLowerCase();
          const tokens = nodeTokenSource(node);

          if (tag === 'main') { weight += 1500; }
          if (tag === 'article') { weight += 1200; }
          if (role === 'main') { weight += 1200; }
          if (node === document.body) { weight -= 1500; }
          if (/(^|\b)(content|article|story|post|entry|main)(\b|$)/.test(tokens)) { weight += 400; }
          if (/(^|\b)(nav|menu|footer|header|sidebar)(\b|$)/.test(tokens)) { weight -= 1000; }

          return weight;
        }

        function linkDensity(node) {
          const textLength = normalizeWhitespace(node.innerText || node.textContent || '').length;
          if (textLength === 0) {
            return 0;
          }

          let linkTextLength = 0;
          node.querySelectorAll('a').forEach(anchor => {
            linkTextLength += normalizeWhitespace(anchor.innerText || anchor.textContent || '').length;
          });

          return linkTextLength / textLength;
        }

        function normalizeWhitespace(value) {
          return (value || '').replace(/\s+/g, ' ').trim();
        }

        function nodeTokenSource(node) {
          const className = typeof node.className === 'string' ? node.className : (node.getAttribute('class') || '');
          const id = node.id || '';
          const ariaLabel = node.getAttribute('aria-label') || '';
          return `${id} ${className} ${ariaLabel}`.toLowerCase();
        }

        function describeNode(node) {
          if (!node || !node.tagName) {
            return '(not found)';
          }

          const tag = node.tagName.toLowerCase();
          const id = node.id ? `#${node.id}` : '';
          const classes = Array.from(node.classList || []).slice(0, 3).map(name => `.${name}`).join('');
          return `${tag}${id}${classes}`;
        }
        """#
    }
}
