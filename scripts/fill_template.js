// Fills {{NAME}} placeholders in a prompt template.
//
//   node fill_template.js <template> <output>
//
// Each {{NAME}} takes the value of the environment variable FILL_NAME, or the
// contents of the file named by FILLFILE_NAME. Values go through the environment,
// never the command line, so titles and descriptions need no quoting. Only the
// text below the template's first line that is exactly "---" is used, so a
// template can open with a comment for its maintainers. A placeholder with no
// value is left as it is, for the orchestrator to fill.
const fs = require('fs');

const [templatePath, outputPath] = process.argv.slice(2);
if (!templatePath || !outputPath) {
  console.error('usage: node fill_template.js <template> <output>');
  process.exit(2);
}

let text = fs.readFileSync(templatePath, 'utf8').replace(/\r\n/g, '\n');
const cut = text.search(/^---$/m);
if (cut >= 0) text = text.slice(cut + 4);

text = text.replace(/\{\{([A-Z_]+)\}\}/g, (placeholder, name) => {
  if (process.env['FILL_' + name] !== undefined) return process.env['FILL_' + name];
  const file = process.env['FILLFILE_' + name];
  if (file) return fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n').trim();
  return placeholder;
});

fs.writeFileSync(outputPath, text);
