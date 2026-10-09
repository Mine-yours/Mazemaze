// What the paste page shows right now as plain text (without the invisible placeholders translator.js leaves).
const out = document.getElementById("out");
if (!out) { return null; }
return Array.from(out.children).map(function (d) {
  return d.classList.contains("blank") ? "" : d.textContent.replace(/​/g, "");
}).join("\n");
