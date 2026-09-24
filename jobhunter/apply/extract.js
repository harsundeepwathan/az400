() => {
  const clean = s => (s || '').replace(/\s+/g, ' ').replace(/\s*[*✱]\s*$/, ' *').trim();
  const txt = el => clean(el ? (el.innerText || el.textContent) : '');
  const visible = el => {
    const r = el.getBoundingClientRect(); const s = getComputedStyle(el);
    return (r.width > 0 || r.height > 0) && s.visibility !== 'hidden' && s.display !== 'none';
  };
  const byId = id => id ? document.getElementById(id) : null;
  const ownLabel = el => {
    if (el.id) { const l = document.querySelector(`label[for="${CSS.escape(el.id)}"]`); if (l) return txt(l); }
    const al = el.getAttribute('aria-label'); if (al) return clean(al);
    const lb = el.getAttribute('aria-labelledby');
    if (lb) return clean(lb.split(/\s+/).map(i => txt(byId(i))).join(' '));
    const wrap = el.closest('label'); if (wrap) return txt(wrap);
    return '';
  };
  const containerLabel = (el, exclude) => {
    let p = el.parentElement;
    for (let i = 0; i < 6 && p; i++, p = p.parentElement) {
      const cand = p.querySelector('legend, label, [class*="label" i], [class*="question" i], [data-ui*="label"], h3, h4, span[id]');
      if (cand && !cand.contains(el) && !(exclude || []).some(x => cand.contains(x))) return txt(cand);
    }
    return '';
  };
  const groupQuestion = inputs => {
    const first = inputs[0];
    const fs = first.closest('fieldset'); if (fs && fs.querySelector('legend')) return txt(fs.querySelector('legend'));
    const rg = first.closest('[role="radiogroup"], [role="group"]');
    if (rg) {
      const lb = rg.getAttribute('aria-labelledby'); if (lb) return clean(lb.split(/\s+/).map(i => txt(byId(i))).join(' '));
      if (rg.getAttribute('aria-label')) return clean(rg.getAttribute('aria-label'));
    }
    // Smallest ancestor holding the whole group; question = its text minus the option labels.
    let c = first.parentElement;
    while (c && !inputs.every(i => c.contains(i))) c = c.parentElement;
    for (let i = 0; i < 3 && c; i++, c = c.parentElement) {
      let t = txt(c);
      inputs.forEach(inp => { const o = ownLabel(inp); if (o) t = t.replace(o, ' '); });
      t = clean(t);
      if (t.length > 2) return t.slice(0, 400);
    }
    return '';
  };

  const fields = [];
  let n = 0;
  const stamp = el => { const id = 'f' + (n++); el.setAttribute('data-jh-id', id); return id; };
  const isReq = (el, label) => el.required || el.getAttribute('aria-required') === 'true' || /[*✱]\s*$/.test(label || '');

  const els = Array.from(document.querySelectorAll('input, textarea, select'));
  const groups = {};
  for (const el of els) {
    const type = (el.getAttribute('type') || el.tagName).toLowerCase();
    if (['hidden', 'submit', 'button', 'image', 'reset', 'search'].includes(type)) continue;
    if (type !== 'file' && !visible(el) && !(['radio', 'checkbox'].includes(type) && el.closest('label') && visible(el.closest('label')))) continue;
    if (el.disabled || el.readOnly && type !== 'file') continue;
    if ((type === 'radio' || type === 'checkbox') && el.name) {
      (groups[type + ':' + el.name] = groups[type + ':' + el.name] || []).push(el); continue;
    }
    if (el.getAttribute('role') === 'combobox' || el.getAttribute('aria-autocomplete') === 'list') {
      const label = ownLabel(el) || containerLabel(el);
      fields.push({ id: stamp(el), kind: 'combobox', label, name: el.name || el.id || '', required: isReq(el, label), options: [], multiple: false });
      continue;
    }
    const label = ownLabel(el) || containerLabel(el) || el.placeholder || el.name || '';
    const f = { id: stamp(el), label, name: el.name || el.id || '', required: isReq(el, label), options: [], multiple: false };
    if (el.tagName === 'SELECT') { f.kind = 'select'; f.multiple = el.multiple; f.options = Array.from(el.options).map(o => clean(o.text)).filter(Boolean); }
    else if (el.tagName === 'TEXTAREA') f.kind = 'textarea';
    else if (type === 'checkbox') { f.kind = 'checkbox'; f.options = [label]; }
    else if (type === 'radio') { f.kind = 'radio'; f.options = [label]; }
    else if (['email', 'tel', 'url', 'number', 'file', 'date'].includes(type)) f.kind = type;
    else f.kind = 'text';
    if (type === 'file') f.label = f.label || txt(el.closest('div'));
    fields.push(f);
  }
  for (const [key, inputs] of Object.entries(groups)) {
    const kind = key.split(':')[0];
    if (inputs.length === 1 && kind === 'checkbox') {
      const el = inputs[0]; const label = ownLabel(el) || containerLabel(el);
      fields.push({ id: stamp(el), kind, label, name: el.name, required: isReq(el, label), options: [label], multiple: false });
      continue;
    }
    const id = 'f' + (n++);
    const options = inputs.map((el, i) => { el.setAttribute('data-jh-id', id); el.setAttribute('data-jh-opt', String(i)); return ownLabel(el) || el.value; });
    const label = groupQuestion(inputs);
    fields.push({ id, kind, label, name: inputs[0].name, required: inputs.some(el => isReq(el, label)), options, multiple: kind === 'checkbox' });
  }
  return fields;
}
