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

const files = walk(path.join(__dirname, 'docs/api'));
let count = 0;
files.forEach(file => {
  let content = fs.readFileSync(file, 'utf8');
  let original = content;
  
  // Fix <= which breaks MDX parser when it thinks it's a JSX tag
  content = content.replace(/<=/g, '&lt;=');

  // Fix { and } inside <div class="member-signature"> to avoid Acorn JS evaluation
  content = content.replace(/<div class="member-signature">([\s\S]*?)<\/div>/g, (match, p1) => {
    let fixed = p1.replace(/\{/g, '&#123;').replace(/\}/g, '&#125;');
    return `<div class="member-signature">${fixed}</div>`;
  });

  // Fix VitePress <Badge> components which Docusaurus doesn't recognize
  content = content.replace(/<Badge\s+(?:type|text)="([^"]+)"\s+(?:type|text)="([^"]+)"\s*\/>/g, (match, attr1, attr2) => {
    let text = match.includes('text="') ? match.match(/text="([^"]+)"/)[1] : 'badge';
    let type = match.includes('type="') ? match.match(/type="([^"]+)"/)[1] : 'info';
    return `<span class="badge badge--${type}">${text}</span>`;
  });
  content = content.replace(/<Badge\s+text="([^"]+)"\s*\/>/g, '<span class="badge badge--info">$1</span>');
  
  // Rewrite absolute VitePress links to Docusaurus base links
  content = content.replace(/href="\/api\//g, 'href="/dart_lz4/docs/api/');
  content = content.replace(/\]\(\/api\//g, '](/dart_lz4/docs/api/');
  
  // Also, VitePress links often miss the .md extension, but Docusaurus can route them if they match the folder structure
  // However, Docusaurus validation might be strict about `#` fragments. Let's just fix the root path for now.
  
  if (content !== original) {
    fs.writeFileSync(file, content);
    count++;
  }
});

console.log(`Fixed ${count} MDX files.`);
