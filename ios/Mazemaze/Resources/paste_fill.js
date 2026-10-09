// Run by the app (isolated world, `lines` is passed as an argument, never spliced into code).
// One <div> per line; text goes in with textContent only, so pasted markup is shown as text.
const out = document.getElementById("out");
if (!out || !Array.isArray(lines)) { return false; }
const frag = document.createDocumentFragment();
for (const line of lines) {
  const d = document.createElement("div");
  if (line === "") { d.className = "blank"; d.appendChild(document.createElement("br")); }
  else { d.textContent = String(line); }
  frag.appendChild(d);
}
out.replaceChildren(frag);
return true;
