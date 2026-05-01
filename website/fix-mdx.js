const fs = require('fs');
const path = require('path');

function walk(dir) {
  let results = [];
  if (!fs.existsSync(dir)) return results;
  const list = fs.readdirSync(dir);
  list.forEach(file => {
    file = path.join(dir, file);
    const stat = fs.statSync(file);
    if (stat && stat.isDirectory()) {
      results = results.concat(walk(file));
    } else if (file.endsWith('.md')) {
      results.push(file);
    }
  });
  return results;
}

const apiRoot = path.join(__dirname, 'docs/api');
const files = walk(apiRoot);
let count = 0;

files.forEach(file => {
  let content = fs.readFileSync(file, 'utf8');
  let original = content;
  const fileName = path.basename(file);
  const relPath = path.relative(apiRoot, file).replace(/\\/g, '/');

  // 1. Fix metadata/frontmatter
  if (relPath === 'index.md') {
    // API root landing page
    content = content.replace(/^---([\s\S]*?)---/, (match, p1) => {
      return `---
title: "API Reference"
sidebar_label: "Overview"
slug: /api
---`;
    });
  } else if (relPath === 'dart_lz4/index.md') {
    // Main library landing page
    content = content.replace(/^---([\s\S]*?)---/, (match, p1) => {
      return `---
title: "dart_lz4 library"
sidebar_label: "Core Library"
---`;
    });
  } else if (relPath.startsWith('guide/')) {
    // Guide pages
    content = content.replace(/^---([\s\S]*?)---/, (match, p1) => {
      let title = p1.match(/title: "([^"]+)"/)?.[1] || "Guide";
      return `---
title: "${title}"
sidebar_label: "${title}"
---`;
    });
  }

  // 2. Fix <= which breaks MDX parser when it thinks it's a JSX tag
  content = content.replace(/<=/g, '&lt;=');

  // 3. Fix { and } inside <div class="member-signature"> to avoid Acorn JS evaluation
  content = content.replace(/<div class="member-signature">([\s\S]*?)<\/div>/g, (match, p1) => {
    let fixed = p1.replace(/\{/g, '&#123;').replace(/\}/g, '&#125;');
    return `<div class="member-signature">${fixed}</div>`;
  });

  // 4. Fix VitePress <Badge> components which Docusaurus doesn't recognize
  content = content.replace(/<Badge\s+(?:type|text)="([^"]+)"\s+(?:type|text)="([^"]+)"\s*\/>/g, (match, attr1, attr2) => {
    let text = match.includes('text="') ? match.match(/text="([^"]+)"/)[1] : 'badge';
    let type = match.includes('type="') ? match.match(/type="([^"]+)"/)[1] : 'info';
    return `<span class="badge badge--${type}">${text}</span>`;
  });
  content = content.replace(/<Badge\s+text="([^"]+)"\s*\/>/g, '<span class="badge badge--info">$1</span>');
  
  // 5. Link Rewriting (Flattened)
  // Original generated links use /api/ or /guide/
  // We want them to use relative paths or /docs/api/ paths
  content = content.replace(/href="\/api\//g, 'href="/dart_lz4/docs/api/');
  content = content.replace(/\]\(\/api\//g, '](/dart_lz4/docs/api/');
  content = content.replace(/href="\/guide\//g, 'href="/dart_lz4/docs/api/guide/');
  content = content.replace(/\]\(\/guide\//g, '](/dart_lz4/docs/api/guide/');

  // Fix broken cross-links in the generator output (e.g. docs/OSSF_BEST_PRACTICES.md)
  content = content.replace(/\]\(docs\/OSSF_BEST_PRACTICES\.md\)/g, '](guide/OSSF_BEST_PRACTICES)');

  if (content !== original) {
    fs.writeFileSync(file, content);
    count++;
  }
});

console.log(`Fixed ${count} MDX files.`);
