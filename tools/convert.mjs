// Regenerates ../index.html from ../BLOG.md.
// Usage: cd tools && npm install && node convert.mjs
import { Marked } from 'marked';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const src = readFileSync(join(repoRoot, 'BLOG.md'), 'utf8');

// GitHub-style slugs so the article's Table of Contents anchors keep working.
const slugCounts = new Map();
function githubSlug(text) {
  let slug = text
    .toLowerCase()
    .trim()
    .replace(/[^\w\s-]/g, '')
    .replace(/\s+/g, '-');
  const n = slugCounts.get(slug) ?? 0;
  slugCounts.set(slug, n + 1);
  return n === 0 ? slug : `${slug}-${n}`;
}

const escapeHtml = (s) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

const marked = new Marked({ gfm: true });

marked.use({
  renderer: {
    heading({ tokens, depth }) {
      const text = this.parser.parseInline(tokens);
      const raw = tokens.map((t) => t.raw ?? '').join('');
      const id = githubSlug(raw.replace(/[*_`]/g, ''));
      return `<h${depth} id="${id}">${text}</h${depth}>\n`;
    },
    code({ text, lang }) {
      if (lang === 'mermaid') {
        return `<div class="diagram"><pre class="mermaid">${escapeHtml(text)}</pre></div>\n`;
      }
      const cls = lang ? `language-${lang}` : 'language-plaintext';
      return `<pre><code class="${cls}">${escapeHtml(text)}</code></pre>\n`;
    },
  },
});

const body = marked.parse(src);

const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>How to Move a Running Pod Between Kubernetes Nodes and Survive Spot Instance Reclaims</title>
<meta name="description" content="Freeze a live pod with CRIU, carry it off a dying spot node, and restore it on another one — by hand, on kind. A hands-on preview of Kubernetes KEP-5823.">
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github-dark.min.css">
<style>
  :root {
    --bg: #ffffff;
    --fg: #1b1f24;
    --muted: #57606a;
    --accent: #0969da;
    --border: #d0d7de;
    --code-inline-bg: #f0f2f5;
    --table-stripe: #f6f8fa;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0d1117;
      --fg: #e6edf3;
      --muted: #8b949e;
      --accent: #58a6ff;
      --border: #30363d;
      --code-inline-bg: #1c2128;
      --table-stripe: #161b22;
    }
  }
  * { box-sizing: border-box; }
  html { scroll-behavior: smooth; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--fg);
    font: 18px/1.7 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  }
  main {
    max-width: 760px;
    margin: 0 auto;
    padding: 3rem 1.25rem 5rem;
  }
  h1 {
    font-size: 2.2rem;
    line-height: 1.25;
    margin: 0 0 1.5rem;
    letter-spacing: -0.02em;
  }
  h2 {
    font-size: 1.55rem;
    line-height: 1.3;
    margin: 2.5rem 0 1rem;
    padding-top: 0.5rem;
    letter-spacing: -0.01em;
  }
  h3 { font-size: 1.2rem; margin: 2rem 0 0.75rem; }
  h2 a, h3 a { color: inherit; }
  p { margin: 0 0 1.1rem; }
  a { color: var(--accent); text-decoration: none; }
  a:hover { text-decoration: underline; }
  strong { font-weight: 650; }
  ul, ol { padding-left: 1.6rem; margin: 0 0 1.1rem; }
  li { margin-bottom: 0.35rem; }
  hr {
    border: none;
    border-top: 1px solid var(--border);
    margin: 2.5rem 0;
  }
  code {
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
    font-size: 0.85em;
    background: var(--code-inline-bg);
    padding: 0.15em 0.4em;
    border-radius: 5px;
  }
  pre {
    background: #0d1117;
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 1rem 1.2rem;
    overflow-x: auto;
    margin: 0 0 1.1rem;
    line-height: 1.55;
  }
  pre code {
    background: none;
    padding: 0;
    font-size: 0.82rem;
    color: #e6edf3;
  }
  .diagram {
    margin: 1.5rem 0;
    text-align: center;
  }
  .diagram pre.mermaid {
    background: transparent;
    border: none;
    display: flex;
    justify-content: center;
    overflow-x: auto;
  }
  table {
    border-collapse: collapse;
    width: 100%;
    margin: 0 0 1.1rem;
    font-size: 0.95rem;
  }
  th, td {
    border: 1px solid var(--border);
    padding: 0.5rem 0.8rem;
    text-align: left;
  }
  th { background: var(--table-stripe); }
  tr:nth-child(even) td { background: var(--table-stripe); }

  /* Floating table of contents (wide screens only) */
  #toc { display: none; }
  @media (min-width: 1280px) {
    #toc {
      display: block;
      position: fixed;
      top: 3rem;
      left: max(1rem, calc(50vw - 380px - 240px));
      width: 210px;
      max-height: calc(100vh - 6rem);
      overflow-y: auto;
      font-size: 0.8rem;
      line-height: 1.45;
    }
    .inline-toc { display: none; }
  }
  #toc .toc-title {
    font-size: 0.7rem;
    font-weight: 650;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--muted);
    margin-bottom: 0.6rem;
    padding-left: 0.75rem;
  }
  #toc ul { list-style: none; padding: 0; margin: 0; }
  #toc li { margin: 0; }
  #toc a {
    display: block;
    color: var(--muted);
    padding: 0.28rem 0.75rem;
    border-left: 2px solid var(--border);
  }
  #toc a:hover { color: var(--fg); text-decoration: none; }
  #toc a.active {
    color: var(--accent);
    border-left-color: var(--accent);
    font-weight: 600;
  }

  @media (max-width: 640px) {
    body { font-size: 16.5px; }
    h1 { font-size: 1.7rem; }
    h2 { font-size: 1.35rem; }
    main { padding-top: 2rem; }
  }
</style>
</head>
<body>
<nav id="toc" aria-label="Table of contents">
  <div class="toc-title">Contents</div>
  <ul></ul>
</nav>
<main>
${body}
</main>
<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
<script>
  document.querySelectorAll('pre code[class*="language-"]:not(.language-plaintext)')
    .forEach((el) => hljs.highlightElement(el));
</script>
<script>
  // Floating ToC: built from the article's h2 headings, with scrollspy.
  (function () {
    var tocHeading = document.getElementById('table-of-contents');
    if (tocHeading) {
      tocHeading.classList.add('inline-toc');
      var next = tocHeading.nextElementSibling;
      if (next && next.tagName === 'UL') next.classList.add('inline-toc');
    }
    var headings = Array.prototype.filter.call(
      document.querySelectorAll('main h2'),
      function (h) { return h.id && h.id !== 'table-of-contents'; }
    );
    var list = document.querySelector('#toc ul');
    var links = headings.map(function (h) {
      var li = document.createElement('li');
      var a = document.createElement('a');
      a.href = '#' + h.id;
      a.textContent = h.textContent;
      li.appendChild(a);
      list.appendChild(li);
      return a;
    });
    var ticking = false;
    function update() {
      ticking = false;
      var current = -1;
      for (var i = 0; i < headings.length; i++) {
        if (headings[i].getBoundingClientRect().top <= 120) current = i;
      }
      links.forEach(function (a, i) { a.classList.toggle('active', i === current); });
    }
    window.addEventListener('scroll', function () {
      if (!ticking) { ticking = true; requestAnimationFrame(update); }
    }, { passive: true });
    window.addEventListener('resize', function () {
      if (!ticking) { ticking = true; requestAnimationFrame(update); }
    }, { passive: true });
    update();
  })();
</script>
<script type="module">
  import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';
  const dark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  mermaid.initialize({ startOnLoad: true, theme: dark ? 'dark' : 'neutral' });
</script>
</body>
</html>
`;

writeFileSync(join(repoRoot, 'index.html'), html);
console.log('written index.html,', html.length, 'bytes');
